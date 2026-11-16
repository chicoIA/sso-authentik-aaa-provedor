# App tacacs

TACACS+ para login e comandos nos equipamentos (Cisco, Huawei, Juniper, Datacom),
usando o diretório do authentik. **Previsto para depois da migração do RADIUS**: o
orquestrador só sobe com comando explícito (`./provedor up tacacs`). Não mexe
no cadastro de NAS, nos segredos do RADIUS nem no FreeRADIUS atual.

- Daemon: [tac_plus-ng](https://github.com/MarcJHuber/event-driven-servers) (Marc Huber),
  compilado no `Dockerfile` a partir de um commit **fixo** (`TACPLUS_COMMIT`).
- Usuários e senhas: nenhum fica no tac_plus-ng. Ele consulta o outpost LDAP
  (`ldap://ldap-outpost:3389`, bind com `ldap-servico`) pelo backend MAVIS
  `mavis_tacplus-ng_ldap.pl` (Perl Net::LDAP) e lê o `memberOf` do usuário.
- Porta `49/tcp` publicada no host (container escuta 4949; não é `network_mode: host`).
  `mem_limit` 192m, sem privilégios (usuário `tacacs`, `cap_drop: ALL`, rootfs somente leitura).

## Grupos do authentik e perfis

| Grupo | Perfil no equipamento |
|---|---|
| `tacacs-admin` | priv-lvl 15, todos os comandos |
| `tacacs-operador` | priv-lvl 2: no Huawei, nível de configuração (`system-view` e configurar; sem usuários, AAA, arquivos, `save`/`reboot`); no Juniper, classe `operator`; onde há autorização por comando (Datacom), tudo menos `aaa`/usuários, firmware, arquivos, `reboot`, `rollback` |
| `tacacs-leitura` | priv-lvl 1, só `show`, `display`, `ping`, `traceroute`/`tracert`, `exit`/`quit`/`logout` e ajuste de paginação do terminal; o resto é negado |
| `tacacs-admin-or-hosts-leitura` | **admin em todos os equipamentos, menos nos da lista** (atributo `tacacs_leitura_em` do grupo; por exemplo, as bordas BGP), onde é `tacacs-leitura`. A restrição vale mesmo se a pessoa também estiver em `tacacs-admin` |
| `tacacs-admin-or-hosts-operador` | **admin em todos os equipamentos, menos nos da lista** `tacacs_operador_em`, onde é `tacacs-operador` (lista vazia = admin em tudo) |

Quem está em mais de um grupo recebe o maior privilégio. Quem não está em
nenhum é **negado**. Só os grupos `tacacs-*` são lidos (`LDAP_MEMBEROF_FILTER` no
`entrypoint.sh`): os outros grupos do usuário não custam buscas no login. O blueprint `blueprints/04-tacacs.yaml` cria os grupos (atributo
`tacacs_priv_lvl` = 15/7/1, só informativo) e libera o bind deles na aplicação
`provedor-ldap`. Para Juniper, o perfil devolve `local-user-name` igual ao nome do
grupo (crie usuários-modelo locais com esses nomes; roteiro em
[docs/tacacs-juniper-mx204.md](../../docs/tacacs-juniper-mx204.md)).

### Acesso por conjunto de equipamentos (editado no authentik)

Um grupo `tacacs-*` com os atributos abaixo vira, no TACACS+, **leitura (ou operador) nos
equipamentos listados e o perfil do `tacacs_priv_lvl` em todos os outros**
(*Diretório → Grupos → grupo → Editar → Atributos*):

```yaml
tacacs_priv_lvl: 15          # perfil fora da lista: 15 admin, 7 operador, 1 leitura
tacacs_leitura_em:           # IP de ORIGEM do equipamento (o "equipamento" do painel): nome
  172.16.41.254: BORDA-A
  172.17.30.165: BORDA-C
tacacs_operador_em:          # (opcional) aqui o grupo é operador
  172.16.41.250: CORE-A
```

As duas listas são opcionais; IP nas duas = leitura (a mais restrita). **Huawei:** operador =
nível 2 (configuração, sem usuários/AAA/arquivos/`save`); no Juniper, classe `operator`.

Para incluir ou tirar um equipamento, edite a lista e salve: em até ~1 minuto vale no
servidor principal e no servidor reserva ([docs/failover-vps.md](../../docs/failover-vps.md)). Aceita IP ou faixa (`172.16.76.0/24`). Para outro grupo com a
mesma lógica, crie o grupo `tacacs-<nome>` com esses atributos (o bind no LDAP é criado
sozinho). A regra vem antes dos grupos globais: a restrição vale mesmo para quem também
está em `tacacs-admin`. Coloque a pessoa no grupo **antes** de ela tentar logar (uma
recusa fica no cache do outpost LDAP; se acontecer, `docker restart provedor-ldap-ldap-outpost-1`).

Por trás: `provedor-tacacs-conjuntos` (`apps/tacacs/conjuntos/`, timer de 1 min no servidor principal)
lê os grupos pela API, gera `/etc/provedor-tacacs/{redes,regras}.cfg` (montado em
`/etc/tacacs/conjuntos`, incluído pelo `tac_plus-ng.cfg.modelo`), **testa a configuração
antes de aplicar** (`tac_plus-ng -P`), reinicia o TACACS+ só se mudou (~3 s) e copia os
arquivos e o estado para o servidor reserva (por SSH, host `vps`). IP inválido é ignorado com aviso; authentik fora ou
configuração inválida = fica a última lista boa. Também guarda um hash dos membros dos
grupos `tacacs-*` (`/var/lib/provedor-tacacs/membros.sha256`) e, quando muda, reinicia o
outpost LDAP para limpar o cache de bind (sem isso, a recusa de quem ainda não tinha grupo fica guardada por 5 min).
`provedor-tacacs-conjuntos --mostrar`
mostra o que seria gerado. Estado: `/var/lib/provedor-tacacs/conjuntos.estado` (código
0 ok, 1 aviso, 2 erro), no Zabbix pelo SNMP do servidor reserva (`apps/vps/snmp/`, código 9 = sem
notícia há 5 min). Sem os arquivos, o TACACS+ sobe só com os grupos globais.

Instalação (servidor principal): `install -m 0755 apps/tacacs/conjuntos/provedor-tacacs-conjuntos /usr/local/sbin/`,
os `.service`/`.timer` em `/etc/systemd/system/` e `systemctl enable --now provedor-tacacs-conjuntos.timer`.

## Variáveis (`env.example`)

- `TACACS_KEY`: chave TACACS+ dos equipamentos (gerada pelo orquestrador; 8+ caracteres,
  só letras, números e `. _ ~ + = @ % ^ -`). Mesma chave em todos os equipamentos.
- Usa também `LDAP_SERVICO_SENHA` e `AUTHENTIK_LDAP_BASE_DN` (do app ldap).
- Opcional: `TACACS_LDAP_URL` (padrão `ldap://ldap-outpost:3389`).

Equipamentos aceitos (qualquer outro IP é recusado): `100.65.0.0/16`, `100.66.0.0/16`,
`172.16.0.0/12`, `198.51.100.0/26` e `10.233.0.0/16` (rede interna do Docker, para
testes). Para mudar as faixas, edite `tac_plus-ng.cfg.modelo` (`device equipamentos`)
e suba de novo com `./provedor up tacacs`.

## Subir e testar

```
./provedor up tacacs        # constrói a imagem, usa a rede provedor e o volume provedor-tacacs-logs
apps/tacacs/teste.sh        # com o app no ar
```

O `teste.sh` cria usuários temporários pela API, faz authen, author (`show version`
permitido e `configure terminal` negado para leitura) e accounting start/stop com um
cliente TACACS+ descartável, confere as linhas em `eventos.tsv` e apaga os usuários.

## Operar pela interface do authentik

- Dar acesso: Diretório > Grupos > `tacacs-admin`, `tacacs-operador` ou `tacacs-leitura` >
  Usuários > Adicionar usuário existente.
- Tirar acesso: remover o usuário do grupo (vale em até 1 minuto, por causa do cache do
  MAVIS) ou desativar o usuário.
- Trocar a senha: no próprio usuário no authentik. Não há senha local no equipamento TACACS.
- Não há edição de texto para usuários ou permissões.

## Log de eventos (contrato com o painel)

`/var/log/tacacs/eventos.tsv` (volume `provedor-tacacs-logs`), também em `docker logs`:

```
data_hora_iso8601  tipo  nas_ip  usuario  porta  origem  resultado  detalhe
```

`tipo` = `authen`/`author`/`acct`; `resultado` = `permitido`/`negado` (authen, author) ou
`start`/`stop`/`update` (acct); `detalhe` = comando ou mensagem. O tac_plus-ng troca
TAB, quebra de linha e bytes não imprimíveis por `\ooo` (octal). Na subida, se o arquivo
passar de 50 MB, o anterior vira `eventos.tsv.1`.

## Configurar os equipamentos

Servidor TACACS+: `100.66.80.196`, porta 49, chave = `TACACS_KEY`. Antes de ligar o
TACACS+ num equipamento, restrinja o SSH dele às redes de gerência
([docs/ssh-acl.md](../../docs/ssh-acl.md)). Mantenha sempre um
usuário local de emergência (`local` como segunda opção de autenticação). Os blocos
abaixo são exemplos; confira a sintaxe na versão do seu equipamento.

**Cisco IOS**

```
aaa new-model
tacacs server PROVEDOR
 address ipv4 100.66.80.196
 key <TACACS_KEY>
 timeout 5
aaa group server tacacs+ PROVEDOR
 server name PROVEDOR
aaa authentication login default group PROVEDOR local
aaa authentication enable default group PROVEDOR enable
aaa authorization exec default group PROVEDOR local
aaa authorization commands 0 default group PROVEDOR local
aaa authorization commands 1 default group PROVEDOR local
aaa authorization commands 7 default group PROVEDOR local
aaa authorization commands 15 default group PROVEDOR local
aaa accounting exec default start-stop group PROVEDOR
aaa accounting commands 15 default start-stop group PROVEDOR
```

Cuidado: com `aaa authorization commands`, os comandos dos usuários **locais** também
vão ao TACACS+ e são negados se eles não estiverem num grupo `tacacs-*`. Teste com um
usuário local antes de salvar: sem isso, os usuários locais perdem o acesso de admin
e a conta local de monitoramento tem a coleta negada.

**Huawei e Juniper:** use os roteiros (local primeiro, sem
`authorization-cmd`, que nega os comandos dos usuários locais):
[NE8000 / VRP8](../../docs/tacacs-huawei-ne8000.md),
[S12700 / VRP5](../../docs/tacacs-huawei-s12700.md),
[MX204 / Junos](../../docs/tacacs-juniper-mx204.md).

**Datacom (DmOS)** — roteiro com testes de aceitação em
[docs/tacacs-datacom.md](../../docs/tacacs-datacom.md). A sintaxe muda com a versão do
firmware; se a forma do roteiro não existir na sua, esta é uma referência aproximada
(valide no manual):

```
config
 tacacs-server host 100.66.80.196 key <TACACS_KEY>
 aaa authentication-order tacacs local
```

**Mikrotik (RouterOS) não suporta TACACS+.** Continua usando RADIUS (FreeRADIUS/authentik),
sem mudança.

## Limitações

- Por padrão não há segundo fator no TACACS+ (o provider LDAP vem com `mfa_support: false`).
  Para exigir `senha;código TOTP` no SSH dos equipamentos: [docs/ssh-2fa.md](../../docs/ssh-2fa.md).
- Só autenticação por senha em texto (PAP/ASCII) via LDAP; CHAP e MS-CHAP não funcionam.
- Falha de comunicação com o outpost LDAP resulta em login negado; mantenha o usuário local no equipamento.
