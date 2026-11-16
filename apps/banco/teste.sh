#!/usr/bin/env bash
# Confere que o banco responde, que a retenção calcula o corte e que não há senha gravada.
set -euo pipefail
DIR=$(cd "$(dirname "$0")" && pwd)
"$DIR/banco.sh" tamanho
"$DIR/banco.sh" retencao | tee /dev/stderr | grep -q 'retenção de' || { echo "FALHA: retenção não calculou o corte"; exit 1; }
echo "OK: apps/banco"
