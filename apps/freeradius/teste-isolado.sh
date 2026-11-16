#!/usr/bin/env bash
# Teste funcional ISOLADO da imagem (sem tocar na produção, sem portas no host):
# cria uma rede Docker própria com
#   - MariaDB descartável (tests/daloradius_exemplo.sql) com o socket em um diretório temporário;
#   - um FreeRADIUS "authentik falso" (responde Accept com atributos);
#   - o FreeRADIUS desta imagem (rede bridge, não host).
# Prova: proxy PAP, cache, upstream fora (sem resposta), CHAP legado, FR_CHAP_LEGADO=nao,
# FR_GRAVAR_SQL=nao/sim e o cadastro NAS lido da tabela. Remove tudo no fim.
#   uso: apps/freeradius/teste-isolado.sh
set -euo pipefail

AQUI="$(cd "$(dirname "$0")" && pwd)"
RAIZ="$(cd "$AQUI/../.." && pwd)"
P="frtest$$"
REDE="${P}-rede"
IMG="provedor/freeradius:teste-isolado"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/frtest.XXXXXX")"
SEG_NAS="NasTeste$RANDOM$RANDOM"      # segredo do NAS na tabela (só de teste)
SEG_LOCAL="Local$RANDOM$RANDOM"
SEG_UP="Up$RANDOM$RANDOM"
SEG_DB="Db$RANDOM$RANDOM"
SENHA="Sx$RANDOM$RANDOM"
SENHA_CHAP="Cx$RANDOM$RANDOM"
erros=0

ok()  { echo "OK: $*"; }
nok() { echo "FALHA: $*" >&2; erros=$((erros+1)); }
limpar() {
  [ -z "${MANTER:-}" ] || { echo "MANTER=1: prefixo $P, tmp $TMP (remova depois)"; return 0; }
  docker rm -f "$P-fr" "$P-up" "$P-db" "$P-cli" >/dev/null 2>&1 || true
  docker rm -f "$P-rele" >/dev/null 2>&1 || true
  docker network rm "$REDE" >/dev/null 2>&1 || true
  docker rmi "$IMG" >/dev/null 2>&1 || true
  rm -rf "$TMP" 2>/dev/null || true
}
trap limpar EXIT

docker build -q -t "$IMG" "$AQUI" >/dev/null || { echo "FALHA: docker build" >&2; exit 1; }
docker network create "$REDE" >/dev/null
chmod 777 "$TMP"; mkdir -p "$TMP/sock" "$TMP/up"; chmod 777 "$TMP/sock"

# ---------- MariaDB descartável (socket compartilhado) ----------
{
  cat "$RAIZ/tests/daloradius_exemplo.sql"
  cat <<SQL
INSERT INTO nas (nasname, shortname, type, secret, description) VALUES
  ('0.0.0.0/0', 'Todos', 'other', '$SEG_NAS', 'Todos (teste)');
INSERT INTO radcheck (username, attribute, op, value) VALUES
  ('chapuser', 'Cleartext-Password', ':=', '$SENHA_CHAP'),
  ('chapoff',  'Cleartext-Password', ':=', '$SENHA_CHAP');
INSERT INTO radusergroup (username, groupname, priority) VALUES
  ('chapuser', 'noc', 1), ('chapoff', 'daloRADIUS-Disabled-Users', 1);
INSERT INTO radgroupcheck (groupname, attribute, op, value) VALUES
  ('daloRADIUS-Disabled-Users', 'Auth-Type', ':=', 'Reject');
SQL
} > "$TMP/db.sql"
docker run -d --name "$P-db" --network "$REDE" --memory 256m \
  -e MARIADB_ROOT_PASSWORD="r$SEG_DB" -e MARIADB_DATABASE=radius -e MARIADB_USER=radius -e MARIADB_PASSWORD="$SEG_DB" \
  -v "$TMP/sock:/run/mysqld" -v "$TMP/db.sql:/docker-entrypoint-initdb.d/01.sql:ro" \
  docker.io/library/mariadb:10.11 >/dev/null
for i in $(seq 1 60); do
  docker exec "$P-db" mariadb -uradius -p"$SEG_DB" radius -e 'SELECT 1 FROM nas LIMIT 1' >/dev/null 2>&1 && break
  sleep 2
  [ "$i" = 60 ] && { echo "FALHA: MariaDB de teste não subiu" >&2; exit 1; }
done
sql() { docker exec "$P-db" mariadb -N -uradius -p"$SEG_DB" radius -e "$1" 2>/dev/null; }

# ---------- "authentik falso" ----------
cat > "$TMP/up/clients.conf" <<EOT
client todos { ipaddr = 0.0.0.0/0
 secret = $SEG_UP
 require_message_authenticator = no }
EOT
cat > "$TMP/up/authorize" <<EOT
usuario1 Cleartext-Password := "$SENHA"
	Mikrotik-Group = "full",
	Huawei-Exec-Privilege = 15,
	Service-Type = Administrative-User
usuario2 Cleartext-Password := "$SENHA"
	Mikrotik-Group = "read"
fulano@exemplo.net.br Cleartext-Password := "$SENHA"
	Mikrotik-Group = "full"
EOT
docker run -d --name "$P-up" --network "$REDE" --memory 128m \
  -v "$TMP/up/clients.conf:/etc/freeradius/clients.conf:ro" \
  -v "$TMP/up/authorize:/etc/freeradius/mods-config/files/authorize:ro" \
  freeradius/freeradius-server:3.2.10 freeradius -X >/dev/null
sleep 3
[ "$(docker inspect -f '{{.State.Running}}' "$P-up")" = true ] || { echo "FALHA: upstream falso não subiu" >&2; docker logs "$P-up" 2>&1 | tail -5 >&2; exit 1; }
UP_IP=$(docker inspect -f "{{(index .NetworkSettings.Networks \"$REDE\").IPAddress}}" "$P-up")

# ---------- cliente (um "NAS") ----------
docker run -d --name "$P-cli" --network "$REDE" --memory 64m --entrypoint sleep "$IMG" 3600 >/dev/null

subir_fr() { # [VAR=valor ...]
  local extra=() v
  for v in "$@"; do extra+=(-e "$v"); done
  docker rm -f "$P-fr" >/dev/null 2>&1 || true
  docker run -d --name "$P-fr" --network "$REDE" --memory 192m \
    -v "$TMP/sock:/run/mysqld:ro" \
    -e AUTHENTIK_OUTPOST_IP="$UP_IP" -e OUTPOST_RADIUS_PORTA=1812 -e AUTHENTIK_RADIUS_SECRET="$SEG_UP" \
    -e FR_SEGREDO_LOCAL="$SEG_LOCAL" -e FR_PORTA_AUTH=1812 -e FR_PORTA_ACCT=1813 \
    -e DALO_DB_USER=radius -e DALO_DB_PASS="$SEG_DB" -e DALO_DB_NAME=radius \
    -e FR_CACHE_TTL=300 "${extra[@]}" "$IMG" >/dev/null
  for i in $(seq 1 30); do
    if docker exec "$P-fr" sh -c 'echo "Message-Authenticator = 0x00" | radclient -r 1 -t 2 127.0.0.1:1812 status "$FR_SEGREDO_LOCAL"' >/dev/null 2>&1; then
      FR_IP=$(docker inspect -f "{{(index .NetworkSettings.Networks \"$REDE\").IPAddress}}" "$P-fr")
      return 0
    fi
    sleep 1
  done
  echo "FALHA: FreeRADIUS de teste não subiu" >&2; docker logs "$P-fr" 2>&1 | tail -20 >&2; exit 1
}
# radclient pelo NAS (segredo vindo da tabela nas, cliente 0.0.0.0/0)
nas() { # tipo "atributos" [timeout]   (envia via stdin; senha nunca vai para argumentos de log)
  printf '%b\n' "$2" | docker exec -i "$P-cli" radclient -x -t "${3:-4}" -r 1 "$FR_IP:${4:-1812}" "${1:-auth}" "$SEG_NAS" 2>&1 || true
}
pap() { nas auth "User-Name = \"$1\", User-Password = \"$2\", NAS-IP-Address = 10.233.9.9" "${3:-4}"; }
n_up() { docker logs "$P-up" 2>&1 | grep -c 'Received Access-Request' || true; }
frlog() { docker logs "$P-fr" 2>&1; }
logtem() { # padrão (regex): espera até ~5s o docker entregar a linha de log
  local i l
  for i in 1 2 3 4 5 6 7 8 9 10; do
    l=$(frlog); grep -q -- "$1" <<<"$l" && return 0; sleep 0.5
  done
  return 1
}

# ========== A. sintaxe com banco ==========
if docker run --rm --network "$REDE" -v "$TMP/sock:/run/mysqld:ro" \
   -e AUTHENTIK_RADIUS_SECRET=x -e FR_SEGREDO_LOCAL=y -e DALO_DB_USER=radius -e DALO_DB_PASS="$SEG_DB" -e DALO_DB_NAME=radius \
   "$IMG" freeradius -XC >"$TMP/xc.log" 2>&1; then ok "freeradius -XC (config e conexão pelo socket)"; else nok "freeradius -XC"; tail -15 "$TMP/xc.log" >&2; fi

# ========== B. modo teste: PAP, cache, NAS da tabela ==========
subir_fr FR_CHAP_LEGADO=sim FR_GRAVAR_SQL=nao
base_pa=$(sql "SELECT COUNT(*) FROM radpostauth"); base_ac=$(sql "SELECT COUNT(*) FROM radacct")

s=$(pap usuario1 "$SENHA")
grep -q 'Received Access-Accept' <<<"$s" && ok "PAP aceito (NAS da tabela, cliente 0.0.0.0/0)" || nok "PAP não aceito: $(sed 's/User-Password.*//' <<<"$s" | tail -3)"
grep -Eq 'Mikrotik-Group = "?full' <<<"$s" && grep -Eq 'Huawei-Exec-Privilege = 15' <<<"$s" && grep -q 'Administrative-User' <<<"$s" \
  && ok "atributos do upstream presentes" || nok "atributos do upstream ausentes"
[ "$(n_up)" = 1 ] && ok "1 pedido chegou ao upstream" || nok "upstream recebeu $(n_up) pedidos (esperado 1)"
logtem "usuario=usuario1 proto=pap origem=authentik resultado=Access-Accept" && ok "log origem=authentik" || nok "log origem=authentik ausente"

s=$(pap usuario1 "$SENHA")
grep -q 'Received Access-Accept' <<<"$s" && grep -Eq 'Mikrotik-Group = "?full' <<<"$s" && grep -Eq 'Huawei-Exec-Privilege = 15' <<<"$s" \
  && ok "2o pedido aceito com os mesmos atributos" || nok "2o pedido sem accept/atributos"
[ "$(n_up)" = 1 ] && ok "CACHE: 2o pedido não chegou ao upstream" || nok "cache não funcionou (upstream recebeu $(n_up))"
logtem "usuario=usuario1 proto=pap origem=cache resultado=Access-Accept" && ok "log origem=cache" || nok "log origem=cache ausente"

s=$(pap usuario1 "senha-errada")
grep -q 'Received Access-Reject' <<<"$s" && ok "senha errada rejeitada (não usa o cache de outra senha)" || nok "senha errada não rejeitada"
[ "$(n_up)" = 2 ] && ok "senha errada consultou o upstream" || nok "contagem upstream=$(n_up) (esperado 2)"
s=$(pap usuario1 "senha-errada")
grep -q 'Received Access-Reject' <<<"$s" && [ "$(n_up)" = 3 ] && ok "Reject não é guardado no cache" || nok "Reject foi cacheado? upstream=$(n_up)"
for i in 1 2 3; do
  s=$(pap usuario1 "senha-errada")
  grep -q 'Received Access-Accept' <<<"$s" && nok "SENHA ERRADA ACEITA na tentativa $i (cache/reserva)"
done
ok "senha errada repetida nunca é aceita"
s=$(pap fulano@exemplo.net.br "$SENHA")
grep -q 'Received Access-Accept' <<<"$s" && ok "usuário com @ literal aceito" || nok "usuário com @ não aceito"

# conferência: nada gravado no banco em modo teste
[ "$(sql 'SELECT COUNT(*) FROM radpostauth')" = "$base_pa" ] && ok "FR_GRAVAR_SQL=nao: radpostauth intacto" || nok "radpostauth foi alterado em modo teste"

# accounting em modo teste: só log
s=$(nas acct "User-Name = \"usuario1\", Acct-Status-Type = Start, Acct-Session-Id = \"abc1\", NAS-IP-Address = 10.233.9.9" 4 1813)
grep -q 'Accounting-Response' <<<"$s" && ok "accounting respondido (modo teste)" || nok "accounting sem resposta"
logtem 'PROVEDOR-ACCT .*usuario=usuario1 tipo=Start .*gravado=nao' && ok "accounting registrado só em log" || nok "log de accounting ausente"
[ "$(sql 'SELECT COUNT(*) FROM radacct')" = "$base_ac" ] && ok "radacct intacto em modo teste" || nok "radacct alterado em modo teste"

# ========== C. CHAP legado ==========
base_up=$(n_up)
s=$(nas auth "User-Name = \"chapuser\", CHAP-Password = \"$SENHA_CHAP\", NAS-IP-Address = 10.233.9.9")
grep -q 'Received Access-Accept' <<<"$s" && grep -Eq 'Mikrotik-Group = "?full' <<<"$s" && ok "CHAP legado aceito pelo SQL com atributos do grupo" || nok "CHAP legado não aceito: $(grep -E 'Access|Reply' <<<"$s")"
logtem 'LEGADO-CHAP usuario=chapuser nas=' && ok "log LEGADO-CHAP" || nok "log LEGADO-CHAP ausente"
logtem 'usuario=chapuser proto=chap origem=legado resultado=Access-Accept' && ok "log PROVEDOR-AUTH proto=chap origem=legado" || nok "log de resultado do CHAP ausente"
s=$(nas auth "User-Name = \"chapuser\", CHAP-Password = \"errada\", NAS-IP-Address = 10.233.9.9")
grep -q 'Received Access-Reject' <<<"$s" && ok "CHAP com senha errada rejeitado" || nok "CHAP errado não rejeitado"
s=$(nas auth "User-Name = \"chapoff\", CHAP-Password = \"$SENHA_CHAP\", NAS-IP-Address = 10.233.9.9")
grep -q 'Received Access-Reject' <<<"$s" && ok "usuário do grupo daloRADIUS-Disabled-Users rejeitado" || nok "desativado não rejeitado"
s=$(nas auth "User-Name = \"chapuser\", MS-CHAP-Password = \"$SENHA_CHAP\", NAS-IP-Address = 10.233.9.9")
grep -q 'Received Access-Accept' <<<"$s" && ok "MS-CHAP legado aceito" || nok "MS-CHAP legado não aceito: $(grep -E 'Access|Reply|Error' <<<"$s" | head -3)"
logtem 'proto=mschap origem=legado' && ok "log proto=mschap" || nok "log mschap ausente"
[ "$(n_up)" = "$base_up" ] && ok "CHAP/MS-CHAP não foram ao authentik" || nok "CHAP chegou ao upstream (n=$(n_up), antes=$base_up)"

# ========== D. upstream fora do ar -> sem resposta ==========
docker stop "$P-up" >/dev/null
t0=$(date +%s)
s=$(pap usuario2 "$SENHA" 30)
t1=$(date +%s)
if ! grep -qE 'Received Access-(Accept|Reject)' <<<"$s"; then ok "authentik fora: sem resposta ao NAS ($((t1-t0))s)"; else nok "respondeu com authentik fora: $(grep -E 'Access-' <<<"$s")"; fi
logtem 'usuario=usuario2 .*resultado=SEM-RESPOSTA' && ok "log SEM-RESPOSTA" || nok "log SEM-RESPOSTA ausente"
s=$(pap usuario1 "$SENHA" 6)
grep -q 'Received Access-Accept' <<<"$s" && ok "com authentik fora, quem está no cache continua entrando (TTL)" || nok "cache não atendeu com authentik fora"
docker start "$P-up" >/dev/null

# ========== E. FR_CHAP_LEGADO=nao ==========
subir_fr FR_CHAP_LEGADO=nao FR_GRAVAR_SQL=nao
s=$(nas auth "User-Name = \"chapuser\", CHAP-Password = \"$SENHA_CHAP\", NAS-IP-Address = 10.233.9.9")
grep -q 'Received Access-Reject' <<<"$s" && ok "FR_CHAP_LEGADO=nao: CHAP recusado" || nok "CHAP não recusado com legado=nao"
logtem 'CHAP-RECUSADO usuario=chapuser' && ok "log CHAP-RECUSADO" || nok "log CHAP-RECUSADO ausente"
sleep 3   # upstream voltando

# ========== F. FR_GRAVAR_SQL=sim (banco descartável) ==========
subir_fr FR_CHAP_LEGADO=sim FR_GRAVAR_SQL=sim "FR_ACCT_IGNORAR_USUARIOS=zabbix mon.itor@ex.com"
pap usuario1 "$SENHA" >/dev/null; pap usuario1 "senha-errada" >/dev/null
nas auth "User-Name = \"chapuser\", CHAP-Password = \"$SENHA_CHAP\", NAS-IP-Address = 10.233.9.9" >/dev/null
nas acct "User-Name = \"usuario1\", Acct-Status-Type = Start, Acct-Session-Id = \"sess-$$\", NAS-IP-Address = 10.233.9.9" 4 1813 >/dev/null
[ "$(sql "SELECT COUNT(*) FROM radacct WHERE acctsessionid='sess-$$'")" = 1 ] && ok "FR_GRAVAR_SQL=sim: radacct gravado" || nok "radacct não gravado"
nas acct "User-Name = \"zabbix\", Acct-Status-Type = Start, Acct-Session-Id = \"zbx-$$\", NAS-IP-Address = 10.233.9.9" 4 1813 | grep -q 'Accounting-Response' && ok "accounting do zabbix respondido" || nok "accounting do zabbix sem resposta"
nas acct "User-Name = \"monXitor@ex.com\", Acct-Status-Type = Start, Acct-Session-Id = \"rx-$$\", NAS-IP-Address = 10.233.9.9" 4 1813 >/dev/null
[ "$(sql "SELECT COUNT(*) FROM radacct WHERE acctsessionid='zbx-$$'")" = 0 ] && ok "FR_ACCT_IGNORAR_USUARIOS: zabbix fora do radacct" || nok "zabbix gravado no radacct"
[ "$(sql "SELECT COUNT(*) FROM radacct WHERE acctsessionid='rx-$$'")" = 1 ] && ok "FR_ACCT_IGNORAR_USUARIOS: ponto escapado (monXitor gravado)" || nok "regex sem escape"
[ "$(sql "SELECT COUNT(*) FROM radpostauth WHERE username='usuario1' AND pass='(authentik)' AND reply='Access-Accept' AND authdate > NOW() - INTERVAL 2 MINUTE")" -ge 1 ] && ok "radpostauth gravado com pass='(authentik)'" || nok "radpostauth Accept sem '(authentik)'"
[ "$(sql "SELECT COUNT(*) FROM radpostauth WHERE username='usuario1' AND reply='Access-Reject' AND pass='(authentik)'")" -ge 1 ] && ok "radpostauth registra o Reject" || nok "radpostauth sem Reject"
[ "$(sql "SELECT COUNT(*) FROM radpostauth WHERE username='chapuser' AND pass='(legado)'")" -ge 1 ] && ok "radpostauth do CHAP com pass='(legado)'" || nok "radpostauth do CHAP ausente"
[ "$(sql "SELECT COUNT(*) FROM radpostauth WHERE pass LIKE '%$SENHA%' OR pass LIKE '%$SENHA_CHAP%'")" = 0 ] && ok "nenhuma senha gravada em radpostauth" || nok "SENHA gravada em radpostauth!"
if frlog | grep -qF -- "$SENHA"; then nok "senha apareceu no log!"; else ok "senha não aparece no log"; fi
[ "$(sql 'SELECT COUNT(*) FROM nas')" = 3 ] && ok "tabela nas intacta" || nok "tabela nas alterada"


# ========== G. rajada (zabbix): trava + reserva com um authentik LENTO ==========
#  Relé UDP que atrasa cada pedido 2 s (como o PBKDF2 do authentik real) e
#  conta quantos pedidos chegaram ao "authentik".
cat > "$TMP/rele.py" <<'PY'
import socket, threading, time, sys
up = (sys.argv[1], 1812); s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.bind(("0.0.0.0", 1812))
def trata(dado, origem):
    print("PEDIDO", flush=True); time.sleep(2)
    u = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); u.settimeout(5); u.sendto(dado, up)
    try: s.sendto(u.recvfrom(4096)[0], origem)
    except Exception: pass
while True:
    d, o = s.recvfrom(4096); threading.Thread(target=trata, args=(d, o), daemon=True).start()
PY
docker run -d --name "$P-rele" --network "$REDE" --memory 64m -v "$TMP/rele.py:/rele.py:ro" \
  docker.io/library/python:3.12-slim python -u /rele.py "$UP_IP" >/dev/null
sleep 2
RELE_IP=$(docker inspect -f "{{(index .NetworkSettings.Networks \"$REDE\").IPAddress}}" "$P-rele")
n_rele() { docker logs "$P-rele" 2>&1 | grep -c PEDIDO || true; }
subir_fr FR_CHAP_LEGADO=sim FR_GRAVAR_SQL=nao FR_CACHE_TTL=4 FR_CACHE_RESERVA_TTL=300 FR_CACHE_TRAVA_TTL=25 AUTHENTIK_OUTPOST_IP="$RELE_IP"
rajada() { # usuario senha N retransmissoes timeout -> nº de Access-Accept
  local i
  for i in $(seq 1 "$3"); do printf 'User-Name = "%s"\nUser-Password = "%s"\nNAS-IP-Address = 10.233.%d.%d\n\n' "$1" "$2" $((i / 250)) $((i % 250 + 1)); done \
    | docker exec -i "$P-cli" sh -c "cat > /tmp/rajada; radclient -f /tmp/rajada -p $3 -r $4 -t $5 $FR_IP:1812 auth '$SEG_NAS' 2>&1" | grep -c 'Received Access-Accept' || true
}
antes=$(n_rele)
aceitos=$(rajada usuario1 "$SENHA" 60 4 3)
depois=$(n_rele)
[ "$aceitos" -ge 60 ] && ok "rajada fria: 60/60 aceitos (retransmissão encontra o cache)" || nok "rajada fria: só $aceitos/60 aceitos"
[ $((depois - antes)) -le 3 ] && ok "rajada fria: só $((depois - antes)) pedido(s) chegaram ao authentik (trava)" || nok "rajada fria: $((depois - antes)) pedidos foram ao authentik"
logtem 'origem=cache-aguardou' && ok "log origem=cache-aguardou (esperou a consulta em andamento)" || nok "log origem=cache-aguardou ausente"

aceitos=$(rajada usuario2 "$SENHA" 1 1 10)   # usuario2 entra na reserva
sleep 5                                       # cache fresco (4 s) expira
antes=$(n_rele)
aceitos=$(rajada usuario1 "$SENHA" 60 1 2)
sleep 4   # revalidação em segundo plano
depois=$(n_rele)
[ "$aceitos" -ge 60 ] && ok "rajada com reserva: 60/60 aceitos na hora (timeout de 2 s)" || nok "rajada com reserva: só $aceitos/60 aceitos"
[ $((depois - antes)) -eq 1 ] && ok "rajada com reserva: 1 revalidação em segundo plano" || nok "rajada com reserva: $((depois - antes)) pedidos ao authentik"
logtem 'origem=reserva ' && ok "log origem=reserva" || nok "log origem=reserva ausente"
r=$(rajada usuario1 "$SENHA" 1 1 4); out=$(pap usuario1 "$SENHA")
grep -q 'Mikrotik-Group' <<<"$out" && ok "atributos presentes após a revalidação" || nok "atributos ausentes após a revalidação"

#  authentik fora: quem está na reserva entra NA HORA; senha nunca vista fica sem resposta
vivos=$(frlog | grep -c 'alive again' || true)
docker stop "$P-rele" >/dev/null
sleep 5
s0=$(date +%s%N); out=$(pap usuario1 "$SENHA" 3); ms=$(( ($(date +%s%N) - s0) / 1000000 ))
grep -q 'Received Access-Accept' <<<"$out" && grep -q 'Mikrotik-Group' <<<"$out" && ok "authentik fora + reserva: aceito com atributos em ${ms} ms" || nok "authentik fora + reserva não aceitou"
out=$(pap usuario1 "senha-nunca-vista" 30)
grep -qE 'Received Access-(Accept|Reject)' <<<"$out" && nok "senha desconhecida respondida com authentik fora" || ok "authentik fora + sem reserva: sem resposta"
docker start "$P-rele" >/dev/null
#  O home server passa por zombie (response_window 20 s) -> dead (zombie_period)
#  -> vivo de novo (revive_interval 30 s): ~80 s depois da falha. Antes disso a
#  revalidação falha na hora e a reserva continua valendo (authentik "fora").
for i in $(seq 1 120); do
  [ "$(frlog | grep -c 'alive again' || true)" -gt "$vivos" ] && break
  sleep 1
done
[ "$i" -lt 120 ] || nok "home server não voltou a ficar vivo em 120 s"

#  authentik passa a recusar (usuário desativado/senha trocada): o primeiro
#  pedido ainda sai da reserva e dispara a revalidação, que apaga a reserva.
sed "s/^usuario2 Cleartext-Password := .*/usuario2 Cleartext-Password := \"trocada-$$\"/" "$TMP/up/authorize" > "$TMP/up/authorize.novo"
cat "$TMP/up/authorize.novo" > "$TMP/up/authorize"   # mantém o inode (bind mount)
docker restart "$P-up" >/dev/null; sleep 4
sleep 5
pap usuario2 "$SENHA" 3 >/dev/null
sleep 5    # revalidação em segundo plano (relé de 2 s)
logtem 'usuario=usuario2 proto=pap origem=revalidacao resultado=Access-Reject' && ok "revalidação em segundo plano recebeu a recusa" || nok "log da revalidação com recusa ausente"
out=$(pap usuario2 "$SENHA" 10)
grep -q 'Received Access-Reject' <<<"$out" && ok "reserva apagada: próximo login recusado" || nok "reserva continuou aceitando após a recusa: $(grep -oE 'Received Access-(Accept|Reject)' <<<"$out")"
docker rm -f "$P-rele" >/dev/null 2>&1 || true

[ "$erros" -eq 0 ] || { echo "$erros verificação(ões) falharam" >&2; exit 1; }
echo "Teste isolado concluído sem falhas."
