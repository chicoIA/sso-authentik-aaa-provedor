#!/usr/bin/env bash
# Manutenção do banco do daloRADIUS (radacct / radpostauth).
#
#   banco.sh tamanho                 tamanho das tabelas e linhas por período
#   banco.sh enxugar [--executar]    mantém só os últimos BANCO_RETENCAO_DIAS dias
#                                    trocando a tabela por uma nova (sem travar
#                                    o FreeRADIUS); sem --executar só simula
#   banco.sh retencao [--executar]   limpeza diária em lotes (timer systemd)
#   banco.sh antigos                 lista as tabelas *_antigo_* (rollback)
#   banco.sh descartar-antigos --sim apaga as tabelas *_antigo_* (libera disco)
#
# A coluna radpostauth.pass (senha em texto puro gravada pelo daloRADIUS) é
# esvaziada nas linhas mantidas. Nada mais é alterado; a tabela nas nunca é tocada.
set -euo pipefail

DIR=$(cd "$(dirname "$0")" && pwd)
RAIZ=$(cd "$DIR/../.." && pwd)
[ -r "$RAIZ/.env" ] && set -a && . "$RAIZ/.env" && set +a

DIAS=${BANCO_RETENCAO_DIAS:-180}
DB=${DALO_DB_NAME:-radius}
LOTE=${BANCO_LOTE:-50000}
LOTE_DEL=${BANCO_LOTE_DELETE:-5000}
PAUSA=${BANCO_PAUSA:-0.1}
BACKUP_GLOB=${BANCO_BACKUP_GLOB:-/root/backup-pre-authentik-*/radius-radacct.sql.gz /var/backups/provedor/*/radius-radacct.sql.gz}

# Credenciais: /root/.my-radius.cnf ou DALO_DB_* do .env (sem imprimir a senha).
CNF=${BANCO_MY_CNF:-/root/.my-radius.cnf}
if [ ! -r "$CNF" ]; then
  CNF=$(mktemp); trap 'rm -f "$CNF"' EXIT; chmod 600 "$CNF"
  {
    echo "[client]"; echo "user=${DALO_DB_USER:-radius}"; echo "password=${DALO_DB_PASS:?defina DALO_DB_PASS}"
    if [ -n "${DALO_DB_SOCKET:-}" ]; then echo "socket=$DALO_DB_SOCKET"; else echo "host=${DALO_DB_HOST:-localhost}"; fi
  } > "$CNF"
fi

q() { mysql --defaults-file="$CNF" -N -B "$DB" -e "$1"; }
log() { echo "[$(date '+%F %T')] $*"; }
falha() { echo "ERRO: $*" >&2; exit 1; }

# Primeiro id gravado há DIAS dias. Usa a ordem de gravação (id), não a data
# enviada pelo equipamento: há NAS com relógio errado (datas de 1970, 2001...).
corte_radacct() {
  local janela n
  for janela in 1 3 7 15; do
    n=$(q "select count(*) from radacct force index(acctstarttime)
           where acctstarttime between now() - interval $((DIAS + janela)) day and now() - interval $DIAS day")
    if [ "$n" -gt 0 ]; then
      # percentil 1% dos ids da janela (descarta ids antigos com data maluca)
      q "select radacctid from radacct force index(acctstarttime)
         where acctstarttime between now() - interval $((DIAS + janela)) day and now() - interval $DIAS day
         order by radacctid limit 1 offset $((n / 100))"
      return
    fi
  done
  echo 0
}

corte_radpostauth() {
  # authdate é a hora do servidor (confiável); sem índice, mas a tabela é pequena.
  q "select coalesce(min(id), 0) from radpostauth where authdate >= now() - interval $DIAS day"
}

tamanho() {
  q "select table_name, table_rows, round(data_length/1048576), round(index_length/1048576), round(data_free/1048576)
     from information_schema.tables where table_schema='$DB' and (table_name in ('radacct','radpostauth') or table_name like '%\\_antigo\\_%')
     order by table_name" | awk 'BEGIN{printf "%-32s %12s %10s %10s %10s\n","tabela","linhas~","dados_MB","indices_MB","livre_MB"}{printf "%-32s %12s %10s %10s %10s\n",$1,$2,$3,$4,$5}'
}

backup_existe() {
  local f
  for f in $BACKUP_GLOB; do [ -s "$f" ] && { echo "$f"; return 0; }; done
  return 1
}

# copia em lotes [de, ate] de $1 para $2 com a lista de colunas $4 (pk $3)
copiar() {
  local orig=$1 dest=$2 pk=$3 cols=$4 de=$5 ate=$6 a
  a=$de
  while [ "$a" -le "$ate" ]; do
    q "insert ignore into $dest select $cols from $orig where $pk >= $a and $pk < $((a + LOTE)) and $pk <= $ate"
    a=$((a + LOTE))
    sleep "$PAUSA"
  done
}

enxugar_tabela() {
  local t=$1 pk=$2 cols=$3 corte=$4 executar=$5 sufixo m0 m1 ai total manter
  sufixo=$(date +%Y%m%d)
  m0=$(q "select coalesce(max($pk),0) from $t")
  total=$(q "select count(*) from $t where $pk < $corte")
  manter=$(q "select count(*) from $t where $pk >= $corte")
  log "$t: corte $pk >= $corte (manter ~$manter linhas, remover ~$total)"
  [ "$executar" = sim ] || return 0
  [ "$corte" -gt 0 ] || falha "$t: não foi possível calcular o corte"
  q "show tables like '${t}_antigo_${sufixo}'" | grep -q . && falha "$t: ${t}_antigo_${sufixo} já existe (rode amanhã ou descarte o antigo)"

  ai=$(q "select auto_increment from information_schema.tables where table_schema='$DB' and table_name='$t'")
  q "drop table if exists ${t}_novo; create table ${t}_novo like $t; alter table ${t}_novo auto_increment = $((ai + 5000000))"
  log "$t: copiando $corte..$m0 em lotes de $LOTE"
  copiar "$t" "${t}_novo" "$pk" "$cols" "$corte" "$m0"

  # o que chegou durante a cópia + atualização das sessões recentes (stop/interim)
  m1=$(q "select max($pk) from $t")
  copiar "$t" "${t}_novo" "$pk" "$cols" "$((m0 + 1))" "$m1"
  if [ "$t" = radacct ]; then
    q "replace into radacct_novo select $cols from radacct where radacctid >= $((m0 > 200000 ? m0 - 200000 : 0)) and radacctid <= $m1"
  fi

  log "$t: trocando as tabelas (o original fica como ${t}_antigo_${sufixo})"
  q "rename table $t to ${t}_antigo_${sufixo}, ${t}_novo to $t"
  # o que chegou entre a última cópia e a troca (segundos)
  q "insert ignore into $t select $cols from ${t}_antigo_${sufixo} where $pk > $m1"
  log "$t: pronto ($(q "select count(*) from $t") linhas)"
}

cmd_enxugar() {
  local executar=nao b ca cp
  [ "${1:-}" = --executar ] && executar=sim
  b=$(backup_existe) || falha "nenhum backup completo do radacct encontrado ($BACKUP_GLOB). Rode apps/backup antes."
  log "backup encontrado: $b"
  ca=$(corte_radacct); cp=$(corte_radpostauth)
  tamanho
  if [ "$executar" = sim ]; then
    local livre; livre=$(df -Pm /var/lib/mysql | awk 'NR==2{print $4}')
    [ "$livre" -gt 4096 ] || falha "pouco espaço em /var/lib/mysql (${livre} MB)"
  fi
  enxugar_tabela radacct radacctid '*' "$ca" "$executar"
  enxugar_tabela radpostauth id "id, username, '', reply, authdate" "$cp" "$executar"
  if [ "$executar" = sim ]; then
    tamanho
    log "rollback: rename table radacct to radacct_x, radacct_antigo_<data> to radacct (idem radpostauth)"
  else
    log "simulação: nada foi alterado. Use --executar."
  fi
}

apagar_lotes() {
  local t=$1 cond=$2 n total=0
  while :; do
    n=$(q "delete from $t where $cond limit $LOTE_DEL; select row_count();")
    total=$((total + n))
    [ "$n" -lt "$LOTE_DEL" ] && break
    sleep "$PAUSA"
  done
  echo "$total"
}

cmd_retencao() {
  local executar=nao ca cp n
  [ "${1:-}" = --executar ] && executar=sim
  ca=$(corte_radacct); cp=$(corte_radpostauth)
  log "retenção de $DIAS dias: radacct radacctid < $ca, radpostauth id < $cp"
  if [ "$executar" != sim ]; then
    log "simulação: radacct remove $(q "select count(*) from radacct where radacctid < $ca"), radpostauth remove $(q "select count(*) from radpostauth where id < $cp"), senhas a limpar $(q "select count(*) from radpostauth where pass <> ''")"
    return 0
  fi
  [ "$ca" -gt 0 ] && n=$(apagar_lotes radacct "radacctid < $ca") && log "radacct: $n linhas removidas"
  [ "$cp" -gt 0 ] && n=$(apagar_lotes radpostauth "id < $cp") && log "radpostauth: $n linhas removidas"
  # senha em texto puro gravada pelo FreeRADIUS antigo; authdate=authdate evita o ON UPDATE
  local total=0
  while :; do
    n=$(q "update radpostauth set pass = '', authdate = authdate where pass <> '' limit $LOTE_DEL; select row_count();")
    total=$((total + n)); [ "$n" -lt "$LOTE_DEL" ] && break; sleep "$PAUSA"
  done
  log "radpostauth: senha removida de $total linhas"
}

cmd_antigos() { q "show tables like '%\\_antigo\\_%'"; }

cmd_descartar() {
  [ "${1:-}" = --sim ] || falha "isto apaga as tabelas de rollback; confirme com: banco.sh descartar-antigos --sim"
  local t
  for t in $(cmd_antigos); do log "apagando $t"; q "drop table \`$t\`"; done
  tamanho
}

case "${1:-}" in
  tamanho) tamanho ;;
  enxugar) shift; cmd_enxugar "$@" ;;
  retencao) shift; cmd_retencao "$@" ;;
  antigos) cmd_antigos ;;
  descartar-antigos) shift; cmd_descartar "$@" ;;
  *) sed -n '2,13p' "$0"; exit 1 ;;
esac
