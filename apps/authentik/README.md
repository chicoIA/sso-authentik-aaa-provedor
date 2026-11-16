# App authentik (núcleo)

PostgreSQL + `authentik-server` + `authentik-worker` (sem Redis), versão `AUTHENTIK_TAG`.
Este app também monta os blueprints de todos os apps (`authentik`, `radius`, `ldap`,
`tacacs`, `painel`) em `/blueprints/provedor/<app>`; o authentik os aplica sozinho.

Blueprints próprios (`blueprints/`):
- `00-marca.yaml`: marca na tela de login (título, logo, ícone, fundo e cores).
- `01-fluxo-autenticacao.yaml`: fluxo `provedor-radius-autenticacao` (usuário, senha
  e login), usado pelos outposts RADIUS e LDAP. A etapa de MFA `provedor-radius-mfa`
  fica definida, mas fora do fluxo.
- `06-protecao-login-web.yaml`: força bruta no login web (reputação por IP), sem
  afetar RADIUS/LDAP. Ajuste a lista de redes que nunca são bloqueadas.
- `09-mfa-web.yaml`: TOTP obrigatório no login web.
- `10-definir-senha.yaml`: link de recuperação para a pessoa definir a própria senha.
- `07-wiki.yaml`, `11-grafana.yaml`, `12-zabbix.yaml`, `13-netbox.yaml`: login único
  de sistemas web (`docs/grafana-sso.md`, `docs/zabbix-sso.md`, `docs/netbox-sso.md`).
  Troque os endereços de exemplo pelos seus, ou tire da pasta os que não for usar.

Opcional (`opcionais/`, não aplicado sozinho): `mfa-equipamentos.yaml`, segundo fator
no login dos equipamentos (`docs/ssh-2fa.md`).

## Variáveis (`env.example`)
`AUTHENTIK_TAG`, `PG_DB`, `PG_USER`, `PG_PASS`, `AUTHENTIK_SECRET_KEY`,
`AUTHENTIK_BOOTSTRAP_PASSWORD/TOKEN/EMAIL`, `AUTHENTIK_URL_EXTERNA`,
`COMPOSE_PORT_HTTP/HTTPS`, `AUTHENTIK_RADIUS_TOKEN`, `AUTHENTIK_LDAP_TOKEN`.
Consumo reduzido: 1 worker web, worker com 1 processo e 2 threads.

Cuidado: o consumo de memória do `authentik-worker` cresce com o tempo
(`mem_limit: 768m` no `compose.yml`). Acompanhe com `./provedor status` e, se
encostar no limite, recrie o app numa janela combinada.

## Subir e testar
    ./provedor up authentik
    apps/authentik/teste.sh
Depois de aplicados os blueprints dos apps radius e ldap, grave os tokens dos outposts
(`./provedor tokens` faz o mesmo):

    python3 apps/authentik/scripts/tokens_outpost.py --gravar

## Operar pela interface
Acesse `AUTHENTIK_URL_EXTERNA` com `akadmin` e a senha de bootstrap. Usuários, grupos,
senhas, MFA, aplicações e fontes de login são geridos em Diretório e Aplicações.
Blueprints aplicados: Personalização > Blueprints. Veja `NOVOS-LOGINS.md`.

## Marca (tela de login)

O blueprint `blueprints/00-marca.yaml` define o título do fluxo de login web, o logo,
o ícone, a arte de fundo, as cores e o tema claro. As imagens ficam em `marca/` (no
git) e precisam estar na mídia do authentik (fora do git, em `data/`):

```bash
install -d -o 1000 -g 1000 data/media/public/provedor
install -o 1000 -g 1000 -m 644 marca/logo.svg marca/favicon.svg marca/fundo-login.svg data/media/public/provedor/
```

As imagens do repositório são genéricas. Para pôr a marca do seu provedor (logo,
favicon, fundo, cores e textos), siga
[docs/pagina-de-login.md](../../docs/pagina-de-login.md).

Cuidado ao editar `marca/fundo-login.svg`: mantenha o texto entre x=320 e x=1000,
para não ser cortado em telas 5:4 nem coberto pelo cartão de login (layout
`sidebar_right`).
