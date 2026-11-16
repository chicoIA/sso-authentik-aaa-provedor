# Equipamentos e atributos por fabricante

Este guia trata do acesso aos equipamentos por **RADIUS**. Os equipamentos **não
precisam ser reconfigurados** na migração: continuam apontando para o FreeRADIUS com o
mesmo segredo. Use-o para conferir o que cada fabricante espera e para cadastrar novos
perfis. Para TACACS+ (autorização e registro de comandos), veja [tacacs.md](tacacs.md);
para restringir o SSH dos equipamentos às redes de gerência, [ssh-acl.md](ssh-acl.md).

> O authentik só aceita **PAP**. Se o relatório de migração mostrar CHAP, ou o
> log do FreeRADIUS mostrar `enviou CHAP/MS-CHAP/EAP`, ajuste o equipamento
> para PAP.

## Onde ficam os perfis

No authentik, em *Directory > Groups > (grupo) > Attributes*:

```yaml
radius_prioridade: 1
radius_reply:
  - Service-Type := Administrative-User
  - Mikrotik-Group := full
  - Huawei-Exec-Privilege := 15
  - Cisco-AVPair += shell:priv-lvl=15
```

E, para exceções individuais, o mesmo `radius_reply` nos atributos do
usuário (tem prioridade, como o `radreply` no daloRADIUS).

Todos os atributos são enviados para todos os equipamentos, como o
daloRADIUS já fazia; cada equipamento ignora os atributos de outros
fabricantes.

## Atributos suportados

| Fabricante | Atributo | Exemplo | Observação |
|---|---|---|---|
| (RFC) | `Service-Type` | `Administrative-User` | Cisco/HP/Aruba/Datacom usam para nível admin |
| (RFC) | `Reply-Message`, `Class`, `Session-Timeout`, `Idle-Timeout`, `Filter-Id`... | | todo o dicionário RFC |
| Mikrotik | `Mikrotik-Group` | `full` / `write` / `read` | grupo de `/user group` |
| Huawei | `Huawei-Exec-Privilege` | `15` | 0 a 15 (3 = admin, 15 = máximo) |
| Cisco | `Cisco-AVPair` | `shell:priv-lvl=15` | use `+=` para vários valores |
| Juniper | `Juniper-Local-User-Name` | `super-user` | classe/template local |
| Juniper | `Juniper-Allow-Commands`, `Juniper-Deny-Commands` | regex | |
| Fortinet | `Fortinet-Group-Name`, `Fortinet-Access-Profile`, `Fortinet-Vdom-Name` | | |
| H3C | `H3C-Exec-Privilege` | `3` | |
| HP / Aruba switch | `HP-Privilege-Level`, `HP-Command-String` | | |
| ZTE | `ZTE-SW-Privilege` | `15` | |
| Nokia | `Timetra-Profile` | `administrative` | |
| Ruckus | `Ruckus-User-Groups` | | |
| Brocade | `Brocade-Auth-Role` | `admin` | |

### Adicionar um atributo de outro fabricante

1. Ache o atributo no dicionário do FreeRADIUS:
   ```sh
   docker run --rm --entrypoint grep provedor/freeradius:3.2.10 -r "ATTRIBUTE.*Nome-Do-Atributo" /usr/share/freeradius/
   docker run --rm --entrypoint grep provedor/freeradius:3.2.10 -r "^VENDOR.*Fabricante" /usr/share/freeradius/
   ```
2. Inclua uma linha na tabela `FABRICANTES` de
   `apps/radius/blueprints/02-radius-equipamentos.yaml` (e em
   `apps/migracao/app/fabricantes.py`; o teste unitário compara os dois):
   ```python
   "Datacom-Exemplo": (3709, "Datacom", "Exemplo", 1, "string"),
   #  nome no FreeRADIUS     vendor id, vendor, atributo (sem prefixo), código, tipo
   ```
3. Faça commit; o worker reaplica o blueprint (ou *Customization > Blueprints >
   Apply*).
4. Rode o relatório de novo: o atributo deve aparecer como "ok".

## Referência de configuração nos equipamentos

`<IP_RADIUS>` é o endereço do servidor do FreeRADIUS (o mesmo do daloRADIUS
após a virada) e `<segredo do NAS>` é o segredo cadastrado para o equipamento na tabela
`nas`. Sempre mantenha um usuário local de emergência. Os blocos são exemplos; confira a
sintaxe na versão do seu equipamento.

### Mikrotik (RouterOS)

```
/radius add service=login address=<IP_RADIUS> secret=<segredo do NAS> authentication-port=1812 accounting-port=1813 timeout=3s
/user aaa set use-radius=yes accounting=yes default-group=read
```

O `Mikrotik-Group` devolvido escolhe o grupo (`full`, `write`, `read` ou um
grupo customizado). O RouterOS testa os usuários locais antes do RADIUS.

### Huawei (VRP / OLT MA5600/MA5800)

```
radius-server template PROVEDOR
 radius-server shared-key cipher <segredo do NAS>
 radius-server authentication <IP_RADIUS> 1812
 radius-server accounting <IP_RADIUS> 1813
aaa
 authentication-scheme PROVEDOR
  authentication-mode radius local
 accounting-scheme PROVEDOR
  accounting-mode radius
 domain default_admin
  authentication-scheme PROVEDOR
  accounting-scheme PROVEDOR
  radius-server PROVEDOR
```

`authentication-mode radius local`: o usuário local só é usado se o RADIUS
**não responder** — por isso o FreeRADIUS fica em silêncio quando o authentik
cai. O nível vem de `Huawei-Exec-Privilege`.

### Cisco (IOS / IOS-XE)

```
aaa new-model
radius server PROVEDOR
 address ipv4 <IP_RADIUS> auth-port 1812 acct-port 1813
 key <segredo do NAS>
aaa group server radius RAD-PROVEDOR
 server name PROVEDOR
aaa authentication login default group RAD-PROVEDOR local
aaa authorization exec default group RAD-PROVEDOR local if-authenticated
aaa accounting exec default start-stop group RAD-PROVEDOR
```

Nível por `Cisco-AVPair = shell:priv-lvl=15` (e/ou `Service-Type =
Administrative-User`).

### Juniper (Junos)

```
set system radius-server <IP_RADIUS> secret "<segredo do NAS>"
set system authentication-order [ radius password ]
set system login user super-user class super-user
set system login user operador class operator
```

`Juniper-Local-User-Name` escolhe qual template local (`super-user`,
`operador`) o usuário assume.

### Outros (Datacom, ZTE, FiberHome, Intelbras...)

Configure RADIUS com **PAP**, autenticação "radius, depois local" e o
accounting no mesmo servidor. Para o nível de acesso, verifique na
documentação do equipamento qual atributo ele espera (muitos aceitam
`Service-Type = Administrative-User`) e, se for um VSA, adicione em
`FABRICANTES` como descrito acima.
