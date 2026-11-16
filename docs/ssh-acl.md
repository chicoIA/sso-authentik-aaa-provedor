# Restringir o SSH às redes de gerência

Um equipamento com o SSH aberto para a internet recebe tentativas de força bruta o
tempo todo. Com o TACACS+ ligado, **cada tentativa passa pelo TACACS+ e pelo
authentik**: o servidor faz um bind LDAP por tentativa, o que consome memória e
processamento (um volume alto chega a derrubar o container do TACACS+ por falta de
memória), enche o log de eventos e deixa as senhas do SSO expostas a adivinhação. As
tentativas são recusadas, mas uma senha fraca bastaria.

Por isso o SSH dos equipamentos deve aceitar conexões só das redes de onde a equipe
realmente entra. Faça isso **antes** de ligar o TACACS+ em cada equipamento
([tacacs.md](tacacs.md)).

## 1. Levantar quem está exposto

O `eventos.tsv` do TACACS+ tem uma linha por tentativa de login, com os campos
separados por TAB: `data_hora tipo nas_ip usuario porta origem resultado detalhe`.
`nas_ip` é o equipamento e `origem` é o IP de quem tentou entrar.

Logins recusados por equipamento, contando tentativas e origens diferentes (os
equipamentos no topo são os expostos):

```sh
sudo docker exec provedor-tacacs-tacacs-1 cat /var/log/tacacs/eventos.tsv \
  | awk -F'\t' '$2=="authen" && $7=="negado" { n[$3]++; if (!v[$3 FS $6]++) o[$3]++ }
      END { for (e in n) print n[e], o[e], e }' \
  | sort -rn | head -20
```

A saída tem três colunas: tentativas, origens diferentes e IP do equipamento. Milhares
de tentativas vindas de dezenas ou centenas de origens é força bruta da internet;
poucas recusas de poucas origens costuma ser gente da equipe errando a senha. Para ver
as origens de um equipamento (troque `IP_DO_EQUIPAMENTO`):

```sh
sudo docker exec provedor-tacacs-tacacs-1 cat /var/log/tacacs/eventos.tsv \
  | awk -F'\t' -v e=IP_DO_EQUIPAMENTO '$2=="authen" && $7=="negado" && $3==e { print $6 }' \
  | sort | uniq -c | sort -rn | head -20
```

Comece a fechar pelos equipamentos com mais tentativas.

## 2. Levantar de onde a equipe entra (antes de fechar)

Não monte a lista de origens só com as redes internas "óbvias". Tire-a dos logins
**aceitos** de pelo menos uma semana:

```sh
sudo docker exec provedor-tacacs-tacacs-1 cat /var/log/tacacs/eventos.tsv \
  | awk -F'\t' '$2=="authen" && $7=="permitido" { print $6, $4 }' \
  | sort | uniq -c | sort -rn
```

Cada linha é uma origem e o usuário que entrou por ela. Costumam aparecer origens que
ninguém lembrava: o IP público do escritório do NOC, a saída de NAT de um roteador de
borda, o servidor de monitoramento, um servidor de automação. Toda origem legítima
precisa caber em alguma linha da lista; sem isso a equipe fica trancada para fora.

O `eventos.tsv` só mostra quem entra pelo TACACS+. Para os usuários locais e para quem
ainda entra pelo RADIUS, confira também o log do próprio equipamento e o do FreeRADIUS.

## 3. Lista de origens (exemplo)

A lista abaixo é a usada nos modelos deste guia. É um **exemplo**: troque pelas redes
do seu levantamento.

| Rede | Quem usa |
|---|---|
| `10.99.99.0/24` | VPN do NOC (WireGuard, [wireguard.md](wireguard.md)) e monitoramento (Zabbix) |
| `100.65.0.0/16`, `100.66.0.0/16` | redes de gerência (inclui a saída de NAT dos roteadores de borda) |
| `172.16.0.0/12` | rede interna (servidores, automação) |
| `192.0.2.0/24` | bloco do IP público do escritório do NOC |
| `198.51.100.0/24` | outro bloco público próprio de onde a equipe entra |

Só inclua um bloco público depois de confirmar que ele é seu. Prefira a VPN do NOC a
liberar IP público: quem está fora entra pela VPN e chega ao equipamento com origem
`10.99.99.0/24`.

IPv6: se o equipamento aceita SSH por IPv6, feche também (`ssh ipv6 server acl` no
Huawei; `family inet6` no Juniper).

## 4. Cuidados (todos os fabricantes)

- Uma sessão aberta **antes** continua aberta: a ACL vale para conexões novas. Mantenha
  a sessão de quem aplica aberta até testar uma **nova** de outra janela.
- Teste a nova sessão vindo de **cada** origem real (VPN do NOC e IP público do NOC).
- Console ou acesso fora de banda à mão nos equipamentos remotos.
- Um equipamento por vez; o próximo só depois de 10 min sem reclamação.
- A lista de origens do SSH não é a lista de equipamentos aceitos pelo TACACS+
  (`device equipamentos` em `apps/tacacs/tac_plus-ng.cfg.modelo`): uma diz quem pode
  abrir SSH no equipamento, a outra diz quais equipamentos podem falar com o servidor.

## 5. Huawei (VRP)

Antes, veja se já há ACL no SSH ou nas vty, e se o número 2999 está livre:

```
display current-configuration | include ssh server acl|ssh ipv6 server acl|acl inbound|acl ipv6
display acl 2999
```

Se já houver ACL no SSH, acrescente as regras que faltarem **nela** em vez de criar
outra. Se 2999 estiver em uso para outra coisa, use outro número livre de 2000–2999.

```
system-view
acl number 2999
 description SSH-GERENCIA
 rule 5 permit source 10.99.99.0 0.0.0.255
 rule 10 permit source 100.65.0.0 0.0.255.255
 rule 15 permit source 100.66.0.0 0.0.255.255
 rule 20 permit source 172.16.0.0 0.15.255.255
 rule 25 permit source 192.0.2.0 0.0.0.255
 rule 30 permit source 198.51.100.0 0.0.0.255
 rule 100 deny
 quit
ssh server acl 2999
```

Não há `commit confirmed` no VRP: vale na hora. Teste uma nova sessão SSH de outra
janela, pela VPN e pelo IP público do NOC. Funcionou: `return` e `save`. Não funcionou:
na sessão ainda aberta, `system-view` e `undo ssh server acl` (volta na hora).

## 6. Juniper (Junos)

No Junos a restrição é um filtro no `lo0`, que vale para todo tráfego destinado ao
roteador; o modelo só mexe na porta 22 e aceita o resto (explicação em
[tacacs-juniper-mx204.md](tacacs-juniper-mx204.md), seção *Restringir o SSH*). Antes,
`show configuration interfaces lo0`: se já houver filtro no `lo0`, ponha os termos de
SSH **no filtro existente**, antes dos demais.

```
set policy-options prefix-list GERENCIA-SSH 10.99.99.0/24
set policy-options prefix-list GERENCIA-SSH 100.65.0.0/16
set policy-options prefix-list GERENCIA-SSH 100.66.0.0/16
set policy-options prefix-list GERENCIA-SSH 172.16.0.0/12
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

O `commit confirmed 5` desfaz sozinho em 5 min se ninguém confirmar. Teste a nova
sessão, `show firewall filter PROTEGE-SSH` (contador subindo), `show bgp summary` sem
queda; então `commit`.

## 7. Conferir depois

- Huawei: `display acl 2999` mostra os contadores (`matched`) da regra 100 subindo com
  a força bruta. Juniper: `show firewall filter PROTEGE-SSH` mostra o contador
  `ssh-bloqueado`.
- No servidor, as tentativas contra esse equipamento somem do `eventos.tsv`. Rode de
  novo o levantamento da seção 1 no dia seguinte, ou acompanhe ao vivo:

  ```sh
  sudo ./provedor logs tacacs -f | grep IP_DO_EQUIPAMENTO
  ```
