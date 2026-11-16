# TACACS+ no Datacom (DmOS)

Roteiro para ligar o TACACS+ em **um** Datacom, provar que o login funciona nos três
níveis e que o usuário local de emergência continua entrando, e só depois levar aos
demais. Validado em switch DM4270. A sintaxe do DmOS varia com a versão do firmware: os
comandos abaixo são o ponto de partida e cada passo diz como confirmar com `?` antes de
aplicar. Visão geral do TACACS+: [tacacs.md](tacacs.md).

Servidor `100.66.80.196`, porta 49, chave = `TACACS_KEY` do `.env` do servidor (não
cole em chat nem em chamado). O equipamento precisa estar numa faixa aceita
(`100.65.0.0/16`, `100.66.0.0/16`, `172.16.0.0/12`, `198.51.100.0/26`; ver
`device equipamentos` em `apps/tacacs/tac_plus-ng.cfg.modelo`).

## Como funciona

O DmOS pede autorização **por comando**: o que a pessoa pode fazer vem do perfil do
TACACS+, não do `priv-lvl`.

| Grupo no authentik | No DmOS |
|---|---|
| `tacacs-admin` | tudo |
| `tacacs-operador` | configura (interface, `commit`...), mas `aaa`/usuários, firmware, arquivos, `reboot` e `rollback` são negados (o operador não consegue tirar o próprio TACACS+) |
| `tacacs-leitura` | só consulta (`show`, `ping`...); `config` é negado |

A lista de negados do operador fica no perfil `tacacs-operador` de
`apps/tacacs/tac_plus-ng.cfg.modelo`.

## 0. Antes

1. Comece por um Datacom pouco crítico. Anote modelo e firmware: `show firmware` (ou
   `show version`) e guarde `show running-config aaa`.
2. Confira o usuário local de emergência: `show running-config aaa user`. Ele tem de
   continuar existindo e com nível admin.
3. Ponha no authentik três contas de teste (ou pessoas reais) em `tacacs-admin`,
   `tacacs-operador` e `tacacs-leitura`, e deixe uma quarta conta **sem** grupo. Se o
   grupo usar listas por equipamento (`tacacs_*_em`), inclua o IP deste Datacom.
4. Se o monitoramento (Zabbix) coleta este equipamento com uma conta do authentik,
   essa conta precisa estar num grupo `tacacs-*` que permita os comandos da coleta
   (em `tacacs-admin` a coleta funciona sem falhas).
5. Abra **duas** sessões no equipamento e deixe uma parada como reserva.
6. No servidor, acompanhe o log de eventos durante todo o teste
   (`/var/log/tacacs/eventos.tsv`, container `provedor-tacacs-tacacs-1`):

   ```sh
   sudo ./provedor logs tacacs -f
   ```

## 1. Configurar com rollback automático

O DmOS aplica com `commit`; use **`commit confirmed`** para que tudo volte sozinho se o
acesso quebrar.

```
config
aaa server tacacs PROVEDOR            ! confirmar o caminho com: aaa server ?
 host 100.66.80.196                  ! confirmar com: host ?
  shared-secret <TACACS_KEY>
  port 49
 !
!
aaa authentication-order [ tacacs local ]   ! confirmar com: aaa authentication-order ?
commit confirmed 10
```

Se houver opções de autorização/contabilidade por servidor (ver `?` dentro do `host`),
habilite o **accounting** (registro dos comandos, não nega nada). Se a autorização de
comandos for opcional na sua versão, deixe-a para um segundo teste: ela nega os comandos
de quem não tem um perfil que os permita, o que costuma quebrar a coleta de uma conta
de monitoramento.

## 2. Testes de aceitação (dentro dos 10 min)

Numa sessão **nova** para cada linha. No log, as colunas são
`data_hora tipo nas_ip usuario porta origem resultado detalhe`.

| Teste | No equipamento | No log de eventos |
|---|---|---|
| usuário de `tacacs-admin` | entra; `config` funciona | `authen ... permitido`; `author ... permitido` nos comandos |
| usuário de `tacacs-operador` | entra; configura interface e faz `commit`; `aaa` e `reboot` negados | `authen ... permitido`; `author ... negado` nos comandos da lista de negados |
| usuário de `tacacs-leitura` | entra; só `show`; `config` negado | `authen ... permitido`; `author ... negado  config` |
| conta sem grupo `tacacs-*` | Access Denied | `authen ... negado  login failed (backend error) [Insufficient access]` |
| senha errada de um usuário do authentik | recusado, **sem** cair no usuário local | `authen ... negado  login failed [Invalid credentials]` |
| usuário local de emergência | entra pela conta local (ordem `tacacs local`) | `authen ... negado  login failed` (a conta não existe no authentik) |

Para cada login, confira nas linhas `authen`/`author` o que o Datacom pediu e o que o
servidor respondeu. Se todos entrarem com o mesmo nível, anote o atributo ou serviço
que o equipamento pede: pode ser preciso um mapeamento próprio em
`tac_plus-ng.cfg.modelo` para aquela versão do DmOS.

## 3. Fechar

- Tudo certo: `commit` (sem `confirmed`) antes de vencer o prazo. Guarde
  `show running-config aaa` junto com o modelo e o firmware anotados.
- Algo errado: não faça nada; em 10 min volta sozinho. Anote o horário do teste e
  procure no `eventos.tsv` as linhas do IP do equipamento nesse horário para ver o que
  ele pediu.

## Como ler o log com o DmOS

- `acct ... stop` = comando **executado** (registro de contabilidade, não é falha);
  `author ... permitido/negado` = decisão de autorização.
- `commit`, `end`, `exit` e `paginate` só aparecem como `acct` (o DmOS não pede
  autorização para eles).
- O `no` some no `author` (`no description` chega como `description`). Entrar num
  submodo exige o comando do topo (`aaa`), então negá-lo fecha o submodo inteiro.
- Um comando do DmOS pode virar vários: `show interface link` roda
  `show interface ten-gigabit-ethernet | tab ...` e `show interface hundred-gigabit-ethernet | tab ...`
  (e `paginate false`).
- No painel, o evento mais novo aparece em cima.

## Cuidados

- **Ordem `tacacs local`.** O usuário local de emergência é tentado primeiro no
  TACACS+ (aparece como `authen ... negado` no log, porque não existe no authentik) e
  só então entra pela conta local. Senha errada de um usuário do authentik e conta sem
  grupo são recusadas e não ganham acesso pela base local.
- **Logo depois de reiniciar o container do TACACS+**, o primeiro login pode falhar com
  `No answer from LDAP backend` (backend subindo); o seguinte entra.
- **Conta de teste:** desative no authentik a conta sem grupo usada no teste.
