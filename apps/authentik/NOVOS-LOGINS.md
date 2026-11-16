# Novos logins nas mesmas contas (tudo pela interface)

Interface de administração: `AUTHENTIK_URL_EXTERNA` > Interface de administração.
As contas (usuários e grupos migrados do daloRADIUS) são únicas: qualquer novo meio de
login deve apontar para a MESMA conta, nunca criar outra.

## 1. Login com Google, Microsoft ou outro provedor (Sources)
Diretório > Federação e Social login > Criar.
- Google: tipo "Google OAuth Source"; Microsoft: "Entra ID OAuth Source"; outros: "OpenID Connect" ou "SAML".
- Preencha Consumer key/secret (ou metadados SAML) obtidos no provedor; callback exibido na tela do source.
- Em "User matching mode" escolha **Link to a user with identical email address** (e-mail) ou
  **identical username** (username). Assim o primeiro login social se vincula à conta existente.
  Use e-mail apenas se o provedor garante e-mail verificado; caso contrário prefira username.
- Defina "User path"/grupos e o fluxo de autenticação/inscrição conforme desejado. Para NÃO
  criar contas novas, deixe o fluxo de inscrição vazio: quem não tiver conta será recusado.
- Para aparecer na tela de login: Fluxos e Estágios > Estágios > estágio de identificação do
  fluxo de login > campo "Sources".

## 2. Sistemas que usam o authentik como login (Applications)
Aplicações > Aplicações > Criar com provedor.
- Web moderna: provedor **OAuth2/OpenID** (anote client ID e secret, defina redirect URIs).
- Sistemas corporativos: provedor **SAML**.
- Apps que só falam proxy reverso: provedor **Proxy**.
- Controle quem entra em cada aplicação na aba "Policy / Group / User Bindings" (vincule grupos).

Exemplos prontos no repositório: Grafana (`docs/grafana-sso.md`), Zabbix
(`docs/zabbix-sso.md`) e NetBox (`docs/netbox-sso.md`).

## 3. Sistemas LDAP e RADIUS
- LDAP: use a aplicação/provedor `provedor-ldap` já existente (bind DN da conta `ldap-servico`).
  Para um sistema com regras próprias crie outro provedor LDAP e um Outpost (Aplicações > Outposts),
  vinculando os grupos que podem fazer bind.
- RADIUS: provedor RADIUS adicional com seu próprio segredo e "Client networks"; associe ao
  outpost `provedor-radius` editando o outpost (`docs/vpn.md` mostra o caso de um
  concentrador de VPN). Não use as portas 1812/1813, que são do FreeRADIUS.

## 4. App passwords (senhas de aplicativo)
Para equipamentos/clientes que não suportam MFA: Diretório > Tokens e App passwords > Criar,
intenção "App password", usuário dono da conta. O valor vale como senha no lugar da principal.

## 5. MFA
- Cada usuário cadastra TOTP/WebAuthn/códigos de recuperação em Configurações do usuário > MFA.
- MFA no login web: obrigatório (`blueprints/09-mfa-web.yaml`); quem não tem cadastra o TOTP
  no próximo login.
- Nos outposts RADIUS/LDAP não há MFA no estado padrão: só usuário e senha, mesmo para quem
  tem TOTP. O segundo fator nos equipamentos é opcional (ver `docs/operacao.md`, seção MFA, e
  `docs/ssh-2fa.md`).
