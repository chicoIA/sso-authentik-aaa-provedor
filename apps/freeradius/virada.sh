#!/usr/bin/env bash
# Virada na MESMA VM: FreeRADIUS do sistema (daloRADIUS) <-> FreeRADIUS em Docker (authentik).
#
#   sudo apps/freeradius/virada.sh status   # quem atende 1812/1813 e as portas de teste
#   sudo apps/freeradius/virada.sh ativar   # sistema para; este sobe em 1812/1813 com FR_GRAVAR_SQL=sim
#   sudo apps/freeradius/virada.sh voltar   # rollback: este para; o FreeRADIUS do sistema volta
#
# Os equipamentos não mudam: mesmo IP, mesmas portas, mesmos segredos (tabela nas).
# "ativar" só mexe no FreeRADIUS do sistema depois que o teste na 11812 passa e, se
# qualquer coisa falhar depois, volta sozinho para o FreeRADIUS do sistema.
set -euo pipefail

AQUI="$(cd "$(dirname "$0")" && pwd)"
RAIZ="$(cd "$AQUI/../.." && pwd)"
cd "$RAIZ"
ENVF="$RAIZ/.env"
DC=(docker compose -p provedor-freeradius --env-file "$ENVF" -f "$AQUI/compose.yml")

[ "$(id -u)" = 0 ] || { echo "Rode com sudo (precisa de systemctl)." >&2; exit 1; }
[ -f "$ENVF" ] || { echo "Arquivo .env não encontrado em $RAIZ." >&2; exit 1; }

SERVICO=""
for s in freeradius radiusd; do
    if systemctl list-unit-files "$s.service" --no-legend 2>/dev/null | grep -q "^$s"; then
        SERVICO=$s
        break
    fi
done

# valor de uma variável do .env (sem imprimir nada além do valor pedido)
lerenv() { grep -E "^$1=" "$ENVF" | tail -1 | cut -d= -f2- || true; }

definir() { # VAR valor  (altera só estas chaves do .env)
    if grep -q "^$1=" "$ENVF"; then
        sed -i "s|^$1=.*|$1=$2|" "$ENVF"
    else
        echo "$1=$2" >> "$ENVF"
    fi
}

cid() { docker ps -q --filter label=com.docker.compose.project=provedor-freeradius \
            --filter label=com.docker.compose.service=freeradius | head -1; }

# Status-Server no container, pela porta indicada (segredo vem do ambiente do container).
status_server() { # porta
    local c; c=$(cid); [ -n "$c" ] || return 1
    docker exec "$c" sh -c \
        "echo 'Message-Authenticator = 0x00' | radclient -r 2 -t 3 127.0.0.1:$1 status \"\$FR_SEGREDO_LOCAL\"" >/dev/null 2>&1
}

porta_em_uso() { # porta -> 0 se algum processo escuta em UDP
    ss -H -lun "sport = :$1" 2>/dev/null | grep -q .
}

status() {
    echo "== serviço do sistema: ${SERVICO:-não encontrado} ($( [ -n "$SERVICO" ] && systemctl is-active "$SERVICO" 2>/dev/null || echo '-'))"
    echo "== container freeradius"
    "${DC[@]}" ps --format '{{.Service}}\t{{.Status}}' 2>/dev/null || true
    echo "   portas no .env: auth=$(lerenv FR_PORTA_AUTH) acct=$(lerenv FR_PORTA_ACCT) gravar_sql=$(lerenv FR_GRAVAR_SQL)"
    echo "== quem escuta nas portas RADIUS"
    ss -lunp | grep -E ':(1812|1813|11812|11813)\b' || echo "   ninguém"
}

stack_saudavel() {
    local ok=1
    docker ps -q --filter label=com.docker.compose.service=radius-outpost --filter status=running | grep -q . \
        || { echo "   o outpost RADIUS (radius-outpost) não está rodando" >&2; ok=0; }
    curl -fsS -o /dev/null --max-time 5 http://127.0.0.1:9000/-/health/ready/ \
        || { echo "   o authentik-server não está pronto (http://127.0.0.1:9000/-/health/ready/)" >&2; ok=0; }
    [ "$ok" = 1 ]
}

voltar() {
    echo "== parando o FreeRADIUS do Docker"
    "${DC[@]}" stop freeradius || true
    definir FR_PORTA_AUTH 11812
    definir FR_PORTA_ACCT 11813
    definir FR_GRAVAR_SQL nao
    if [ -z "$SERVICO" ]; then
        echo "Serviço freeradius/radiusd do sistema não encontrado: religue manualmente." >&2
        return 1
    fi
    echo "== religando $SERVICO do sistema"
    systemctl enable "$SERVICO" >/dev/null 2>&1 || true
    systemctl start "$SERVICO"
    :
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        if systemctl is-active --quiet "$SERVICO" && porta_em_uso 1812; then
            echo "   $SERVICO ativo e escutando em 1812"
            echo
            echo "Rollback concluído: o daloRADIUS voltou a atender. Para testar o novo de novo"
            echo "(portas 11812/11813, ao lado do atual): ./provedor up freeradius"
            return 0
        fi
        sleep 1
    done
    echo "ATENÇÃO: $SERVICO não ficou ativo em 1812. Veja: journalctl -u $SERVICO -n 50" >&2
    return 1
}

ativar() {
    [ -n "$SERVICO" ] || { echo "Serviço freeradius/radiusd do sistema não encontrado." >&2; exit 1; }

    echo "== 1/5 conferindo o stack (authentik e outpost)"
    stack_saudavel || exit 1

    echo "== 2/5 teste do FreeRADIUS novo nas portas de teste (nada do sistema é tocado)"
    local pa; pa=$(lerenv FR_PORTA_AUTH); pa=${pa:-11812}
    if [ "$pa" != 11812 ]; then
        echo "   FR_PORTA_AUTH=$pa no .env: a virada espera o modo de teste (11812). Se já virou, use 'status'." >&2
        exit 1
    fi
    status_server 11812 || { echo "   FreeRADIUS novo sem resposta na 11812 (./provedor up freeradius)" >&2; exit 1; }
    "$AQUI/teste.sh" || { echo "   teste.sh falhou: o FreeRADIUS do sistema NÃO foi tocado." >&2; exit 1; }

    echo "== 3/5 preparando a imagem (antes de parar o sistema, para a troca ser rápida)"
    "${DC[@]}" build freeradius

    echo "== 4/5 trocando: parando $SERVICO do sistema e subindo o Docker em 1812/1813 (FR_GRAVAR_SQL=sim)"
    # a partir daqui, qualquer falha volta sozinha para o FreeRADIUS do sistema
    falhou() { echo "Falhou ($1): voltando para o FreeRADIUS do sistema." >&2; voltar || true; exit 1; }
    systemctl stop "$SERVICO" || falhou "parar $SERVICO"
    systemctl disable "$SERVICO" >/dev/null 2>&1 || true
    definir FR_PORTA_AUTH 1812
    definir FR_PORTA_ACCT 1813
    definir FR_GRAVAR_SQL sim
    "${DC[@]}" up -d --no-build --force-recreate freeradius || falhou "subir o container"

    local pronto=0
    for _ in $(seq 1 30); do
        if status_server 1812; then pronto=1; break; fi
        sleep 1
    done
    [ "$pronto" = 1 ] || falhou "sem resposta em 1812"

    echo "== 5/5 teste ponta a ponta já em 1812"
    "$AQUI/teste.sh" || falhou "teste.sh em 1812"

    echo
    echo "Virada concluída. Acompanhe: docker compose -p provedor-freeradius logs -f freeradius"
    echo "Para voltar: sudo $AQUI/virada.sh voltar"
}

case "${1:-status}" in
    status) status ;;
    ativar) ativar ;;
    voltar) voltar ;;
    *) echo "uso: $0 status|ativar|voltar" >&2; exit 2 ;;
esac
