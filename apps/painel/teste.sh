#!/usr/bin/env bash
# Testa o app painel JÁ NO AR: /saude, ingestão acompanhando eventos.tsv e
# proteção por login (telas devem redirecionar para o authentik). Não cria nada
# nem imprime segredos.
set -euo pipefail

RAIZ=/opt/authentik-aaa-provedor
set -a; . "$RAIZ/.env"; set +a
BASE=http://127.0.0.1:9049
falha() { echo "FALHA: $*" >&2; exit 1; }
jq_() { python3 -I -c "import sys,json;d=json.load(sys.stdin);print($1)"; }

SAUDE=$(curl -fsS --max-time 10 "$BASE/saude") || falha "painel não responde em $BASE/saude (suba com ./provedor up painel)"
[ "$(echo "$SAUDE" | jq_ 'd["status"]')" = ok ] || falha "/saude não retornou status ok"
echo "ok: /saude responde"

# Ingestão: a posição lida precisa alcançar o tamanho do arquivo (dentro do container).
CT=$(docker ps -q --filter label=com.docker.compose.project=provedor-painel --filter label=com.docker.compose.service=painel | head -1)
[ -n "$CT" ] || falha "container do painel não encontrado"
TAM=$(docker exec "$CT" stat -c %s /var/log/tacacs/eventos.tsv 2>/dev/null) || falha "eventos.tsv não visível no painel (volume provedor-tacacs-logs / app tacacs no ar?)"
ok=0
for _ in 1 2 3 4 5 6 7 8 9 10; do
  POS=$(curl -fsS --max-time 10 "$BASE/saude" | jq_ 'd["posicao"]')
  TAM=$(docker exec "$CT" stat -c %s /var/log/tacacs/eventos.tsv)
  if [ "$POS" -ge "$TAM" ] || { [ $((TAM - POS)) -lt 4096 ] && [ "$POS" -gt 0 ]; }; then ok=1; break; fi
  sleep 2
done
[ "$ok" = 1 ] || falha "ingestão atrasada: posição $POS < tamanho $TAM do eventos.tsv"
echo "ok: ingestão em dia (posição $POS de $TAM bytes)"

# Telas protegidas: sem sessão devem redirecionar (302) para /login.
for rota in / /eventos /sessoes /eventos.csv; do
  cod=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$BASE$rota")
  [ "$cod" = 302 ] || falha "$rota deveria exigir login (302), retornou $cod"
done
LOC=$(curl -s -o /dev/null -w '%{redirect_url}' --max-time 10 "$BASE/login")
case "$LOC" in "${AUTHENTIK_URL_EXTERNA:-https://100.66.80.196:9443}"/application/o/authorize/*client_id=painel-tacacs*) ;; *) falha "/login não redireciona ao authorize do authentik" ;; esac
echo "ok: telas exigem login e /login aponta para o authentik"

# O authentik conhece o provider (discovery público do app).
cod=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 "http://127.0.0.1:9000/application/o/painel-tacacs/.well-known/openid-configuration")
[ "$cod" = 200 ] || falha "authentik sem o app painel-tacacs (discovery retornou $cod); blueprint 05-painel aplicado?"
echo "ok: aplicação painel-tacacs existe no authentik"
echo "TUDO OK (painel)"
