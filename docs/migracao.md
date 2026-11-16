# Migração do daloRADIUS para o authentik (subida segura)

Cenário: o authentik sobe na **mesma VM** do daloRADIUS. O conjunto usa perto
de 2 GB de memória e todo serviço tem `mem_limit`; com 4 GB de RAM há folga, com
2 GB é preciso swap. O FreeRADIUS, o MariaDB e o Apache/daloRADIUS do sistema
continuam atendendo até a virada; os apps em Docker sobem **um por vez** ao lado
deles.

```
 antes:   equipamento ──1812──► freeradius (sistema) ──► MariaDB (radcheck, nas...)
 teste:   equipamento ──1812──► freeradius (sistema)               (produção igual)
          radclient de teste ──11812──► freeradius (Docker) ──► outpost ──► authentik
 virada:  equipamento ──1812──► freeradius (Docker) ──► outpost ──► authentik
                                       └──► MariaDB (nas só leitura; radacct/radpostauth)
 voltar:  sudo ./provedor virada voltar   (religa o freeradius do sistema)
```

**O cadastro de NAS não muda.** O FreeRADIUS novo lê a mesma tabela `nas`
(`read_clients = yes`, `client_table = "nas"`), com as mesmas entradas CIDR
(inclusive `0.0.0.0/0`, se houver) e os mesmos segredos, **só leitura**. Nenhum
script exporta, copia ou regrava a tabela `nas` ou os segredos; o backup também
não a copia (`BACKUP_NAS=nao`). Continue cadastrando equipamentos pelo daloRADIUS.

## Antes de começar

- Docker com `default-address-pools` em `10.233.0.0/16` no
  `/etc/docker/daemon.json` (o `preparar` confere e recusa sem isso). Por quê: o
  pool padrão do Docker cria redes em `172.16.0.0/12`, faixa comum de gerência
  dos equipamentos. Se a sua rede usa `10.233.0.0/16`, troque o pool e a rede no
  script `provedor` e nos `env.example` antes de subir.
- FreeRADIUS do sistema com o módulo SQL em
  `/etc/freeradius/3.0/mods-available/sql`: o `preparar` lê dali as credenciais
  do banco (`DALO_DB_*`), sem imprimi-las.
- Um usuário local de emergência em cada equipamento, com o método "RADIUS e
  depois local" (ver [operacao.md](operacao.md)).
- Troque o domínio e os endereços de exemplo (`exemplo.net.br`,
  `AUTHENTIK_URL_EXTERNA`, `PAINEL_URL_EXTERNA`) pelos seus no `.env` e nos
  blueprints que for usar.

## Ponto de verificação da produção (repita entre todos os passos)

```sh
sudo ./provedor status
```

Esperado, antes da virada:

- `freeradius active`, `mariadb active`, `apache2 active`;
- `radpostauth: N aceites nos últimos 10 min` com N parecido com o mesmo horário
  de outros dias (usuários de monitoramento, como o `zabbix`, chegam em rajadas;
  de madrugada pode ser baixo);
- 1812/1813 escutados pelo `freeradius` do sistema; nada novo em 1812;
- memória "livre p/ subir" acima de 600 MB.

Se qualquer item sair do esperado: **pare**, derrube o último app que subiu
(`sudo ./provedor down <app>`) e confira de novo. Os apps em Docker nunca
mexem no FreeRADIUS/MariaDB/Apache do sistema.

## Passo a passo

Todos os comandos na raiz do repositório, como root. Clone em
`/opt/authentik-aaa-provedor`: os `teste.sh` e as unidades systemd usam esse
caminho.

| # | Comando | O que conferir depois |
|---|---|---|
| 0 | `sudo ./provedor status` | linha de base da produção (anote o radpostauth) |
| 1 | `sudo ./provedor backup completo` | `OK`/caminho da cópia; produção |
| 2 | `sudo ./provedor preparar` | rede `provedor` 10.233.10.0/24, volume `provedor-tacacs-logs`, `.env` modo 600 com DALO_DB_* lidos do FreeRADIUS (nada impresso); produção |
| 3 | `sudo ./provedor up authentik` | espera o `/-/health/ready/`; `sudo ./provedor teste authentik` (blueprints `successful`); `status` (memória dos containers); produção |
| 4 | `sudo ./provedor tokens` | tokens dos outposts gravados no `.env`; produção |
| 5 | `sudo ./provedor up radius` | `sudo ./provedor teste radius`; produção |
| 6 | `sudo ./provedor migrar relatorio` | ler `apps/migracao/saida/relatorio-<data>.md`: total de usuários, quem será desativado, usuários que só existem no arquivo `users` do FreeRADIUS, atributos sem suporte e restrições sem equivalente |
| 7 | `sudo ./provedor migrar simular` e `sudo ./provedor migrar aplicar` | grupos com os mesmos nomes do daloRADIUS, usuários no path `daloradius` |
| 8 | `sudo ./provedor migrar verificar --radius` | zero divergências (login real no outpost); ver o cuidado abaixo |
| 9 | `sudo ./provedor up ldap` | `sudo ./provedor teste ldap`; produção |
| 10 | `sudo ./provedor up freeradius` | sobe em **11812/11813**, `FR_GRAVAR_SQL=nao`; `sudo ./provedor teste freeradius`; `ss -lunp` mostra 1812 ainda com o freeradius do sistema; produção |
| 11 | dias de observação | `sudo ./provedor teste todos`; `./provedor logs freeradius` (quem usa CHAP/MS-CHAP) |
| 12 | `sudo ./provedor backup pre-virada` | cópia do dia |
| 13 | `sudo ./provedor virada ativar` (digite `VIRAR`) | ver abaixo |

Os passos 3, 4, 5, 9 e 10 podem ser feitos de uma vez com
`sudo ./provedor up base` (para no primeiro erro e confere a produção entre
cada app), mas a subida passo a passo é a recomendada na primeira vez.

Antes de subir qualquer app o orquestrador recusa se `MemAvailable + SwapFree`
for menor que 600 MB ou se o `mariadb`/`freeradius` do sistema estiver inativo.

### Quem pode entrar depois de migrar

A aplicação *Equipamentos de rede (RADIUS)* libera três grupos, todos criados pelo
blueprint `apps/radius/blueprints/02-radius-equipamentos.yaml`:

- `radius-equipamentos`: a migração põe todo usuário aqui. Dá acesso sem nível
  próprio; o nível vem dos grupos migrados, que chegam com os **nomes do
  daloRADIUS** e os `radius_reply` de lá;
- `radius-admin` e `radius-leitura`: grupos de nível, com um perfil de exemplo em
  `radius_reply`.

Depois da virada, escolha um dos dois caminhos e fique só com ele:

- manter os grupos migrados e o `radius-equipamentos`; ou
- passar as pessoas para `radius-admin`/`radius-leitura`, ajustar o `radius_reply`
  desses dois grupos ao perfil que o seu daloRADIUS devolvia e remover o
  `radius-equipamentos` (o blueprint diz o que apagar). Antes de apagar, confira que
  todo membro dele já está num dos dois grupos de nível.

Por quê escolher um só: com a mesma prioridade, os grupos são aplicados em ordem
alfabética e o `:=` do último vence (ver [operacao.md](operacao.md)).

## Virada

`virada ativar` (via `apps/freeradius/virada.sh`):

1. confere authentik e outpost;
2. testa o FreeRADIUS novo na 11812 (nada do sistema é tocado se falhar);
3. para e desabilita o `freeradius` do sistema, muda o `.env` para
   1812/1813 e `FR_GRAVAR_SQL=sim` e recria o container;
4. testa em 1812; **se falhar, volta sozinho** para o FreeRADIUS do sistema.

Depois da virada confira: `sudo ./provedor status` (agora `freeradius inactive`
é o esperado e o container escuta 1812/1813), `radpostauth` voltando a crescer
com `pass = (authentik)`, login real em um equipamento de cada fabricante e
`sudo ./provedor logs freeradius -f`. Valide com tráfego real: os testes do
repositório usam o cliente `localhost`, não os seus equipamentos.

Rollback a qualquer momento: `sudo ./provedor virada voltar` (digite `VOLTAR`).
Ele para o container, devolve 11812/11813 e `FR_GRAVAR_SQL=nao` ao `.env` e
religa o FreeRADIUS do sistema, que volta a ler a mesma tabela `nas`.

Com a virada ativa, `down`/`restart` de `freeradius`, `authentik` ou `radius`
pedem confirmação: derrubá-los deixa os equipamentos sem resposta RADIUS (eles
caem no usuário local de emergência).

## Depois da virada

- Pare de rodar `migrar aplicar`: o authentik passa a ser a fonte dos usuários.
  Por quê: a ferramenta recria os grupos com os nomes do daloRADIUS e devolve a
  eles quem foi movido.
- TACACS+ e painel: [tacacs.md](tacacs.md).
- Dia a dia: [operacao.md](operacao.md).
- Retenção do `radacct`/`radpostauth`: `apps/banco/README.md`.
- Reserva em outra máquina: [failover-vps.md](failover-vps.md).
