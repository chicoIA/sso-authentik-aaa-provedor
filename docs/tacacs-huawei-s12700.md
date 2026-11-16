# TACACS+ no Huawei S12700 (VRP5)

Roteiro para os switches Huawei da família S (VRP5, sem `commit`).
NE8000 (VRP8): [tacacs-huawei-ne8000.md](tacacs-huawei-ne8000.md).
Visão geral: [tacacs.md](tacacs.md).

## Resultado esperado

| Quem loga | Como autentica |
|---|---|
| usuários locais (`admin`...) | base local primeiro, como antes |
| quem está num grupo `tacacs-*` do authentik | TACACS+, nível 1/2/15 conforme o grupo |
| quem só está nos grupos do RADIUS | **recusado**: o RADIUS sai do `default_admin` |
| comandos de todos | registrados no TACACS+ (painel) |

## Cuidados

- **Não misturar RADIUS e TACACS+ no `default_admin`.** Com `local hwtacacs radius`, o
  Huawei só passa ao método seguinte quando o anterior **não responde**: quem só tem
  RADIUS passa a ser recusado. E quem ainda entra pelo RADIUS (com o TACACS+ fora) tem a
  **autorização** mandada ao TACACS+ **sem nome de usuário**, que é negada: a pessoa
  entra sem poder de admin. Parar o TACACS+ não resolve (fica sem método que autorize).
- **Não usar `authorization-cmd` no S12700.** O nível devolvido pelo TACACS+ (1/2/15)
  já limita os comandos; `authorization-cmd` só acrescenta formas de travar o acesso.
- **Antes de trocar, pôr nos grupos `tacacs-*` todo mundo que entra hoje pelo RADIUS**
  nesse equipamento (log do FreeRADIUS: `PROVEDOR-AUTH nas=<IP> ... Access-Accept`).
- **Chave:** conexões que abrem, trocam um pacote e fecham sem evento no servidor =
  chave errada. Reaplicar `hwtacacs-server shared-key cipher` copiando do `.env`.
- **Sem `commit`:** cada comando vale na hora. Sessão aberta com usuário **local**
  admin e console à mão; não dar `save` antes de testar; a troca do domínio por último.
- **SSH exposto à internet:** restrinja com ACL antes de tudo (passo 0 abaixo e
  [ssh-acl.md](ssh-acl.md)).
- **Recuperação se o acesso travar:** recusar o TACACS+ só para o IP do equipamento no
  firewall do servidor (`reject with tcp reset`) faz o Huawei cair no `local` na hora.

## Configuração

A lista de origens da ACL é um exemplo: troque pelas redes de onde a sua equipe
realmente entra ([ssh-acl.md](ssh-acl.md) mostra como levantar).

```
system-view
# 0) SSH só das redes de gerência (ACL livre? inclua todas as origens reais)
acl number 2999
 rule 5 permit source 100.65.0.0 0.0.255.255
 rule 10 permit source 100.66.0.0 0.0.255.255
 rule 15 permit source 172.16.0.0 0.15.255.255
 rule 20 permit source 10.99.99.0 0.0.0.255
 rule 25 permit source 192.0.2.0 0.0.0.255
 rule 30 permit source 198.51.100.0 0.0.0.255
 rule 100 deny
 quit
ssh server acl 2999

# 1) Template
hwtacacs-server template provedor
 hwtacacs-server authentication 100.66.80.196 49
 hwtacacs-server authorization 100.66.80.196 49
 hwtacacs-server accounting 100.66.80.196 49
 hwtacacs-server source-ip source-loopback 0
 hwtacacs-server shared-key cipher <TACACS_KEY>
 undo hwtacacs-server user-name domain-included
 hwtacacs-server timer response-timeout 10
 hwtacacs-server timer quiet 1
 quit

# 2) Esquemas (ainda não mudam o login)
aaa
 authentication-scheme local-tacacs
  authentication-mode local hwtacacs
  quit
 authorization-scheme local-tacacs
  authorization-mode local hwtacacs
  quit
 accounting-scheme sem-contabilidade
  accounting-mode none
  quit
 recording-scheme REGISTRO
  recording-mode hwtacacs provedor
  quit
 cmd recording-scheme REGISTRO
 quit
ssh authentication-type default password

# 3) Por último: troca o login (vale na hora)
aaa
 domain default_admin
  authentication-scheme local-tacacs
  authorization-scheme local-tacacs
  accounting-scheme sem-contabilidade
  hwtacacs-server provedor
  undo radius-server
```

O domínio `default` (usuários não administrativos) continua como estava.

**Origem (V200):** nos Huawei V200 use `hwtacacs-server source-ip source-loopback 0`
no lugar de um IP fixo. O endereço do LoopBack0 precisa estar nas faixas aceitas pelo
servidor (`device equipamentos` em `apps/tacacs/tac_plus-ng.cfg.modelo`); confira com
`display interface LoopBack0`.

## Como validar

Sem fechar a sessão local aberta, e com o log de eventos aberto no servidor
(`sudo ./provedor logs tacacs -f`):

| Teste | Resultado esperado | No log de eventos |
|---|---|---|
| SSH novo com usuário **local** admin | entra, nível 3/15, `system-view` funciona | nenhum `authen`; só os comandos dele |
| SSH novo com usuário de `tacacs-admin` | entra; `display users`; `system-view` funciona | `authen ... permitido` e `author ... permitido` |
| Comandos nessa sessão | executam | aparecem no painel (`http://100.66.80.196:9049`) |

Passou em tudo: então `save`.

Recusa de usuário local: `display aaa online-fail-record username <u>` e
`display local-user username <u>` (senha, `State: Block`, `Service-type` sem ssh).

## Desfazer (volta ao RADIUS)

```
aaa
 domain default_admin
  authentication-scheme default
  authorization-scheme default
  accounting-scheme default
  undo hwtacacs-server
  radius-server RADIUS-ANTIGO
```

(`default` aqui é o esquema `local radius` que o equipamento já usava e `RADIUS-ANTIGO`
é o nome do template RADIUS dele; confira com
`display current-configuration configuration aaa` antes.)
