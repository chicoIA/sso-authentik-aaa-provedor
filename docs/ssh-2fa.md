# Segundo fator no SSH dos equipamentos (TACACS+ e RADIUS)

O repositório sobe com **2FA obrigatório no login web** e **só senha nos equipamentos**.
Este documento mostra como exigir o segundo fator também no SSH dos equipamentos, usando
o mesmo TOTP que a pessoa já cadastrou no authentik.

## Como funciona

O equipamento só tem um campo de senha e não sabe pedir um código. Por isso o código
viaja **dentro do campo de senha**, separado por ponto e vírgula:

```
login:    joao.silva
Password: MinhaSenha;123456
```

O caminho do login por TACACS+:

```
ssh ──► equipamento ──TACACS+ (49/tcp)──► tac_plus-ng ──MAVIS/LDAP bind──► outpost LDAP ──► authentik
                                                                             │
                                             separa "senha" e "123456" ◄─────┘
                                             e executa o fluxo: usuário → senha → MFA → login
```

1. O equipamento manda usuário e o texto digitado ao `tac_plus-ng`.
2. O `tac_plus-ng` faz um *bind* LDAP com esse texto no outpost LDAP do authentik.
3. Com `mfa_support: true`, o outpost separa o que vem depois do último `;` e entrega
   senha e código ao fluxo `provedor-radius-autenticacao`.
4. O estágio `provedor-radius-mfa` valida o código. Só então o bind é aceito e o
   `tac_plus-ng` aplica o nível do grupo (`tacacs-admin`, `tacacs-operador`,
   `tacacs-leitura`).

Pelo RADIUS o desenho é o mesmo: FreeRADIUS → outpost RADIUS → mesmo fluxo.

O separador é **`;`** e é fixo no authentik. Formatos como `senha:código` ou
`senha+código` não são reconhecidos: o texto inteiro seria tratado como senha e recusado.

## Formas de login

| Forma | O que a pessoa digita | Quando vale |
|---|---|---|
| Só senha | `MinhaSenha` | padrão do repositório; e, com o MFA ligado em modo `skip`, para quem não tem autenticador |
| Senha + TOTP | `MinhaSenha;123456` | MFA ligado e a pessoa tem TOTP (o mesmo do login web) |
| Senha + código estático | `MinhaSenha;abcd1234` | MFA ligado; códigos de recuperação gerados no authentik, uso único |
| Senha + aprovação no celular (Duo) | `MinhaSenha` e aprova no aplicativo | exige incluir `duo` em `device_classes` e aumentar o tempo de espera do equipamento; não foi testado neste projeto |
| Usuário local de emergência | senha do cofre | só quando o TACACS+/RADIUS **não responde**; não tem segundo fator |

O que **não** funciona por esse caminho: WebAuthn/passkey e chave de segurança (o
equipamento não tem navegador), e CHAP/MS-CHAP (o outpost precisa receber a senha em
claro, por PAP ou pelo login ASCII do TACACS+).

## Ligar

Faça primeiro num ambiente de teste ou fora do horário de pico, com o usuário local de
emergência conferido em pelo menos um equipamento.

1. Copie o blueprint opcional para a pasta aplicada:
   ```sh
   cp apps/authentik/opcionais/mfa-equipamentos.yaml apps/authentik/blueprints/
   ```
   Ele acrescenta o estágio `provedor-radius-mfa` ao fluxo dos outposts (ordem 30, entre
   a senha e o login).
2. Ligue o suporte nos providers que devem pedir o código:
   - TACACS+ (e tudo que usa LDAP): `mfa_support: true` em
     `apps/ldap/blueprints/03-ldap.yaml`;
   - RADIUS: `mfa_support: true` em
     `apps/radius/blueprints/02-radius-equipamentos.yaml`.
3. Reaplique: `sudo ./provedor up authentik`. Confira em *Fluxos > provedor-radius-autenticacao*
   que há quatro estágios (10 identificação, 20 senha, 30 MFA, 100 login).
4. Teste com **uma** conta que tenha TOTP, mantendo outra sessão aberta no equipamento:
   - `senha;código` certo: entra;
   - só a senha: recusado;
   - `senha;código` errado: recusado, e **não** cai no usuário local (o servidor respondeu);
   - conta sem autenticador: entra só com a senha (modo `skip`).
   Acompanhe em `/var/log/tacacs/eventos.tsv` e em *Eventos > Logs* do authentik.

### Opcional ou obrigatório

O estágio vem com `not_configured_action: skip`: quem tem autenticador precisa do código,
quem não tem entra só com a senha. É o modo certo para a transição.

Para obrigar todo mundo, troque para `deny` no estágio `provedor-radius-mfa`
(`apps/authentik/blueprints/01-fluxo-autenticacao.yaml`). Antes disso:

- todas as pessoas já cadastraram o TOTP (o login web obrigatório cuida disso:
  `09-mfa-web.yaml`);
- as **contas de automação** (monitoramento, backup de configuração, scripts) não
  conseguem digitar código. Deixe-as fora da exigência com uma política no vínculo de
  ordem 30 que só execute o estágio para pessoas (por exemplo, uma *expression policy*
  `return not ak_is_group_member(request.user, name="automacao")`), e restrinja essas
  contas por grupo de nível baixo e por lista de equipamentos.

## Cuidados

- **Caches.** O `tac_plus-ng` guarda a autenticação por 60 s (`mavis cache timeout`) e o
  outpost LDAP guarda o resultado do bind (`bind_mode: cached`) pelo tempo da sessão do
  fluxo (5 min). Dentro dessas janelas, o mesmo `senha;código` é aceito de novo sem
  consultar o authentik. Isso é o que permite ao equipamento autenticar duas vezes no
  mesmo login (login e `enable`, por exemplo), já que o authentik não aceita o mesmo
  código TOTP duas vezes. Se a política da empresa não tolera essa janela, use
  `bind_mode: direct` no provider LDAP e reduza o cache do MAVIS, sabendo que os
  equipamentos que autenticam duas vezes vão pedir um código novo.
- **Senhas com `;`.** O que vem depois do último `;` é lido como código. Oriente a equipe
  a não usar senha que termine em `;` seguido de números.
- **Relógio.** O TOTP depende de hora certa no servidor do authentik (NTP) e no celular.
- **Tempo de resposta.** O login passa por mais uma etapa. Mantenha o timeout do
  TACACS+/RADIUS no equipamento em 5 s ou mais.
- **Uma senha, um código, uma tentativa.** Clientes SSH que tentam a senha de novo
  sozinhos gastam o código. Para não redigitar a cada janela, use o multiplexador do
  OpenSSH (`ControlMaster auto`, `ControlPersist 10m`).
- **Reputação por IP.** Continue sem a política de reputação no fluxo dos outposts: todos
  os logins chegam com o IP do FreeRADIUS ou do TACACS+, e um bloqueio pararia todos.
- **Força bruta.** O segundo fator não reduz o volume de tentativas que chega ao
  servidor. Restrinja o SSH às redes de gerência: [ssh-acl.md](ssh-acl.md).

## Desligar

1. `mfa_support: false` nos providers e reaplique.
2. Apague o vínculo de ordem 30 **pela interface** (*Fluxos > provedor-radius-autenticacao >
   Vínculos de estágio*) e remova o arquivo copiado no passo 1. Não use `state: absent`
   em `flowstagebinding`: a reaplicação falha no authentik 2026.8.

## Servidores Linux

Os servidores que entram pelo LDAP do authentik ([linux-sso.md](linux-sso.md)) usam o
mesmo provider. Com `mfa_support: true` nele, o SSH dos servidores também passa a aceitar
`senha;código` no campo de senha. Se o SSSD estiver com cache de credenciais para uso
sem rede, o que fica em cache é o texto digitado, com o código: desligue esse cache
(`cache_credentials = false`) nos servidores onde o segundo fator é exigido.

## Situação

O mecanismo `senha;código` rodou no ambiente de origem deste projeto e depois foi
desligado por decisão operacional (2FA só no login web). O blueprint opcional foi montado
a partir daquela configuração. A aprovação por Duo, a política para contas de automação e
o `bind_mode: direct` são caminhos previstos pelo authentik que este projeto não validou
em produção: teste antes de adotar.
