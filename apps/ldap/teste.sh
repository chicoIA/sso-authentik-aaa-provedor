#!/usr/bin/env bash
# Testa o outpost LDAP já no ar: bind da conta de serviço, bind de usuário
# temporário (com memberOf), senha errada, usuário fora do grupo.
# Remove tudo que criar. Nunca imprime senhas.
set -euo pipefail

RAIZ=/opt/authentik-aaa-provedor
set -a; . "$RAIZ/.env"; set +a
API=http://127.0.0.1:9000/api/v3
BASE="${AUTHENTIK_LDAP_BASE_DN:-dc=ldap,dc=provedor,dc=com,dc=br}"
ALVO=ldap://ldap-outpost:3389
IMG=provedor-ldap-cliente:teste
SUF="t$$$RANDOM"
U_OK="teste-ldap-ok-$SUF"; U_FORA="teste-ldap-fora-$SUF"
SENHA="$(head -c 18 /dev/urandom | base64 | tr -d '/+=')Aa1"
USERS=()

falha() { echo "FALHA: $*" >&2; exit 1; }
[ -n "${AUTHENTIK_BOOTSTRAP_TOKEN:-}" ] && [ -n "${LDAP_SERVICO_SENHA:-}" ] || falha "variáveis do .env ausentes (AUTHENTIK_BOOTSTRAP_TOKEN, LDAP_SERVICO_SENHA)"

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
}
trap limpar EXIT

docker ps --format '{{.Names}}' | grep -q 'ldap-outpost' || falha "container ldap-outpost não está no ar"

# Imagem descartável com ldapsearch (construída uma vez).
if ! docker image inspect "$IMG" >/dev/null 2>&1; then
  printf 'FROM alpine:3.20\nRUN apk add --no-cache openldap-clients\n' | docker build -q -t "$IMG" - >/dev/null \
    || falha "não consegui construir a imagem do cliente LDAP"
fi

# ldap_bind DN SENHA [FILTRO ATRIBUTO...] -> saída do ldapsearch (a senha vai por variável de ambiente)
ldap() {
  local dn=$1 senha=$2; shift 2
  docker run --rm --network provedor -e LDAP_PW="$senha" "$IMG" \
    sh -c 'dn=$1; shift; ldapsearch -x -LLL -o nettimeout=10 -H "$0" -D "$dn" -w "$LDAP_PW" "$@"' \
    "$ALVO" "$dn" "$@" 2>&1
}

grupo=$(api GET "/core/groups/?name=ldap-acesso" | jq_ "d['results'][0]['pk'] if d['results'] else ''")
[ -n "$grupo" ] || falha "grupo ldap-acesso não existe (blueprint não aplicado?)"

criar_usuario() { # nome grupos_json
  local pk
  pk=$(api POST /core/users/ "$(python3 -I -c '
import json,sys
print(json.dumps({"username":sys.argv[1],"name":sys.argv[1],"is_active":True,"groups":json.loads(sys.argv[2])}))' "$1" "$2")" | jq_ "d['pk']")
  USERS+=("$pk")
  printf '%s' "$SENHA" | python3 -I -c 'import json,sys;print(json.dumps({"password":sys.stdin.read()}))' \
    | curl -fsS -X POST -H "Authorization: Bearer $AUTHENTIK_BOOTSTRAP_TOKEN" -H 'Content-Type: application/json' -d @- "$API/core/users/$pk/set_password/" >/dev/null
}
criar_usuario "$U_OK" "[\"$grupo\"]"
criar_usuario "$U_FORA" "[]"
sleep 2  # cache do outpost (bind/search "cached")

DN_SERV="cn=ldap-servico,ou=users,$BASE"
DN_OK="cn=$U_OK,ou=users,$BASE"
DN_FORA="cn=$U_FORA,ou=users,$BASE"

# 1) conta de serviço: bind + pesquisa do diretório inteiro encontra o usuário de teste
saida=$(ldap "$DN_SERV" "$LDAP_SERVICO_SENHA" -b "ou=users,$BASE" "(cn=$U_OK)" cn memberOf) \
  || falha "bind da conta de serviço ldap-servico falhou (senha/permissão/grupo?)"
echo "$saida" | grep -qi "^cn: $U_OK" || falha "conta de serviço não enxerga o usuário de teste (falta search_full_directory?)"
echo "$saida" | grep -qi "^memberOf: cn=ldap-acesso,ou=groups,$BASE" || falha "memberOf ldap-acesso ausente no usuário de teste"
echo "OK: conta de serviço faz bind, pesquisa o diretório e memberOf correto"

# 2) usuário do grupo: bind funciona
ldap "$DN_OK" "$SENHA" -b "$DN_OK" -s base cn >/dev/null || falha "bind do usuário de teste (em ldap-acesso) falhou"
echo "OK: bind de usuário em ldap-acesso"

# 3) senha errada: bind deve falhar
if ldap "$DN_OK" "${SENHA}x" -b "$DN_OK" -s base cn >/dev/null; then
  falha "bind com senha errada foi ACEITO"
fi
echo "OK: senha errada rejeitada"

# 4) usuário fora de ldap-acesso: bind deve falhar
if ldap "$DN_FORA" "$SENHA" -b "$DN_FORA" -s base cn >/dev/null; then
  falha "usuário fora de ldap-acesso conseguiu bind"
fi
echo "OK: usuário fora de ldap-acesso rejeitado"

echo "Teste LDAP concluído com sucesso."
