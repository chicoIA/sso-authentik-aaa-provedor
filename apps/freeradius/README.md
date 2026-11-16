# App freeradius

FreeRADIUS 3.2 em Docker (`network_mode: host`, `mem_limit 192m`) que **substitui o
FreeRADIUS de produção na virada**. Os equipamentos não mudam: mesmo IP, portas
1812/1813, mesmos segredos.

## O que ele faz

| Pedido | Comportamento |
|---|---|
| **Cadastro NAS** | Lido da tabela `nas` do daloRADIUS (`read_clients`, **só leitura**, CIDR inclusive `0.0.0.0/0`), como no FreeRADIUS do sistema. Segredos nunca vão para arquivo. `clients.conf` só tem o `localhost` (healthcheck/testes). NAS novo na tabela entra ao reiniciar o container. |
| **PAP** | Cache em memória (acerto responde sem consultar o authentik); senão proxy ao outpost (`127.0.0.1:18120`, `response_window 20s`). Authentik fora do ar: quem tem reserva no cache continua entrando; para os demais **não responde** ao NAS (`do_not_respond`), que cai no usuário local. Usuários com `@` são literais. |
| **CHAP / MS-CHAP / EAP-MD5** | O authentik só aceita PAP. `FR_CHAP_LEGADO=sim` (padrão): autentica pelo SQL do daloRADIUS como o FreeRADIUS antigo (`radcheck`, grupos, `daloRADIUS-Disabled-Users`) e registra `LEGADO-CHAP usuario=... nas=...`. `nao`: recusa e registra `CHAP-RECUSADO`. |
| **Accounting / post-auth** | `FR_GRAVAR_SQL=nao` (teste): só log. `sim` (após a virada): `radacct` e `radpostauth` (inclui recusas), com `pass` = `(authentik)` ou `(legado)`, nunca a senha. O accounting dos usuários de `FR_ACCT_IGNORAR_USUARIOS` (monitoramento) não vai para o `radacct`; o login deles continua registrado. |

### Cache (rajadas do monitoramento)

Por quê: cada verificação de senha custa cerca de 1,5 s de CPU no authentik (PBKDF2), e um
usuário de monitoramento como o `zabbix` faz centenas de logins no mesmo segundo.

`rlm_cache` (rbtree, em memória), chave = SHA-256(segredo do outpost | usuário | senha): a
senha nunca fica guardada. O cache guarda os atributos de resposta (`Mikrotik-Group`,
`Huawei-Exec-Privilege`, ...). Só entra Access-Accept vindo do authentik; senha errada
nunca é cacheada. São duas camadas e uma trava (`raddb/mods-available/provedor`):

- **fresco** (`FR_CACHE_TTL`, padrão 300 s): responde direto.
- **reserva** (`FR_CACHE_RESERVA_TTL`, padrão 1728000 s = 20 dias): quando o fresco
  expira, o pedido é respondido na hora pela reserva e uma cópia vai em segundo plano
  ao servidor virtual `revalidar` (porta interna `FR_PORTA_REVALIDA`, só em 127.0.0.1),
  que consulta o authentik. Se o authentik recusar (usuário desativado, senha trocada),
  a reserva é apagada na hora; se o authentik estiver fora do ar, a reserva continua
  valendo até o TTL.
- **trava** (`FR_CACHE_TRAVA_TTL`, padrão 25 s, maior que o `response_window`): marca
  que já há uma consulta ao authentik em andamento para aquele usuário e senha, para
  uma rajada gerar uma consulta só.

**Desativar um usuário ou trocar a senha no authentik vale em até `FR_CACHE_TTL` segundos
mais um login** (o que dispara a revalidação). Para valer na hora:
`sudo ./provedor restart freeradius` (zera os três caches).

Cuidado: com a reserva, quem entrou com a mesma senha nos últimos 20 dias continua
entrando durante uma queda do authentik. Se a sua política não aceita isso, reduza
`FR_CACHE_RESERVA_TTL`.

### Logs (`docker compose -p provedor-freeradius logs freeradius`)

```
PROVEDOR-AUTH nas=<ip> usuario=<u> proto=pap|chap|mschap|eap origem=cache|reserva|cache-aguardou|authentik|legado resultado=Access-Accept|Access-Reject|SEM-RESPOSTA
LEGADO-CHAP usuario=<u> nas=<ip> proto=chap|mschap|eap
PROVEDOR-ACCT nas=<ip> usuario=<u> tipo=Start|Stop|Interim-Update ... gravado=nao
```

Relatório de quem ainda usa CHAP: `logs freeradius | grep LEGADO-CHAP | awk '{print $4,$5}' | sort | uniq -c`.

## Variáveis (`env.example`)

`FR_SEGREDO_LOCAL`, `FR_PORTA_AUTH`/`FR_PORTA_ACCT` (11812/11813 teste; 1812/1813 produção),
`DALO_DB_USER`/`DALO_DB_PASS`/`DALO_DB_NAME` (socket `/run/mysqld`, `radius@localhost`),
`FR_CACHE_TTL`, `FR_CACHE_RESERVA_TTL`, `FR_CACHE_TRAVA_TTL`, `FR_PORTA_REVALIDA`,
`FR_CHAP_LEGADO`, `FR_GRAVAR_SQL`, `FR_EXIGIR_MSGAUTH`, `FR_ACCT_IGNORAR_USUARIOS`. Usa também
`AUTHENTIK_RADIUS_SECRET` (app radius) e, opcional, `OUTPOST_RADIUS_PORTA`.

## Testar

- `apps/freeradius/teste.sh` (stack no ar, porta de teste): cria usuário temporário no authentik,
  testa aceite com atributos, 2º pedido vindo do cache, senha errada, desativado, CHAP legado e
  accounting; apaga tudo.
- `apps/freeradius/teste-isolado.sh`: valida a imagem sozinha (rede Docker própria com MariaDB
  descartável e um "authentik falso"; não toca em nada do servidor). Útil após mudar a configuração.

## Virada (`virada.sh`, como root)

- `status`: quem escuta 1812/1813/11812/11813.
- `ativar`: confere authentik/outpost, roda `teste.sh` na 11812, **só então** para o FreeRADIUS do
  sistema, sobe este em 1812/1813 com `FR_GRAVAR_SQL=sim`, testa de novo e, se algo falhar, volta
  sozinho para o do sistema.
- `voltar`: rollback (para este, volta 11812/11813 + `FR_GRAVAR_SQL=nao`, religa o do sistema).

## Operar pela interface do authentik

Nada muda no FreeRADIUS: quem entra e os atributos de resposta são do authentik (ver app `radius`):
Diretório > Grupos > `radius-admin`/`radius-leitura` (liberar/retirar), atributos `radius_reply` /
`radius_prioridade` no grupo ou usuário, "Ativo" no usuário para desativar (respeitando o TTL do cache).
Usuário que só existe no arquivo `users` do FreeRADIUS antigo não entra pelo SQL legado: a
migração lê esse arquivo e o cria no authentik; confira no relatório antes da virada.
