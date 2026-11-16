#!/usr/bin/env bash
# Teste do cálculo de atributos numa MariaDB descartável, em rede Docker isolada
# (sem network host, sem portas publicadas). Não toca no banco de produção.
set -euo pipefail
DIR=$(cd "$(dirname "$0")/.." && pwd)
RAIZ=$(cd "$DIR/../.." && pwd)
REDE="provedor-migracao-teste-$$"
DB="$REDE-db"
limpar() { docker rm -f "$DB" >/dev/null 2>&1 || true; docker network rm "$REDE" >/dev/null 2>&1 || true; }
trap limpar EXIT

docker build -q -t provedor/migracao:local "$DIR" >/dev/null
docker network create --internal "$REDE" >/dev/null
docker run -d --name "$DB" --network "$REDE" --memory 256m \
    -e MARIADB_ROOT_PASSWORD=raiz-teste -e MARIADB_DATABASE=radius \
    -v "$RAIZ/tests/daloradius_exemplo.sql:/docker-entrypoint-initdb.d/01.sql:ro" \
    mariadb:10.11 >/dev/null
for _ in $(seq 1 60); do
    docker exec "$DB" mariadb -uroot -praiz-teste radius -e 'SELECT 1 FROM radcheck LIMIT 1' >/dev/null 2>&1 && break
    sleep 2
done
docker run --rm --network "$REDE" --memory 128m --entrypoint python \
    -v "$DIR/tests:/tests:ro" -v "$DIR/../radius/blueprints:/blueprint-radius:ro" \
    -e DALO_DB_HOST="$DB" -e DALO_DB_USER=root -e DALO_DB_PASS=raiz-teste \
    provedor/migracao:local /tests/teste_calculo.py
