# painel - painel web do TACACS+

Mostra o que foi feito nos equipamentos via TACACS+: logins (permitidos/negados),
comandos autorizados/negados e sessões de accounting. Flask + SQLite em um
container (porta **9049**, 128 MB). Telas em pt-BR, tema claro/escuro automático
(segue o navegador), funciona em celular.

## Como funciona

- Acompanha `/var/log/tacacs/eventos.tsv` (volume `provedor-tacacs-logs`, montado
  **somente leitura**), guarda a posição lida e trata rotação (inode novo) e
  truncamento. Grava no SQLite do volume `painel-dados`.
- Retenção: `PAINEL_RETENCAO_DIAS` (padrão 365); a limpeza roda de hora em hora.
- Telas: visão geral (24 h / 7 dias), eventos (filtros por período, usuário,
  equipamento, tipo, resultado e texto do comando; paginação; **Exportar CSV**,
  até 100 mil linhas), sessões (pares start/stop com duração; "aberta" = sem stop
  ainda) e páginas por usuário (`/usuario/NOME`) e equipamento (`/equipamento/IP`).
- `/saude` (sem login) devolve o estado da ingestão em JSON.

## Variáveis (`env.example`)

`PAINEL_OIDC_SECRET`, `PAINEL_SECRET_KEY` (obrigatórias, geradas pelo orquestrador),
`PAINEL_URL_EXTERNA`, `PAINEL_OIDC_VERIFICAR_TLS`, `PAINEL_RETENCAO_DIAS`,
`PAINEL_AUTHENTIK_INTERNO`, `AUTHENTIK_URL_EXTERNA`.

## Login (OIDC) e a questão issuer interno x externo

O authentik monta o `issuer` do token a partir do host usado na requisição.
O navegador chega por `AUTHENTIK_URL_EXTERNA` (o endereço público ou interno do
authentik, na 9443) e o container poderia chegar por `http://authentik-server:9000`, gerando issuers
diferentes. Por isso o painel **não valida o `iss`/id_token**: o navegador é
redirecionado ao endereço externo (authorize), e o container troca o código e lê o
`userinfo` direto no authentik (canal servidor-a-servidor, com o client secret),
por padrão no mesmo `AUTHENTIK_URL_EXTERNA` (IP do host, que o container alcança
pela bridge). O certificado padrão do 9443 é autoassinado, então `PAINEL_OIDC_VERIFICAR_TLS=0`
(padrão); se o authentik for publicado com certificado válido, use `1`. Para evitar TLS
nesse canal, defina `PAINEL_AUTHENTIK_INTERNO=http://authentik-server:9000`.
O acesso exige o claim `groups` (escopo `profile`) com `painel-tacacs` ou `tacacs-admin`.

O login do painel é login web: passa pelo TOTP obrigatório do authentik. O painel fala
HTTP na 9049; deixe a porta acessível só pela rede interna ou pela VPN do NOC
(`docs/wireguard.md`), ou ponha um proxy com TLS na frente e ajuste `PAINEL_URL_EXTERNA`.

## Operar pela interface do authentik

- Dar acesso: Directory > Groups > `painel-tacacs` > Users > Add existing user
  (membros de `tacacs-admin` já entram).
- Aplicação/provider `painel-tacacs`: Applications > Applications. O blueprint
  `blueprints/05-painel.yaml` é aplicado sozinho (depende do blueprint do tacacs).
- A URL do painel é o redirect do provider; se mudar `PAINEL_URL_EXTERNA`,
  reaplique o blueprint (Customization > Blueprints > Exemplo - Painel TACACS+ > Apply).

## Testar

`apps/painel/teste.sh` (com o app no ar): confere `/saude`, se a ingestão alcançou o
fim do `eventos.tsv`, se as telas exigem login e se o app existe no authentik.

`PAINEL_MODO_TESTE=1` desliga o login **somente** com `PAINEL_BIND=127.0.0.1`
(o servidor recusa subir de outro modo). É para teste isolado; nunca em produção.
Exemplo isolado: `tests/eventos_exemplo.tsv` serve de entrada de exemplo.
