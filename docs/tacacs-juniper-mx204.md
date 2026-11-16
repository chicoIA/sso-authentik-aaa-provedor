# TACACS+ no Juniper MX204 (Junos)

Roteiro para o MX204; serve de modelo para os demais Juniper.
Visão geral do TACACS+: [tacacs.md](tacacs.md). Huawei: [tacacs-huawei-ne8000.md](tacacs-huawei-ne8000.md).

## Como funciona

O Junos não usa níveis. O TACACS+ devolve `local-user-name` (serviço `junos-exec`)
e o equipamento aplica a **classe** do usuário-modelo local com esse nome:

| Grupo no authentik | Usuário-modelo no MX | Classe Junos |
|---|---|---|
| `tacacs-admin` | `tacacs-admin` | `super-user` |
| `tacacs-operador` | `tacacs-operador` | `operator` (show, clear, ping; sem configurar) |
| `tacacs-leitura` | `tacacs-leitura` | `read-only` |

| Quem loga | Como autentica |
|---|---|
| usuários locais (`root`, conta de emergência...) | base local primeiro, como antes |
| quem só existe no authentik (ex.: `joao.silva`) | TACACS+ |
| login, mudanças e comandos de **todos** | registrados no TACACS+ (painel) |

Os usuários locais não dependem do TACACS+. Diferente do Huawei, no Junos uma
senha local errada também segue para o TACACS+ (inofensivo).

## Antes

1. **SSH restrito às redes de gerência** (próxima seção). Com o SSH aberto para a
   internet, o equipamento recebe tentativas de força bruta o tempo todo (`root`,
   `supervisor`, `ubuntu`...). Com o TACACS+, cada tentativa testa senha de usuário
   do SSO: não ligue o TACACS+ num equipamento exposto.
2. Usuário de teste no grupo `tacacs-admin` do authentik.
3. IP de origem dentro das faixas aceitas (`device equipamentos` em
   `apps/tacacs/tac_plus-ng.cfg.modelo`: `100.65/16`, `100.66/16`, `172.16/12`...).
4. Gerência em routing-instance? `show configuration system management-instance`.
   Se sim, acrescentar `routing-instance mgmt_junos` no `tacplus-server`.
5. Conflitos: `show configuration system | display set | match "tacplus|radius|authentication-order|login user"`.
6. Uma sessão aberta durante todo o teste; a chave `TACACS_KEY` vem do `.env`
   (não cole em chat nem em chamado).
7. No servidor, o log de eventos aberto: `sudo ./provedor logs tacacs -f`.

## Restringir o SSH (filtro no lo0)

O filtro do `lo0` vale para todo tráfego destinado ao roteador (BGP, OSPF, BFD...).
Este só mexe na porta 22 e aceita o resto. **Se o `lo0` já tem filtro**
(`show configuration interfaces lo0`), coloque os termos de SSH no filtro
existente, **antes** dos demais, em vez de criar outro.

```
set policy-options prefix-list GERENCIA-SSH 100.65.0.0/16
set policy-options prefix-list GERENCIA-SSH 100.66.0.0/16
set policy-options prefix-list GERENCIA-SSH 172.16.0.0/12
set policy-options prefix-list GERENCIA-SSH 10.99.99.0/24
set policy-options prefix-list GERENCIA-SSH 192.0.2.0/24
set policy-options prefix-list GERENCIA-SSH 198.51.100.0/24
set firewall family inet filter PROTEGE-SSH term ssh-ok from source-prefix-list GERENCIA-SSH
set firewall family inet filter PROTEGE-SSH term ssh-ok from protocol tcp
set firewall family inet filter PROTEGE-SSH term ssh-ok from destination-port ssh
set firewall family inet filter PROTEGE-SSH term ssh-ok then accept
set firewall family inet filter PROTEGE-SSH term ssh-bloqueia from protocol tcp
set firewall family inet filter PROTEGE-SSH term ssh-bloqueia from destination-port ssh
set firewall family inet filter PROTEGE-SSH term ssh-bloqueia then count ssh-bloqueado
set firewall family inet filter PROTEGE-SSH term ssh-bloqueia then discard
set firewall family inet filter PROTEGE-SSH term resto then accept
set interfaces lo0 unit 0 family inet filter input-list PROTEGE-SSH
commit confirmed 5
```

A lista `GERENCIA-SSH` acima é um exemplo: ajuste às origens reais da sua equipe e do
monitoramento ([ssh-acl.md](ssh-acl.md) mostra como levantar). Se o SSH atende IPv6,
repetir em `family inet6`. Dentro dos 5 minutos: SSH novo de dentro da rede entra,
`show firewall filter PROTEGE-SSH` mostra o contador subindo, `show bgp summary` sem
queda; então `commit`.

## Configuração do TACACS+

```
set system authentication-order [ password tacplus ]
set system tacplus-server 100.66.80.196 port 49
set system tacplus-server 100.66.80.196 secret "<TACACS_KEY>"
set system tacplus-server 100.66.80.196 source-address <IP de gerência>
set system tacplus-server 100.66.80.196 timeout 10
set system login user tacacs-admin uid 2101 class super-user
set system login user tacacs-operador uid 2102 class operator
set system login user tacacs-leitura uid 2103 class read-only
set system accounting events [ login change-log interactive-commands ]
set system accounting destination tacplus
commit confirmed 5
```

- Os usuários-modelo **não têm senha**: ninguém loga com eles, só servem de molde.
- `timeout 10`: o primeiro login "frio" leva ~2 s (fluxo do authentik); o padrão do
  Junos é 3 s.
- `accounting`: login/logout, mudanças de configuração e todos os comandos digitados.

## Como validar

Dentro dos 5 minutos, sem fechar a sessão aberta:

| Teste | Resultado esperado | No log de eventos |
|---|---|---|
| SSH novo com usuário **local** | entra como antes | — |
| SSH novo com o usuário do authentik | entra; `show cli authorization` mostra a classe do grupo | `authen ... permitido` |
| Comandos nessa sessão | executam | linhas `acct` com o comando (também no painel) |

O painel fica em `http://100.66.80.196:9049` (ícone *Painel TACACS+* no portal do SSO).
Tudo certo: `commit`. Senão, não faça nada: o Junos desfaz sozinho.

## Desfazer

Depois de confirmado:

```
delete system tacplus-server 100.66.80.196
delete system authentication-order
delete system accounting
delete system login user tacacs-admin
delete system login user tacacs-operador
delete system login user tacacs-leitura
commit confirmed 5
```

(Confira antes com `show configuration system accounting` se já havia accounting
para outro destino, para não apagá-lo.)

## Cuidados

- SSH exposto à internet (ver "Antes"): restringir **antes** de ligar o TACACS+.
- O servidor já trata o Junos (`service=junos-exec` → `local-user-name`), coberto
  pelo `./provedor teste tacacs`.
- No Junos o perfil `tacacs-operador` não configura (classe `operator`); no Huawei ele
  entra no nível de configuração (nível 2).
