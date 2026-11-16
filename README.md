# authentik-aaa-provedor

Autenticação centralizada para um provedor de internet, com o **authentik** como fonte
única de identidade:

- **Equipamentos de rede** (roteadores, switches, OLTs) por **RADIUS** e **TACACS+**, sem
  reconfigurar o que já aponta para um FreeRADIUS/daloRADIUS existente.
- **Sistemas web** (wiki, Grafana, Zabbix, NetBox) por **SSO** com segundo fator.
- **Servidores Linux** por LDAP/SSSD.
- **Servidor reserva numa VPS**, que assume o mesmo IP de serviço por BGP se o principal
  cair.

Todos os nomes, domínios e endereços aqui são de exemplo (`Exemplo Telecom`,
`exemplo.net.br`, faixas de documentação). Veja [Adaptar ao seu ambiente](#adaptar-ao-seu-ambiente).

## Como as peças conversam

```
                         ┌────────────────────── authentik ──────────────────────┐
 navegador ──HTTPS──► Caddy (VPS) ──túnel──► server/worker ── PostgreSQL          │
                                              ▲   ▲   ▲                           │
              OIDC/SAML (wiki, Grafana,       │   │   │                           │
              Zabbix, NetBox, painel) ────────┘   │   │                           │
                                                  │   │                           │
 equipamento ──RADIUS 1812/1813──► FreeRADIUS ──► outpost RADIUS                  │
                                       │                                          │
                                       └─► MariaDB (nas, radacct, radpostauth)    │
                                                      │                           │
 equipamento ──TACACS+ 49──► tac_plus-ng ──LDAP──► outpost LDAP                   │
 servidor Linux ──SSSD/LDAPS 636──────────────────────┘                           │
                         └───────────────────────────────────────────────────────┘

 VPS reserva: réplica do PostgreSQL e do MariaDB + a mesma pilha parada.
 VM e VPS anunciam o mesmo /32 por BGP (túneis WireGuard); a VM ganha enquanto está no ar.
```

Detalhes: [docs/arquitetura.md](docs/arquitetura.md).

## O que está aqui e em que estado

| Parte | Onde | Estado no ambiente de origem |
|---|---|---|
| authentik (PostgreSQL, server, worker), fluxos e marca | `apps/authentik/` | em produção |
| RADIUS dos equipamentos (FreeRADIUS na frente do outpost) | `apps/freeradius/`, `apps/radius/` | em produção |
| Migração do daloRADIUS (usuários, grupos, atributos) | `apps/migracao/` | executada |
| LDAP (outpost) | `apps/ldap/` | em produção |
| TACACS+ (`tac_plus-ng` via LDAP), três níveis, listas por equipamento | `apps/tacacs/` | em produção com Huawei, Juniper e Datacom |
| Painel de auditoria do TACACS+ (login OIDC) | `apps/painel/` | em produção |
| SSO da wiki (OIDC), Grafana (OIDC), Zabbix (SAML), NetBox (OIDC) | `apps/authentik/blueprints/`, `apps/zabbix/`, `apps/netbox/`, `apps/grafana/` | em produção |
| Página de login personalizada, 2FA web obrigatório, proteção de força bruta | `apps/authentik/blueprints/00`, `06`, `09`, `10` | em produção |
| Backup e retenção do banco | `apps/backup/`, `apps/banco/` | em produção |
| Login de servidores Linux (SSSD/LDAPS, sudo por grupo) | `apps/linux/` | scripts prontos; **falta validar em servidor real** |
| Reserva na VPS (réplicas, pilha parada, vigia, BGP) | `apps/vps/`, `apps/host/` | réplicas e BGP no ar, pilha testada em porta alternativa; **troca automática ainda desligada** (falta o teste de queda) |
| Restringir o SSH dos equipamentos às redes de gerência | [docs/ssh-acl.md](docs/ssh-acl.md) | roteiro pronto; **aplicação nos equipamentos pendente** |
| Segundo fator no SSH dos equipamentos (`senha;código`) | `apps/authentik/opcionais/`, [docs/ssh-2fa.md](docs/ssh-2fa.md) | opcional; desligado por padrão |
| VPN do NOC em WireGuard | `apps/wireguard/` | **modelo não validado** (a origem usava outra VPN) |
| Concentrador de VPN autenticando por RADIUS | [docs/vpn.md](docs/vpn.md) | **desenho, não implantado** |

## Requisitos

- **VM principal**: Debian 12, Docker com Compose, 4 GB de RAM (o conjunto usa perto de
  2 GB), na rede de gerência. Se já existe um FreeRADIUS com MariaDB do daloRADIUS, a
  instalação convive com ele até a virada.
- **VPS reserva** (opcional): Debian 12, 2 vCPU, 4 GB de RAM, IP público fixo.
- Um nome DNS público para o login (`sso.<seu domínio>`).
- Para a reserva: dois roteadores de borda que falem WireGuard e BGP.

## Começar

```sh
git clone <este repositório> /opt/authentik-aaa-provedor && cd /opt/authentik-aaa-provedor
sudo ./provedor ajuda
sudo ./provedor preparar          # rede Docker, volume e .env com segredos gerados
sudo ./provedor up base           # authentik -> tokens -> radius -> ldap -> freeradius
sudo ./provedor teste base
```

Ordem completa, com os pontos de verificação e a virada com rollback de um comando:
[docs/migracao.md](docs/migracao.md). Depois da base:

1. Página de login: [docs/pagina-de-login.md](docs/pagina-de-login.md)
2. TACACS+ e painel: [docs/tacacs.md](docs/tacacs.md) (`sudo ./provedor up tacacs`, `up painel`)
3. SSO dos sistemas: [Grafana](docs/grafana-sso.md), [Zabbix](docs/zabbix-sso.md), [NetBox](docs/netbox-sso.md), [Linux](docs/linux-sso.md)
4. Túneis e VPN: [docs/wireguard.md](docs/wireguard.md)
5. Reserva na VPS: [docs/failover-vps.md](docs/failover-vps.md)
6. Fechar o SSH e, se quiser, segundo fator: [docs/ssh-acl.md](docs/ssh-acl.md), [docs/ssh-2fa.md](docs/ssh-2fa.md)

## Documentos

| Documento | Conteúdo |
|---|---|
| [docs/arquitetura.md](docs/arquitetura.md) | por que FreeRADIUS na frente do authentik, fluxo de um login, limites |
| [docs/migracao.md](docs/migracao.md) | subida segura, verificação, virada e rollback |
| [docs/operacao.md](docs/operacao.md) | dia a dia: usuários, grupos, MFA, emergência, backup, atualização |
| [docs/equipamentos.md](docs/equipamentos.md) | atributos RADIUS por fabricante |
| [docs/tacacs.md](docs/tacacs.md) | TACACS+, níveis, listas, painel |
| [docs/tacacs-huawei-ne8000.md](docs/tacacs-huawei-ne8000.md), [s12700](docs/tacacs-huawei-s12700.md), [juniper-mx204](docs/tacacs-juniper-mx204.md), [datacom](docs/tacacs-datacom.md) | roteiro por fabricante, com testes de aceitação |
| [docs/ssh-acl.md](docs/ssh-acl.md) | SSH só das redes de gerência |
| [docs/ssh-2fa.md](docs/ssh-2fa.md) | formas de login no SSH e segundo fator via TACACS+/RADIUS |
| [docs/pagina-de-login.md](docs/pagina-de-login.md) | marca, cores, 2FA web, definição de senha |
| [docs/grafana-sso.md](docs/grafana-sso.md), [zabbix-sso.md](docs/zabbix-sso.md), [netbox-sso.md](docs/netbox-sso.md), [linux-sso.md](docs/linux-sso.md) | SSO de cada sistema |
| [docs/wireguard.md](docs/wireguard.md) | túneis VPS ↔ bordas e VPN do NOC |
| [docs/failover-vps.md](docs/failover-vps.md) | reserva na VPS: BGP, réplicas, ativação e volta |
| [docs/monitoramento-zabbix.md](docs/monitoramento-zabbix.md) | itens e alertas da reserva e do TACACS+ |
| [docs/vpn.md](docs/vpn.md) | VPN e outros sistemas por RADIUS, LDAP ou SSO |
| [apps/CONTRATO.md](apps/CONTRATO.md) | convenções comuns a todos os apps |

## Adaptar ao seu ambiente

Procure e troque antes de subir (`grep -rn` ajuda):

| Exemplo no repositório | Troque por |
|---|---|
| `exemplo.net.br`, `sso.exemplo.net.br` | seu domínio e o nome do login |
| `Exemplo`, `Exemplo Telecom` | nome da empresa (blueprints e marca) |
| `dc=ldap,dc=provedor,dc=com,dc=br` | sua base LDAP (`AUTHENTIK_LDAP_BASE_DN`) |
| `100.66.80.196` | IP de serviço do RADIUS/TACACS+ |
| `100.65.0.0/16`, `100.66.0.0/16`, `172.16.0.0/12`, `10.99.99.0/24` | suas redes de gerência e a da VPN |
| `198.51.100.0/24`, `192.0.2.0/24`, `2001:db8::/32` | seus prefixos públicos |
| `203.0.113.85` | IP público da VPS |
| AS `64500`, `65010`, `65020`, `65030` | seu AS e os privados que escolher |
| `<CHAVE_PUBLICA_WIREGUARD>` | chaves geradas em cada ponta |

Segredos nunca entram no git: o `.env` é gerado pelo `./provedor preparar` e está no
`.gitignore`, assim como chaves do WireGuard, *community* SNMP e certificados.

## Testes

- `sudo ./provedor teste todos`: testa cada app no ar, sem imprimir segredos.
- `tests/isolados.sh`: FreeRADIUS e cálculo da migração em redes Docker descartáveis,
  com um daloRADIUS de exemplo.

## Origem

Este repositório é a versão genérica de um projeto que migrou um provedor do daloRADIUS
para o authentik. As configurações vêm de um ambiente em produção, com os dados da
empresa trocados por exemplos. O que não chegou a ser validado lá está marcado na
tabela de estado e nos próprios documentos.
