# app `vps` — servidor reserva (arquivos de sistema da VPS)

Diferente dos outros apps, este **não é um projeto Docker**: são os arquivos de
sistema de uma VPS com Caddy na frente, que publica o `sso.` e é o **RADIUS
reserva** (mesmo IP `100.66.80.196`, por BGP). Desenho, roteamento e roteiro de
implantação: [docs/failover-vps.md](../../docs/failover-vps.md).

O que está aqui é a fonte da verdade. **Mudou na VPS → atualize aqui** (e vice-versa).

| Arquivo no repositório | Destino na VPS | O que faz |
|---|---|---|
| `nftables/provedor.nft` | `/etc/nftables.d/provedor.nft` | firewall de entrada do host, em tabela própria (não apaga as regras do Docker) |
| `systemd/provedor-firewall.service` | `/etc/systemd/system/` | carrega o firewall no boot |
| `wireguard/wg-borda-b4.conf` | `/etc/wireguard/wg-borda-b4.conf` | túnel com o BORDA-B (VPS `172.17.55.7/31`, BORDA-B `172.17.55.6`; porta 51821) |
| `wireguard/wg-borda-a4.conf` | `/etc/wireguard/wg-borda-a4.conf` | túnel com o BORDA-A (VPS `172.16.20.5/31`, BORDA-A `172.16.20.4`; porta 51822) |
| `frr/frr.conf` | `/etc/frr/frr.conf` | BGP + BFD: recebe só redes internas (BORDA-B preferido, BORDA-A com local-pref 50) e anuncia só o `.196/32`, quando a `radius0` existe |
| `caddy/compose.yml`, `caddy/Caddyfile` | `/opt/proxy/` | site `sso.`: só Brasil, documentação da API só da rede interna, destino importado de `sso-destino.caddy` |
| `caddy/sso-destino.caddy` | `/data/provedor/sso-destino.caddy` no Caddy | destino do `sso.`: authentik da VM (`172.16.7.10:9443`); trocado por `provedor-reserva ativa`/`volta` |
| `geoip/provedor-geoip-br` | `/usr/local/sbin/` | gera a lista de IPs do Brasil (LACNIC) em `/data/provedor/brasil.caddy` do Caddy |
| `geoip/provedor-geoip-br.{service,timer}` | `/etc/systemd/system/` | atualiza a lista toda segunda, 04:30 |
| `mndp/provedor-mndp` + `.service` | `/usr/local/sbin/`, `/etc/systemd/system/` | anuncia a VPS por MNDP nos túneis: ela aparece em `/ip neighbor` dos roteadores MikroTik |
| `snmp/snmpd-provedor-reserva.conf` | trecho acrescentado a `/etc/snmp/snmpd.conf` | linhas `extend` lidas pelo Zabbix ([docs/monitoramento-zabbix.md](../../docs/monitoramento-zabbix.md)) |
| `reserva/` | `/opt/provedor-reserva/`, `/usr/local/sbin/`, `/etc/systemd/system/` | pilha reserva e scripts de ativação: [reserva/README.md](reserva/README.md) |

Segredos **nunca** entram no repositório: chaves privadas do WireGuard
(`/etc/wireguard/vps.key`, `/etc/wireguard/vps-borda-a.key`), community SNMP,
`.env`. Nos `.conf` do WireGuard, `<CHAVE_PUBLICA_WIREGUARD>` é a chave pública
de cada roteador. Se a VPS for refeita, gere chaves novas e troque a chave
pública da VPS nos roteadores.

## O que os arquivos pressupõem

- IP público `203.0.113.85` (e um IPv6), interface `eth0`, SSH na **porta 2222**,
  Debian 12.
- Caddy em Docker, em 80/443, com o Caddyfile em `/opt/proxy/Caddyfile`. Os scripts
  (`provedor-reserva`, `provedor-geoip-br`) usam o container `proxy-caddy-1`, o
  volume `proxy_caddy_data` (montado em `/data` no Caddy) e a rede Docker
  `proxy_default`. Se os nomes do seu Caddy forem outros, ajuste nos scripts,
  em `caddy/compose.yml` e em `reserva/compose.yml`.
- Docker em `192.168.0.0/16` (docker0 `192.168.0.1/24`), com IPv6 nativo
  (`fd00:db8:1::/48`).
- A VPN do NOC usa `10.99.99.0/24` ([docs/wireguard.md](../../docs/wireguard.md));
  o FRR da VPS recusa essa rede se ela vier por BGP.
- Portas `51821`-`51829`/udp reservadas para os túneis WireGuard dos roteadores.
  Se a VPS tiver outro serviço com faixa de portas UDP dinâmica, mantenha-o
  fora dessa faixa.
- Considere `apt-mark hold` em `docker-compose-plugin` e `docker-buildx-plugin`,
  para atualizar o Docker Compose só de propósito.

## Reconstruir em outra VPS (emergência)

Ordem pensada para nunca ficar sem acesso. Rode como root, a partir deste
diretório (`apps/vps`).

1. **Debian 12 mínimo, SSH funcionando.** Ajuste a porta do SSH se não for 2222
   (e a regra correspondente em `provedor.nft`).
2. **Pacotes:**
   `apt-get install -y nftables wireguard-tools frr frr-pythontools`
3. **Docker longe das redes internas** — antes de subir qualquer container,
   `/etc/docker/daemon.json` com `"bip": "192.168.0.1/24"` e
   `"default-address-pools": [{"base": "192.168.0.0/16", "size": 24}]`,
   e IPv6 nativo para o Caddy ver o IP real de quem chega por IPv6:
   `"ipv6": true, "fixed-cidr-v6": "fd00:db8:1::/64", "experimental": true,
   "ip6tables": true` (no Docker 20.10 o `ip6tables` exige `experimental`). No
   compose do Caddy, a rede dele leva `enable_ipv6: true` e `ipam.config` com
   `192.168.1.0/24` e `fd00:db8:1:1::/64`.
   Por quê: o padrão do Docker, `172.17.0.0/16`, costuma ser rede interna de
   provedor (no exemplo, `172.16.0.0/16` e `172.17.0.0/16` são), e a rota
   conectada do Docker vence a que vem pelo BGP. Escolha uma faixa que a rede
   interna não usa.
4. **Firewall, com volta automática** (se travar o SSH, ele se desfaz em 3 min):
   ```bash
   mkdir -p /etc/nftables.d && cp nftables/provedor.nft /etc/nftables.d/
   nft -c -f /etc/nftables.d/provedor.nft
   systemd-run --unit=provedor-fw-rollback --on-active=180 /usr/sbin/nft delete table inet provedor
   nft -f /etc/nftables.d/provedor.nft
   # abra um SSH NOVO e confirme; depois:
   systemctl stop provedor-fw-rollback.timer
   cp systemd/provedor-firewall.service /etc/systemd/system/
   systemctl daemon-reload && systemctl enable provedor-firewall
   ```
   **Nunca** use `/etc/nftables.conf` nem `systemctl enable nftables`: esse
   arquivo começa com `flush ruleset` e apaga as regras do Docker.
5. **WireGuard:** `wg genkey | tee /etc/wireguard/vps.key | wg pubkey`
   (chmod 600; idem para `/etc/wireguard/vps-borda-a.key`); copie
   `wireguard/*.conf` para `/etc/wireguard/` (600) e
   `systemctl enable --now wg-quick@wg-borda-b4` (idem os demais). Troque a chave
   pública da VPS nos roteadores. A VPS **não** tem `Endpoint` nos peers: quem
   inicia é o roteador, que pode vir de qualquer IP (link de redundância atrás de
   NAT). Se o IP público da nova VPS mudar, só ajuste o `endpoint-address` nos
   roteadores. Os `.conf` usam `Table = off`: o `wg-quick` não cria rotas, quem
   decide o caminho é o BGP. Lado do roteador:
   [docs/wireguard.md](../../docs/wireguard.md).
6. **FRR:** em `/etc/frr/daemons` ligue `bgpd=yes` e `bfdd=yes`; copie
   `frr.conf`, `systemctl restart frr`, confira com
   `vtysh -c 'show bgp summary'` e `vtysh -c 'show ip route bgp'`.
7. **Serviços:** o Caddy com o site `sso.` (`caddy/`, `geoip/`) e a pilha
   reserva ([reserva/README.md](reserva/README.md)). A ordem completa, com a
   validação de cada passo, está em
   [docs/failover-vps.md](../../docs/failover-vps.md).

## Editar o Caddyfile sem derrubar o Caddy

Valide a cópia dentro do container antes de sobrescrever. Use `cp` (mantém o
inode; o arquivo é montado no container) e depois `caddy reload`:

```bash
docker cp /tmp/Caddyfile.novo proxy-caddy-1:/tmp/ && \
docker exec proxy-caddy-1 caddy validate --config /tmp/Caddyfile.novo --adapter caddyfile && \
cp /tmp/Caddyfile.novo /opt/proxy/Caddyfile && \
docker exec proxy-caddy-1 caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile
```

## Conferências rápidas

```bash
nft list table inet provedor          # firewall
journalctl -k | grep provedor-drop    # o que está sendo bloqueado
wg show                               # túneis (handshake recente = ok)
vtysh -c 'show bgp summary'           # sessões BGP
vtysh -c 'show ip bgp neighbors <ip> advertised-routes'   # vazio, ou só o .196/32 com a reserva ativa
ip route get <ip-do-nas>              # tem que sair por uma interface wg-*
```
