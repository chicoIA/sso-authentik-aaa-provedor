# Página de login

A tela de login web do authentik sai personalizada por blueprint, sem editar nada pela
interface. Este documento mostra o que é ajustado e como trocar pela identidade da sua
empresa.

## O que o repositório ajusta

| Arquivo | Efeito |
|---|---|
| `apps/authentik/blueprints/00-marca.yaml` | título, logo, ícone da aba, imagem de fundo, cores, fontes, tema claro, cartão de login à direita, título do fluxo, sem o rodapé "Powered by authentik" |
| `apps/authentik/marca/` | `logo.svg`, `favicon.svg` e `fundo-login.svg` de exemplo |
| `apps/authentik/blueprints/09-mfa-web.yaml` | TOTP obrigatório: quem não tem cadastra no próximo login |
| `apps/authentik/blueprints/06-protecao-login-web.yaml` | bloqueio por reputação de IP depois de 5 senhas erradas, com exceção para as redes internas |
| `apps/authentik/blueprints/10-definir-senha.yaml` | link de uso único para a pessoa definir a própria senha (não há "Esqueci a senha" nem e-mail) |

O login dos equipamentos (RADIUS, TACACS+) usa outro fluxo e não é afetado por nada
disso.

## Trocar pela sua marca

### 1. Imagens

Substitua os três arquivos em `apps/authentik/marca/`, mantendo os nomes (ou ajuste os
nomes no blueprint):

| Arquivo | Recomendação |
|---|---|
| `logo.svg` | largo, cerca de 335×90. PNG com fundo transparente também serve |
| `favicon.svg` | quadrado |
| `fundo-login.svg` | 1920×1080. É um SVG de texto: abra num editor e troque frases e cores |

No `fundo-login.svg`, mantenha o texto entre `x=320` e `x=1000`. O cartão de login ocupa
a direita da tela e a imagem é cortada nas bordas conforme a proporção do monitor
(16:9, 16:10, 5:4).

Copie para a mídia do authentik (o dono precisa ser o usuário `1000` do container):

```sh
cd apps/authentik
install -d -o 1000 -g 1000 data/media/public/provedor
install -o 1000 -g 1000 -m 644 marca/logo.svg marca/favicon.svg marca/fundo-login.svg data/media/public/provedor/
```

### 2. Textos e cores

Em `apps/authentik/blueprints/00-marca.yaml`:

| Campo | O que é |
|---|---|
| `branding_title` | nome na aba do navegador e nos títulos |
| `branding_logo`, `branding_favicon`, `branding_default_flow_background` | caminhos relativos à mídia (`provedor/logo.svg`...) |
| `attributes.settings.theme.base` | `light` ou `dark` |
| `branding_custom_css` | cores e fontes. As variáveis `--pf-global--primary-color--100/200/300`, `--pf-global--link--Color` e `--ak-accent` definem a cor principal; troque `#1f6feb` e `#0f3d6e` pelas suas |
| `title` do fluxo `default-authentication-flow` | frase acima do campo de usuário (`Exemplo — Acesso`) |
| `layout` | `sidebar_right` deixa o cartão à direita e a arte à esquerda; `stacked` centraliza |

O CSS também aumenta o logo no painel e na área do usuário, alinha a arte à esquerda,
estiliza o título e esconde o último item do rodapé. Cada bloco tem um comentário
dizendo o que faz; apague os que não quiser.

### 3. Aplicar

```sh
sudo ./provedor up authentik
```

O worker reaplica os blueprints sozinho. Para forçar na hora:

```sh
docker exec provedor-authentik-authentik-worker-1 ak apply_blueprint provedor/authentik/00-marca.yaml
```

Abra o endereço do login numa janela anônima. Se a imagem antiga persistir, é cache do
navegador.

## Cuidados

- O blueprint aplica antes o brand e o fluxo padrão do authentik
  (`metaapplyblueprint`). Sem isso, uma reaplicação do blueprint padrão volta o título
  para "Welcome to authentik!".
- Mudanças feitas pela interface nesses mesmos campos são desfeitas na próxima
  reaplicação. Altere sempre no arquivo.
- As classes CSS (`pf-c-*`, `ak-*`) são internas do authentik e podem mudar entre
  versões. Depois de atualizar o authentik, confira a tela de login e a área do usuário.
- A pasta `apps/authentik/data/` não vai para o git (`.gitignore`). Entra no backup
  (`sudo ./provedor backup completo`) e precisa ser copiada para a reserva
  (`apps/vps/reserva/`, pasta `media`), ou a tela da reserva aparece sem a marca.

## Tela de segundo fator e de senha

- **Cadastro do TOTP.** No primeiro login depois de ligar o `09-mfa-web.yaml`, a pessoa
  vê o QR code, lê com o aplicativo autenticador e confirma um código. Daí em diante o
  código é pedido a cada login web.
- **Definir senha.** *Diretório > Usuários > (usuário) > Criar link de recuperação*. O
  link abre uma tela só com os campos da nova senha, é de uso único e expira. Ele não faz
  login: o segundo fator continua sendo pedido em seguida.
- **Bloqueio por tentativas.** Para liberar um IP antes do prazo:
  *Personalização > Políticas > Reputação* e apague a linha do IP.
