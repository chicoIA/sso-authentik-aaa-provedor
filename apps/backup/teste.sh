#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
BACKUP_DIR="$T" ./backup.sh completo >"$T/.log" 2>&1 || { echo "FALHA: backup.sh completo"; sed 's/password=.*//' "$T/.log" | tail -20; exit 1; }
D="$(cat "$T/.ultimo")"
[ -f ../../.env ] && { [ -s "$D/env.bak" ] || { echo "FALHA: falta env.bak"; exit 1; }; }
for f in apps.tar.gz MANIFESTO.sha256; do [ -s "$D/$f" ] || { echo "FALHA: falta $f"; exit 1; }; done
(cd "$D" && sha256sum -c MANIFESTO.sha256 >/dev/null) || { echo "FALHA: sha256"; exit 1; }
for g in "$D"/*.gz; do gzip -t "$g" || { echo "FALHA: gzip -t $g"; exit 1; }; done
[ ! -e "$D/radius.sql.gz" ] || ! zcat "$D/radius.sql.gz" | grep -q 'CREATE TABLE `nas`' || { echo "FALHA: tabela nas copiada sem BACKUP_NAS=sim"; exit 1; }
./backup.sh listar >/dev/null
echo "OK: backup testado ($(ls "$D" | wc -l) arquivos)"
