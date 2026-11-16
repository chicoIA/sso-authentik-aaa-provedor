#!/usr/bin/env bash
# Testa o app tacacs JÁ NO AR: cria usuários temporários no authentik (API),
# faz authen/author/acct TACACS+ de verdade (cliente python num container
# descartável na rede provedor) e confere as linhas em eventos.tsv.
# Remove tudo que criar. Nunca imprime chave nem senhas.
set -euo pipefail

RAIZ=/opt/authentik-aaa-provedor
set -a; . "$RAIZ/.env"; set +a
API=http://127.0.0.1:9000/api/v3
IMG=provedor-tacacs-cliente:teste
SUF="t$$$RANDOM"
U_LEIT="teste-tacacs-leit-$SUF"; U_ADMIN="teste-tacacs-adm-$SUF"; U_SEM="teste-tacacs-sem-$SUF"; U_BGP="teste-tacacs-bgp-$SUF"; U_OPER="teste-tacacs-oper-$SUF"
SENHA="$(head -c 18 /dev/urandom | base64 | tr -d '/+=')Aa1"
USERS=()
TMP="$(mktemp -d)"
ORIGEM=203.0.113.7

falha() { echo "FALHA: $*" >&2; exit 1; }
[ -n "${AUTHENTIK_BOOTSTRAP_TOKEN:-}" ] && [ -n "${TACACS_KEY:-}" ] || falha "variáveis do .env ausentes (AUTHENTIK_BOOTSTRAP_TOKEN, TACACS_KEY)"

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
  [ -n "${TMP:-}" ] && [ -d "$TMP" ] && rm -r -- "$TMP" 2>/dev/null || true
}
trap limpar EXIT

# ---------- pré-requisitos ----------
CONT=$(docker ps -q --filter label=com.docker.compose.project=provedor-tacacs --filter label=com.docker.compose.service=tacacs | head -n1)
[ -n "$CONT" ] || falha "container tacacs não está no ar (./provedor up tacacs)"
docker port "$CONT" 4949/tcp 2>/dev/null | grep -q ':49$' || falha "porta 49/tcp do host não está publicada para o tacacs"
docker exec "$CONT" test -f /var/log/tacacs/eventos.tsv || falha "eventos.tsv não existe no volume de logs"

if ! docker image inspect "$IMG" >/dev/null 2>&1; then
  printf 'FROM python:3.12-alpine\nRUN pip install --no-cache-dir tacacs_plus==2.6\n' | docker build -q -t "$IMG" - >/dev/null \
    || falha "não consegui construir a imagem do cliente TACACS+"
fi

# ---------- usuários temporários ----------
grupo_pk() {
  api GET "/core/groups/?name=$1" | jq_ "d['results'][0]['pk'] if d['results'] else ''"
}
G_LEIT=$(grupo_pk tacacs-leitura); G_ADMIN=$(grupo_pk tacacs-admin); G_BGP=$(grupo_pk tacacs-admin-or-hosts-leitura); G_OPER=$(grupo_pk tacacs-operador)
[ -n "$G_BGP" ] || falha "grupo tacacs-admin-or-hosts-leitura não existe (blueprint 04-tacacs não aplicado?)"
[ -n "$G_LEIT" ] && [ -n "$G_ADMIN" ] || falha "grupos tacacs-leitura/tacacs-admin não existem (blueprint 04-tacacs não aplicado?)"

criar_usuario() { # nome grupos_json
  local pk
  pk=$(api POST /core/users/ "$(python3 -I -c '
import json,sys
print(json.dumps({"username":sys.argv[1],"name":sys.argv[1],"is_active":True,"groups":json.loads(sys.argv[2])}))' "$1" "$2")" | jq_ "d['pk']")
  USERS+=("$pk")
  printf '%s' "$SENHA" | python3 -I -c 'import json,sys;print(json.dumps({"password":sys.stdin.read()}))' \
    | curl -fsS -X POST -H "Authorization: Bearer $AUTHENTIK_BOOTSTRAP_TOKEN" -H 'Content-Type: application/json' -d @- "$API/core/users/$pk/set_password/" >/dev/null
}
criar_usuario "$U_LEIT" "[\"$G_LEIT\"]"
criar_usuario "$U_ADMIN" "[\"$G_ADMIN\"]"
criar_usuario "$U_SEM" "[]"
criar_usuario "$U_BGP" "[\"$G_BGP\"]"
criar_usuario "$U_OPER" "[\"$G_OPER\"]"

# ---------- cliente TACACS+ ----------
cat > "$TMP/cliente.py" <<'PY'
import os, sys
from tacacs_plus.client import TACACSClient
from tacacs_plus.flags import TAC_PLUS_ACCT_FLAG_START, TAC_PLUS_ACCT_FLAG_STOP

ORIGEM, PORTA = os.environ["T_ORIGEM"], "vty0"
c = TACACSClient(os.environ["T_HOST"], int(os.environ["T_PORT"]), os.environ["T_KEY"], timeout=10)
senha = os.environ["T_PW"]

def args(cmd):
    a = [b"service=shell"]
    if cmd:
        p = cmd.split()
        a.append(("cmd=" + p[0]).encode())
        a += [("cmd-arg=" + x).encode() for x in p[1:]] + [b"cmd-arg=<cr>"]
    else:
        a.append(b"cmd*")
    return a

def authen(u, pw):
    return c.authenticate(u, pw, rem_addr=ORIGEM, port=PORTA).valid
def author(u, cmd):
    r = c.authorize(u, arguments=args(cmd), rem_addr=ORIGEM, port=PORTA)
    return r.valid, [x.decode() for x in r.arguments]
def author_junos(u):  # Juniper: pede o usuário-modelo local (local-user-name)
    r = c.authorize(u, arguments=[b"service=junos-exec"], rem_addr=ORIGEM, port=PORTA)
    return r.valid, [x.decode() for x in r.arguments]
def acct(u, fl, cmd):
    return c.account(u, fl, arguments=args(cmd) + [b"task_id=1"], rem_addr=ORIGEM, port=PORTA).valid
def sai(k, v):
    print("%s=%s" % (k, 1 if v is True else 0 if v is False else v))

modo, leit, adm, sem, bgp, oper = sys.argv[1:7]
try:
    if modo == "sonda":
        sai("sonda", authen(leit, senha)); sys.exit(0)
    sai("authen_leit_ok", authen(leit, senha))
    sai("authen_leit_errada", authen(leit, senha + "x"))
    sai("authen_adm_ok", authen(adm, senha))
    sai("authen_sem_grupo", authen(sem, senha))
    # O cliente de teste (rede do Docker) não está no conjunto bgp: admin.
    sai("authen_bgp_fora", authen(bgp, senha))
    v, a = author(leit, "");                        sai("author_leit_exec", v); sai("author_leit_priv", "priv-lvl=1" in a)
    v, a = author(leit, "show version");            sai("author_leit_show", v)
    v, a = author(leit, "display ip routing-table"); sai("author_leit_display", v)
    v, a = author(leit, "configure terminal");      sai("author_leit_conf", v)
    v, a = author(adm, "");                         sai("author_adm_exec", v); sai("author_adm_priv", "priv-lvl=15" in a)
    v, a = author(adm, "configure terminal");       sai("author_adm_conf", v)
    v, a = author(oper, "");                        sai("author_oper_priv", v and "priv-lvl=2" in a)
    v, a = author(oper, "interface ten-gigabit-ethernet 1/1/3"); sai("author_oper_conf", v)
    v, a = author(oper, "aaa user teste");          sai("author_oper_aaa", v)
    v, a = author(oper, "request system reboot");   sai("author_oper_reboot", v)
    v, a = author(bgp, "");                         sai("author_bgp_fora_priv", v and "priv-lvl=15" in a)
    v, a = author(bgp, "configure terminal");       sai("author_bgp_fora_conf", v)
    v, a = author_junos(leit);                      sai("junos_leit", v and "local-user-name=tacacs-leitura" in a)
    v, a = author_junos(adm);                       sai("junos_adm", v and "local-user-name=tacacs-admin" in a)
    sai("acct_start", acct(leit, TAC_PLUS_ACCT_FLAG_START, "show version"))
    sai("acct_stop", acct(leit, TAC_PLUS_ACCT_FLAG_STOP, "show version"))
except Exception as e:
    print("erro=%s" % type(e).__name__)
    sys.exit(2)
PY

cliente() { # modo
  T_KEY="$TACACS_KEY" T_PW="$SENHA" docker run --rm --network provedor \
    -v "$TMP/cliente.py:/cliente.py:ro" \
    -e T_KEY -e T_PW -e T_HOST=tacacs -e T_PORT=4949 -e T_ORIGEM="$ORIGEM" \
    "$IMG" python /cliente.py "$1" "$U_LEIT" "$U_ADMIN" "$U_SEM" "$U_BGP" "$U_OPER" 2>&1
}

# O outpost LDAP (modo cached) leva alguns segundos para enxergar usuários novos.
ok=0
for _ in $(seq 1 15); do
  if [ "$(cliente sonda | tr -d '\r')" = "sonda=1" ]; then ok=1; break; fi
  sleep 2
done
[ "$ok" = 1 ] || falha "authentication do usuário temporário (tacacs-leitura) nunca passou: confira o app ldap, a conta ldap-servico e a TACACS_KEY"

RES="$(cliente completo | tr -d '\r')"
espera() { # chave valor mensagem
  echo "$RES" | grep -qx "$1=$2" || falha "$3 (esperado $1=$2; recebido: $(echo "$RES" | grep "^$1=" || echo "$RES" | head -n3))"
  echo "OK: $3"
}
espera authen_leit_ok 1 "authen: usuário em tacacs-leitura entra"
espera authen_leit_errada 0 "authen: senha errada é negada"
espera authen_adm_ok 1 "authen: usuário em tacacs-admin entra"
espera authen_sem_grupo 0 "authen: usuário sem grupo tacacs é negado"
espera authen_bgp_fora 1 "authen: tacacs-admin-or-hosts-leitura entra fora do conjunto bgp"
espera author_leit_exec 1 "author: shell da leitura permitido"
espera author_leit_priv 1 "author: leitura recebe priv-lvl=1"
espera author_leit_show 1 "author: 'show version' permitido para leitura"
espera author_leit_display 1 "author: 'display ...' permitido para leitura"
espera author_leit_conf 0 "author: 'configure terminal' negado para leitura"
espera author_adm_exec 1 "author: shell do admin permitido"
espera author_adm_priv 1 "author: admin recebe priv-lvl=15"
espera author_adm_conf 1 "author: 'configure terminal' permitido para admin"
espera author_oper_priv 1 "author: operador recebe priv-lvl=2 (Huawei: nível de configuração)"
espera author_oper_conf 1 "author: operador configura interface (Datacom)"
espera author_oper_aaa 0 "author: 'aaa ...' negado para operador"
espera author_oper_reboot 0 "author: 'request system reboot' negado para operador"
espera author_bgp_fora_priv 1 "author: tacacs-admin-or-hosts-leitura recebe priv-lvl=15 fora do conjunto bgp"
espera author_bgp_fora_conf 1 "author: tacacs-admin-or-hosts-leitura configura fora do conjunto bgp"
espera junos_leit 1 "author: Juniper (junos-exec) leitura recebe local-user-name=tacacs-leitura"
espera junos_adm 1 "author: Juniper (junos-exec) admin recebe local-user-name=tacacs-admin"
espera acct_start 1 "acct: start aceito"
espera acct_stop 1 "acct: stop aceito"

# ---------- eventos.tsv ----------
sleep 1
EV="$(docker exec "$CONT" cat /var/log/tacacs/eventos.tsv | grep -F -e "$U_LEIT" -e "$U_ADMIN" -e "$U_SEM" || true)"
[ -n "$EV" ] || falha "nenhuma linha dos usuários de teste em eventos.tsv"

# Formato: 8 campos separados por TAB, data ISO 8601 no início.
echo "$EV" | awk -F'\t' -v re='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}([.][0-9]+)?([+-][0-9]{2}:[0-9]{2}|Z)$' \
  'NF != 8 || $1 !~ re || $2 !~ /^(authen|author|acct)$/ { exit 1 }' \
  || falha "linha de eventos.tsv fora do formato do contrato (8 campos TAB, data ISO 8601, tipo authen|author|acct)"
echo "OK: eventos.tsv no formato do contrato"

linha() { # tipo usuario resultado detalhe
  echo "$EV" | awk -F'\t' -v t="$1" -v u="$2" -v r="$3" -v d="$4" -v o="$ORIGEM" \
    '$2 == t && $4 == u && $6 == o && $7 == r && ($8 == d || d == "*") { f = 1 } END { exit f ? 0 : 1 }'
}
conferir() { linha "$1" "$2" "$3" "$4" || falha "evento ausente em eventos.tsv: tipo=$1 usuario=$2 resultado=$3 detalhe=$4"; }
conferir authen "$U_LEIT" permitido "*"
conferir authen "$U_LEIT" negado "*"
conferir authen "$U_SEM" negado "*"
conferir author "$U_LEIT" permitido "show version"
conferir author "$U_LEIT" negado "configure terminal"
conferir author "$U_ADMIN" permitido "configure terminal"
conferir acct "$U_LEIT" start "show version"
conferir acct "$U_LEIT" stop "show version"
echo "OK: eventos authen/author/acct registrados com permitido/negado e start/stop"

echo "Teste TACACS+ concluído com sucesso."
