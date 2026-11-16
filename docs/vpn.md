# VPN e outros sistemas no authentik

Depois que o acesso aos equipamentos estiver estável no authentik, um
concentrador de VPN pode usar os mesmos usuários, com regras próprias de acesso.

Este documento trata de autenticar no authentik um concentrador de VPN qualquer.
O acesso do NOC ao próprio ambiente (VPN do NOC, WireGuard) está em
[wireguard.md](wireguard.md).

## Opção A: VPN via RADIUS (recomendada para concentradores de VPN)

Mikrotik, FortiGate, pfSense/OPNsense e OpenVPN autenticam via RADIUS PAP.

Este é um desenho: o repositório não traz o blueprint nem a configuração do
FreeRADIUS para a VPN. Os passos abaixo dizem o que criar; teste em bancada
antes de apontar o concentrador de produção.

1. No authentik, crie um provider RADIUS `provedor-radius-vpn` (com **outro**
   segredo), uma aplicação `vpn` e vincule um grupo `vpn` à aplicação.
   Copie o padrão de `apps/radius/blueprints/02-radius-equipamentos.yaml` em um
   `apps/radius/blueprints/06-radius-vpn.yaml`, com
   `shared_secret: !Env AUTHENTIK_RADIUS_SECRET_VPN`, e adicione o provider ao
   outpost `provedor-radius`.
2. Em `apps/radius/env.example`: `AUTHENTIK_RADIUS_SECRET_VPN=<gerar>`; passe a
   variável ao `authentik-worker` (`apps/authentik/compose.yml`) e ao `freeradius`
   (`apps/freeradius/compose.yml`) e rode `./provedor preparar` (só acrescenta).
3. Em `apps/freeradius/raddb/` crie o pool/servidor `authentik_vpn` (`proxy.conf`)
   e a regra que escolhe o pool pelo NAS (`policy.d/provedor`).
4. Cadastre o concentrador de VPN como NAS na tabela `nas`, como qualquer outro
   equipamento (pelo daloRADIUS ou direto no banco, ver
   [operacao.md](operacao.md)); ela continua sendo o único cadastro de
   equipamentos.

O FreeRADIUS manda os pedidos desse NAS para o provider da VPN; os
equipamentos seguem no provider de equipamentos. MFA (`senha;código`) costuma
ser obrigatória na VPN: deixe `mfa_support: true` nesse provider e use um
fluxo com a etapa de validação de MFA e `not_configured_action: deny`.

Por quê um provider separado: o outpost escolhe o provider pelo segredo, e a
aplicação `vpn` tem os próprios grupos. Assim quem entra na VPN não ganha,
só por isso, login nos equipamentos, e a MFA da VPN não muda o login deles.

Atributos específicos da VPN (pool de IP, rotas, `Framed-IP-Address`,
`Fortinet-Group-Name`...) usam o mesmo `radius_reply` nos grupos.

## Opção B: LDAP

Para sistemas que só falam LDAP (alguns firewalls e sistemas legados; para
servidores Linux há um roteiro pronto em [linux-sso.md](linux-sso.md)):

1. O blueprint `apps/ldap/blueprints/03-ldap.yaml` já cria o provider, a
   aplicação, o outpost e a conta `ldap-servico` (senha `LDAP_SERVICO_SENHA`).
2. `sudo ./provedor up ldap` (faz parte do `base`; o token vem de `./provedor tokens`).
3. `sudo ./provedor teste ldap`
4. Configure o sistema:
   - Servidor: `ldap://<servidor>:389` (ou `ldaps://<servidor>:636`)
   - Bind DN: `cn=ldap-servico,ou=users,dc=ldap,dc=provedor,dc=com,dc=br`
   - Base de usuários: `ou=users,dc=ldap,dc=provedor,dc=com,dc=br`, filtro `(cn=%s)`
   - Grupos: `ou=groups,dc=ldap,dc=provedor,dc=com,dc=br`, atributo `memberOf`

Somente quem está no grupo `ldap-acesso` consegue fazer bind (além dos grupos
`tacacs-*` e `linux-*`, vinculados à mesma aplicação pelos blueprints deles).
O LDAP não pede o segundo fator no estado padrão.

## Opção C: SSO (OIDC/SAML)

Sistemas web modernos (Grafana: [grafana-sso.md](grafana-sso.md); Zabbix:
[zabbix-sso.md](zabbix-sso.md); NetBox: [netbox-sso.md](netbox-sso.md); Proxmox,
GLPI...) devem usar OIDC/SAML direto no authentik, sem LDAP: login único no
navegador e MFA centralizado.
