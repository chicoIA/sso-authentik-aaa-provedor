# Zabbix pelo SSO

O Zabbix 7.0 não tem OIDC: o login é **SAML** direto no authentik, com criação
de conta no primeiro acesso (JIT). O roteiro foi escrito para um Zabbix 7.0
(frontend nginx + php-fpm, pacote oficial) atrás de um proxy reverso nginx,
publicado em `https://zabbix.exemplo.net.br`, com o authentik em
`https://sso.exemplo.net.br`; troque os dois nomes pelos seus. Lado do
authentik: `apps/zabbix/12-zabbix.yaml` (a cópia que o authentik aplica fica em
`apps/authentik/blueprints/`).

| Grupo no authentik | Papel no Zabbix | Grupo de usuários no Zabbix (criar) |
|---|---|---|
| `zabbix-admin` | Super admin role | `SSO admin` |
| `zabbix-operador` | Admin role | `SSO operador` (leitura-escrita nos grupos de hosts) |
| `zabbix-leitura` | User role | `SSO leitura` (leitura nos grupos de hosts) |

Quem não está em nenhum dos três é recusado no próprio authentik. O MFA (TOTP) do login
web vale também para o Zabbix.

O que **não muda**: o login local (`Admin` e demais contas internas) continua; usuários
de API (o do Grafana, por exemplo) não passam pelo SAML; *Default authentication* fica em
*Internal*. A tela de login só ganha o link **"Sign in with Single Sign-On (SAML)"**.

O SAML só passa pelo navegador: o servidor do Zabbix não precisa alcançar o SSO.

## 1. authentik (uma vez)

Em `apps/zabbix/12-zabbix.yaml`, troque pelo seu endereço: `acs_url`, `sls_url`
e `meta_launch_url` (endereço do Zabbix) e `issuer_override` (endereço do SSO).
Depois, na VM do authentik, como root, na raiz do repositório:

```sh
cp apps/zabbix/12-zabbix.yaml apps/authentik/blueprints/12-zabbix.yaml   # aplicado na hora
```

A pasta é vigiada pelo authentik: a cópia de lá é a que vale; mantenha as duas
iguais. O blueprint não mexe em nada que já existe: cria só os grupos
`zabbix-*`, o provider `provedor-zabbix` e a aplicação `Zabbix`. Desfazer:
apague a aplicação e o provider na tela e o arquivo.
Depois, ponha as pessoas nos grupos `zabbix-admin` / `zabbix-operador` / `zabbix-leitura`.

Por quê o `issuer_override`: sem ele o authentik monta o entity ID do IdP pelo
endereço da requisição, que muda se alguém entrar por outro nome (IP, nome
interno). Com o valor fixo, o *IdP entity ID* configurado no Zabbix sempre
confere.

## 2. Proxy nginx

O php-saml do Zabbix confere se a resposta chegou no mesmo endereço do ACS
(`https://...`). No proxy, acrescente no `location /` do bloco do Zabbix
(faça backup do arquivo antes):

```nginx
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Forwarded-Host $host;
        proxy_set_header X-Forwarded-Port 443;
```

Aplique com `nginx -t && systemctl reload nginx` (reload não derruba conexões).
Para voltar: restaure o backup e recarregue de novo.

## 3. Frontend do Zabbix

Como root, no servidor do frontend. Nada aqui reinicia serviço: o PHP lê os
arquivos a cada requisição.

1. Ache a pasta do frontend e a configuração (pacote oficial: `/usr/share/zabbix`, que no
   7.0 pode estar em `/usr/share/zabbix/ui`):

   ```sh
   UI=$(dirname "$(find /usr/share/zabbix -maxdepth 2 -name index_sso.php | head -1)"); echo "$UI"
   CONF=/etc/zabbix/web/zabbix.conf.php; ls -l "$CONF"
   ```

2. Exporte o certificado de assinatura do provider no authentik e grave em
   `idp.crt`. No authentik: *Aplicações > Providers > provedor-zabbix*, botão de
   download do certificado de assinatura (é o certificado `authentik
   Self-signed Certificate`, que também pode ser baixado em *Sistema >
   Certificados*). Baixe só o certificado, que é público, nunca a chave privada.
   Cole o conteúdo no lugar do marcador:

   ```sh
   mkdir -p "$UI/conf/certs"
   cat > "$UI/conf/certs/idp.crt" <<'CRT'
   -----BEGIN CERTIFICATE-----
   <conteúdo do certificado de assinatura do provider SAML>
   -----END CERTIFICATE-----
   CRT
   chmod 644 "$UI/conf/certs/idp.crt"
   openssl x509 -in "$UI/conf/certs/idp.crt" -noout -enddate -fingerprint -sha256
   ```

   O `openssl` tem de mostrar a mesma validade (`notAfter`) e o mesmo SHA256 que
   o authentik mostra para esse certificado em *Sistema > Certificados*. Anote a
   data de vencimento.
   O Zabbix procura `conf/certs/idp.crt` dentro da pasta do frontend; se o
   `zabbix.conf.php` já tiver `$SSO['IDP_CERT']` apontando para outro lugar, use aquele.

3. Configuração atrás do proxy (backup antes):

   ```sh
   cp -a "$CONF" "$CONF.bak-$(date +%Y%m%d)"
   grep -n "SSO" "$CONF"            # se já houver $SSO['SETTINGS'], editar em vez de acrescentar
   echo "\$SSO['SETTINGS'] = ['use_proxy_headers' => true, 'strict' => true];" >> "$CONF"
   php -l "$CONF"                   # tem de dizer "No syntax errors"
   ```

   Sem `use_proxy_headers` o login falha com "The response was received at http://...".
   Se o `php -l` acusar erro: `cp -a "$CONF.bak-<data>" "$CONF"`.

## 4. Tela do Zabbix

*Users > User groups*: crie `SSO admin`, `SSO operador` (permissões *Read-write* nos
grupos de hosts; leitura nos grupos de templates) e `SSO leitura` (*Read* nos
grupos de hosts). Crie também `SSO desativados` com *Disabled*.

Cuidado: **grupo de hosts novo** não entra sozinho nos grupos SSO (o Zabbix 7.0
não tem "todos"). Ao criar um, dê permissão a `SSO operador` (Read-write) e
`SSO leitura` (Read); senão quem entra pelo SSO não vê os hosts dele.

*Users > Authentication*:

- Aba *Authentication*: **Deprovisioned users group** = `SSO desativados`. Não mude
  *Default authentication*.
- Aba *SAML settings*:

| Campo | Valor |
|---|---|
| Enable SAML authentication | ligado |
| Enable JIT provisioning | ligado |
| IdP entity ID | `https://sso.exemplo.net.br/application/saml/zabbix/metadata/` |
| SSO service URL | `https://sso.exemplo.net.br/application/saml/zabbix/sso/binding/redirect/` |
| SLO service URL | `https://sso.exemplo.net.br/application/saml/zabbix/slo/binding/redirect/` |
| Username attribute | `http://schemas.goauthentik.io/2021/02/saml/username` |
| SP entity ID | `zabbix` |
| SP name ID format | `urn:oasis:names:tc:SAML:2.0:nameid-format:unspecified` |
| Sign | *Messages* e *Assertions* ligados; o resto desligado |
| Encrypt | desligado |
| Case-sensitive login | desligado |
| Group name attribute | `http://schemas.xmlsoap.org/claims/Group` |
| User name attribute | `http://schemas.xmlsoap.org/ws/2005/05/identity/claims/name` |
| User group mapping | `zabbix-admin` → `SSO admin` + *Super admin role*; `zabbix-operador` → `SSO operador` + *Admin role*; `zabbix-leitura` → `SSO leitura` + *User role* |

Para a conta criada pelo JIT já receber a mídia de e-mail, mapeie a mídia pelo
atributo `http://schemas.xmlsoap.org/ws/2005/05/identity/claims/emailaddress`
(*Media type mapping*).

Os mesmos passos podem ser feitos pela API do Zabbix (grupos de usuários,
diretório SAML com JIT e mapeamentos); o resultado é o da tela acima.

Teste com um usuário de `zabbix-leitura` numa aba anônima antes de avisar a
equipe; depois passe o mesmo usuário para `zabbix-operador` e entre de novo. A
conta tem de ser criada pelo JIT com o papel e o grupo do mapeamento, e com nome
e e-mail vindos do authentik.

## Contas que já existem no Zabbix

O SAML liga pelo **username**. Se já existe uma conta interna com o mesmo login, ela
entra pelo SSO mantendo os grupos atuais (não é tocada pelo JIT; confira no primeiro teste). Para passar a ser
controlada pelos grupos do authentik, apague a conta interna (com cuidado com dono de
ações, relatórios e mídias) e entre de novo pelo SSO. Não apague `Admin`, os usuários de
API (Grafana e outras integrações) nem a conta que os equipamentos ou scripts usam.

## Desfazer

Desligue *Enable SAML authentication* na tela (vale na hora). Contas criadas pelo JIT
ficam, sem senha local.

Quem sai dos grupos `zabbix-*` no authentik deixa de conseguir entrar na hora (o authentik
recusa). A conta no Zabbix fica parada; para limpar, ponha em `SSO desativados` ou apague.

## Vencimento do certificado

O certificado do item 3.2 tem validade. Ao trocar o certificado de assinatura no
authentik, troque também o `idp.crt` no frontend, senão o login SAML para de
funcionar. Vale monitorar a data (`openssl x509 -in idp.crt -noout -enddate`).
