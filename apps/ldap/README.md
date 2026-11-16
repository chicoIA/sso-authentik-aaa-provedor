# App ldap

Outpost LDAP do authentik (`ldap-outpost`, portas `389` e `636` do host).
É a base para o TACACS+, para o login em servidores Linux e para sistemas que só
falam LDAP. Não mexe no cadastro de NAS nem nos segredos do RADIUS.

## O que os blueprints criam

`blueprints/03-ldap.yaml`:

- provider `provedor-ldap` (base DN `dc=ldap,dc=provedor,dc=com,dc=br`,
  `bind_mode` = `cached`, `search_mode` = `direct` para usuário novo aparecer na hora, sem MFA), fluxo `provedor-radius-autenticacao`;
- aplicação `provedor-ldap` e outpost `provedor-ldap`;
- grupo `ldap-acesso` (quem pode fazer bind), vinculado à aplicação;
- conta de serviço `ldap-servico` (senha `LDAP_SERVICO_SENHA`), com a permissão
  `search_full_directory` e membro de `ldap-acesso`.
  Bind DN: `cn=ldap-servico,ou=users,dc=ldap,dc=provedor,dc=com,dc=br`.

`blueprints/04-linux.yaml` (cópia de `apps/linux/04-linux.yaml`): grupos
`linux-*` e a conta de serviço `linux-servico` do login em servidores Linux
(`docs/linux-sso.md`). Se não for usar, tire o arquivo da pasta.

Os grupos `tacacs-*` são vinculados à aplicação pelo app `tacacs`.

### Certificado da porta 636 (ldaps)

O provider procura um certificado chamado `ldap-sso.provedor.interno`. O
repositório não traz certificado: cada ambiente gera o seu no authentik
(*Sistema > Certificados*) com esse nome e reaplica o blueprint. O passo a passo
está em `docs/linux-sso.md`. Enquanto o certificado não existir, o provider fica
sem certificado próprio na 636; a porta 389 não depende dele.

## Variáveis (`env.example`)

- `LDAP_SERVICO_SENHA`: senha da conta de serviço (o worker do authentik também precisa recebê-la).
- `AUTHENTIK_LDAP_TOKEN`: token do outpost, preenchido por script.
- `AUTHENTIK_LDAP_BASE_DN`: opcional.

## Testar

`apps/ldap/teste.sh` (com o app no ar). Cria usuários temporários, testa bind da
conta de serviço, `memberOf`, bind de usuário, senha errada e usuário fora do
grupo, e apaga tudo. Usa um container descartável na rede `provedor`.

## Operar pela interface do authentik

- Liberar um usuário/sistema: Diretório > Grupos > `ldap-acesso` > adicionar.
- Trocar a senha da conta de serviço: alterar `LDAP_SERVICO_SENHA` no `.env`
  e reaplicar o blueprint (ou Diretório > Usuários > `ldap-servico` > Definir senha).
- Ver o outpost: Aplicações > Outposts > `provedor-ldap` (deve estar conectado).

Cuidado com o `bind_mode` = `cached`: o outpost guarda o resultado do bind, e
quem acabou de entrar num grupo pode esperar até 5 min para o bind passar. O
`provedor-tacacs-conjuntos` (`apps/tacacs/conjuntos/`) reinicia o outpost para
limpar esse cache quando os membros dos grupos `tacacs-*` ou `linux-*` mudam.
