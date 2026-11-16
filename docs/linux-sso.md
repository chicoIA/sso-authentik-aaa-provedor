# Login em servidores Linux (Debian/Ubuntu) pelo SSO

O servidor consulta o LDAP do authentik (ldaps, porta 636) pelo SSSD. A pessoa entra por
SSH com o usuário e a senha do SSO; o nível vem do grupo no authentik. Arquivos prontos em
`apps/linux/`. Comece por um servidor sem importância e só depois leve aos demais.

| Grupo no authentik | O que pode |
|---|---|
| `linux-admin` | virar root: `sudo -i` ou `sudo su -` (pede a senha do SSO da própria pessoa) |
| `linux-operador` | `sudo systemctl start/stop/restart/reload <serviço>`, `sudo docker start/stop/restart/ps/logs`; ver status e logs. Não vira root, não instala, não edita serviço |
| `linux-leitura` | sem root: `systemctl status`, `journalctl`, `ping`, `traceroute`, `mtr`, `dig`, `ip`, `ss` |

Por lista de servidores (mesmo padrão do `tacacs-admin-or-hosts-operador`):

| Grupo no authentik | Nos servidores da lista `linux_operador_em` | Nos demais |
|---|---|---|
| `linux-admin-or-hosts-operador` | operador | admin |
| `linux-leitura-or-hosts-operador` | operador | leitura |

A lista fica no próprio grupo: *Diretório > Grupos > (grupo) > Editar > Atributos >
`linux_operador_em`*, uma linha `IP: nome` por servidor (qualquer IP do servidor, ou o
hostname; nome sem espaços). Lista vazia = admin (ou leitura) em todos. Cada servidor lê
as listas pelo LDAP a cada 5 min (`provedor-linux-sso-listas`, timer) e grava
`/etc/sudoers.d/provedor-sso-listas`; `provedor-linux-sso-listas status` mostra a decisão.
Sem resposta do LDAP o servidor mantém o que tinha (no primeiro uso, o mais restrito).

Cuidado: quem está em mais de um grupo recebe a soma. Não ponha a mesma pessoa em
`linux-admin` e num grupo por lista.

Quem não está em nenhum desses grupos é recusado no servidor (`simple_allow_groups`).
O `su` com a senha do root local não é usado: o root local continua com a senha/chave
que já tinha, só para emergência. Limite: no estado padrão o LDAP não pede o segundo
fator (MFA); o login no servidor é usuário + senha do SSO.

## Uma vez, no authentik

Combine a janela com o NOC: os passos mexem no provider LDAP, que em produção
também atende o TACACS+.

1. Certificado da 636. Cada ambiente gera o seu; o repositório não traz
   certificado. No authentik, *Sistema > Certificados > Gerar*, com o nome
   `ldap-sso.provedor.interno` (o mesmo valor como nome alternativo) e validade
   longa (por exemplo, 10 anos). Depois exporte **só o certificado** (não a chave)
   e grave em `apps/linux/ldap-sso.crt`: é esse arquivo que os servidores usam
   para confiar no LDAP. Confira:

   ```sh
   openssl x509 -in apps/linux/ldap-sso.crt -noout -subject -enddate -fingerprint -sha256
   ```

   O nome tem de ser exatamente esse: o blueprint `apps/ldap/blueprints/03-ldap.yaml`
   liga o certificado ao provider por ele
   (`certificate: !Find [authentik_crypto.certificatekeypair, [name, ldap-sso.provedor.interno]]`)
   e os scripts de `apps/linux/` validam o servidor LDAP por esse nome, que cada
   servidor resolve pelo `/etc/hosts` (o instalador acrescenta a linha). Como o
   blueprint do LDAP é aplicado antes de o certificado existir, reaplique-o
   depois de gerar (*Personalização > Blueprints > Exemplo - LDAP > Aplicar*) ou
   escolha o certificado em *Providers > provedor-ldap > Editar > Certificado
   TLS*. A porta 389 (TACACS+) não muda.
2. Grupos e conta de serviço: copie `apps/linux/04-linux.yaml` para
   `apps/ldap/blueprints/` (aplica sozinho; o repositório já traz a cópia,
   mantenha as duas iguais).
3. Senha da conta `linux-servico`: *Diretório > Usuários > linux-servico > Definir senha*
   (longa, aleatória). Guarde em `/root/linux-ldap-servico.senha` (600) na VM do
   authentik; ela não fica no repositório.
4. Instale o `provedor-tacacs-conjuntos` (`apps/tacacs/conjuntos/`): ele também
   limpa o cache de bind do outpost quando os membros de `linux-*` mudam. Por
   quê: o provider usa `bind_mode` = `cached`; sem essa limpeza, quem entra num
   grupo espera até 5 min.

## Em cada servidor

1. Rede: o servidor precisa alcançar a VM do authentik na porta 636. O script
   usa `172.16.7.10` como padrão; passe o IP do seu authentik como segundo
   argumento (`testar <IP>`, `instalar <IP>`).
2. Copie a pasta `apps/linux/` para o servidor, já com o `ldap-sso.crt` do seu
   ambiente (ex.: `scp -r apps/linux root@srv:/root/provedor-linux`).
3. Teste sem mudar nada: `/root/provedor-linux/provedor-linux-sso testar` (pede a senha
   da `linux-servico`; confere porta, certificado e senha).
4. Instale: `/root/provedor-linux/provedor-linux-sso instalar`. Faz backup em
   `/root/bak-provedor-linux-sso`, instala `sssd-ldap`, grava `/etc/sssd/sssd.conf` (600),
   cria o home no primeiro login, põe `/etc/sudoers.d/provedor-sso` (validado com `visudo`).
5. SSH com senha: se o servidor só aceita chave, acrescente no fim do `sshd_config`
   (vale só para os grupos do SSO; root continua só por chave):
   ```
   Match Group linux-admin,linux-operador,linux-leitura,linux-admin-or-hosts-operador,linux-leitura-or-hosts-operador
       PasswordAuthentication yes
   ```
   `sshd -t && systemctl reload ssh`.
6. **Sem fechar a sessão atual**, abra outra: `ssh <usuário-do-sso>@servidor`. Confira
   `id` (grupos) e `sudo -l` (permissões).
7. Desfazer: `provedor-linux-sso desfazer` (root e usuários locais nunca são afetados).

## Comportamento

- Lista de um grupo por lista alterada no authentik: vale em até 5 min em cada servidor
  (na hora com `provedor-linux-sso-listas` no servidor).
- Mudança de grupo no authentik: vale em até 5 min (cache do SSSD); na hora com
  `sss_cache -E` no servidor.
- Pessoa desativada no authentik: não entra mais (o bind falha). Sessões abertas continuam
  até sair.
- SSO fora do ar: quem já entrou naquele servidor nos últimos 7 dias entra pelo cache.
- UID/GID: o authentik usa 2000 + id do usuário. O instalador avisa se houver usuário
  local nessa faixa.
- Troca do certificado: ao gerar outro certificado para a 636, distribua o novo
  `ldap-sso.crt` aos servidores (`/etc/ssl/provedor/ldap-sso.crt`) antes de
  trocar no provider; senão o SSSD deixa de confiar no LDAP.
- Chave SSH em vez de senha: possível (atributo `sshPublicKey` no usuário +
  `AuthorizedKeysCommand /usr/bin/sss_ssh_authorizedkeys`), mas não está incluído
  nos scripts.
