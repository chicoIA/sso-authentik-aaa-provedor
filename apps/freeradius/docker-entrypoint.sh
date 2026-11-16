#!/bin/sh
# Entrypoint: libera o stdout do container para o usuário "freerad" (o FreeRADIUS
# derruba privilégios depois de subir e o linelog escreve em /dev/stdout).
set -e
chmod 666 /proc/self/fd/1 2>/dev/null || true

# FR_ACCT_IGNORAR_USUARIOS="zabbix zabbix@dominio" -> regex literal (escapada) usada no accounting.
FR_ACCT_IGNORAR_REGEX=$(printf '%s' "${FR_ACCT_IGNORAR_USUARIOS:-}" | tr ',' ' ' | xargs -n1 2>/dev/null \
  | sed 's/[][\\.^$*+?(){}|/]/\\&/g' | paste -sd'|' -)
if [ -n "$FR_ACCT_IGNORAR_REGEX" ]; then FR_ACCT_IGNORAR_ATIVO=sim; else FR_ACCT_IGNORAR_ATIVO=nao; FR_ACCT_IGNORAR_REGEX=nenhum; fi
export FR_ACCT_IGNORAR_REGEX FR_ACCT_IGNORAR_ATIVO
exec "$@"
