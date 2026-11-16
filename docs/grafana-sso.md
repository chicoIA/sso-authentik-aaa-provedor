# Grafana pelo SSO

Login OIDC do Grafana direto no authentik, sem LDAP. O roteiro foi escrito para
um Grafana 12 OSS (serviço `grafana-server`) atrás de um proxy reverso nginx,
publicado em `https://painel.exemplo.net.br`, com o authentik em
`https://sso.exemplo.net.br`; troque os dois nomes pelos seus. Lado do
authentik: `apps/authentik/blueprints/11-grafana.yaml`, aplicado sozinho quando
o app `authentik` sobe.

| Grupo no authentik | Papel no Grafana |
|---|---|
| `grafana-admin` | Admin (da organização) |
| `grafana-editor` | Editor |
| `grafana-leitura` | Viewer |

Quem não está em nenhum dos três é recusado (`role_attribute_strict`), mesmo com
conta válida no SSO. O usuário `admin` local do Grafana continua como reserva: se o
SSO cair, entra-se por ele (não ligue `disable_login_form`).

## Lado do authentik

1. No blueprint, troque a `url` de `redirect_uris` e o `meta_launch_url` pelo
   endereço do seu Grafana (o redirect termina em `/login/generic_oauth`).
2. Ponha as pessoas nos grupos `grafana-admin` / `grafana-editor` /
   `grafana-leitura`.
3. O `client_secret` é gerado pelo authentik e não fica no repositório: copie de
   *Aplicações > Providers > provedor-grafana* direto para o `grafana.ini` ou
   para o ambiente do container, sem passar por chat ou e-mail.

O servidor do Grafana chama os endereços de token e userinfo do authentik: ele
precisa alcançar o endereço do SSO, e não só o navegador da pessoa.

## Lado do Grafana (uma vez)

1. Em `grafana.ini` (ou as variáveis `GF_AUTH_GENERIC_OAUTH_*` equivalentes):

   ```ini
   [server]
   root_url = https://painel.exemplo.net.br/

   [auth.generic_oauth]
   enabled = true
   name = Exemplo SSO
   icon = signin
   client_id = grafana
   client_secret = <do authentik>
   scopes = openid profile email offline_access
   auth_url = https://sso.exemplo.net.br/application/o/authorize/
   token_url = https://sso.exemplo.net.br/application/o/token/
   api_url = https://sso.exemplo.net.br/application/o/userinfo/
   signout_redirect_url = https://sso.exemplo.net.br/application/o/grafana/end-session/
   use_pkce = true
   use_refresh_token = true
   login_attribute_path = preferred_username
   name_attribute_path = name
   email_attribute_path = email
   groups_attribute_path = groups
   role_attribute_path = contains(groups[*], 'grafana-admin') && 'Admin' || contains(groups[*], 'grafana-editor') && 'Editor' || contains(groups[*], 'grafana-leitura') && 'Viewer'
   role_attribute_strict = true
   allow_sign_up = true
   auto_login = false
   ```

2. Reinicie o Grafana. Na tela de login aparece **"Sign in with Exemplo SSO"**; o
   formulário local continua.
3. Teste: um usuário em `grafana-admin` entra e vê *Administration*; um em
   `grafana-leitura` não consegue editar; um sem grupo recebe erro de login.
   Mude alguém de `grafana-leitura` para `grafana-admin` e confira que o papel
   muda no login seguinte.

Faça backup do `grafana.ini` e do banco do Grafana antes de mexer.

Desfazer: desligue *Enabled* na tela *Administration > Authentication > Generic
OAuth* (ou `enabled = false` no arquivo). Pela tela não precisa reiniciar.

## Cuidados

- **`root_url` é obrigatório.** Sem ele o Grafana manda
  `redirect_uri=http://localhost:3000/...` e o authentik responde "Redirect URI
  Error".
- **Tela ou arquivo, não os dois.** O que é salvo pela tela *Administration >
  Authentication > Generic OAuth* fica no banco (`sso_setting`) e vale sobre o
  `[auth.generic_oauth]` do arquivo. Se configurar pela tela, deixe no
  `grafana.ini` só o `root_url`.
- **Groups attribute path na tela**: o campo só aparece depois de ligar *Define
  allowed groups* (seção *Extra security measures*); sem ele todo mundo é
  recusado. Deixe *Auto login* desligado, para o formulário local continuar à
  mão.
- **Papel**: é lido dos grupos a cada login e na renovação do token.
- **Scope `offline_access`**: necessário para o refresh token. Sem ele o log do
  Grafana mostra `No refresh token available` e a sessão cai após 1 h, quando o
  access token vence.
- **Contas locais que já existem**: o Grafana liga pelo **login** (igual ao
  `preferred_username` do authentik). Logins que não coincidem geram conta nova
  no primeiro acesso; a antiga pode ser apagada depois.
- **E-mail repetido**: se uma conta local do Grafana com outro login já tem o
  mesmo e-mail, o login SSO falha com `unable to create user: user not found`.
  Solução: troque o e-mail da conta antiga (ex.: `fulano+local@`) e entre de
  novo. **Não** ligue `oauth_allow_insecure_email_lookup`: no authentik o usuário
  pode mudar o próprio e-mail e assim tomaria a conta de outro.

## Proxy reverso e endurecimento (recomendado)

Não fazem parte do SSO, mas convém acertar na mesma janela.

No proxy nginx, no bloco do Grafana:

- upstream com keepalive e os cabeçalhos `Upgrade`/`Connection` (com um `map`
  para o WebSocket). Sem eles o Grafana Live não funciona: `/api/live/ws`
  devolve 400.
- `X-Forwarded-Proto`, HTTP/2 e gzip de JSON/JS/CSS; `server_tokens off`.
- um log com o tempo por requisição (tempo total e tempo do upstream) ajuda a
  separar lentidão do proxy, do Grafana e da fonte de dados.

No `grafana.ini`:

- `cookie_secure = true` e `disable_gravatar = true`; `wal = true` no banco
  SQLite.
- `[dashboards] min_refresh_interval = 1m` quando a fonte coleta a cada 1 min:
  dashboards com atualização de 5 s a 30 s e dezenas de consultas cada só
  repetem a mesma leitura e pesam na fonte de dados.

Porta 3000 só para o proxy: a unidade
`apps/grafana/provedor-grafana-porta.service` cria a cadeia iptables `PV-G3000`,
que aceita a própria máquina e o IP do proxy e rejeita o resto, registrando os
bloqueios com o prefixo `PROVEDOR-G3000-BLOQ`. Troque o IP do proxy no arquivo
(o exemplo usa `198.51.100.13`), copie para `/etc/systemd/system/` e habilite
com `systemctl enable --now provedor-grafana-porta`. Antes de bloquear, observe
por alguns dias com uma regra só de LOG na porta 3000, para descobrir quem ainda
acessa direto. Desfazer: `systemctl disable --now provedor-grafana-porta`.

Nas duas máquinas, por estarem expostas: root no SSH só por chave, fail2ban no
`sshd` e atualizações em dia. Ao atualizar o Grafana, guarde o pacote da versão
anterior e uma cópia do banco, para poder voltar.
