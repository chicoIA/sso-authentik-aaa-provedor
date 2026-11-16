#!/usr/bin/env bash
# Cópias de segurança do ambiente Exemplo. Uso: backup.sh completo|pre-virada|listar|restaurar-authentik <arquivo> --sim
set -euo pipefail
umask 077
RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ENVF="$RAIZ/.env"
envv() { [ -f "$ENVF" ] && grep -E "^$1=" "$ENVF" | tail -1 | cut -d= -f2- | sed -e 's/^"//' -e 's/"$//' || true; }
BACKUP_DIR="${BACKUP_DIR:-$(envv BACKUP_DIR)}"; BACKUP_DIR="${BACKUP_DIR:-/var/backups/provedor}"
BACKUP_RETENCAO_DIAS="${BACKUP_RETENCAO_DIAS:-$(envv BACKUP_RETENCAO_DIAS)}"; BACKUP_RETENCAO_DIAS="${BACKUP_RETENCAO_DIAS:-14}"
BACKUP_RADACCT="${BACKUP_RADACCT:-$(envv BACKUP_RADACCT)}"; BACKUP_RADACCT="${BACKUP_RADACCT:-nao}"
BACKUP_NAS="${BACKUP_NAS:-$(envv BACKUP_NAS)}"; BACKUP_NAS="${BACKUP_NAS:-nao}"
# containers do app authentik (projeto compose provedor-authentik), achados pelos rótulos
cont() { docker ps -q --filter label=com.docker.compose.project=provedor-authentik \
           --filter "label=com.docker.compose.service=$1" 2>/dev/null | head -1; }
PG_CONT="${PG_CONT:-$(cont authentik-postgres)}"
LOW=(nice -n 19 ionice -c3)

log() { echo "[backup $(date +%H:%M:%S)] $*"; }
aviso() { echo "[backup] AVISO: $*" >&2; }

mycnf() { # imprime caminho de arquivo de credenciais mysql (temporário se vier do .env)
  if [ -f /root/.my-radius.cnf ]; then echo /root/.my-radius.cnf; return; fi
  local h u p; h="$(envv DALO_DB_HOST)"; u="$(envv DALO_DB_USER)"; p="$(envv DALO_DB_PASS)"
  [ -n "$u" ] && [ -n "$p" ] || return 1
  local t; t="$(mktemp)"; TMPS+=("$t")
  printf '[client]\nhost=%s\nport=%s\nuser=%s\npassword=%s\n' "${h:-127.0.0.1}" "$(envv DALO_DB_PORT)" "$u" "$p" >"$t"
  echo "$t"
}
TMPS=(); trap 'rm -f "${TMPS[@]:-}" 2>/dev/null || true' EXIT

fazer() {
  local modo="$1" ts dest; ts="$(date +%Y%m%d-%H%M%S)"
  dest="$BACKUP_DIR/$modo-$ts"; mkdir -p "$dest"; chmod 700 "$BACKUP_DIR" "$dest"
  log "destino: $dest"
  # pg_dump
  if [ -n "$PG_CONT" ] && docker ps -q --no-trunc 2>/dev/null | grep -q "^$PG_CONT"; then
    local pu pd; pu="$(docker exec "$PG_CONT" printenv POSTGRES_USER 2>/dev/null || echo authentik)"
    pd="$(docker exec "$PG_CONT" printenv POSTGRES_DB 2>/dev/null || echo authentik)"
    if "${LOW[@]}" docker exec "$PG_CONT" pg_dump -U "$pu" -d "$pd" -Fc >"$dest/authentik.pgdump"; then log "pg_dump ok"
    else aviso "pg_dump falhou"; rm -f "$dest/authentik.pgdump"; fi
  else aviso "authentik-postgres fora do ar: pulando pg_dump"; fi
  # .env
  [ -f "$ENVF" ] && { cp "$ENVF" "$dest/env.bak"; chmod 600 "$dest/env.bak"; log ".env ok"; } || aviso ".env inexistente"
  # apps
  "${LOW[@]}" tar -czf "$dest/apps.tar.gz" -C "$RAIZ" --exclude='apps/*/saida' --exclude='apps/*/volumes' apps && log "apps ok"
  # freeradius
  if [ -d /etc/freeradius ]; then "${LOW[@]}" tar -czf "$dest/etc-freeradius.tar.gz" -C /etc freeradius && log "/etc/freeradius ok"; else aviso "sem /etc/freeradius"; fi
  # mysql
  if [ "$modo" = completo ]; then
    local cnf; if cnf="$(mycnf)" && command -v mysqldump >/dev/null; then
      local db; db="$(envv DALO_DB_NAME)"; db="${db:-radius}"
      local ign=(--ignore-table="$db.radacct" --ignore-table="$db.radpostauth")
      [ "$BACKUP_NAS" = sim ] || { ign+=(--ignore-table="$db.nas"); log "tabela nas NAO copiada (BACKUP_NAS=nao)"; }
      if "${LOW[@]}" mysqldump --defaults-extra-file="$cnf" --single-transaction --quick "${ign[@]}" "$db" | gzip >"$dest/radius.sql.gz"; then log "mysqldump ok"
      else aviso "mysqldump falhou"; rm -f "$dest/radius.sql.gz"; fi
      if [ "$BACKUP_RADACCT" = sim ]; then
        log "radacct/radpostauth (pesado)..."
        "${LOW[@]}" mysqldump --defaults-extra-file="$cnf" --single-transaction --quick "$db" radacct radpostauth | gzip >"$dest/radius-radacct.sql.gz" || { aviso "dump radacct falhou"; rm -f "$dest/radius-radacct.sql.gz"; }
      fi
    else aviso "sem credenciais mysql: pulando banco radius"; fi
  fi
  # verificação e manifesto
  local f ok=1; : >"$dest/MANIFESTO.sha256"
  for f in "$dest"/*; do
    case "$f" in */MANIFESTO.sha256) continue;; esac
    case "$f" in *.gz) gzip -t "$f" || { aviso "gzip -t falhou: $f"; ok=0; };; esac
    (cd "$dest" && sha256sum "$(basename "$f")") >>"$dest/MANIFESTO.sha256"
  done
  chmod 600 "$dest"/*
  find "$BACKUP_DIR" -maxdepth 1 -mindepth 1 -type d -name '*-2*' -mtime +"$BACKUP_RETENCAO_DIAS" -exec rm -rf {} + 2>/dev/null || true
  [ "$ok" = 1 ] || { echo "[backup] ERRO: verificação falhou em $dest" >&2; exit 1; }
  log "concluído: $dest"; echo "$dest" >"$BACKUP_DIR/.ultimo" 
}

listar() {
  [ -d "$BACKUP_DIR" ] || { echo "sem cópias em $BACKUP_DIR"; return; }
  for d in "$BACKUP_DIR"/*-2*/; do [ -d "$d" ] && printf '%s  %s\n' "$(du -sh "$d" | cut -f1)" "$d"; done
}

restaurar() {
  local arq="${1:-}"; shift || true
  [ -f "$arq" ] || { echo "uso: backup.sh restaurar-authentik <arquivo.pgdump> --sim" >&2; exit 2; }
  [ "${1:-}" = "--sim" ] || { echo "Restauração SOBRESCREVE o banco do authentik. Confirme com --sim." >&2; exit 2; }
  [ -n "$PG_CONT" ] || { echo "authentik-postgres não está rodando." >&2; exit 1; }
  local pu pd srv wrk; pu="$(docker exec "$PG_CONT" printenv POSTGRES_USER)"; pd="$(docker exec "$PG_CONT" printenv POSTGRES_DB)"
  srv="$(cont authentik-server)"; wrk="$(cont authentik-worker)"
  log "parando authentik-server/worker"; docker stop $srv $wrk >/dev/null 2>&1 || true
  docker exec -i "$PG_CONT" pg_restore -U "$pu" -d "$pd" --clean --if-exists --no-owner <"$arq"
  docker start $srv $wrk >/dev/null 2>&1 || true
  log "restauração concluída"
}

case "${1:-}" in
  completo) fazer completo;;
  pre-virada) fazer pre-virada;;
  listar) listar;;
  restaurar-authentik) shift; restaurar "$@";;
  *) echo "uso: $0 completo|pre-virada|listar|restaurar-authentik <arquivo> --sim" >&2; exit 2;;
esac
