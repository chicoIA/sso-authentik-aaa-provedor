#!/usr/bin/env bash
# Coleta, no servidor ATUAL (FreeRADIUS + daloRADIUS instalados sem Docker),
# as informações necessárias para revisar a migração. Segredos e senhas são
# substituídos por <REMOVIDO>. Revise o arquivo gerado antes de compartilhar.
#
# Uso (como root no servidor do daloRADIUS):
#   DALO_DB_USER=radius DALO_DB_NAME=radius ./coletar_ambiente_atual.sh
# A senha do MySQL é pedida no terminal (não fica no histórico).
set -euo pipefail

DALO_DB_HOST=${DALO_DB_HOST:-127.0.0.1}
DALO_DB_PORT=${DALO_DB_PORT:-3306}
DALO_DB_USER=${DALO_DB_USER:-radius}
DALO_DB_NAME=${DALO_DB_NAME:-radius}

SAIDA=$(mktemp -d /tmp/coleta-radius-XXXX)
trap 'rm -rf "$SAIDA"' EXIT
mkdir -p "$SAIDA/freeradius"

ocultar() {
    sed -E \
        -e 's/^([[:space:]]*(secret|password|passwd|private_key_password|login_password|bind_pw|key|identity_password)[[:space:]]*=[[:space:]]*).*/\1<REMOVIDO>/I' \
        -e 's/(([A-Za-z0-9]+-)?Password[[:space:]]*:?=[[:space:]]*)("[^"]*"|[^,[:space:]]*)/\1<REMOVIDO>/g'
}

echo "== sistema"
{
    echo "# coletado em $(date -Is) em $(hostname)"
    grep -E '^(PRETTY_NAME|VERSION_ID)=' /etc/os-release || true
    (freeradius -v 2>/dev/null || radiusd -v 2>/dev/null) | head -2 || true
    mysql --version 2>/dev/null || true
    php -v 2>/dev/null | head -1 || true
    command -v docker >/dev/null && docker --version || echo "docker: não instalado"
    echo
    echo "# portas RADIUS em uso"
    ss -lunp 2>/dev/null | grep -E ':(1812|1813|1645|1646)\b' || true
    echo
    echo "# bind do MySQL (para o servidor Docker conseguir conectar)"
    grep -rhE '^[[:space:]]*bind-address' /etc/mysql 2>/dev/null || echo "bind-address não definido"
} > "$SAIDA/sistema.txt"

echo "== configuração do FreeRADIUS (sem segredos)"
RADDB=""
for d in /etc/freeradius/3.0 /etc/freeradius /etc/raddb; do
    [ -f "$d/radiusd.conf" ] && RADDB=$d && break
done
if [ -n "$RADDB" ]; then
    echo "$RADDB" > "$SAIDA/freeradius/caminho.txt"
    ls -l "$RADDB/sites-enabled" "$RADDB/mods-enabled" > "$SAIDA/freeradius/habilitados.txt" 2>&1 || true
    for f in radiusd.conf clients.conf proxy.conf dictionary \
             mods-enabled/sql mods-enabled/files mods-enabled/ldap mods-enabled/eap \
             mods-config/files/authorize users huntgroups; do
        [ -e "$RADDB/$f" ] || continue
        mkdir -p "$SAIDA/freeradius/$(dirname "$f")"
        ocultar < "$RADDB/$f" > "$SAIDA/freeradius/$f"
    done
    for f in "$RADDB"/sites-enabled/*; do
        mkdir -p "$SAIDA/freeradius/sites-enabled"
        ocultar < "$f" > "$SAIDA/freeradius/sites-enabled/$(basename "$f")"
    done
    if [ -d "$RADDB/policy.d" ]; then
        mkdir -p "$SAIDA/freeradius/policy.d"
        find "$RADDB/policy.d" -type f -newer "$RADDB/radiusd.conf" -exec sh -c \
            'for f; do sed -E "s/(secret|password)[[:space:]]*=.*/\1 = <REMOVIDO>/I" "$f" > "$0/$(basename "$f")"; done' \
            "$SAIDA/freeradius/policy.d" {} + || true
    fi
else
    echo "FreeRADIUS não encontrado em /etc/freeradius ou /etc/raddb" > "$SAIDA/freeradius/caminho.txt"
fi

echo "== banco do daloRADIUS (estrutura e estatísticas, sem senhas)"
read -r -s -p "Senha do MySQL para $DALO_DB_USER@$DALO_DB_HOST: " MYSQL_PWD
echo
export MYSQL_PWD
sql() { mysql -h "$DALO_DB_HOST" -P "$DALO_DB_PORT" -u "$DALO_DB_USER" "$DALO_DB_NAME" --table -e "$1" 2>&1 || true; }

mysqldump -h "$DALO_DB_HOST" -P "$DALO_DB_PORT" -u "$DALO_DB_USER" --no-data --skip-comments \
    "$DALO_DB_NAME" > "$SAIDA/esquema.sql" 2>&1 || true

{
    echo "# linhas por tabela"
    for t in radcheck radreply radgroupcheck radgroupreply radusergroup userinfo nas radacct radpostauth operators; do
        sql "SELECT '$t' AS tabela, COUNT(*) AS linhas FROM $t"
    done
    echo "# radcheck: atributos usados (sem valores)"
    sql "SELECT attribute, op, COUNT(*) AS usuarios FROM radcheck GROUP BY attribute, op ORDER BY 3 DESC"
    echo "# radreply: atributos usados"
    sql "SELECT attribute, op, COUNT(*) AS usuarios FROM radreply GROUP BY attribute, op ORDER BY 3 DESC"
    echo "# radgroupreply: perfis por grupo"
    sql "SELECT groupname, attribute, op, value FROM radgroupreply ORDER BY groupname, id"
    echo "# radgroupcheck"
    sql "SELECT groupname, attribute, op, value FROM radgroupcheck WHERE attribute NOT LIKE '%Password%' ORDER BY groupname, id"
    echo "# radusergroup: membros por grupo"
    sql "SELECT groupname, priority, COUNT(*) AS membros FROM radusergroup GROUP BY groupname, priority"
    echo "# nas: quantidade por tipo"
    sql "SELECT type, COUNT(*) AS nas FROM nas GROUP BY type"
    echo "# radpostauth: logins nos últimos 90 dias (CHAP = pass começando com 0x)"
    sql "SELECT reply, (pass LIKE '0x%') AS chap, COUNT(*) AS total FROM radpostauth WHERE authdate > NOW() - INTERVAL 90 DAY GROUP BY 1, 2"
    echo "# radacct: sessões nos últimos 30 dias por NAS"
    sql "SELECT nasipaddress, COUNT(*) AS sessoes FROM radacct WHERE acctstarttime > NOW() - INTERVAL 30 DAY GROUP BY nasipaddress ORDER BY 2 DESC LIMIT 50"
} > "$SAIDA/banco.txt"
unset MYSQL_PWD

ARQUIVO="/tmp/coleta-radius-$(hostname)-$(date +%Y%m%d%H%M).tar.gz"
tar -czf "$ARQUIVO" -C "$SAIDA" .
echo
echo "Gerado: $ARQUIVO"
echo "Revise antes de compartilhar:  mkdir -p /tmp/revisao && tar -xzf $ARQUIVO -C /tmp/revisao && grep -ri 'secret\\|password' /tmp/revisao"
