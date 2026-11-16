# app `host` — arquivos de sistema da VM principal

Como `apps/vps`, não é um projeto Docker: são arquivos do próprio Debian da VM
onde rodam o authentik, o FreeRADIUS e o TACACS+. Desenho e ordem de
implantação: [docs/failover-vps.md](../../docs/failover-vps.md).

| Arquivo no repositório | Destino na VM | O que faz |
|---|---|---|
| `nftables/provedor-vm.nft` | `/etc/nftables.d/provedor-vm.nft` | firewall de entrada (host e portas publicadas pelo Docker) e SNAT dos containers para o `.196` |
| `systemd/provedor-firewall.service` | `/etc/systemd/system/` | carrega o firewall no boot |
| `network/interfaces` | `/etc/network/interfaces` | placa antiga (`ens192`) ligada sem IP, durante a migração |
| `network/00-radius0` | `/etc/network/interfaces.d/00-radius0` | IP de serviço `100.66.80.196/32` numa interface dummy (`radius0`) |
| `network/ens224` | `/etc/network/interfaces.d/ens224` | placa do BGP, `172.16.7.10/30`, sem gateway |
| `frr/frr.conf` | `/etc/frr/frr.conf` | AS 65020, BGP + BFD com o roteador do AS 64500 (`172.16.7.9`): anuncia o `/32` e recebe só a rota padrão (`bgpd` e `bfdd` ligados em `/etc/frr/daemons`) |
| `fase8/provedor-vm-saude` + `.service` | `/usr/local/sbin/`, `/etc/systemd/system/` | retira o anúncio do `/32` se o FreeRADIUS local parar de responder e reanuncia quando ele volta |
| `fase8/provedor-traz-contabilidade` | `/usr/local/sbin/` | importa da VPS a contabilidade gravada enquanto a reserva atendeu |
| `reserva/provedor-envia-radius` + `.service`/`.timer` | `/usr/local/sbin/`, `/etc/systemd/system/` | envia à VPS, a cada 5 min, as 6 tabelas que o FreeRADIUS lê |

O que os scripts pressupõem (ajuste no início de cada um):

- o caminho do `.env` do repositório na VM (variável `ENV`), de onde leem
  `DALO_DB_USER`, `DALO_DB_PASS`, `DALO_DB_NAME` e `DALO_DB_SOCKET`;
- `provedor-envia-radius` conecta em `root@203.0.113.85`, porta 2222, com a
  chave `/root/.ssh/id_ed25519_reserva` (que na VPS só executa o recebimento:
  ver [apps/vps/reserva/README.md](../vps/reserva/README.md));
- `provedor-traz-contabilidade` usa o atalho `ssh vps`, que precisa existir na
  configuração de SSH do root da VM;
- `provedor-vm-saude` usa o container `provedor-freeradius-freeradius-1` e o
  vizinho BGP `172.16.7.9`.

## Rede e BGP

O `.196` fica numa dummy para não depender de placa, e a VM o anuncia como
`/32` pela `/30` da `ens224`. Se a `radius0` cair, o `network` do FRR some e o
`/32` é retirado sozinho. A rota padrão **não** fica no ifupdown: vem do FRR,
em camadas, com o `.196` como origem. O porquê de cada camada está em
[docs/failover-vps.md](../../docs/failover-vps.md), seção "Rota padrão da VM",
e nos comentários de `frr/frr.conf`.

`provedor-vm-saude` sonda o FreeRADIUS local a cada 10 s: com 30 s sem
resposta troca a saída do BGP para a `route-map NADA` (retira o `/32`); com
60 s respondendo, volta para a `SAIDA`. Ele só reanuncia o que ele mesmo
retirou; uma retirada feita à mão pelo `vtysh` fica como está. Com
`PROVEDOR_SAUDE_OBSERVAR=1` no `.service` (como está no repositório), só
registra o que faria: use assim até o teste de falha e depois tire a variável.

```bash
vtysh -c 'show bgp summary'                                          # sessão com o 172.16.7.9
vtysh -c 'show ip bgp neighbors 172.16.7.9 advertised-routes'        # só o 100.66.80.196/32
vtysh -c 'show ip route 0.0.0.0/0'                                   # padrão vinda do BGP
journalctl -t provedor-vm-saude                                      # o que o serviço fez (ou faria)
```

## Firewall

Aceita só origens privadas (`10/8`, `172.16/12`, `192.168/16`), o CGNAT de
gerência (`100.65/16` e `100.66/16`; o resto de `100.64/10` é de clientes e fica
bloqueado), o IP fixo do NOC (`203.0.113.50`) e os prefixos públicos do AS 64500.
Troque essas faixas pelas suas no conjunto `permitidos_v4`/`permitidos_v6`.
Cobre os serviços do host (chain `input`: SSH, RADIUS, MariaDB) e as portas
publicadas pelo Docker (chain `forward`: LDAP 389/636, authentik 9000/9443),
que chegam por DNAT e não passam pelo `input`.

Regras com motivo próprio:

- **Postgres (5432)** é publicado só para a replicação: a chain `forward`
  descarta qualquer origem que não seja a VPS pelos túneis (`172.17.55.7` e
  `172.16.20.5`).
- **Saída dos containers:** a chain `forward` libera pelo nome das interfaces
  do Docker (`docker0`, `br-*`), não por "tudo que não vem da placa X". Por
  quê: com uma regra do segundo tipo, uma placa nova chegaria às portas do
  Docker sem filtro.
- **SNAT para o `.196`** na saída dos containers pela `ens224` (chain
  `saida-containers`): o MASQUERADE do Docker usaria o IP da placa
  (`172.16.7.10`), que é privado.

**Modo bloqueio:** a última regra de cada chain descarta e registra no máximo
6 por minuto (`provedor-vm-drop` / `provedor-vm-fwd-drop`). Antes de bloquear,
vale rodar alguns dias em observação (as mesmas regras, com o log e sem o
`drop` final) e ver quem aparece. Para conferir:

```bash
nft list table inet provedor | grep 'counter packets'
journalctl -k | grep -E 'provedor-vm-(fwd-)?drop'
```

**Mudar regras:** aplique sempre com volta automática para o arquivo anterior e
confira o SSH (pela VPN do NOC, [docs/wireguard.md](../../docs/wireguard.md)),
o RADIUS e o SSO pela VPS:

```bash
cp -a /etc/nftables.d/provedor-vm.nft /root/backup-provedor-vm-$(date +%Y%m%d-%H%M).nft
systemd-run --unit=provedor-fw-rollback --on-active=180 /usr/sbin/nft -f /root/backup-provedor-vm-<data>.nft
cp apps/host/nftables/provedor-vm.nft /etc/nftables.d/ && nft -f /etc/nftables.d/provedor-vm.nft
# conferir; depois:
systemctl stop provedor-fw-rollback.timer
```

**Nunca** use `/etc/nftables.conf` nem `systemctl enable nftables`: ele começa
com `flush ruleset` e apaga as regras do Docker.

Atenção: os prefixos públicos do AS costumam incluir IPs de clientes (CPEs).
Para fechar mais, troque-os por faixas de gerência.
