#!/usr/bin/env bash
# Testes ISOLADOS (não precisam do ambiente no ar e não tocam na produção):
# cada um cria sua própria rede Docker, sem portas no host, e remove tudo no fim.
#   - apps/freeradius/teste-isolado.sh   FreeRADIUS + MariaDB de exemplo + "authentik falso"
#   - apps/migracao/tests/teste_unitario.sh  cálculo de atributos daloRADIUS -> authentik
# Entrada comum: tests/daloradius_exemplo.sql (banco daloRADIUS fictício).
# Os testes do ambiente JÁ NO AR são: ./provedor teste <app|base|todos>
set -euo pipefail
RAIZ="$(cd "$(dirname "$0")/.." && pwd)"
falhas=()
for t in apps/freeradius/teste-isolado.sh apps/migracao/tests/teste_unitario.sh; do
    echo "===================== $t"
    if "$RAIZ/$t"; then echo "OK: $t"; else falhas+=("$t"); echo "FALHA: $t"; fi
done
if [ "${#falhas[@]}" -gt 0 ]; then
    echo "FALHA: ${falhas[*]}" >&2
    exit 1
fi
echo "OK: testes isolados"
