# migracao

Ferramenta que copia usuários e grupos do daloRADIUS para o authentik. Roda sob
demanda (várias vezes) até a virada; não é um serviço. O banco `radius` é aberto
**somente leitura** (sessão `READ ONLY`, só `SELECT`) e a tabela `nas` nem é lida
(só contada). Senhas nunca aparecem em relatório nem em saída.

Fontes: banco `radius` e o arquivo `users` do FreeRADIUS atual
(`/etc/freeradius/3.0/mods-config/files/authorize`, montado só leitura), de onde
vêm os usuários que não estão no SQL (entradas `DEFAULT` são ignoradas).

## O que é migrado

- `Cleartext-Password` vira a senha (gravada só na criação; `--atualizar-senhas` regrava).
- Grupos com o mesmo nome do daloRADIUS, com `attributes.radius_reply`
  (lista `"Atributo op valor"`) e `attributes.radius_prioridade`.
- `Auth-Type := Reject`, `Expiration` vencida ou membro de grupo com `Auth-Type := Reject`
  (`daloRADIUS-Disabled-Users`) viram usuário **desativado**; esse grupo não é criado.
- Todo usuário vai também para o grupo `radius-equipamentos` (criado pela ferramenta
  se não existir); path `daloradius`; `userinfo` vira nome, e-mail e
  `attributes.daloradius`; usernames com `@` são literais.
- Demais itens de `radcheck` ficam em `attributes.radius_check`, só como registro.
- Quem sumiu do daloRADIUS é listado, nunca apagado.

O blueprint do app `radius` vincula `radius-equipamentos` à aplicação RADIUS, junto com
`radius-admin` e `radius-leitura`. Como sair do grupo de migração depois da virada:
`docs/migracao.md`.

Cuidado: se depois da migração você renomear os grupos no authentik ou mover as pessoas
para `radius-admin`/`radius-leitura`, não rode `aplicar` de novo: ele recria os grupos
com os nomes do daloRADIUS e põe os usuários de volta neles.

## Variáveis (`env.example`)

`DALO_DB_USER`, `DALO_DB_PASS`, `DALO_DB_NAME`, `DALO_DB_SOCKET` (padrão
`/run/mysqld/mysqld.sock`), `AUTHENTIK_BOOTSTRAP_TOKEN`, `AUTHENTIK_RADIUS_SECRET`
(só para `--radius`), `MIGRACAO_API_URL`, `MIGRACAO_RADIUS_ALVO`.

## Uso

```bash
C="docker compose -p provedor-migracao --env-file .env -f apps/migracao/compose.yml --profile ferramenta run --rm migracao"
$C relatorio --saida /saida/relatorio-$(date +%F).md   # grava em apps/migracao/saida/ (ignorado pelo git)
$C aplicar --simular                                   # mostra o que faria
$C aplicar                                             # cria/atualiza (idempotente)
$C verificar                                           # compara usuário a usuário
$C verificar --radius                                  # + login real no outpost 127.0.0.1:18120
```

Pelo orquestrador: `sudo ./provedor migrar relatorio | simular | aplicar | verificar`.

`verificar` confere ativo/inativo, grupos, `radius_reply`/prioridade e o conjunto de
atributos de resposta que o authentik calcularia, contra o que o daloRADIUS devolveria
(inclui atributos que o authentik não sabe enviar). Com `--radius` faz o login de cada
usuário ativo e compara os atributos recebidos. Sai com código 1 se houver divergência.
Atributo novo de fabricante: adicione em `FABRICANTES` no blueprint do app `radius` e
em `app/fabricantes.py` (o teste unitário compara os dois).

## Testar

- `./teste.sh` (com o authentik no ar): roda `verificar` e falha se divergir.
- `tests/teste_unitario.sh`: cálculo de atributos numa MariaDB descartável (rede isolada).

## Operar pela interface do authentik

Depois de `aplicar`: Diretório > Usuários (path `daloradius`) para ativar/desativar,
trocar senha ou ver `attributes`; Diretório > Grupos para editar `radius_reply`
(uma linha `"Atributo op valor"` por item) e `radius_prioridade`. Alterações feitas
pela interface em `radius_reply` aparecerão como divergência no `verificar` enquanto
o daloRADIUS for a fonte; após a virada, deixe de rodar `aplicar`.
