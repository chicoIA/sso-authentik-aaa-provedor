#!/usr/bin/env bash
# Testa o app authentik já no ar. Não imprime segredos.
set -euo pipefail

ENV=/opt/authentik-aaa-provedor/.env
[[ -r $ENV ]] || { echo "FALHA: $ENV não encontrado" >&2; exit 1; }
# Lê só a variável necessária (sem "source": o .env pode ter valores com símbolos).
TOKEN=$(grep -m1 '^AUTHENTIK_BOOTSTRAP_TOKEN=' "$ENV" | cut -d= -f2- | sed -e "s/^[\"']//" -e "s/[\"']\$//")
[[ -n $TOKEN && $TOKEN != "<"* ]] || { echo "FALHA: AUTHENTIK_BOOTSTRAP_TOKEN vazio no .env" >&2; exit 1; }
BASE=http://127.0.0.1:9000
falhas=0
falha() { echo "FALHA: $*" >&2; falhas=$((falhas + 1)); }

for p in live ready; do
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$BASE/-/health/$p/" || true)
  if [[ $code == 200 || $code == 204 ]]; then echo "ok: /-/health/$p/ ($code)"; else falha "/-/health/$p/ devolveu $code"; fi
done

api=$(mktemp); trap 'rm -f "$api"' EXIT
code=$(curl -s -o "$api" -w '%{http_code}' --max-time 20 -H "Authorization: Bearer $TOKEN" "$BASE/api/v3/core/users/me/" || true)
if [[ $code == 200 ]]; then echo "ok: API v3 aceita o token"; else falha "API v3 com o token devolveu $code"; fi

code=$(curl -s -o "$api" -w '%{http_code}' --max-time 30 -H "Authorization: Bearer $TOKEN" "$BASE/api/v3/managed/blueprints/?page_size=200" || true)
if [[ $code == 200 ]]; then
  python3 - "$api" <<'PY' || falhas=$((falhas + 1))
import json, sys
itens = [b for b in json.load(open(sys.argv[1]))["results"] if "provedor" in (b.get("path") or "")]
if not itens:
    print("FALHA: nenhum blueprint provedor registrado (montagens/descoberta?)", file=sys.stderr); sys.exit(1)
ruins = [b for b in itens if b.get("status") != "successful"]
for b in ruins:
    print(f"FALHA: blueprint {b['path']} status={b.get('status')}", file=sys.stderr)
print(f"ok: {len(itens) - len(ruins)}/{len(itens)} blueprints provedor com status successful")
sys.exit(1 if ruins else 0)
PY
else
  falha "lista de blueprints devolveu $code"
fi

echo "Memória dos containers:"
for c in authentik-postgres authentik-server authentik-worker; do
  id=$(docker ps -q --filter "label=com.docker.compose.project=provedor-authentik" --filter "label=com.docker.compose.service=$c")
  if [[ -z $id ]]; then falha "container $c não está rodando"; continue; fi
  docker stats --no-stream --format "  {{.Name}}: {{.MemUsage}} ({{.MemPerc}})" "$id"
done

if ((falhas)); then echo "RESULTADO: $falhas falha(s)" >&2; exit 1; fi
echo "RESULTADO: authentik OK"
