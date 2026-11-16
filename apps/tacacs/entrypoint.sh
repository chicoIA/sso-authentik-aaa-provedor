#!/bin/sh
# Entrypoint do container tacacs: valida o ambiente, gera a configuração (com a
# chave) em tmpfs, ajusta o volume de logs e roda o tac_plus-ng sem privilégios.
# Nunca imprime a chave nem a senha do LDAP.
set -eu

faltou() { echo "tacacs: $1" >&2; exit 1; }

[ -n "${TACACS_KEY:-}" ] || faltou "defina TACACS_KEY no .env"
[ "${#TACACS_KEY}" -ge 8 ] || faltou "TACACS_KEY precisa ter ao menos 8 caracteres"
case "$TACACS_KEY" in
  *[!A-Za-z0-9._~+=@%^-]*) faltou "TACACS_KEY só pode ter letras, números e . _ ~ + = @ % ^ -" ;;
esac
[ -n "${LDAP_SERVICO_SENHA:-}" ] || faltou "defina LDAP_SERVICO_SENHA no .env"

BASE="${TACACS_LDAP_BASE_DN:-dc=ldap,dc=provedor,dc=com,dc=br}"
CFG=/run/tacacs/tac_plus-ng.cfg
LOG_DIR=/var/log/tacacs
EVENTOS="$LOG_DIR/eventos.tsv"

# Volume de logs: pode ter sido criado vazio por outro container (painel), então
# acerta dono aqui. O arquivo fica legível por todos (o painel monta só leitura).
mkdir -p "$LOG_DIR"
chown tacacs:tacacs "$LOG_DIR"
# Rotação simples na subida: acima de 50 MB guarda o arquivo antigo como .1
if [ -f "$EVENTOS" ] && [ "$(stat -c %s "$EVENTOS")" -gt 52428800 ]; then
  mv -f "$EVENTOS" "$EVENTOS.1"
fi
touch "$EVENTOS"
chown tacacs:tacacs "$EVENTOS"
chmod 0755 "$LOG_DIR"
chmod 0644 "$EVENTOS"

# Configuração com a chave. A chave só tem caracteres seguros (validado acima).
# Conjuntos de equipamentos (gerados pelo provedor-tacacs-conjuntos): sem o arquivo,
# o include aponta para /dev/null e o TACACS+ sobe só com os grupos globais.
VAZIO_REDES=/etc/tacacs/conjuntos/redes.cfg; VAZIO_REGRAS=/etc/tacacs/conjuntos/regras.cfg
[ -r "$VAZIO_REDES" ] || { echo "[tacacs] aviso: sem $VAZIO_REDES (conjuntos vazios)" >&2; VAZIO_REDES=/dev/null; }
[ -r "$VAZIO_REGRAS" ] || { echo "[tacacs] aviso: sem $VAZIO_REGRAS (conjuntos vazios)" >&2; VAZIO_REGRAS=/dev/null; }
umask 077
TACACS_KEY="$TACACS_KEY" R1="$VAZIO_REDES" R2="$VAZIO_REGRAS" perl -pe \
  's/\@TACACS_KEY\@/$ENV{TACACS_KEY}/g; s{include = /etc/tacacs/conjuntos/redes\.cfg}{include = $ENV{R1}}; s{include = /etc/tacacs/conjuntos/regras\.cfg}{include = $ENV{R2}}' \
  /etc/tacacs/tac_plus-ng.cfg.modelo > "$CFG"
chown tacacs:tacacs "$CFG"
chmod 0600 "$CFG"

# Ambiente do backend MAVIS LDAP (herdado pelo script Perl).
export LDAP_HOSTS="${TACACS_LDAP_URL:-ldap://ldap-outpost:3389}"
export LDAP_BASE="$BASE"
export LDAP_USER="cn=ldap-servico,ou=users,$BASE"
export LDAP_PASSWD="$LDAP_SERVICO_SENHA"
# No authentik o login é o "cn" do usuário (uid é um identificador interno).
export LDAP_FILTER='(&(objectClass=inetOrgPerson)(cn=%s))'
export LDAP_BASE_GROUP="ou=groups,$BASE"
export LDAP_MEMBEROF_REGEX='^cn=([^,]+),'
export LDAP_SKIP_POSIXGROUP=1
export LDAP_SKIP_GROUPOFNAMES=1
export LDAP_NESTED_GROUP_DEPTH=1
# Só os grupos tacacs-* entram nas regras: expandir os demais custava ~120 ms
# por grupo, duas vezes por login (o NE8000 desiste em 5 s por padrão).
export LDAP_MEMBEROF_FILTER='^cn=tacacs-'
export LDAP_CONNECT_TIMEOUT="${TACACS_LDAP_TIMEOUT:-5}"
export TZ="${TZ:-America/Sao_Paulo}"
unset TACACS_KEY LDAP_SERVICO_SENHA

if [ "${1:-}" = "-P" ]; then   # só valida a sintaxe da configuração
  exec setpriv --reuid=tacacs --regid=tacacs --clear-groups \
    /usr/local/sbin/tac_plus-ng -P "$CFG"
fi

# Repete o arquivo de eventos em stdout (docker logs). Roda sem privilégios,
# herda o stdout do container e continua depois do exec abaixo.
setpriv --reuid=tacacs --regid=tacacs --clear-groups \
  tail -n 0 -F "$EVENTOS" 2>/dev/null &

exec setpriv --reuid=tacacs --regid=tacacs --clear-groups \
  /usr/local/sbin/tac_plus-ng -f "$CFG"
