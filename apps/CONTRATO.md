# Contrato entre os apps (leia antes de mexer em qualquer `apps/<app>/`)

Cada diretório em `apps/` é um **app independente**: um projeto Docker Compose
próprio (`provedor-<app>`), com seu `compose.yml`, `env.example`, `README.md`
e `teste.sh`. O orquestrador `./provedor` (raiz do repositório) sobe, testa e
derruba os apps na ordem certa. Os apps se falam pela rede Docker externa
`provedor` e leem um único `.env` na raiz.

## Servidor (premissas do repositório)

O repositório parte de um servidor como este. Confira cada item no seu ambiente
antes de subir qualquer coisa; onde for diferente, ajuste o `.env` e o script
`provedor`.

- Uma VM pequena com Debian 12 e 4 vCPU. O conjunto usa perto de **2 GB de
  memória**: com 4 GB de RAM há folga, com 2 GB é preciso swap. Por isso todo
  serviço tem `mem_limit` e o authentik roda com consumo reduzido.
- **Produção no sistema (sem Docker) — NÃO TOCAR**:
  FreeRADIUS 3.2 (systemd `freeradius`, UDP 1812/1813, configuração em
  `/etc/freeradius/3.0`),
  MariaDB (`*:3306`, socket `/run/mysqld/mysqld.sock`, banco `radius`),
  Apache `:80` com daloRADIUS em `/var/www/html/daloradius`.
  Recomendado: `OOMScoreAdjust=-900` nas unidades `mariadb` e `freeradius`,
  para o kernel não matá-los primeiro se faltar memória.
- Docker recente com o plugin Compose (referência: Docker 29 e Compose v5). Pool de redes Docker: **`10.233.0.0/16`**
  (`default-address-pools` em `/etc/docker/daemon.json`; o `./provedor preparar`
  confere). **Nunca** crie redes Docker em faixas usadas pelos equipamentos
  (NAS). O padrão do Docker cai em `172.16.0.0/12`, que costuma ser rede de
  gerência, assim como o CGNAT `100.64.0.0/10`.

## Dados do daloRADIUS (banco `radius`)

O que a migração e o FreeRADIUS novo esperam encontrar, e os casos que tratam:

- Usuários em `radcheck` com `Cleartext-Password :=`. `radreply` pode estar
  vazio ou ter atributos por usuário.
- Usernames com `@dominio` são **literais** (não há `suffix`/realm stripping no
  `authorize`): migrar com o nome exato.
- Grupos (`radusergroup`/`radgroupreply`) com o perfil de cada nível. Exemplo
  típico, que o blueprint do app `radius` reproduz em `radius-admin` e
  `radius-leitura`:
  - administrador: `Mikrotik-Group := full`,
    `Service-Type := Administrative-User`, `Huawei-Exec-Privilege = 15`
  - leitura: `Service-Type := Login-User`, `Mikrotik-Group := read`,
    `Huawei-Exec-Privilege = 2`
  - `daloRADIUS-Disabled-Users`: `radgroupcheck Auth-Type := Reject`
    → usuário **desativado** no authentik.
- O arquivo `users` do FreeRADIUS em produção (`mods-config/files/authorize`)
  pode ter usuários que **não** estão no SQL (com `Cleartext-Password` e
  atributos de resposta). Eles também precisam ser migrados; a ferramenta lê o
  arquivo.
- Tabela `nas`: entradas por IP ou CIDR, às vezes com um `0.0.0.0/0` ("todos").
  **A tabela `nas` e os segredos são intocáveis**: o FreeRADIUS novo só LÊ
  (`read_clients = yes`, `client_table = "nas"`). Nunca exportar, regravar,
  alterar ou copiar segredos para arquivos.
- Carga: o usuário de monitoramento (ex.: `zabbix`) costuma responder pela
  maior parte dos logins e chega em **rajadas** (centenas de NAS no mesmo
  segundo). O cache do FreeRADIUS novo existe por causa disso. O `radacct`
  cresce a ponto de chegar a dezenas de GB (ver `apps/banco`).
- No daloRADIUS padrão o `radpostauth` só registra aceites (não há
  `Post-Auth-Type REJECT`) e grava a senha em texto puro na coluna `pass`.
- Site `default` do FreeRADIUS de um daloRADIUS típico: authorize =
  filter_username, preprocess, huntgroup via SQL, chap, mschap, eap, files, sql,
  expiration, logintime, pap; accounting/session/post-auth = sql (+ sqlippool).
- Uso de CHAP/MS-CHAP pelos equipamentos: em geral **desconhecido** antes da
  migração. O FreeRADIUS novo registra em log quem manda CHAP/MS-CHAP, para o
  relatório.

## Regras de segurança (valem para quem mexe em qualquer app)

1. Nunca parar/reiniciar/recarregar `freeradius`, `mariadb` ou `apache2` do
   sistema; nunca editar `/etc/freeradius`, `/etc/mysql`, `/var/www`.
2. Nunca escutar 1812/1813 (UDP). Testes do FreeRADIUS novo: **11812/11813**.
3. Banco `radius`: **somente leitura**. Nada de INSERT/UPDATE/DELETE/DDL.
   Em modo teste (`FR_GRAVAR_SQL=nao`) o FreeRADIUS novo não grava
   `radacct`/`radpostauth`; só em produção (`FR_GRAVAR_SQL=sim`, após a virada).
4. Nunca imprimir segredos/senhas em logs, relatórios ou saída de comandos.
   Credenciais do MySQL para scripts: `/root/.my-radius.cnf` (modo 600) ou
   variáveis `DALO_DB_*` do `.env`.
5. Fase de construção: só escrever arquivos e validar estaticamente
   (`docker compose config`, `docker build` da própria imagem,
   `python3 -m py_compile`, `freeradius -XC` dentro da imagem). **Não** rodar
   `docker compose up` — a subida é feita pelo orquestrador, um app por vez.
6. Todo serviço tem `mem_limit` (a VM é pequena) e `restart: unless-stopped`
   (ferramentas que rodam e terminam, como `migracao`, usam `restart: "no"`).
7. Escreva só dentro do seu `apps/<app>/`. Textos, comentários e mensagens em
   português (pt-BR), no estilo do repositório.

## Convenções técnicas

| Item | Valor |
|---|---|
| Projeto Compose de cada app | `provedor-<app>` (`docker compose -p provedor-<app> --env-file .env -f apps/<app>/compose.yml`) |
| Rede compartilhada | `networks: { provedor: { external: true, name: provedor } }` (criada pelo orquestrador, `10.233.10.0/24`) |
| `.env` | único, na raiz; cada app documenta suas variáveis em `apps/<app>/env.example` |
| Nomes de serviço (DNS na rede `provedor`) | `authentik-postgres`, `authentik-server`, `authentik-worker`, `radius-outpost`, `freeradius`, `ldap-outpost`, `tacacs`, `painel` |
| authentik interno | `http://authentik-server:9000` |
| authentik externo | `AUTHENTIK_URL_EXTERNA` (o padrão do `env.example` é só um exemplo: troque pelo endereço do seu ambiente) |
| Versão authentik | `AUTHENTIK_TAG=2026.8.3` (sem Redis: só PostgreSQL) |
| Blueprints | cada app coloca os seus em `apps/<app>/blueprints/*.yaml`; o app `authentik` monta `apps/<app>/blueprints` em `/blueprints/provedor/<app>` (apps: authentik, radius, ldap, tacacs, painel). Blueprints opcionais ficam em `apps/authentik/opcionais/` e só valem quando copiados para `apps/authentik/blueprints/` |
| Token admin para scripts | `AUTHENTIK_BOOTSTRAP_TOKEN` (API `http://127.0.0.1:9000/api/v3/`) |

### Portas no host

| Serviço | Porta |
|---|---|
| authentik-server | `9000/tcp` (http), `9443/tcp` (https) |
| authentik-postgres | `5432/tcp` (replicação para a reserva, `docs/failover-vps.md`; restrinja no firewall do host) |
| radius-outpost | `127.0.0.1:18120/udp` → container `1812/udp` |
| freeradius (network_mode host) | `FR_PORTA_AUTH`/`FR_PORTA_ACCT` = 11812/11813 (teste) ou 1812/1813 (após a virada) |
| ldap-outpost | `389/tcp` → `3389`, `636/tcp` → `6636`; interno `ldap-outpost:3389` |
| tacacs | `49/tcp` → container `4949` (só sobe com `./provedor up tacacs`) |
| painel | `9049/tcp` |

### Objetos no authentik (identificadores fixos)

| Objeto | Nome / slug |
|---|---|
| Fluxo de autenticação para outposts | `provedor-radius-autenticacao` (usuário e senha; etapa de MFA `provedor-radius-mfa` definida mas não vinculada, ver `docs/ssh-2fa.md`; também usado pelo LDAP) |
| Aplicação/provider RADIUS | app `radius-equipamentos`, provider `provedor-radius-equipamentos`, outpost `provedor-radius` |
| Grupos de acesso RADIUS | `radius-admin`, `radius-leitura` (vinculados à aplicação; dão o acesso e o nível) |
| Grupos migrados | mesmos nomes do daloRADIUS, atributos `radius_reply` (lista `"Atributo op valor"`) e `radius_prioridade`; todo usuário migrado entra também em `radius-equipamentos`, que o blueprint vincula à aplicação (ver `docs/migracao.md`) |
| Aplicação/provider LDAP | app `provedor-ldap`, provider `provedor-ldap`, outpost `provedor-ldap`, base DN `dc=ldap,dc=provedor,dc=com,dc=br`, `bind_mode` = `cached`, `search_mode` = `direct`; certificado da 636 com o nome `ldap-sso.provedor.interno` (gerado em cada ambiente, `docs/linux-sso.md`) |
| Acesso LDAP | grupo `ldap-acesso`; conta de serviço `ldap-servico` (senha `LDAP_SERVICO_SENHA`), bind DN `cn=ldap-servico,ou=users,dc=ldap,dc=provedor,dc=com,dc=br` |
| TACACS+ | grupos `tacacs-admin` (priv 15), `tacacs-operador` (priv 7), `tacacs-leitura` (priv 1), mais os grupos por lista `tacacs-admin-or-hosts-leitura` e `tacacs-admin-or-hosts-operador`; atributo de grupo `tacacs_priv_lvl`; todos podem fazer bind no app `provedor-ldap` (`docs/tacacs.md`) |
| Login Linux | grupos `linux-admin`, `linux-operador`, `linux-leitura`, `linux-admin-or-hosts-operador`, `linux-leitura-or-hosts-operador`; conta de serviço `linux-servico`; bind no app `provedor-ldap` (`docs/linux-sso.md`) |
| Painel TACACS | app/provider OAuth2 `painel-tacacs` (client_id `painel-tacacs`, segredo `PAINEL_OIDC_SECRET`), acesso: grupos `painel-tacacs` e `tacacs-admin` |
| SSO de sistemas web | providers `provedor-grafana` (OIDC, client_id `grafana`), `provedor-zabbix` (SAML), `provedor-netbox` (OIDC, client_id `netbox`), `provedor-wiki` (OIDC, client_id `wiki-provedor`); grupos `grafana-*`, `zabbix-*`, `netbox-*`, `wiki-leitura`/`wiki-escrita` |

### Log do TACACS (contrato entre `tacacs` e `painel`)

Volume Docker externo `provedor-tacacs-logs`, montado em `/var/log/tacacs`
(leitura e escrita no `tacacs`, só leitura no `painel`). Arquivo
`/var/log/tacacs/eventos.tsv`, uma linha por evento, campos separados por TAB
(TAB/quebra de linha dentro de campo viram espaço):

```
data_hora_iso8601  tipo  nas_ip  usuario  porta  origem  resultado  detalhe
```

- `tipo`: `authen` | `author` | `acct`
- `resultado`: authen → `permitido`/`negado`; author → `permitido`/`negado`;
  acct → `start`/`stop`/`update`
- `detalhe`: comando (author/acct) ou mensagem/perfil (authen)
- `origem`: IP de quem conectou no equipamento (rem_addr), se o NAS enviar
