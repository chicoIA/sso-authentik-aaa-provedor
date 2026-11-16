# WireGuard no ambiente

O WireGuard aparece em dois papéis independentes:

| Papel | Entre quem | Para quê | Arquivos |
|---|---|---|---|
| **Túneis da reserva** | VPS ↔ roteadores de borda | levar BGP e o tráfego RADIUS/TACACS+/SSO entre a VPS e a rede interna | `apps/vps/wireguard/` |
| **VPN do NOC** | pessoas ↔ rede de gerência | dar alcance aos equipamentos e sistemas para quem está fora | `apps/wireguard/` (modelos) |

Em nenhum dos dois o WireGuard identifica a pessoa. Ele só dá alcance de rede. Quem a
pessoa é, o segundo fator e o nível de acesso são decididos pelo authentik em cada
sistema (SSO web, TACACS+, RADIUS).

## Endereços do exemplo

| O quê | Endereço |
|---|---|
| IP de serviço do RADIUS/TACACS+ (anycast, VM e VPS) | `100.66.80.196/32` |
| IP público da VPS | `203.0.113.85` |
| Túnel VPS ↔ BORDA-B | `172.17.55.6/31` (roteador `.6`, VPS `.7`), porta `51821` |
| Túnel VPS ↔ BORDA-A | `172.16.20.4/31` (roteador `.4`, VPS `.5`), porta `51822` |
| VPN do NOC | `10.99.99.0/24` (concentrador `.1`), porta `51820` |
| Redes de gerência | `100.65.0.0/16`, `100.66.0.0/16`, `172.16.0.0/12` |
| AS do provedor / da VPS / da VM | `64500` / `65010` / `65020` |

Troque tudo pelos seus valores. Os `/31` dos túneis precisam ser de uma faixa que a rede
interna consiga rotear.

## 1. Túneis da reserva (VPS ↔ bordas)

O desenho completo do failover está em [failover-vps.md](failover-vps.md). Aqui fica
só o transporte.

```
                    internet
   BORDA-B ═══ wg-borda-b4 (51821) ═══╗
   (AS do site B)                     ║
                                      ╠═══ VPS (AS 65010)
   BORDA-A ═══ wg-borda-a4 (51822) ═══╝      FRR + Caddy + pilha reserva
   (AS 64500)
        cada túnel: um /31, uma sessão eBGP e BFD
```

### Na VPS

```sh
apt-get install -y wireguard-tools
umask 077
wg genkey | tee /etc/wireguard/vps.key | wg pubkey            # pública -> roteador BORDA-B
wg genkey | tee /etc/wireguard/vps-borda-a.key | wg pubkey    # pública -> roteador BORDA-A
cp apps/vps/wireguard/wg-borda-*.conf /etc/wireguard/ && chmod 600 /etc/wireguard/*
# edite PublicKey em cada arquivo com a chave pública do roteador correspondente
systemctl enable --now wg-quick@wg-borda-b4 wg-quick@wg-borda-a4
```

O que cada linha dos arquivos `wg-borda-*.conf` faz e por quê:

| Linha | Motivo |
|---|---|
| `PostUp = wg set %i private-key ...` | a chave privada fica num arquivo separado, fora do git |
| `Table = off` | o `wg-quick` não cria rotas; quem decide o caminho é o BGP (FRR) |
| `AllowedIPs = 0.0.0.0/0, ::/0` | o túnel aceita qualquer rede interna que o BGP ensinar; o filtro fica no FRR (`ENTRADA-INTERNAS`) |
| sem `Endpoint` | quem inicia é o roteador. A VPS aprende IP e porta a cada *handshake*, então o roteador pode sair por um link reserva atrás de NAT |
| `PersistentKeepalive = 15` | mantém o NAT do caminho aberto |
| `MTU = 1420` | folga para o cabeçalho do WireGuard sobre IPv4 ou IPv6 |
| uma porta por túnel (`51821`–`51829`) | uma interface por roteador, cada uma com sua sessão BGP |

O firewall da VPS (`apps/vps/nftables/provedor.nft`) abre as portas dos túneis para
qualquer origem (o WireGuard não responde a quem não tem a chave) e só aceita BGP, BFD e
RADIUS **vindos de dentro** das interfaces `wg-*`. A VPS não encaminha entre túneis nem
entre túnel e internet.

### No roteador de borda

O repositório não traz a configuração dos roteadores, que depende do fabricante. O que
cada um precisa ter:

1. Interface WireGuard com chave própria, o `/31` do túnel e MTU 1420.
2. Peer = chave pública da VPS, *endpoint* `203.0.113.85:<porta do túnel>`, *keepalive*
   15 s, `allowed-address 0.0.0.0/0`.
3. Sessão eBGP com o outro lado do `/31` (AS 65010), com BFD.
4. Filtros: anunciar à VPS só as redes internas; aceitar da VPS só o `/32` de serviço.

Modelo em RouterOS 7 (confira os nomes dos parâmetros na sua versão):

```
/interface wireguard add name=wg-vps listen-port=51821 mtu=1420
/interface wireguard peers add interface=wg-vps public-key="<CHAVE_PUBLICA_DA_VPS>" \
    endpoint-address=203.0.113.85 endpoint-port=51821 allowed-address=0.0.0.0/0 \
    persistent-keepalive=15s
/ip address add address=172.17.55.6/31 interface=wg-vps
/routing bgp connection add name=vps remote.address=172.17.55.7 remote.as=65010 \
    local.role=ebgp use-bfd=yes input.filter=bgp-in-vps output.filter-chain=bgp-out-vps
```

### Cuidados

- **Sem NAT no túnel.** O FreeRADIUS reconhece o equipamento pelo IP de origem e o
  equipamento só aceita resposta do IP de serviço. Qualquer *masquerade* no caminho
  entre a rede interna e o túnel quebra os dois sentidos, e ainda faz o authentik ver
  todos os acessos do SSO com o IP do roteador. Ponha uma exceção de NAT para o `/31` do
  túnel e para o `/32` de serviço antes da regra de *masquerade*.
- **O `/31` precisa estar no IGP.** A rede interna tem de saber voltar para o endereço da
  VPS no túnel (interface passiva no OSPF basta).
- **O roteador sai com IP público.** Se o WireGuard do roteador sair com um IP privado de
  *loopback*, o *handshake* não fecha. Force a origem com uma regra de *src-nat* para o
  destino `203.0.113.85:<porta>` se for o caso.
- **Docker fora das redes internas.** O padrão do Docker (`172.17.0.0/16`) costuma
  colidir com redes de gerência e ganharia do BGP por ser rota conectada. Na VPS o Docker
  usa `192.168.0.0/16` (`apps/vps/README.md`).
- **BFD com folga.** Túnel pela internet perde pacote. Com 300 ms × 3 as sessões caem à
  toa; o perfil do repositório usa 1 s × 3.
- **Dois caminhos.** Um túnel por roteador de borda, em locais diferentes. Se a borda
  tiver IPv6, um segundo túnel com *underlay* IPv6 cobre a queda do IPv4.
- **Chaves.** As privadas ficam só em `/etc/wireguard/` de cada ponta. Se a VPS for
  refeita, gere chaves novas e troque a pública nos roteadores.

### Conferir

```sh
wg show                                   # handshake recente e contadores subindo
ping -c3 172.17.55.6                      # outro lado do /31
vtysh -c 'show bgp summary'               # sessões Established
vtysh -c 'show bfd peers brief'
ip route get <ip-de-um-equipamento>       # tem de sair por uma wg-borda-*
```

## 2. VPN do NOC

Serve para a equipe alcançar, de fora, as redes de gerência e os sistemas internos. A
rede `10.99.99.0/24` aparece no restante do repositório como origem liberada: no firewall
da VM, nas ACLs de SSH dos equipamentos ([ssh-acl.md](ssh-acl.md)) e nas listas do
TACACS+.

No ambiente de origem deste projeto o acesso remoto do NOC usava outra solução de VPN,
que ficou de fora desta versão. Os modelos abaixo são o equivalente em WireGuard puro e
**não foram validados em produção por este projeto**.

### Onde pôr o concentrador

Dentro da rede de gerência (um servidor Linux pequeno ou o próprio roteador de borda),
com uma porta UDP publicada. Assim a rede `10.99.99.0/24` é uma rede interna comum e
entra no roteamento como as outras.

Se preferir hospedá-lo na VPS, três coisas mudam: a interface não pode se chamar `wg-*`
sem rever o firewall da VPS (as regras `wg-*` tratam todo túnel como roteador e bloqueiam
o encaminhamento entre túneis); a VPS precisa anunciar `10.99.99.0/24` às bordas; e a
linha `seq 15` do `ENTRADA-INTERNAS` em `apps/vps/frr/frr.conf` continua valendo (a VPS
não deve aprender por BGP uma rede que é dela).

### Concentrador

```sh
apt-get install -y wireguard-tools
umask 077 && wg genkey | tee /etc/wireguard/noc.key | wg pubkey
cp apps/wireguard/wg-noc.conf.exemplo /etc/wireguard/wg-noc.conf && chmod 600 /etc/wireguard/wg-noc.conf
sysctl -w net.ipv4.ip_forward=1           # e persistir em /etc/sysctl.d/
systemctl enable --now wg-quick@wg-noc
```

- **Sem NAT** na saída para a rede interna, pelo mesmo motivo dos túneis da reserva: os
  registros de acesso passam a mostrar o IP de cada pessoa. Para isso a rede interna
  precisa de rota para `10.99.99.0/24` apontando para o concentrador (estática
  redistribuída ou interface no OSPF).
- Firewall no concentrador: da `wg-noc` para a gerência, liberar só o necessário (SSH,
  HTTPS, Winbox e o que mais a equipe usa).

### Uma chave por pessoa

A pessoa gera o par no próprio dispositivo e envia só a pública. Cada pessoa recebe um
`/32` fixo (`apps/wireguard/cliente-noc.conf.exemplo`), o que permite reconhecer a
origem nos logs. No desligamento, apague o `[Peer]` e recarregue:

```sh
wg syncconf wg-noc <(wg-quick strip wg-noc)
```

O WireGuard não tem usuário, senha nem segundo fator: quem tem o arquivo entra na rede.
Por isso a chave fica num dispositivo com disco cifrado e bloqueio de tela, e cada
sistema atrás da VPN continua pedindo o login do authentik. Se a empresa precisa de
usuário e senha **na própria VPN**, use um concentrador que autentique por RADIUS:
[vpn.md](vpn.md).

### O que ajustar no restante do ambiente

| Onde | O quê |
|---|---|
| `apps/host/nftables/provedor-vm.nft` | `10.0.0.0/8` já cobre a rede da VPN; restrinja se quiser |
| ACL de SSH dos equipamentos | `10.99.99.0/24` entre as origens liberadas ([ssh-acl.md](ssh-acl.md)) |
| TACACS+ | listas por equipamento e por origem, se usadas ([tacacs.md](tacacs.md)) |
| authentik | nada: o login web é público pelo `sso.` e protegido por 2FA |
