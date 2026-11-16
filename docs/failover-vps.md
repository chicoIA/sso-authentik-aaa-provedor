# Servidor reserva na VPS (RADIUS, TACACS+ e SSO com o mesmo IP)

Objetivo: se a VM principal (ou o site onde ela está) cair, uma VPS fora da
rede do provedor assume o **mesmo IP de serviço** (`100.66.80.196`), sem mudar
nada nos equipamentos. Isso importa porque há NAS que só aceitam um servidor
RADIUS. A mesma VPS dá ao authentik uma URL pública fixa
(`https://sso.exemplo.net.br`) para o login único.

Arquivos de sistema da VPS e reconstrução de emergência:
[apps/vps/README.md](../apps/vps/README.md). Pilha Docker da reserva:
[apps/vps/reserva/README.md](../apps/vps/reserva/README.md). Arquivos de
sistema da VM: [apps/host/README.md](../apps/host/README.md).

## Cenário de referência

Os endereços e nomes abaixo são os dos arquivos do repositório. Troque pelos
seus, nos arquivos e neste texto, antes de aplicar.

| Elemento | Papel | Endereços |
|---|---|---|
| VM (principal) | authentik, FreeRADIUS, TACACS+, LDAP | AS 65020; `172.16.7.10/30` na `ens224`; IP de serviço `100.66.80.196/32` na dummy `radius0` |
| Switch do site A (Huawei S12700) | gateway da VM | AS 64500; `172.16.7.9` |
| BORDA-A (MikroTik, core do site A) | borda com túnel para a VPS | AS 64500; túnel `172.16.20.4/31` |
| BORDA-B (MikroTik, site B) | borda com túnel para a VPS | AS 65030; túnel `172.17.55.6/31` |
| VPS (reserva) | Caddy do `sso.`, pilha reserva | AS 65010; `203.0.113.85`; túneis `172.17.55.7` (`wg-borda-b4`) e `172.16.20.5` (`wg-borda-a4`) |

Os switches e NAS aprendem as rotas por OSPF. Não há iBGP entre o S12700 e as
bordas: o `/32` do serviço circula entre eles só pelo OSPF. Se o site A cair
inteiro, a região do site B alcança a VPS só pelo túnel do BORDA-B.

## Decisões de desenho

| Tema | Decisão |
|---|---|
| Mesmo IP nos dois lados | anycast por BGP: VM e VPS anunciam `100.66.80.196/32`; a VM ganha sempre que está no ar |
| ASN da VPS | **65010** (privado, próprio). eBGP com BORDA-A (AS 64500) e BORDA-B (AS 65030) |
| Transporte | WireGuard, um túnel por roteador, cada um com sua sessão BGP + BFD. Um segundo túnel por roteador com underlay IPv6 pode ser acrescentado depois, com o IPv4 preferido. Detalhes em [wireguard.md](wireguard.md) |
| Endereços dos túneis | privados, um `/31` por túnel |
| FRR / WireGuard | no sistema da VPS (não em Docker): o BGP não pode cair quando o Docker reinicia |
| IP da VM | continua **privado**. A VM ganha uma `/30` só para o BGP; o `.196` vai para uma interface dummy (`radius0`) e deixa de depender de placa |
| URL do SSO | `https://sso.exemplo.net.br` → Caddy da VPS → authentik ativo pelo túnel |
| Ativação da reserva | automática depois de 5 min sem resposta RADIUS da VM (opcional); a volta é sempre manual |

## Roteamento

### Como o NAS chega no RADIUS

Os roteadores aprendem o `/32` por BGP e o injetam no OSPF (os switches
aprendem por OSPF). Com a VM no ar, o melhor caminho é sempre o da VM:

- a VPS anuncia com AS-path mais longo (`set as-path prepend 65010 65010 65010`
  na `route-map SAIDA` de `apps/vps/frr/frr.conf`);
- nas bordas, o que vem da VPS entra com distância 250 e só é usado quando a
  rota da VM some do OSPF;
- **no OSPF**, o `/32` aprendido da VM entra com custo menor que o aprendido
  da VPS.

Por quê a VM precisa anunciar o próprio `/32` por BGP: se o `.196` existir só
como parte da rede conectada da VM, o `/32` da VPS, mais específico, ganharia
dela.

### Redistribuição BGP → OSPF

Com a VM no ar:

- **S12700 (gateway da VM, AS 64500):** `import-route bgp type 1` com a
  route-policy `BGP-IMPORT-IN-OSPF-IPV4` (um nó dela casa o `ip-prefix`
  `100.66.80.196/32`). O `/32` aprendido da VM entra no OSPF como externo
  tipo 1, custo 1.
- **BORDA-A e BORDA-B:** aprendem o `/32` da VM pelo OSPF. O `ospf-in` precisa
  aceitar `/32` dentro da faixa de gerência (no exemplo, `100.66.0.0/16 le 32`).
- As bordas podem repassar o `/32` da VM para a VPS pelo BGP; a VPS recusa
  (`ENTRADA-INTERNAS seq 10`), para nunca rotear o IP de serviço de volta para
  o túnel.

Para a VPS servir de reserva, os filtros abaixo entram nas bordas e no S12700:

| Onde | Mudança | Por quê |
|---|---|---|
| BORDA-A e BORDA-B, `bgp-in-vps` | `set distance 250` no `.196/32` | o eBGP (distância 20) ganharia do OSPF (110) que leva à VM, mesmo com ela no ar |
| BORDA-A, `ospf-out` | `.196/32` de BGP: tipo 1, custo 1000, tag 65010 | reserva principal |
| BORDA-B, OSPF | `redistribute=bgp` com filtro de saída só do `.196/32`: tipo 2, custo 2000, tag 65010 | reserva se o core do site A cair (tipo 2 perde sempre do tipo 1) |
| BORDA-A e BORDA-B, `ospf-in` | recusar `.196/32` com tag 65010 (antes das outras regras) | sem isso cada borda instala a reserva da outra (110 < 250), retira a sua e as duas oscilam |
| S12700, `VM-RADIUS-IN` | aceitar o `.196/32` com `apply preference 10` | no VRP o BGP vale 255 e o OSPF externo 150: quando a VM voltasse, o S12700 ficaria com a rota de reserva e não exportaria a da VM. Conferir `Pre 10` em `display ip routing-table 100.66.80.196` |

O `redistribute` só exporta rotas ativas: com a VM no ar a rota da VPS
(distância 250) fica inativa nas duas bordas e nada é exportado.

### Como a VPS responde ao NAS

A resposta sai do `.196` (interface dummy `radius0` na VPS) para o IP do NAS.
Para isso a VPS **recebe por BGP as redes internas** dos roteadores e as
instala no kernel apontando para o túnel. O filtro de entrada
(`ENTRADA-INTERNAS`) aceita apenas `100.64.0.0/10`, `172.16.0.0/12` e
`10.0.0.0/8`, e recusa:

- a rota padrão e **qualquer prefixo público**: o Caddy atende pela internet e
  precisa continuar saindo pela `eth0`;
- o próprio `100.66.80.196/32`;
- a rede da VPN do NOC (`10.99.99.0/24`, ver [wireguard.md](wireguard.md));
- `192.168.0.0/16`, usada pelo Docker da VPS;
- os `/31` dos próprios túneis.

As mesmas redes chegam pelas duas bordas. O que vem do BORDA-A recebe
`local-preference 50` (`route-map ENTRADA-RESERVA`): o BORDA-B é o caminho
normal e o BORDA-A assume se ele cair.

Cuidados no roteador:

- **O `/31` do túnel precisa estar no OSPF, e o tráfego que vem do túnel não
  pode sofrer NAT.** Por quê: se a borda faz masquerade na saída para o core,
  o authentik vê todos os acessos do `sso.` com o IP do roteador (e ignora o
  `X-Forwarded-For`, porque esse IP não é um proxy confiável), e a resposta
  RADIUS da VPS sai com o IP trocado e é descartada pelo NAS. Se a rede interna
  não conhece o `/31`, o caminho de volta para a VPS pode entrar em loop.
  Correção no MikroTik: interface do túnel no OSPF (passiva) e `srcnat accept`
  para `172.17.55.6/31` e `100.66.80.196/32` antes do masquerade.
- **Sem NAT/masquerade na saída para o túnel.** O FreeRADIUS identifica o NAS
  pelo IP de origem (tabela `nas`); com NAT ele veria o IP do roteador.
- Anuncie à VPS só as redes internas (agregados bastam) e **não** repasse nada
  vindo da VPS para as operadoras.
- **O WireGuard do roteador precisa sair com IP público.** Se a regra de NAT de
  saída não cobrir o tráfego do próprio roteador, o pacote sai com IP privado e
  o handshake não fecha. No exemplo, o BORDA-A usa src-nat para o tráfego com
  destino `203.0.113.85:51822`.
- **BFD em túnel pela internet:** com 300 ms x 3 as sessões caem em perdas
  curtas. O perfil `rapido` da VPS usa 1 s x 3 (detecção em 3 s). O intervalo é
  negociado pelo maior valor, então vale também para o lado dos roteadores.

**Cobertura:** a VPS só responde a um NAS se tiver rota para ele. Uma borda
pode alcançar uma rede de gerência (pela rota padrão, por exemplo) sem
anunciá-la à VPS; os NAS dessa rede ficam sem resposta no failover. Confira na
VPS, para uma amostra de NAS de cada rede: `ip route get <ip-do-nas>` tem que
sair por uma interface `wg-*`. Se faltar, corrija o anúncio no roteador; não
crie rotas agregadas estáticas na VPS.

### Docker longe das redes internas

Cuidado: o Docker usa `172.17.0.0/16` no `docker0` por padrão. Se essa faixa
(ou qualquer outra do Docker) for rede interna do provedor, a rota conectada
do Docker vence a do BGP e a VPS não alcança esses equipamentos. Mova o Docker
da VPS para uma faixa que a rede interna não usa (no exemplo,
`192.168.0.0/16`) antes de subir o BGP. O passo está em
[apps/vps/README.md](../apps/vps/README.md).

### Rota padrão da VM

Com o `.196` numa dummy, a VM precisa sair com esse endereço como origem,
porque os NAS só aceitam resposta do `.196`. `apps/host/frr/frr.conf` resolve
isso em camadas (a primeira que valer ganha):

1. a `0.0.0.0/0` recebida do S12700 por BGP, com origem `.196`
   (`route-map ORIGEM-196`). Se a sessão BGP/BFD cair, ela some;
2. durante a migração, uma estática de distância 250 pela placa antiga
   (`ens192`, sem IP, `onlink`), também com origem `.196`;
3. uma estática de distância 254 pelo `172.16.7.9`, com origem `172.16.7.10`:
   mantém a gerência e a réplica vivas se só o BGP cair.

Cuidados:

- Não ponha rota padrão no kernel pelo ifupdown: o zebra prefere a rota do
  kernel (distância 0) e não instala a do BGP.
- A dummy é declarada com `inet manual` (`apps/host/network/00-radius0`): com
  `inet static` o ifupdown põe `broadcast 100.66.80.196` na `/32` e cria uma
  rota de broadcast no endereço do serviço.
- Os containers da VM saem pela `ens224` com SNAT para o `.196` (chain
  `saida-containers` de `apps/host/nftables/provedor-vm.nft`). Sem isso o
  MASQUERADE do Docker usaria o `172.16.7.10`, que é privado.

## Pilha reserva (na VPS)

| Componente | Como fica na VPS |
|---|---|
| authentik (server + worker) | parado; sobe na ativação sobre o Postgres promovido |
| Postgres do authentik | réplica em streaming (só leitura) da VM; promovida na ativação e refeita na volta |
| FreeRADIUS | mesma imagem e configuração da VM, na rede do host, atendendo no `.196`; outpost RADIUS local |
| MariaDB (`nas`, `radcheck`...) | cópia das 6 tabelas que o FreeRADIUS lê, enviada pela VM a cada 5 min |
| Contabilidade (`radacct`, `radpostauth`) | gravada no MariaDB da reserva numa faixa de ids própria; exportada na volta e importada na VM |
| LDAP e TACACS+ | sobem na ativação, com as portas presas ao `.196` |
| Vigia (`provedor-reserva-vigia`) | sonda o RADIUS da VM, ativa a reserva e sobe/desce a `radius0` conforme o FreeRADIUS local responde |

O anúncio do `.196` pela VPS é a própria interface `radius0`: o FRR
redistribui a rota conectada (`redistribute connected route-map SAIDA`).
Interface no ar, `/32` anunciado; interface fora, anúncio retirado. Por isso a
`radius0` só é criada depois que a pilha respondeu.

Na VM, `provedor-vm-saude` faz o papel inverso: retira o anúncio do `/32` se o
FreeRADIUS local ficar 30 s sem responder e reanuncia depois de 60 s
respondendo. Sem ele, com a VM ligada e o FreeRADIUS parado, o `/32`
continuaria anunciado e a reserva nunca seria usada.

Ativação, volta e manutenção das réplicas:
[apps/vps/reserva/README.md](../apps/vps/reserva/README.md).

## Roteiro de implantação

Faça na ordem. Os passos 1 a 7 não mexem no RADIUS em produção; os passos 8 e
9 mexem e pedem janela e validação com tráfego real.

### 1. Preparar a VPS

Debian 12, firewall, Docker fora das redes internas e IPv6 na rede Docker
(para o Caddy ver o IP real de quem chega por IPv6). Siga
[apps/vps/README.md](../apps/vps/README.md), passos 1 a 4. Como referência de
tamanho, 2 vCPU, 4 GB de RAM, 2 GB de swap e 120 GB de disco comportam o Caddy
e a pilha reserva.

Validar: `nft list table inet provedor` mostra as regras; um SSH novo abre
depois de aplicar o firewall; `ip -br addr` não mostra nenhuma rede Docker
dentro das faixas internas.

### 2. DNS e certificado do `sso.`

Aponte `sso.exemplo.net.br` (A e AAAA) para a VPS e crie o site no Caddyfile
com uma resposta provisória. O Caddy emite o certificado sozinho. O bloco
definitivo (`apps/vps/caddy/Caddyfile`) entra no passo 4, quando o túnel
existir.

Validar: `https://sso.exemplo.net.br` responde com certificado válido.

### 3. Primeiro túnel e BGP (BORDA-B)

Suba `wg-borda-b4` e o FRR na VPS (passos 5 e 6 de
[apps/vps/README.md](../apps/vps/README.md)); o lado do roteador está em
[wireguard.md](wireguard.md). No roteador: sessão eBGP com a VPS, anunciando
só redes internas; `/31` do túnel no OSPF; nenhuma regra de NAT para o que
vem do túnel ou vai para ele.

Validar:

- `wg show` com handshake recente;
- `vtysh -c 'show bgp summary'` com a sessão de pé e prefixos recebidos;
- `vtysh -c 'show ip bgp neighbors 172.17.55.6 advertised-routes'` vazio (a
  `radius0` ainda não existe);
- a VPS alcança a VM (portas 9000/9443 do authentik) e uma amostra de NAS;
- da rede interna, ping para `172.17.55.7`.

### 4. `sso.` apontando para o authentik da VM

Suba o Caddy com `apps/vps/caddy/compose.yml` e `apps/vps/caddy/Caddyfile` (em `/opt/proxy`). O Caddy da VPS
passa a fazer `reverse_proxy` para o authentik da VM pelo túnel
(`apps/vps/caddy/sso-destino.caddy`). O upstream é HTTPS (9443) para o
authentik saber que o acesso é https e não gerar URLs `http://`. O acesso é
restrito a IPs do Brasil (`provedor-geoip-br`) e a proteção contra força bruta
é a do fluxo de login do authentik
(`apps/authentik/blueprints/06-protecao-login-web.yaml`).

Validar: login pelo `sso.` funciona de fora da rede; nos eventos do authentik,
o IP de origem é o IP real de quem acessou. Se aparecer o IP da borda, o túnel
está sofrendo NAT (ver "Cuidados no roteador").

### 5. Segundo túnel e BGP (BORDA-A)

Mesmo procedimento com `wg-borda-a4` (porta 51822). As rotas dessa sessão
entram com `local-preference 50`.

Validar: duas sessões BGP de pé; a rede interna conhece `172.16.20.4/31` (a VM
pinga `172.16.20.5`); o tráfego chega à VM sem NAT; `ip route get <ip-do-nas>`
sai por `wg-*` para NAS de todas as redes de gerência.

### 6. Réplicas e pilha reserva

Siga [apps/vps/reserva/README.md](../apps/vps/reserva/README.md): réplica em
streaming do Postgres, cópia das tabelas do MariaDB a cada 5 min e teste da
pilha de atendimento num clone, em porta alternativa.

Validar: `pg_stat_wal_receiver` em `streaming`; linha `ok` no journal do
`provedor-envia-radius` na VM; no teste do clone, Accept, Reject e accounting
gravado.

### 7. VM: placa nova e BGP sem troca de rotas

1. Acrescente à VM a placa `ens224` com `172.16.7.10/30`, sem gateway
   (`apps/host/network/ens224`).
2. Instale o FRR com `bgpd=yes` e `bfdd=yes` em `/etc/frr/daemons` e uma
   configuração que ainda não troque rotas: use a `route-map NADA` (já
   definida em `apps/host/frr/frr.conf`) nos dois sentidos do vizinho.
3. No S12700: sessão eBGP com a VM (AS 65020) e as route-policies
   `VM-RADIUS-IN`/`VM-RADIUS-OUT` negando tudo. Deixe pronta a importação
   BGP → OSPF (`BGP-IMPORT-IN-OSPF-IPV4` casando só `100.66.80.196/32`,
   `import-route bgp type 1`). Confira o prefixo do `ip-prefix`: um endereço
   errado ali só aparece na hora da virada.

Validar: BGP + BFD de pé, com 0 rotas nos dois sentidos; o RADIUS em produção
segue pela placa antiga, sem mudança.

### 8. VM: IP de serviço na dummy e anúncio do `/32` (janela)

Mexe no RADIUS em produção. Tenha acesso à console da VM.

1. Tire o `.196` da placa antiga e ponha na `radius0`
   (`apps/host/network/00-radius0`; a `ens192` fica ligada, sem IP, como em
   `apps/host/network/interfaces`).
2. Aplique `apps/host/frr/frr.conf` completo (anúncio do `/32`, rota padrão em
   camadas) e `apps/host/nftables/provedor-vm.nft` (SNAT dos containers).
3. No S12700: `VM-RADIUS-IN` aceita o `/32` com `apply preference 10`, e a
   sessão com a VM anuncia a rota padrão (`default-route-advertise`).

Validar:

- `display ip routing-table 100.66.80.196` no S12700 mostra a rota da VM com
  `Pre 10`; as bordas têm o `/32` por OSPF;
- autenticações e accounting de NAS reais chegando no log do FreeRADIUS;
- login pelo `sso.`, LDAP e TACACS+ funcionando;
- os containers da VM alcançam a internet (saem com o `.196`);
- reinicie a VM e repita as conferências.

Enquanto a `ens192` existir, retirar o `/32` não tira a VM do ar: a rede
conectada antiga entrega o `.196` pela placa antiga. Retire a `ens192` e a
estática de distância 250 depois de um período estável.

### 9. VPS anuncia o `/32` como reserva; teste de falha (janela)

1. Na VPS: instale `provedor-reserva`, `provedor-radius-sonda` e o serviço
   `provedor-reserva-vigia`, com o automático **desligado** (sem o arquivo
   `/etc/provedor-reserva/automatico`). O firewall já aceita RADIUS vindo dos
   túneis para o `.196` (`provedor.nft`).
2. Na VM: instale `provedor-vm-saude` em modo de observação
   (`PROVEDOR_SAUDE_OBSERVAR=1` no `.service`), que só registra o que faria.
3. Nas bordas e no S12700: aplique os filtros da tabela em "Redistribuição
   BGP → OSPF".
4. Confira antes do teste: `provedor-reserva estado` mostra a VM respondendo,
   a réplica em `streaming`, ao menos uma sessão BGP de pé e todas as imagens
   da pilha ativa presentes.
5. Teste de falha: deixe o RADIUS da VM sem responder e rode
   `provedor-reserva ativa` (ou espere o vigia, se o automático estiver
   ligado). Depois, com a VM de volta, `provedor-reserva volta` na VPS e
   `provedor-traz-contabilidade` na VM.
6. Com o teste aprovado: tire o `PROVEDOR_SAUDE_OBSERVAR=1` do
   `provedor-vm-saude.service` e crie `/etc/provedor-reserva/automatico` na
   VPS, se quiser a ativação automática.
7. Configure o monitoramento:
   [monitoramento-zabbix.md](monitoramento-zabbix.md).

Validar durante o teste:

- com a VM no ar, `vtysh -c 'show ip bgp neighbors <ip> advertised-routes'` na
  VPS fica vazio e as bordas não exportam nada com tag 65010;
- com a reserva ativa, as bordas instalam o `/32` da VPS, os NAS autenticam
  (log do `reserva-freeradius`) e o `sso.` abre com a administração congelada;
- quando a VM volta a anunciar, o tráfego volta para ela sozinho e nenhuma
  borda oscila (a rota do `/32` não fica alternando no OSPF);
- o estado da reserva passa pelos códigos 1 → 2 → 3 → 4 → 6 → 0;
- a contabilidade do período aparece na VM depois do
  `provedor-traz-contabilidade`.

### 10. Túneis com underlay IPv6 (opcional)

Um segundo túnel por roteador sobre IPv6, com sessão BGP + BFD própria e o
IPv4 preferido. O repositório traz só os túneis IPv4; o firewall da VPS já
reserva as portas 51821-51829 para WireGuard.
