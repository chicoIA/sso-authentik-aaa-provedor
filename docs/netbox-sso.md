# NetBox pelo SSO

Login OIDC do NetBox direto no authentik, pelo python-social-auth que já vem no
NetBox. O roteiro foi escrito para um NetBox 4.4 (imagem netbox-docker) num
cluster Kubernetes, publicado em `https://infra.exemplo.net.br`, com o authentik
em `https://sso.exemplo.net.br`; troque os dois nomes pelos seus. Lado do
authentik: `apps/netbox/13-netbox.yaml` (a cópia que o authentik aplica fica em
`apps/authentik/blueprints/`).

| Grupo no authentik | No NetBox |
|---|---|
| `netbox-admin` | superusuário |
| `netbox-editor` | grupo `SSO editor` (permissões dadas no NetBox) |
| `netbox-leitura` | grupo `SSO leitura` |

O papel é refeito a cada login (`apps/netbox/provedor_sso.py`). Quem não está em
nenhum grupo é recusado no authentik. O login local do NetBox continua.

## 1. authentik

Em `apps/netbox/13-netbox.yaml`, troque pelo endereço do seu NetBox a `url` de
`redirect_uris` (termina em `/oauth/complete/oidc/`) e o `meta_launch_url`
(termina em `/login/`). Copie o arquivo para
`apps/authentik/blueprints/13-netbox.yaml` (pasta vigiada: aplicado na hora) e
mantenha as duas cópias iguais. O `client_secret` é gerado pelo authentik e fica
em *Aplicações > Providers > provedor-netbox*; leve direto para o Secret do
passo 2, sem passar por chat ou e-mail.

Por quê o `meta_launch_url` aponta para `/login/`: o NetBox só inicia o login
OIDC com um POST em `/oauth/login/oidc/` (o botão da tela de login). Um link
direto para esse endereço, como o atalho do portal do authentik, faz um GET e
não funciona; por isso o atalho leva à tela de login do NetBox.

## 2. NetBox

O servidor do NetBox precisa alcançar `https://sso.exemplo.net.br` (token e
userinfo saem do servidor, não do navegador). Se o SSO for publicado com filtro
de origem (por país ou por faixa de IP), o IP de saída dos pods tem de passar
nesse filtro.

No Kubernetes (imagem netbox-docker), sem editar a imagem:

1. Guarde o `client_secret` num Secret e o `provedor_sso.py` num ConfigMap:

   ```sh
   kubectl -n <ns> create secret generic netbox-sso --from-literal=client_secret='<do authentik>'
   kubectl -n <ns> create configmap netbox-sso-pipeline --from-file=provedor_sso.py=apps/netbox/provedor_sso.py
   ```

2. No Deployment do NetBox (e do worker, se houver), monte o ConfigMap como arquivo em
   `/opt/netbox/netbox/netbox/provedor_sso.py` (`subPath: provedor_sso.py`) e exponha o
   Secret como variável `NETBOX_SSO_SECRET`. A configuração abaixo vai num arquivo extra
   de `/etc/netbox/config/` (ex.: `sso.py`, também por ConfigMap); com o chart Helm,
   em `extraConfig`. No arquivo, `SOCIAL_AUTH_OIDC_SECRET = os.environ['NETBOX_SSO_SECRET']`
   (com `import os`). Faça backup do que existir antes (`kubectl get deploy,cm -o yaml`).

   ```python
   import os

   REMOTE_AUTH_ENABLED = True
   REMOTE_AUTH_BACKEND = 'social_core.backends.open_id_connect.OpenIdConnectAuth'
   REMOTE_AUTH_AUTO_CREATE_USER = True
   SOCIAL_AUTH_OIDC_OIDC_ENDPOINT = 'https://sso.exemplo.net.br/application/o/netbox/'
   SOCIAL_AUTH_OIDC_KEY = 'netbox'
   SOCIAL_AUTH_OIDC_SECRET = os.environ['NETBOX_SSO_SECRET']
   SOCIAL_AUTH_OIDC_SCOPE = ['openid', 'profile', 'email']
   SOCIAL_AUTH_OIDC_USERNAME_KEY = 'preferred_username'
   LOGOUT_REDIRECT_URL = 'https://sso.exemplo.net.br/application/o/netbox/end-session/'
   SOCIAL_AUTH_PIPELINE = (
       'social_core.pipeline.social_auth.social_details',
       'social_core.pipeline.social_auth.social_uid',
       'social_core.pipeline.social_auth.social_user',
       'social_core.pipeline.user.get_username',
       'social_core.pipeline.user.create_user',
       'social_core.pipeline.social_auth.associate_user',
       'netbox.authentication.user_default_groups_handler',
       'social_core.pipeline.social_auth.load_extra_data',
       'social_core.pipeline.user.user_details',
       'netbox.provedor_sso.papel',
   )
   ```

   O Ingress tem de mandar `X-Forwarded-Proto https` (o ingress-nginx manda por
   padrão); senão o NetBox gera `redirect_uri` com `http://` e o authentik recusa.
   Se acontecer: `SOCIAL_AUTH_REDIRECT_IS_HTTPS = True`.
3. `kubectl -n <ns> rollout restart deploy/<netbox>`: o rollout sobe o pod novo antes de
   derrubar o velho; se o novo não ficar pronto, o velho continua (`rollout undo` volta).
4. Permissões dos grupos `SSO leitura` (view em tudo) e `SSO editor` (view/add/change/
   delete em tudo, menos usuários/grupos/permissões/tokens). Pelo script (primeiro
   só mostra; depois com `env APLICAR=1`):

   ```
   kubectl -n <ns> exec -i deploy/<netbox> -- /opt/netbox/venv/bin/python \
       /opt/netbox/netbox/manage.py nbshell < apps/netbox/sso_ajustes.py
   kubectl -n <ns> exec -i deploy/<netbox> -- env APLICAR=1 /opt/netbox/venv/bin/python \
       /opt/netbox/netbox/manage.py nbshell < apps/netbox/sso_ajustes.py
   ```

   Cuidado: os grupos `SSO leitura` e `SSO editor` nascem sem nenhuma
   `ObjectPermission`. **Sem este passo quem não é `netbox-admin` entra e não vê
   nada.** O script pode rodar mais de uma vez.
5. Teste: botão **"OpenID Connect"** na tela de login, com um usuário de cada
   grupo.

Fora do Kubernetes o roteiro é o mesmo: `provedor_sso.py` ao lado do
`configuration.py` (diretório `netbox/netbox/`), a configuração acima no
arquivo de configuração e o `sso_ajustes.py` pelo `nbshell`.

## Contas que já existem

O social-auth **não** reaproveita conta local: se o login já existe, ele cria outra
com um sufixo hexadecimal (ex.: `fulano761a2451fec3420b`). O `apps/netbox/sso_ajustes.py`
(passo 4) acha essas duplicadas, passa o vínculo SSO para a conta original (que
guarda histórico e tokens) e apaga a duplicada; rode de novo depois do primeiro
login de quem já tinha conta local. Grupos e superusuário são acertados no login
SSO seguinte.

Alternativa manual: antes do primeiro login SSO de alguém que já tem conta
local, renomeie a antiga (ex.: `fulano-local`); depois do login SSO, passe o
que for preciso (favoritos, tokens de API) e apague a antiga. Não mexa nas contas
usadas por integrações (tokens de API).

## Desfazer

`REMOTE_AUTH_ENABLED = False` (ou tire o arquivo `sso.py`) e `rollout restart`.
