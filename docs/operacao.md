# Operação do dia a dia

Tudo pela interface do authentik (endereço em `AUTHENTIK_URL_EXTERNA` do `.env`,
porta 9443) e pelo orquestrador `./provedor` (como root). Ajuda:
`./provedor ajuda`. De fora da rede interna o NOC chega à interface pela VPN do
NOC (WireGuard, [wireguard.md](wireguard.md)).

## Novo colaborador com acesso aos equipamentos

1. *Diretório > Usuários > Criar*: username (o mesmo usado no login dos
   equipamentos), nome e e-mail.
2. *Definir senha* (ou mande o link de recuperação, ver a seção MFA).
3. *Grupos*: adicione a **um** grupo RADIUS: `radius-admin` (administrador) ou
   `radius-leitura` (leitura). O grupo libera o login e dá o nível; não há outro
   grupo a lembrar.

Cuidado: não coloque a pessoa nos dois. Com a mesma prioridade, os grupos são
aplicados em ordem alfabética e o `:=` do último vence.

Exemplo: `joao.silva` em `radius-admin` entra como administrador;
`maria.souza` em `radius-leitura` entra só para leitura.

## Desligamento

*Diretório > Usuários > (usuário) > Desativar*. O login passa a ser recusado nos
equipamentos em até `FR_CACHE_TTL` segundos (padrão 300, cache de aceites do
FreeRADIUS) mais um login, que é o que dispara a revalidação no authentik. Para
valer na hora: `sudo ./provedor restart freeradius` (zera os caches).

## Mudar o perfil (nível de acesso)

Troque o usuário de grupo, ou edite `radius_reply` do grupo (uma linha
`"Atributo op valor"` por item). Exceção para uma pessoa: `radius_reply` nos
atributos do usuário. Formato e atributos em [equipamentos.md](equipamentos.md).

## Onde ver quem entrou

- authentik: *Eventos > Logs* (login, falhas, alterações).
- Banco do daloRADIUS (depois da virada): `radpostauth` e `radacct`.
- `sudo ./provedor logs freeradius -f`: NAS de origem, motivo de recusa e quem
  ainda usa CHAP/MS-CHAP.
- TACACS+: painel na porta 9049 (`PAINEL_URL_EXTERNA`; [tacacs.md](tacacs.md)).

## MFA

Estado padrão do repositório:

- **Login web** (portal do authentik e os sistemas que entram por ele: wiki,
  Grafana, Zabbix, NetBox, painel TACACS+): TOTP **obrigatório**; quem não tem
  cadastra no próximo login (`apps/authentik/blueprints/09-mfa-web.yaml`).
- **Equipamentos** (RADIUS e TACACS+/LDAP): só usuário e senha, mesmo para quem
  tem TOTP. O fluxo `provedor-radius-autenticacao` não tem a etapa de MFA
  vinculada e os providers RADIUS e LDAP ficam com `mfa_support: false`
  (`apps/authentik/blueprints/01-fluxo-autenticacao.yaml`,
  `apps/radius/blueprints/02-radius-equipamentos.yaml`,
  `apps/ldap/blueprints/03-ldap.yaml`).

O segundo fator nos equipamentos é opcional: com ele ligado, quem tem TOTP
digita `senha;código` no campo de senha. O passo a passo e os cuidados estão em
[ssh-2fa.md](ssh-2fa.md).

Senha esquecida ou conta nova: *Diretório > Usuários > (usuário) > Criar link de
recuperação* e mande o link à pessoa (`10-definir-senha.yaml`; o authentik não
envia e-mail). O link só define a senha: o TOTP continua sendo pedido no login
seguinte. TOTP perdido: na conta, aba *Autenticadores*, apague o TOTP; a pessoa
cadastra outro no próximo login.

## Acesso de emergência (break-glass)

Se o authentik ou o outpost cair, o FreeRADIUS responde pela reserva do cache
quem já entrou com a mesma senha nos últimos `FR_CACHE_RESERVA_TTL` segundos
(`apps/freeradius/README.md`) e **não responde** aos demais; sem resposta, os
equipamentos usam o usuário local. Todo equipamento deve ter um usuário local de
emergência (senha no cofre do NOC) e o método "RADIUS e depois local".
Para devolver o atendimento ao FreeRADIUS do sistema (daloRADIUS):
`sudo ./provedor virada voltar`.

## Equipamento novo (NAS) sem o daloRADIUS

Depois da virada a interface web do daloRADIUS (Apache) pode ser parada e
desabilitada; o banco `radius` continua em uso (tabela `nas`, `radacct`,
`radpostauth` e o CHAP legado). Se a tabela `nas` tiver uma entrada `0.0.0.0/0`,
ela já atende qualquer equipamento que use o segredo comum. Para um equipamento
com segredo próprio, cadastre direto no banco e recarregue o FreeRADIUS:

```sh
sudo mysql --defaults-extra-file=/root/.my-radius.cnf radius -e \
  "INSERT INTO nas (nasname, shortname, type, secret, description)
   VALUES ('10.0.0.1', 'nome-curto', 'other', 'SEGREDO', 'descrição')"
sudo ./provedor restart freeradius   # pede confirmação: ~3 s sem RADIUS
```

`/root/.my-radius.cnf` (modo 600) é um arquivo de credenciais do cliente MySQL
com o usuário do banco `radius`.

Precisa da interface web de novo (relatórios de accounting, cadastro de NAS)?
`sudo systemctl enable --now apache2` religa o daloRADIUS (os arquivos continuam
em `/var/www/html/daloradius`). Usuários e perfis NÃO são mais editados nele: a
fonte é o authentik.

## Saúde

```sh
sudo ./provedor status          # containers, memória, produção e radpostauth (10 min)
sudo ./provedor teste todos     # testes de cada app no ar
sudo ./provedor logs <app> -f
```

Os outposts aparecem em *Aplicações > Outposts* (devem estar verdes).

Cuidado com a memória: o consumo do `authentik-worker` cresce com o tempo e o
container tem `mem_limit: 768m`. Acompanhe a coluna de memória do `status`; se
encostar no limite, recrie o app numa janela combinada
(`sudo ./provedor restart authentik`, que depois da virada pede confirmação).

Hora: a VM deve sincronizar por NTP (`systemd-timesyncd`; aponte para o NTP
interno do provedor num arquivo em `/etc/systemd/timesyncd.conf.d/`) e os
containers usam o relógio do host, com `TZ` (padrão `America/Sao_Paulo`).
Confira com `timedatectl timesync-status`. As horas de sessão no `radacct` vêm
do relógio de cada equipamento: aponte os NAS para o mesmo NTP.

Monitoramento pelo Zabbix: [monitoramento-zabbix.md](monitoramento-zabbix.md).
Reserva em outra máquina: [failover-vps.md](failover-vps.md).

## Atualização do authentik

1. Leia as notas de versão em https://docs.goauthentik.io/releases.
2. `sudo ./provedor backup completo`.
3. Troque `AUTHENTIK_TAG` no `.env` (vale para server, worker e outposts).
4. `sudo ./provedor restart authentik`, depois `restart radius` e `restart ldap`.
5. `sudo ./provedor teste base`.

## Backup

`sudo ./provedor backup completo | pre-virada | listar` (`apps/backup`): dump
do PostgreSQL do authentik, `.env`, `apps/`, `/etc/freeradius` e banco `radius`
sem `radacct`/`radpostauth` e **sem a tabela `nas`** (padrão). Timer diário:
`apps/backup/instalar-timer.sh`.

## Token de bootstrap

Os scripts usam `AUTHENTIK_BOOTSTRAP_TOKEN` (administrador). Quando a migração
terminar, considere apagá-lo em *Diretório > Tokens* e criar um token
temporário só quando precisar rodar os scripts de novo.
