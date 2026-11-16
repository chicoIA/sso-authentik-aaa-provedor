#!/usr/bin/env bash
# Testa o app migracao JÁ NO AR (authentik rodando): compara usuário a usuário o
# resultado esperado do daloRADIUS com o que está no authentik e, se o outpost
# RADIUS estiver no ar, faz o login real de cada usuário ativo. Falha (!=0) se houver divergência.
# MIGRACAO_TESTE_RADIUS=nao  pula o login real. Não imprime senhas, não grava nada.
set -euo pipefail
RAIZ=/opt/authentik-aaa-provedor
ENV="$RAIZ/.env"
[ -f "$ENV" ] || { echo "FALHA: $ENV não existe (rode ./provedor preparar)"; exit 1; }
CF=(docker compose -p provedor-migracao --env-file "$ENV" -f "$RAIZ/apps/migracao/compose.yml" --profile ferramenta)

valor() { grep -E "^$1=" "$ENV" | tail -n1 | cut -d= -f2- || true; }
[ -n "$(valor AUTHENTIK_BOOTSTRAP_TOKEN)" ] || { echo "FALHA: AUTHENTIK_BOOTSTRAP_TOKEN vazio no .env"; exit 1; }
[ -n "$(valor DALO_DB_USER)" ] || { echo "FALHA: DALO_DB_USER vazio no .env"; exit 1; }

if ! curl -fsS -o /dev/null --max-time 10 http://127.0.0.1:9000/-/health/live/; then
    echo "FALHA: authentik não responde em http://127.0.0.1:9000 (suba o app authentik antes)"; exit 1
fi

opcoes=()
if [ "${MIGRACAO_TESTE_RADIUS:-sim}" != nao ] && [ -n "$(valor AUTHENTIK_RADIUS_SECRET)" ]; then
    opcoes+=(--radius)
else
    echo "aviso: login RADIUS real não testado (outpost/segredo ausente ou MIGRACAO_TESTE_RADIUS=nao)"
fi

if ! "${CF[@]}" run --rm -T migracao verificar "${opcoes[@]}"; then
    echo "FALHA: o authentik diverge do daloRADIUS (veja as divergências acima; rode 'aplicar' e repita)"
    exit 1
fi
echo "OK: apps/migracao"
