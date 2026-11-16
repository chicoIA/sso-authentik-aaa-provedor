# Monitoramento pelo Zabbix (reserva e TACACS+)

Monitoramento da reserva na VPS ([failover-vps.md](failover-vps.md)) e das
listas de equipamentos do TACACS+ ([tacacs.md](tacacs.md)) pelo Zabbix. Tudo é
lido por **SNMP v2 no host da VPS** (`203.0.113.85`). A VM não precisa de
agente nem de SNMP: o que acontece nela chega à VPS (o vigia da reserva sonda a
VM, e a sincronização das listas do TACACS+ grava o estado na VPS).

## 0. Antes

- Acrescente o trecho `apps/vps/snmp/snmpd-provedor-reserva.conf` ao
  `/etc/snmp/snmpd.conf` da VPS e reinicie o `snmpd`. Os scripts chamados pelas
  linhas `extend` (`provedor-reserva-snmp`, `provedor-tacacs-conjuntos-snmp`,
  em `apps/vps/reserva/`) ficam em `/usr/local/sbin/`.
- Libere o SNMP da VPS só para o Zabbix (`203.0.113.163` no conjunto `snmp_v4`
  de `apps/vps/nftables/provedor.nft`). Use uma community forte, que não vai
  para o repositório nem para chat, e restrinja a `view` do `snmpd` ao que o
  Zabbix lê (uma `view` em `.1` libera a árvore toda).
- Conferir de dentro do Zabbix: `snmpget -v2c -c <community> 203.0.113.85 <OID>`.

Os OIDs são o `nsExtendOutput1Line` de cada linha `extend`. O final do OID é o
nome do `extend`: o número de caracteres seguido do código ASCII de cada um.
**Se você trocar o prefixo `provedor` nos nomes, os OIDs mudam** e precisam ser
recalculados.

## 1. Itens (host da VPS, tipo "Agente SNMP", SNMPv2)

| Nome | `extend` | OID | Tipo de informação | Intervalo |
|---|---|---|---|---|
| Reserva: código | `provedor-reserva-codigo` | `.1.3.6.1.4.1.8072.1.3.2.3.1.1.23.112.114.111.118.101.100.111.114.45.114.101.115.101.114.118.97.45.99.111.100.105.103.111` | Numérico (inteiro) | 30 s |
| Reserva: texto | `provedor-reserva-texto` | `.1.3.6.1.4.1.8072.1.3.2.3.1.1.22.112.114.111.118.101.100.111.114.45.114.101.115.101.114.118.97.45.116.101.120.116.111` | Texto | 30 s |
| TACACS+ listas: código | `provedor-tacacs-conj-codigo` | `.1.3.6.1.4.1.8072.1.3.2.3.1.1.27.112.114.111.118.101.100.111.114.45.116.97.99.97.99.115.45.99.111.110.106.45.99.111.100.105.103.111` | Numérico (inteiro) | 60 s |
| TACACS+ listas: texto | `provedor-tacacs-conj-texto` | `.1.3.6.1.4.1.8072.1.3.2.3.1.1.26.112.114.111.118.101.100.111.114.45.116.97.99.97.99.115.45.99.111.110.106.45.116.101.120.116.111` | Texto | 60 s |

Chaves sugeridas: `provedor.reserva.codigo`, `provedor.reserva.texto`,
`provedor.tacacs.listas.codigo`, `provedor.tacacs.listas.texto`.
Histórico do texto: 7 dias; do código: 90 dias.

## 2. Gatilhos

### Reserva

Os códigos são gravados pelo vigia (`provedor-reserva vigia`) a cada 15 s. O
código 9 é calculado pelo `provedor-reserva-snmp` quando o arquivo de estado
tem mais de 120 s.

| Expressão (sobre o código) | O que é | Severidade |
|---|---|---|
| `last()=1` | VM sem resposta RADIUS (contando os 5 min) | Alta |
| `last()=2 or last()=3` | reserva ativando / ATIVA | Desastre |
| `last()=4` | VM voltou: rodar `provedor-reserva volta` | Média |
| `last()=5` | ativação falhou ou reserva sem anúncio | Desastre |
| `last()=6 or last()=7` | voltando / réplica fora de streaming | Média |
| `last()=8` | VM sem resposta e ativação não automática (ou VPS sem BGP) | Desastre |
| `last()=9 or nodata(5m)=1` | vigia parado | Alta |

### Listas de equipamentos do TACACS+ (`provedor-tacacs-conjuntos`)

O `provedor-tacacs-conjuntos` roda na VM a cada minuto e grava o estado na VPS
(`/var/lib/provedor-tacacs/conjuntos.estado`). O código 9 aparece quando esse
arquivo fica mais de 5 min sem atualização.

| Expressão (sobre o código) | O que é | Severidade |
|---|---|---|
| `last()=1` | item ignorado (IP inválido) ou cópia para a VPS atrasada | Atenção |
| `last()=2` | lista não atualizada (authentik fora ou configuração inválida) | Média |
| `last()=9 or nodata(10m)=1` | sincronização parada (timer da VM ou VM sem falar com a VPS) | Alta |

Em todos: na mensagem, use o item de **texto** correspondente
(`{ITEM.LASTVALUE2}` ou uma macro de item), que diz o motivo.

## 3. Teste

1. Lista do TACACS+: no authentik, ponha um IP inválido (ex.: `999.1.1.1: TESTE`)
   no `tacacs_leitura_em` de um grupo. Em cerca de 1 min o código vira **1** e
   o texto cita o IP. Tire a linha e o código volta a **0**.
2. Reserva: só no teste de falha (passo 9 do roteiro em
   [failover-vps.md](failover-vps.md)), que passa pelos códigos
   1 → 2 → 3 → 4 → 6 → 0.
3. Vigia parado: `systemctl stop provedor-reserva-vigia` na VPS por 3 min leva
   ao código **9**; depois, `systemctl start provedor-reserva-vigia`.

## 4. Depois

- O canal de alerta da reserva (`/etc/provedor-reserva/alerta`, um executável
  opcional que recebe a mensagem como argumento) pode apontar para o mesmo
  destino dos alertas do Zabbix.
- Se a VM tiver agente Zabbix, o arquivo de estado das listas do TACACS+ pode
  ser lido direto nela (`/var/lib/provedor-tacacs/conjuntos.estado`).
