# apps/banco — retenção do banco do daloRADIUS

O banco `radius` de um daloRADIUS cresce sem limite. Num provedor com poucas
dezenas de usuários ele pode passar de 15 GB: dezenas de milhões de sessões em
`radacct` (quase todas do usuário de monitoramento, e boa parte do espaço só em
índices) e milhões de linhas em `radpostauth` — com a **senha em texto puro** de
cada login na coluna `pass` (padrão do daloRADIUS).

Este app mantém só os últimos `BANCO_RETENCAO_DIAS` (padrão **180**) dias. O
histórico completo fica no backup: faça um `./provedor backup completo` com
`BACKUP_RADACCT=sim` antes da primeira limpeza (`apps/backup`). O `enxugar`
recusa rodar se não achar um `radius-radacct.sql.gz` nas cópias
(`/var/backups/provedor/*/`).

Cuidado: o app `backup` apaga as cópias com mais de `BACKUP_RETENCAO_DIAS`
(padrão 14) dias. Se quiser guardar o histórico completo, copie esse dump para
outro lugar.

| Comando | O que faz |
|---|---|
| `./banco.sh tamanho` | tamanho das tabelas |
| `./banco.sh enxugar` | simula a limpeza inicial (mostra o corte) |
| `./banco.sh enxugar --executar` | cria `radacct_novo` só com o período mantido, copia em lotes, troca as tabelas (`RENAME`, atômico) e guarda o original como `radacct_antigo_<data>` — o FreeRADIUS não para |
| `./banco.sh retencao [--executar]` | limpeza diária em lotes de 5 000 linhas + remove senhas gravadas em `radpostauth.pass` |
| `./banco.sh antigos` | lista as tabelas guardadas para rollback |
| `./banco.sh descartar-antigos --sim` | apaga as tabelas `*_antigo_*` (libera o disco de verdade) |

Por quê o corte usa a **ordem de gravação** (id), não a data enviada pelo
equipamento: é comum haver NAS com relógio errado gravando sessões de 1970/2001.

A tabela `nas` (equipamentos e segredos) nunca é tocada.

Credenciais: `/root/.my-radius.cnf` (modo 600), se existir; senão `DALO_DB_*` do
`.env`.

## Timer diário

```sh
cp systemd/provedor-banco-retencao.* /etc/systemd/system/
systemctl daemon-reload && systemctl enable --now provedor-banco-retencao.timer
```

## Rollback da limpeza

Troque `<data>` pelo sufixo que `./banco.sh antigos` mostrar:

```sql
RENAME TABLE radacct TO radacct_descartar, radacct_antigo_<data> TO radacct;
RENAME TABLE radpostauth TO radpostauth_descartar, radpostauth_antigo_<data> TO radpostauth;
```

Depois de alguns dias estável, `./banco.sh descartar-antigos --sim`.

## Crescimento depois da virada

O FreeRADIUS novo (`apps/freeradius`) não grava a senha em `radpostauth`
(grava `(authentik)`/`(legado)`) nem o accounting dos usuários de
monitoramento (`FR_ACCT_IGNORAR_USUARIOS`, padrão `zabbix
zabbix@exemplo.net.br`; ajuste para os seus).

## Cuidado: colunas da `radacct` depois de atualizar o FreeRADIUS

O FreeRADIUS 3.2 grava colunas IPv6 e `class` que a `radacct` de um daloRADIUS
antigo não tem. Depois de uma atualização do sistema (por exemplo Debian 11→12,
FreeRADIUS 3.0→3.2) o accounting para de ser gravado até as colunas existirem.
Confira se a sua `radacct` tem `framedipv6address`, `framedipv6prefix`,
`framedinterfaceid`, `delegatedipv6prefix` e `class`; se faltarem, acrescente
com `ALTER TABLE ... ADD COLUMN` (`ALGORITHM=INSTANT`), copiando os tipos do
schema do FreeRADIUS 3.2 (`mods-config/sql/main/mysql/schema.sql`). Faça o mesmo
nas tabelas `radacct_antigo_<data>` que ainda estiverem guardadas, para o
rollback continuar possível.
