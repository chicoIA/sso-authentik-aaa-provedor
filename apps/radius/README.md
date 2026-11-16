# App radius

Outpost RADIUS do authentik (`radius-outpost`, porta `127.0.0.1:18120/udp`) e a
configuração do provider. O FreeRADIUS (app `freeradius`) encaminha a
autenticação PAP para ele; o authentik valida usuário, senha e grupo.

## O que o blueprint cria (`blueprints/02-radius-equipamentos.yaml`)

- grupos `radius-admin` e `radius-leitura`: quem está num deles entra, com o nível do
  `radius_reply` do grupo. São criados com um perfil de exemplo (Mikrotik `full`/`read`,
  Huawei 15/2) e `state: created`: depois de criados, os atributos são editados na
  interface e o blueprint não os sobrescreve;
- property mapping que devolve os atributos de `radius_reply` do usuário e,
  depois, dos grupos (ordem de `radius_prioridade`), como o rlm_sql fazia.
  Operadores: `:=` substitui, `=` só se ainda não existe, `+=` acrescenta;
- provider `provedor-radius-equipamentos`, aplicação `radius-equipamentos`,
  outpost `provedor-radius`, com `mfa_support: false` (segundo fator opcional:
  `docs/ssh-2fa.md`). Depende do fluxo do app `authentik`.

Também cria e vincula `radius-equipamentos`, o grupo de acesso em que a migração põe
todo usuário (sem nível próprio). Ele pode sair depois da transição: ver
`docs/migracao.md`.

## Variáveis (`env.example`)

- `AUTHENTIK_RADIUS_SECRET`: segredo compartilhado (o worker do authentik também precisa recebê-lo).
- `AUTHENTIK_RADIUS_TOKEN`: token do outpost, preenchido por script.
- `AUTHENTIK_RADIUS_CLIENT_NETWORKS`: opcional.

## Testar

`apps/radius/teste.sh` (com o app no ar). Cria grupo/usuários temporários,
testa aceite com 3 atributos, senha errada, fora do grupo e desativado, e apaga tudo.

## Operar pela interface do authentik

- Liberar um usuário: Diretório > Grupos > `radius-admin` ou `radius-leitura` > adicionar
  (em um só: com a mesma prioridade, o `:=` do último grupo em ordem alfabética vence).
- Atributos de resposta: no grupo ou usuário, Atributos:
  `radius_reply: ["Mikrotik-Group := full", "Huawei-Exec-Privilege = 15"]`
  e `radius_prioridade: 10` (menor vem primeiro).
- Desativar: desmarcar "Ativo" no usuário.
- Atributo de fabricante novo: acrescentar em `FABRICANTES` no property mapping
  (Personalização > Mapeamentos de propriedade).
