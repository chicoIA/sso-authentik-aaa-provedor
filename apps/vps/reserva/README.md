# Pilha reserva na VPS

Projeto Docker `provedor-reserva`, que mantém na VPS as réplicas dos bancos da
VM e, na ativação, atende RADIUS, LDAP, TACACS+ e o `sso.` no lugar dela.
Desenho e roteiro: [docs/failover-vps.md](../../../docs/failover-vps.md).

Na VPS: `/opt/provedor-reserva/`, com o `compose.yml` daqui e um `.env` próprio
(modo 600, fora do repositório). Rede própria `10.233.10.0/24` (só IPv4). Por
quê a mesma faixa da rede Docker da VM: o provider RADIUS do authentik só
aceita o outpost vindo de `10.233.0.0/16` ou `127.0.0.1`, e a réplica traz essa
configuração da VM.

| Serviço | O que é | Quando roda |
|---|---|---|
| `reserva-postgres` | réplica em streaming (só leitura) do Postgres do authentik da VM | sempre |
| `reserva-mariadb` | cópia das 6 tabelas que o FreeRADIUS lê + estrutura vazia de `radacct`/`radpostauth` | sempre |
| `reserva-authentik-server`/`-worker`, `reserva-radius-outpost`, `reserva-freeradius`, `reserva-ldap-outpost`, `reserva-tacacs` | pilha de atendimento, perfil `ativa` (não sobe com `up` comum) | só com a reserva ativa |
| `reserva-pg-teste` | clone descartável do Postgres, perfil `teste` | só no teste |

| Arquivo no repositório | Destino na VPS |
|---|---|
| `compose.yml` | `/opt/provedor-reserva/compose.yml` |
| `provedor-reserva`, `provedor-radius-sonda`, `provedor-recebe-radius`, `provedor-reserva-snmp`, `provedor-tacacs-conjuntos-snmp` | `/usr/local/sbin/` |
| `provedor-reserva-vigia.service` | `/etc/systemd/system/` |

## O que preparar

- **`.env`:** `PG_REPLICA_PASS`, `RESERVA_DB_ROOT_PASS` e `RESERVA_DB_PASS` são
  próprios da reserva. A pilha de atendimento usa os mesmos valores do `.env`
  da VM para `PG_PASS`, `AUTHENTIK_SECRET_KEY`, `AUTHENTIK_RADIUS_TOKEN`,
  `AUTHENTIK_RADIUS_SECRET`, `AUTHENTIK_LDAP_TOKEN`, `FR_SEGREDO_LOCAL`,
  `TACACS_KEY` e `LDAP_SERVICO_SENHA`.
- **Imagens:** as do FreeRADIUS (`provedor/freeradius:3.2.10`) e do TACACS+
  (`provedor-tacacs:local`) são construídas na VM e copiadas com
  `docker save`/`docker load`; ao mudar `apps/freeradius` ou `apps/tacacs`,
  copie de novo. A ativação usa `--pull never`: toda imagem da pilha tem que
  estar baixada antes. `provedor-reserva estado` avisa se faltar alguma.
- **Mesmas versões da VM** para Postgres (réplica física exige o mesmo major) e
  MariaDB.
- **`./media`:** cópia de `apps/authentik/data/media` da VM (marca do login).
- **Rede do Caddy:** o `reserva-authentik-server` entra também na rede Docker do
  Caddy (`proxy_default` no `compose.yml`), para o `sso.` apontar para ele na
  ativação.

## Postgres (réplica)

- Origem: VM `172.16.7.10:5432` (porta publicada no compose do authentik; o
  firewall da VM só aceita `172.17.55.7` e `172.16.20.5`, os IPs da VPS nos
  túneis). **Não** use o `.196`: no failover ele existe na própria VPS.
- Na VM: usuário `replicador` (só REPLICATION) e slot físico `vps_reserva`. A VM
  retém no máximo 2 GB de WAL (`max_slot_wal_keep_size`), para uma VPS fora do
  ar não encher o disco dela.
- Conferir: na VPS `docker exec provedor-reserva-reserva-postgres-1 psql -U authentik -d authentik -c "select status from pg_stat_wal_receiver" -c "select now()-pg_last_xact_replay_timestamp()"`;
  na VM `select * from pg_stat_replication` / `pg_replication_slots`.
- **Primeira carga e refazer do zero** (a VPS ficou fora tempo demais e o slot
  passou de 2 GB, ou depois de um failover): pare o serviço, apague o volume
  `provedor-reserva_pg-reserva` e faça a carga:
  ```bash
  cd /opt/provedor-reserva && set -a && . ./.env && set +a
  docker compose run --rm --no-deps -T -e PGPASSWORD="$PG_REPLICA_PASS" --entrypoint sh reserva-postgres -c \
    'test -z "$(ls -A $PGDATA)" && pg_basebackup -h 172.16.7.10 -U replicador -D $PGDATA -R -S vps_reserva -X stream -c fast --max-rate=10M && chown -R postgres:postgres $PGDATA && chmod 700 $PGDATA'
  docker compose up -d reserva-postgres
  ```
  Nunca suba o serviço com o volume vazio: o entrypoint criaria um banco novo.

## MariaDB (cópia das tabelas do FreeRADIUS)

- A VM envia a cada 5 min (`provedor-envia-radius.timer`, `apps/host/reserva/`):
  `nas radcheck radreply radgroupcheck radgroupreply radusergroup`.
- Chega por SSH com a chave `/root/.ssh/id_ed25519_reserva` da VM, que na VPS
  só executa `/usr/local/sbin/provedor-recebe-radius` (`command=`,
  `from="203.0.113.25"`, `restrict` em `authorized_keys`; o `from` é o IP com
  que a VM chega à VPS).
- O recebimento carrega em `radius_carga` e só troca (RENAME atômico) se o dump
  chegou inteiro e com as 6 tabelas; senão fica a cópia anterior.
- Conferir: `journalctl -u provedor-envia-radius -o cat | grep ^ok | tail -1` na VM.

## Teste da pilha de atendimento

O authentik não roda numa réplica só leitura. O teste é feito num **clone**,
com o FreeRADIUS em porta alternativa (`11812`/`11813`, fechadas no firewall da
VPS), sem tocar na réplica nem na VM:

1. `docker compose --profile teste create reserva-pg-teste`; parar `reserva-postgres`;
   copiar o volume (`docker run --rm -v provedor-reserva_pg-reserva:/de:ro -v provedor-reserva_pg-teste:/para postgres:16.15-alpine sh -c 'cp -a /de/. /para/'`);
   subir de novo a réplica.
2. Subir o clone (`primary_conninfo` vazio: nunca conecta na VM) e `select pg_promote()`.
3. `RESERVA_PG_HOST=reserva-pg-teste docker compose --profile ativa up -d --no-deps <serviços>`.
4. Usuário temporário **só no clone** + `radclient` em `127.0.0.1:11812` dentro do
   `reserva-freeradius`: Accept com o atributo de grupo esperado (ex.:
   `Mikrotik-Group`), Reject com senha errada, accounting gravado no
   `reserva-mariadb` (apague depois).
5. Parar e remover os containers dos perfis `ativa`/`teste` e o volume `provedor-reserva_pg-teste`.

Os `mem_limit` do `compose.yml` foram dimensionados para a pilha inteira caber
numa VPS de 4 GB de RAM.

## Ativação e volta

- `provedor-reserva estado`: estado, sondas, réplica, destino do `sso.` e
  imagens da pilha.
- `provedor-reserva ativa`: promove o Postgres (a partir daí a réplica precisa
  ser refeita), sobe a pilha com o FreeRADIUS em 1812/1813, espera o authentik
  e testa a cadeia FreeRADIUS → outpost → authentik. Só então troca o `sso.`
  para o authentik da reserva (com a administração congelada), cria a `radius0`
  (o anúncio BGP) e sobe o LDAP e o TACACS+, cujas portas são presas ao `.196`.
  Se a pilha não responder, o `.196` **não** é assumido.
- `provedor-reserva volta [--forcar]`: tira a `radius0` e devolve o Caddy para
  a VM. Exporta a contabilidade gravada na reserva para
  `/var/lib/provedor-reserva/contabilidade-*.sql` (na VM:
  `provedor-traz-contabilidade`). Para a pilha e refaz a réplica do zero. Sem
  `--forcar`, só roda se a VM estiver respondendo RADIUS.
- `provedor-reserva-vigia.service`: sonda o RADIUS da VM (Status-Server no
  `.196` e no `172.16.7.10`) a cada 15 s. Ativa sozinho com a VM 5 min sem
  responder (`PROVEDOR_RESERVA_ESPERA`, padrão 300 s), só se existir
  `/etc/provedor-reserva/automatico` e a VPS tiver ao menos uma sessão BGP de
  pé. Sem o arquivo, só avisa. Com a reserva ativa, derruba a `radius0` se o
  FreeRADIUS local parar de responder e a sobe de novo quando ele volta.

Cuidados:

- **A volta é sempre manual.** O tráfego volta sozinho para a VM quando ela
  anuncia o `/32` de novo; o `volta` só arruma a VPS (contabilidade, réplica,
  Caddy).
- **Não altere nada no authentik com a reserva ativa.** O banco promovido é
  descartado na volta, e o que foi mudado nele se perde. Por isso o `sso.` da
  reserva responde 503 em `/if/admin/*`.
- A contabilidade gravada na reserva usa ids a partir de `1000000000` em
  `radacct` e `radpostauth`, para não colidir com os da VM. A importação na VM
  usa `REPLACE` e pode ser repetida.
- A sonda usa o segredo do cliente `172.16.0.0/12` da tabela `nas` (a VPS fala
  com a VM como um NAS). Sem esse registro na cópia da tabela, o vigia não
  consegue sondar a VM.
- Avisos: se existir o executável `/etc/provedor-reserva/alerta`, ele recebe
  cada mensagem de alerta como argumento. Tudo vai também para o syslog
  (`journalctl -t provedor-reserva`). Estado para o Zabbix:
  [docs/monitoramento-zabbix.md](../../../docs/monitoramento-zabbix.md).
