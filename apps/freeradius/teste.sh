#!/usr/bin/env bash
# Testa o FreeRADIUS (app freeradius) JÁ NO AR, ponta a ponta com o authentik:
# usuário temporário (criado pela API) -> radclient em 127.0.0.1:FR_PORTA_AUTH com
# FR_SEGREDO_LOCAL -> proxy -> outpost -> authentik. Verifica aceite com atributos,
# 2o pedido vindo do cache (log), senha errada, usuário desativado, CHAP (legado) e
# accounting (só se FR_GRAVAR_SQL=nao). Remove tudo que criar e nunca imprime senhas.
set -euo pipefail

RAIZ=/opt/authentik-aaa-provedor
set -a; . "$RAIZ/.env"; set +a
API=http://127.0.0.1:9000/api/v3
PORTA="${FR_PORTA_AUTH:-11812}"
PORTA_ACCT="${FR_PORTA_ACCT:-11813}"
ALVO="127.0.0.1:$PORTA"
SUF="t$$$RANDOM"
G_ATTR="teste-fr-attr-$SUF"
U_OK="teste-fr-ok-$SUF"; U_OFF="teste-fr-off-$SUF"; U_CHAP="teste-fr-chap-$SUF"
SENHA="$(head -c 18 /dev/urandom | base64 | tr -d '/+=')Aa1"
declare -a USERS=(); G_ATTR_PK=""

falha() { echo "FALHA: $*" >&2; exit 1; }
command -v radclient >/dev/null || falha "radclient não encontrado (pacote freeradius-utils)"
[ -n "${AUTHENTIK_BOOTSTRAP_TOKEN:-}" ] && [ -n "${FR_SEGREDO_LOCAL:-}" ] || falha "variáveis do .env ausentes (AUTHENTIK_BOOTSTRAP_TOKEN, FR_SEGREDO_LOCAL)"

CID=$(docker ps -q --filter label=com.docker.compose.project=provedor-freeradius \
        --filter label=com.docker.compose.service=freeradius | head -1)
[ -n "$CID" ] || falha "container freeradius não está rodando (./provedor up freeradius)"

api() { # metodo caminho [json]
  local m=$1 p=$2; shift 2
  if [ $# -gt 0 ]; then
    curl -fsS -X "$m" -H "Authorization: Bearer $AUTHENTIK_BOOTSTRAP_TOKEN" -H 'Content-Type: application/json' -d "$1" "$API$p"
  else
    curl -fsS -X "$m" -H "Authorization: Bearer $AUTHENTIK_BOOTSTRAP_TOKEN" "$API$p"
  fi
}
jq_() { python3 -I -c "import sys,json;d=json.load(sys.stdin);print($1)"; }

limpar() {
  local pk
  for pk in "${USERS[@]:-}"; do [ -n "$pk" ] && api DELETE "/core/users/$pk/" >/dev/null 2>&1 || true; done
  [ -n "$G_ATTR_PK" ] && api DELETE "/core/groups/$G_ATTR_PK/" >/dev/null 2>&1 || true
}
trap limpar EXIT

# O servidor responde ao Status-Server?
echo 'Message-Authenticator = 0x00' | radclient -r 2 -t 3 "$ALVO" status "$FR_SEGREDO_LOCAL" >/dev/null 2>&1 \
  || falha "FreeRADIUS não responde em $ALVO (docker compose -p provedor-freeradius logs freeradius)"

grupo_acesso=$(api GET "/core/groups/?name=radius-leitura" | jq_ "d['results'][0]['pk'] if d['results'] else ''")
[ -n "$grupo_acesso" ] || falha "grupo radius-leitura não existe (app radius não aplicado?)"

G_ATTR_PK=$(api POST /core/groups/ "$(python3 -I -c '
import json,sys
print(json.dumps({"name":sys.argv[1],"attributes":{"radius_prioridade":10,"radius_reply":["Mikrotik-Group := full","Huawei-Exec-Privilege = 15","Service-Type := Administrative-User"]}}))' "$G_ATTR")" | jq_ "d['pk']")

criar_usuario() { # nome ativo grupos_json
  local pk
  pk=$(api POST /core/users/ "$(python3 -I -c '
import json,sys
print(json.dumps({"username":sys.argv[1],"name":sys.argv[1],"is_active":sys.argv[2]=="1","groups":json.loads(sys.argv[3])}))' "$1" "$2" "$3")" | jq_ "d['pk']")
  USERS+=("$pk")
  printf '%s' "$SENHA" | python3 -I -c 'import sys,json;print(json.dumps({"password":sys.stdin.read()}))' \
    | curl -fsS -X POST -H "Authorization: Bearer $AUTHENTIK_BOOTSTRAP_TOKEN" -H 'Content-Type: application/json' -d @- "$API/core/users/$pk/set_password/" >/dev/null
}
criar_usuario "$U_OK"  1 "[\"$grupo_acesso\",\"$G_ATTR_PK\"]"
criar_usuario "$U_OFF" 0 "[\"$grupo_acesso\",\"$G_ATTR_PK\"]"

# A saída do radclient -x ecoa a senha do pedido: fica só na variável e nunca é impressa.
rc() { # usuario senha
  printf 'User-Name = "%s", User-Password = "%s"\n' "$1" "$2" \
    | radclient -x -t 10 -r 2 "$ALVO" auth "$FR_SEGREDO_LOCAL" 2>&1 || true
}
tem_log() { # espera até ~5s o docker entregar a linha de log
  local l
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    l=$(docker logs --since 15m "$CID" 2>&1 || true)
    grep -qF -- "$1" <<<"$l" && return 0
    sleep 0.5
  done
  return 1
}

erros=0
ok()  { echo "OK: $*"; }
nok() { echo "FALHA: $*" >&2; erros=$((erros+1)); }
atributos() { # saída do radclient
  grep -Eq 'Mikrotik-Group = "?full|Attr-14988\.3' <<<"$1" && ok "Mikrotik-Group presente" || nok "Mikrotik-Group ausente"
  grep -Eq 'Huawei-Exec-Privilege = 15|Attr-2011\.29' <<<"$1" && ok "Huawei-Exec-Privilege presente" || nok "Huawei-Exec-Privilege ausente"
  grep -q 'Service-Type = Administrative-User' <<<"$1" && ok "Service-Type presente" || nok "Service-Type ausente"
}

# 1) primeiro pedido: vai ao authentik
saida=$(rc "$U_OK" "$SENHA")
if grep -q 'Received Access-Accept' <<<"$saida"; then
  ok "usuário válido aceito (via authentik)"; atributos "$saida"
else
  nok "usuário válido não foi aceito: $(grep -E 'Access-|No reply|Reply-Message' <<<"$saida" | head -3)"
fi
tem_log "usuario=$U_OK proto=pap origem=authentik resultado=Access-Accept" \
  && ok "log: origem=authentik" || nok "log sem origem=authentik para $U_OK"

# 2) segundo pedido: vem do cache
saida=$(rc "$U_OK" "$SENHA")
if grep -q 'Received Access-Accept' <<<"$saida"; then
  ok "2o pedido aceito"; atributos "$saida"
else
  nok "2o pedido não foi aceito"
fi
tem_log "usuario=$U_OK proto=pap origem=cache resultado=Access-Accept" \
  && ok "log: 2o pedido veio do cache" || nok "log sem origem=cache para $U_OK (cache desligado?)"

# 3) senha errada: Reject, e não pode aproveitar o cache da senha certa
saida=$(rc "$U_OK" "senha-errada-xyz")
grep -q 'Received Access-Reject' <<<"$saida" && ok "senha errada rejeitada" || nok "senha errada não foi rejeitada"
tem_log "usuario=$U_OK proto=pap origem=authentik resultado=Access-Reject" \
  && ok "log: recusa registrada" || nok "log sem a recusa de $U_OK"

# 4) desativado: Reject
saida=$(rc "$U_OFF" "$SENHA")
grep -q 'Received Access-Reject' <<<"$saida" && ok "usuário desativado rejeitado" || nok "usuário desativado não foi rejeitado"

# 5) CHAP (modo legado pelo SQL) com usuário que não existe no daloRADIUS: Reject + log
saida=$(printf 'User-Name = "%s", CHAP-Password = "%s"\n' "$U_CHAP" "$SENHA" \
  | radclient -x -t 10 -r 2 "$ALVO" auth "$FR_SEGREDO_LOCAL" 2>&1 || true)
grep -q 'Received Access-Reject' <<<"$saida" && ok "CHAP de usuário desconhecido rejeitado" || nok "CHAP não foi rejeitado"
if [ "${FR_CHAP_LEGADO:-sim}" = sim ]; then
  tem_log "LEGADO-CHAP usuario=$U_CHAP" && ok "log LEGADO-CHAP registrado" || nok "log LEGADO-CHAP ausente"
else
  tem_log "CHAP-RECUSADO usuario=$U_CHAP" && ok "log CHAP-RECUSADO registrado" || nok "log CHAP-RECUSADO ausente"
fi

# 6) accounting: só com FR_GRAVAR_SQL=nao (com sim gravaria no radacct de produção)
if [ "${FR_GRAVAR_SQL:-nao}" = nao ]; then
  saida=$(printf 'User-Name = "%s", Acct-Status-Type = Start, Acct-Session-Id = "%s"\n' "$U_OK" "$SUF" \
    | radclient -t 5 -r 2 "127.0.0.1:$PORTA_ACCT" acct "$FR_SEGREDO_LOCAL" 2>&1 || true)
  grep -q 'Accounting-Response' <<<"$saida" && ok "accounting respondido" || nok "accounting sem resposta"
  tem_log "usuario=$U_OK tipo=Start" && ok "log: accounting registrado (sem gravar no banco)" || nok "log de accounting ausente"
else
  echo "-- FR_GRAVAR_SQL=sim: teste de accounting pulado (gravaria em radacct de produção)"
fi

# nenhuma senha de teste no log do container
if docker logs --since 15m "$CID" 2>&1 | grep -qF -- "$SENHA"; then nok "a senha de teste apareceu no log do container"; else ok "senha não aparece no log"; fi

[ "$erros" -eq 0 ] || falha "$erros verificação(ões) falharam"
echo "Todos os testes do freeradius passaram."
