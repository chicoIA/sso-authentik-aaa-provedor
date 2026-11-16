#!/usr/bin/env bash
# Testa o outpost RADIUS já no ar: aceite com atributos, senha errada,
# usuário fora do grupo e usuário desativado. Remove tudo que criar.
set -euo pipefail

RAIZ=/opt/authentik-aaa-provedor
set -a; . "$RAIZ/.env"; set +a
API=http://127.0.0.1:9000/api/v3
ALVO=127.0.0.1:18120
SUF="t$$$RANDOM"
G_ATTR="teste-radius-attr-$SUF"
U_OK="teste-radius-ok-$SUF"; U_FORA="teste-radius-fora-$SUF"; U_OFF="teste-radius-off-$SUF"
SENHA="$(head -c 18 /dev/urandom | base64 | tr -d '/+=')Aa1"
declare -a USERS=() ; G_ATTR_PK=""

falha() { echo "FALHA: $*" >&2; exit 1; }
command -v radclient >/dev/null || falha "radclient não encontrado (pacote freeradius-utils)"
[ -n "${AUTHENTIK_BOOTSTRAP_TOKEN:-}" ] && [ -n "${AUTHENTIK_RADIUS_SECRET:-}" ] || falha "variáveis do .env ausentes"

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

grupo_acesso=$(api GET "/core/groups/?name=radius-leitura" | jq_ "d['results'][0]['pk'] if d['results'] else ''")
[ -n "$grupo_acesso" ] || falha "grupo radius-leitura não existe (blueprint não aplicado?)"

G_ATTR_PK=$(api POST /core/groups/ "$(python3 -I -c '
import json,sys
print(json.dumps({"name":sys.argv[1],"attributes":{"radius_prioridade":10,"radius_reply":["Mikrotik-Group := full","Huawei-Exec-Privilege = 15","Service-Type := Administrative-User"]}}))' "$G_ATTR")" | jq_ "d['pk']")

criar_usuario() { # nome ativo grupos_json
  local pk
  pk=$(api POST /core/users/ "$(python3 -I -c '
import json,sys
print(json.dumps({"username":sys.argv[1],"name":sys.argv[1],"is_active":sys.argv[2]=="1","groups":json.loads(sys.argv[3])}))' "$1" "$2" "$3")" | jq_ "d['pk']")
  USERS+=("$pk")
  printf '%s' "$SENHA" | python3 -I -c 'import json,sys;print(json.dumps({"password":sys.stdin.read()}))' \
    | curl -fsS -X POST -H "Authorization: Bearer $AUTHENTIK_BOOTSTRAP_TOKEN" -H 'Content-Type: application/json' -d @- "$API/core/users/$pk/set_password/" >/dev/null
}
criar_usuario "$U_OK"   1 "[\"$grupo_acesso\",\"$G_ATTR_PK\"]"
criar_usuario "$U_FORA" 1 "[\"$G_ATTR_PK\"]"
criar_usuario "$U_OFF"  0 "[\"$grupo_acesso\",\"$G_ATTR_PK\"]"

rc() { # usuario senha -> saída do radclient (sem segredos)
  printf 'User-Name = "%s", User-Password = "%s"\n' "$1" "$2" \
    | radclient -x -t 5 -r 1 "$ALVO" auth "$AUTHENTIK_RADIUS_SECRET" 2>&1 || true
}
erros=0
ok()  { echo "OK: $*"; }
nok() { echo "FALHA: $*" >&2; erros=$((erros+1)); }

saida=$(rc "$U_OK" "$SENHA")
if grep -q "Received Access-Accept" <<<"$saida"; then
  ok "usuário válido aceito"
  grep -q 'Mikrotik-Group = "full"\|Mikrotik-Group = full\|Attr-14988\.3\|Mikrotik-Group' <<<"$saida" && ok "Mikrotik-Group presente" || nok "Mikrotik-Group ausente"
  grep -Eq 'Huawei-Exec-Privilege = 15|Attr-2011\.29' <<<"$saida" && ok "Huawei-Exec-Privilege presente" || nok "Huawei-Exec-Privilege ausente"
  grep -Eq 'Service-Type = Administrative-User' <<<"$saida" && ok "Service-Type presente" || nok "Service-Type ausente"
else
  nok "usuário válido não foi aceito"
fi

saida=$(rc "$U_OK" "senha-errada-xyz")
grep -q "Received Access-Reject" <<<"$saida" && ok "senha errada rejeitada" || nok "senha errada não foi rejeitada"
saida=$(rc "$U_FORA" "$SENHA")
grep -q "Received Access-Reject" <<<"$saida" && ok "usuário fora do grupo rejeitado" || nok "usuário fora do grupo não foi rejeitado"
saida=$(rc "$U_OFF" "$SENHA")
grep -q "Received Access-Reject" <<<"$saida" && ok "usuário desativado rejeitado" || nok "usuário desativado não foi rejeitado"

[ "$erros" -eq 0 ] || falha "$erros verificação(ões) falharam"
echo "Todos os testes do radius passaram."
