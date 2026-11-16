# TACACS+ no Huawei NE8000 (VRP8)

Roteiro para os Huawei com VRP8 (configuração com `commit`). Para a família S (VRP5,
sem `commit`): [tacacs-huawei-s12700.md](tacacs-huawei-s12700.md).
Visão geral do TACACS+: [tacacs.md](tacacs.md).

## Resultado esperado

| Quem loga | Domínio | Como autentica |
|---|---|---|
| usuários locais (conta de emergência, `zabbix`...) | `default_admin` | base local primeiro, como antes |
| quem só existe no authentik (ex.: `joao.silva`) | `default_admin` | TACACS+ |
| comandos de **todos** (inclusive locais) | — | registrados no TACACS+ (`cmd recording-scheme`) |

Login sempre **sem domínio** (`joao.silva`, não `joao.silva@...`): com `user-name original`
o servidor receberia o nome com o domínio, que não existe no authentik.

Os usuários locais não dependem do TACACS+: se ele cair, nada muda para eles.

## Antes

1. SSH do equipamento restrito às redes de gerência ([ssh-acl.md](ssh-acl.md)).
2. Usuário de teste no grupo `tacacs-admin` do authentik.
3. **Duas sessões abertas** no equipamento, uma delas com usuário local.
4. A chave `TACACS_KEY` do `.env` (não cole em chat nem em chamado).
5. IP de origem dentro das faixas aceitas (`device equipamentos` em
   `apps/tacacs/tac_plus-ng.cfg.modelo`).
6. No servidor, o log de eventos aberto: `sudo ./provedor logs tacacs -f`.

## Configuração

```
system-view
hwtacacs-server template provedor
 hwtacacs-server authentication 100.66.80.196
 hwtacacs-server authorization 100.66.80.196
 hwtacacs-server accounting 100.66.80.196
 hwtacacs-server source-ip <IP de gerência>
 hwtacacs-server shared-key cipher <TACACS_KEY>
 hwtacacs-server user-name original
 hwtacacs-server timer response-timeout 10
 hwtacacs-server timer quiet 1
 quit
aaa
 # Local primeiro; usuário que não existe localmente vai ao TACACS+
 authentication-scheme local-tacacs
  authentication-mode local hwtacacs
 authorization-scheme local-tacacs
  authorization-mode local hwtacacs
 # Registro de todos os comandos
 recording-scheme REGISTRO
  recording-mode hwtacacs provedor
 cmd recording-scheme REGISTRO
 domain default_admin
  authentication-scheme local-tacacs
  authorization-scheme local-tacacs
  hwtacacs-server provedor
commit
```

## Como validar

Nesta ordem, sem fechar as sessões abertas:

| Teste | Resultado esperado | No log de eventos |
|---|---|---|
| SSH novo com um usuário **local** | entra como antes | nenhum `authen`; só os comandos dele (`acct`) |
| SSH novo com o usuário do authentik, **sem domínio** | entra com o nível do grupo | `authen ... permitido` |
| Alguns comandos nessa sessão | executam | linhas `acct` com o comando (também no painel) |
| Usuário local com a senha errada | recusado (não segue para o TACACS+) | — |

O painel fica em `http://100.66.80.196:9049` (ícone *Painel TACACS+* no portal do SSO).
Recusa inesperada: `display aaa online-fail-record username <usuario> brief`
(`Local user does not exist`, `Server no response`).

## Desfazer

Pela sessão que ficou aberta:

```
aaa
 domain default_admin
  undo authentication-scheme
  undo authorization-scheme
  undo hwtacacs-server
commit
```

## Se o equipamento já tem outro template ou domínio TACACS+

Um equipamento que já passou por um teste anterior pode ter dois templates (um ligado a
um domínio próprio, como `tacacs`, com login `usuario@tacacs`, e outro no
`default_admin`). Funciona, mas é redundante. Para igualar ao modelo acima, nesta ordem:

1. aponte o `recording-scheme REGISTRO` para o template que vai ficar
   (`recording-mode hwtacacs <template>`) e dê `commit`;
2. confira no painel que os comandos continuam chegando;
3. só então remova o domínio, os esquemas e o template que sobraram.

Na ordem inversa, o registro de comandos fica sem template.

## Cuidados

- **Não usar `authorization-cmd`.** Com ele, os comandos dos usuários **locais** também
  vão ao TACACS+, que os nega (não estão em grupo `tacacs-*`); o `local` só entra se o
  servidor não responder. O usuário local fica "só view" e a conta local de
  monitoramento (`zabbix`) tem os comandos negados, o que quebra a coleta. O nível
  devolvido pelo TACACS+ já limita os usuários do authentik. Para tirar:
  `undo authorization-cmd 3` nos `authorization-scheme` e `commit`.
- **Separador de domínio.** Se o equipamento tiver `domain-name-delimiter %`,
  `joao.silva@tacacs` não cai no domínio `tacacs` (vira usuário local inexistente).
  Confira com `display current-configuration configuration aaa | include delimiter`.
- **Domínio no nome.** Por padrão o template manda `usuario@dominio`, que não
  existe no authentik. Nesta versão não há `domain-excluded`: usa-se
  `undo hwtacacs-server user-name domain-included` (confira `Domain-included : No`).
- **Domínio de administração exige nome original.** Ligar ao `default_admin` um
  template sem domínio dá *"...send user names without domain names brings
  security risks..."*. Por isso o template usa `user-name original`.
- **`local hwtacacs` funciona como esperado:** usuário que não existe na base
  local segue para o TACACS+; senha local errada é recusada.
- **Tempo de resposta.** O padrão do equipamento é 5 s e, depois de um timeout, o
  servidor fica em quarentena por 5 min (`Server no response` sem nem enviar). O
  primeiro login "frio" pode levar alguns segundos (fluxo de login do authentik +
  busca de grupos); o servidor só lê grupos `tacacs-*` para ficar em ~1 s, e o
  template usa 10 s de espera e quarentena de 1 min.
- **Contabilidade de sessão no `default_admin`: não ligar.** `accounting
  start-fail online` não existe nesta versão; sem ele, uma queda do TACACS+
  poderia bloquear também os usuários locais. A auditoria fica no
  `cmd recording-scheme`.
- **Níveis.** O VRP vai até o nível 3 nos comandos; qualquer nível acima disso
  equivale a acesso total. Por isso o `tacacs-operador` devolve nível 2
  (configuração, sem usuários/AAA/arquivos/`save`).
- Comandos que não existem nesta versão: `test-aaa`, `display aaa configuration`,
  `display domain name <x>` (use `display domain`).
- O `~` no prompt indica alteração sem `commit`
  (`display configuration candidate changes`).
