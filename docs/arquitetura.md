# Arquitetura

## Objetivo

Substituir o daloRADIUS como fonte de usuários do **acesso da equipe aos
equipamentos** (roteadores, OLTs, switches) pelo authentik, sem reconfigurar
os equipamentos e sem perder o que o daloRADIUS fazia:

| No daloRADIUS | Com authentik |
|---|---|
| Usuário + senha em `radcheck` (Cleartext-Password) | Usuário no authentik (senha com hash forte) |
| Grupos em `radusergroup` | Grupos no authentik |
| Perfil por grupo em `radgroupreply` (`Mikrotik-Group := full`...) | `attributes.radius_reply` do grupo |
| Atributos por usuário em `radreply` | `attributes.radius_reply` do usuário |
| Desativar: `Auth-Type := Reject` | Desativar o usuário no authentik |
| NAS em `nas` | Continua na tabela `nas` (FreeRADIUS lê do MySQL) |
| Accounting em `radacct`, tentativas em `radpostauth` | Igual (FreeRADIUS grava no mesmo MySQL) |
| — | MFA (TOTP) no login web, políticas, log de eventos, LDAP/SSO para outros sistemas |

## Componentes

```
                    UDP 1812/1813 (segredo de cada NAS)
 Mikrotik / OLT / switch ───────────────────────────────► freeradius (rede do host)
                                                            │
                     PAP, UDP 127.0.0.1:18120               │ radacct, radpostauth, nas
                     (segredo AUTHENTIK_RADIUS_SECRET)      ▼
                 ┌──────────────────────────────── MySQL do daloRADIUS
                 ▼
         radius (outpost) ──HTTP──► server/worker (authentik) ──► postgresql
                                         ▲
                     navegador ──9443────┘   (admin, MFA, troca de senha)
```

- **freeradius** (`apps/freeradius/`): FreeRADIUS 3.2.10. Lê os NAS da tabela
  `nas` do daloRADIUS (somente leitura, o mesmo cadastro e os mesmos segredos que
  os equipamentos já usam), encaminha PAP para o outpost (com cache de aceites,
  ver `apps/freeradius/README.md`), atende CHAP/MS-CHAP pelo
  SQL do daloRADIUS enquanto `FR_CHAP_LEGADO=sim` (registrando quem usa) e, depois
  da virada (`FR_GRAVAR_SQL=sim`), grava accounting/pós-autenticação no MySQL. Roda
  com `network_mode: host` para enxergar o IP real de cada NAS.
- **radius** (outpost do authentik): recebe o PAP, executa o fluxo
  `provedor-radius-autenticacao` (usuário e senha; o segundo fator é opcional,
  ver [ssh-2fa.md](ssh-2fa.md)), verifica se
  o usuário pode usar a aplicação *Equipamentos de rede (RADIUS)* (grupos
  `radius-admin`/`radius-leitura`) e devolve os atributos do property mapping.
- **authentik-server / authentik-worker / authentik-postgres** (`apps/authentik/`):
  authentik sem Redis. Toda a configuração fica nos blueprints de cada app
  (`apps/<app>/blueprints/`, montados em `/blueprints/provedor/<app>/` e
  aplicados automaticamente pelo worker).
- **ldap-outpost** (`apps/ldap/`): outpost LDAP, base do TACACS+ e de sistemas
  que só falam LDAP.
- **tacacs** e **painel** (`apps/tacacs/`, `apps/painel/`): TACACS+ e o painel
  web dele, para depois da migração ([tacacs.md](tacacs.md)). Só sobem quando
  nomeados (`./provedor up tacacs`, `./provedor up painel`).

A interface de administração do authentik (porta 9443) e o painel não devem ficar
abertos à internet: o NOC chega a eles pela rede interna ou pela VPN do NOC
(WireGuard, [wireguard.md](wireguard.md)). Os sistemas web que usam o authentik
como login único estão em [grafana-sso.md](grafana-sso.md),
[zabbix-sso.md](zabbix-sso.md), [netbox-sso.md](netbox-sso.md) e
[linux-sso.md](linux-sso.md); a reserva em outra máquina, em
[failover-vps.md](failover-vps.md).

## Por que manter um FreeRADIUS na frente?

O outpost RADIUS do authentik é bom para decidir *quem* entra, mas tem limites
importantes para um ambiente de provedor:

1. **Só PAP** (ou EAP-TLS na versão Enterprise). Nada de CHAP/MS-CHAP.
   Para login administrativo em equipamento isso normalmente não é problema,
   mas o FreeRADIUS deixa explícito no log quem ainda manda CHAP.
2. **Sem accounting**: o outpost ignora `Accounting-Request`. Sem o
   FreeRADIUS, perde-se o registro de quem entrou em qual equipamento e
   quando (`radacct`), que o daloRADIUS mostrava.
3. **Um segredo por provider**: o outpost escolhe o provider pelo segredo
   compartilhado. Os equipamentos costumam ter segredos próprios (tabela `nas`).
   Com o FreeRADIUS, os equipamentos continuam iguais e só o FreeRADIUS conhece
   o segredo do outpost.
4. **Indisponibilidade**: se o authentik cair, o FreeRADIUS atende pela
   reserva do cache quem já entrou com a mesma senha nos últimos
   `FR_CACHE_RESERVA_TTL` segundos e **não responde** aos demais, e o
   equipamento usa o login local. Um `Access-Reject` faria Huawei/Cisco/Juniper
   **não** tentarem o usuário local.
5. **Roteamento**: a coluna `type` do NAS permite mandar, por exemplo, a VPN
   para outro provider (com outras regras de acesso).

A alternativa "equipamentos apontando direto para o outpost" funciona, mas
exige trocar o segredo em todos os equipamentos e perde o accounting.

## Fluxo de um login

1. O técnico faz `ssh admin@olt`. A OLT manda `Access-Request` (PAP) ao
   FreeRADIUS com o segredo dela.
2. O FreeRADIUS identifica o NAS pela tabela `nas`, confere que é PAP e
   encaminha ao outpost (`Proxy-To-Realm = AUTHENTIK_EQUIPAMENTOS`).
3. O outpost executa o fluxo: identificação → senha → login. (Com o segundo
   fator ligado, entra a validação do código entre a senha e o login:
   [ssh-2fa.md](ssh-2fa.md).)
4. O outpost pergunta ao authentik se o usuário pode usar a aplicação
   `radius-equipamentos` (grupos `radius-admin` e `radius-leitura`).
5. O property mapping monta a resposta com os `radius_reply` do usuário e dos
   grupos (ex.: `Huawei-Exec-Privilege = 15`).
6. O FreeRADIUS devolve o `Access-Accept` à OLT e grava em `radpostauth`
   (sem a senha). O accounting da sessão vai para `radacct`.

## Atributos herdados (property mapping)

O mapping **"Exemplo: atributos RADIUS herdados do daloRADIUS"**
(`apps/radius/blueprints/02-radius-equipamentos.yaml`) reproduz a lógica do
`rlm_sql`:

1. começa com `radius_reply` do usuário (antigo `radreply`);
2. aplica `radius_reply` de cada grupo do usuário (antigo `radgroupreply`), na
   ordem de `radius_prioridade` (antigo `radusergroup.priority`, menor primeiro);
3. operadores: `:=` substitui, `=` só adiciona se não existir, `+=` acrescenta.

Os grupos são herdados (subgrupos recebem os atributos dos grupos pai), então
é possível montar, por exemplo, `noc` → filho de `radius-admin`.

Atributos RFC (`Service-Type`, `Reply-Message`, `Class`...) já existem no
dicionário do authentik. Atributos de fabricante precisam constar na tabela
`FABRICANTES` do mapping; o relatório de migração aponta os que faltam.
Veja [equipamentos.md](equipamentos.md).

## Limitações conhecidas

- `Simultaneous-Use`, `Login-Time` e restrições por NAS (`NAS-IP-Address`,
  `Huntgroup-Name`) do daloRADIUS não têm equivalente direto; o relatório lista
  quem usava. Horário e origem podem virar *policies* no authentik; restrição
  por equipamento vira um provider separado (ver [vpn.md](vpn.md), mesma ideia).
- `radusergroup.priority` é por associação usuário-grupo; no authentik a
  prioridade fica no grupo (usa o menor valor encontrado).
- O IP de origem que o authentik vê é o do FreeRADIUS. O IP do equipamento
  fica em `radpostauth`/`radacct` e no log do FreeRADIUS. Por isso **não use**
  a policy de *reputação por IP* no fluxo RADIUS: uma pessoa errando a senha
  bloquearia todos.
