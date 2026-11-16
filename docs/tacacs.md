# TACACS+ e painel

O TACACS+ (`apps/tacacs`, tac_plus-ng) autentica e autoriza comandos nos
equipamentos usando os usuários e grupos do authentik, pelo outpost LDAP. O
painel (`apps/painel`) mostra logins, comandos e sessões. Os dois **não**
sobem com o `base`: só quando nomeados.

Nada disso mexe no RADIUS: o cadastro de NAS (tabela `nas`), os segredos RADIUS
e o FreeRADIUS seguem iguais. Mikrotik não fala TACACS+ e continua no RADIUS.

```
equipamento ──49/tcp──► tacacs ──LDAP──► ldap-outpost ──► authentik (usuários, grupos tacacs-*)
                          └──► /var/log/tacacs/eventos.tsv (volume provedor-tacacs-logs)
                                                    └──► painel :9049 (login pelo authentik)
```

## 1. Ativar

Pré-requisito: `authentik` e `ldap` no ar (`sudo ./provedor ps base`), rede e
volume criados por `sudo ./provedor preparar` (que também gerou `TACACS_KEY`,
`PAINEL_OIDC_SECRET` e `PAINEL_SECRET_KEY` no `.env`).

```sh
sudo ./provedor status            # produção ok e memória > 600 MB
sudo ./provedor up ldap           # se ainda não estiver no ar
sudo ./provedor teste ldap
sudo ./provedor up tacacs         # constrói a imagem; porta 49/tcp
sudo ./provedor teste tacacs      # cria usuários temporários, testa authen/author/acct e apaga
sudo ./provedor up painel         # porta 9049/tcp
sudo ./provedor teste painel
sudo ./provedor status            # confira de novo a produção
```

Os grupos `tacacs-admin`, `tacacs-operador` e `tacacs-leitura` e a aplicação
`painel-tacacs` são criados pelos blueprints assim que o authentik sobe
(`apps/tacacs/blueprints/04-tacacs.yaml`, `apps/painel/blueprints/05-painel.yaml`).

Para desligar: `sudo ./provedor down painel` e `sudo ./provedor down tacacs`
(o histórico fica nos volumes).

## 2. Dar acesso pela interface do authentik

| Grupo | Perfil no equipamento |
|---|---|
| `tacacs-admin` | priv-lvl 15, todos os comandos (e acesso ao painel) |
| `tacacs-operador` | priv-lvl 2: Huawei nível de configuração (sem usuários/AAA/arquivos/`save`); Juniper classe `operator`; Datacom (autorização por comando): configura, mas `aaa`/usuários, `request`/firmware, `copy`/`load`/`file`, `reboot` e `rollback` são negados |
| `tacacs-leitura` | priv-lvl 1: `show`, `display`, `ping`, `traceroute`, sair; o resto é negado |

- Dar acesso: *Diretório > Grupos > `tacacs-…` > Usuários > Adicionar usuário existente*.
  Vale em até 1 minuto, mesmo se a pessoa já tentou entrar antes de ter o grupo: o
  `provedor-tacacs-conjuntos` percebe a mudança de membros e reinicia o outpost LDAP
  (~2 s), limpando o cache de bind, que guarda a recusa por 5 min.
- Trocar de grupo (ex.: leitura -> admin): vale na hora para sessões novas.
- Tirar acesso: remover do grupo (vale em até 1 minuto) ou desativar o usuário.
- Senha: a do próprio usuário no authentik (não há senha local no TACACS+).
- Quem está em mais de um grupo recebe o maior privilégio; quem não está em
  nenhum é negado.
- Painel: membros de `painel-tacacs` ou `tacacs-admin`
  (*Diretório > Grupos > `painel-tacacs` > Usuários*).

### Leitura só em alguns equipamentos

Grupo `tacacs-admin-or-hosts-leitura`: admin em todos os equipamentos, só leitura nos da
lista (por exemplo, as bordas BGP). A lista fica no próprio grupo (*Diretório → Grupos →
tacacs-admin-or-hosts-leitura → Editar → Atributos → `tacacs_leitura_em`*, uma linha
`IP: nome` por equipamento); salvou, vale em ~1 minuto. Detalhes em
[apps/tacacs/README.md](../apps/tacacs/README.md#acesso-por-conjunto-de-equipamentos-editado-no-authentik).

Grupo `tacacs-admin-or-hosts-operador`: igual, mas **operador** nos equipamentos da lista
`tacacs_operador_em` (no Huawei, operador = nível 2: configura, mas não mexe em usuários, AAA, arquivos nem `save`).

### Segundo fator

Por padrão o TACACS+ valida só a senha, pelo LDAP do authentik. Para exigir um segundo
fator no SSH dos equipamentos (a pessoa digita `senha;código TOTP`), veja
[ssh-2fa.md](ssh-2fa.md).

## 3. Configurar os equipamentos

Servidor `100.66.80.196`, porta `49`, chave = `TACACS_KEY` do `.env`
(a mesma em todos). **Mantenha sempre o usuário local de emergência** como
segunda opção. Roteiros por fabricante:

| Equipamento | Roteiro |
|---|---|
| Huawei NE8000 (VRP8, com `commit`) | [tacacs-huawei-ne8000.md](tacacs-huawei-ne8000.md) |
| Huawei S12700 e família S (VRP5, sem `commit`) | [tacacs-huawei-s12700.md](tacacs-huawei-s12700.md) |
| Juniper MX204 (Junos) | [tacacs-juniper-mx204.md](tacacs-juniper-mx204.md) |
| Datacom (DmOS) | [tacacs-datacom.md](tacacs-datacom.md) |
| Cisco IOS e resumo dos demais | [apps/tacacs/README.md](../apps/tacacs/README.md#configurar-os-equipamentos) |

Resumo Cisco:

```
aaa new-model
tacacs server PROVEDOR
 address ipv4 100.66.80.196
 key <TACACS_KEY>
aaa group server tacacs+ PROVEDOR
 server name PROVEDOR
aaa authentication login default group PROVEDOR local
aaa authorization exec default group PROVEDOR local
aaa authorization commands 15 default group PROVEDOR local
aaa accounting exec default start-stop group PROVEDOR
aaa accounting commands 15 default start-stop group PROVEDOR
```

Equipamentos aceitos pelo tac_plus-ng: `100.65.0.0/16`, `100.66.0.0/16`,
`172.16.0.0/12`, `198.51.100.0/26` (edite `device equipamentos` em
`apps/tacacs/tac_plus-ng.cfg.modelo` e rode `sudo ./provedor restart tacacs`).
O que vale é o IP de **origem** com que o equipamento fala com o servidor.

### Ordem recomendada

1. **Restrinja o SSH do equipamento às redes de gerência antes de ligar o TACACS+**
   ([ssh-acl.md](ssh-acl.md)). Com o SSH aberto para a internet, cada tentativa de
   força bruta passa pelo TACACS+ e pelo authentik.
2. Coloque nos grupos `tacacs-*` todas as pessoas que hoje entram nesse equipamento
   pelo RADIUS (no log do FreeRADIUS: `PROVEDOR-AUTH nas=<IP> ... Access-Accept`).
3. Teste primeiro em **um** equipamento de cada fabricante, com uma sessão já aberta
   e o usuário local de emergência conferido. Acompanhe o log de eventos durante o
   teste: `sudo ./provedor logs tacacs -f`.
4. Só depois leve aos demais, um por vez.
5. Se houver servidor reserva ([failover-vps.md](failover-vps.md)), faça um teste de
   falha real depois da implantação: ele também prova o TACACS+ e as listas por
   equipamento na reserva.
6. Monitoramento das listas no Zabbix: [monitoramento-zabbix.md](monitoramento-zabbix.md).

### Cuidados que valem para todos os fabricantes

- **Autorização por comando atinge os usuários locais.** Onde ela é ligada
  (`authorization-cmd` no Huawei, `aaa authorization commands` no Cisco), os comandos
  dos usuários **locais** também vão ao TACACS+, que os nega (eles não estão em grupo
  `tacacs-*`). O caso típico é a conta local de monitoramento (`zabbix`): a coleta
  quebra. Nos Huawei e no Juniper o nível ou a classe devolvidos no login já limitam a
  pessoa; não ligue a autorização por comando.
- **Registro de comandos não nega nada.** A contabilidade (`cmd recording-scheme` no
  Huawei, `accounting` no Junos) só registra. Se você retirar a autorização por
  comando, mantenha o registro: sem ele os comandos de ninguém aparecem no painel.
- **Uma resposta de recusa impede o usuário local.** Na ordem "TACACS+, depois local",
  o equipamento só cai no usuário local quando o servidor **não responde**. Uma senha
  errada ou uma conta sem grupo recebem recusa e param ali. Por isso os roteiros Huawei
  e Juniper usam "local primeiro".
- **A chave não vai em chat nem em chamado.** Copie `TACACS_KEY` direto do `.env`.

## 4. Ver tudo no painel

`http://100.66.80.196:9049` → login pelo authentik.

- **Visão geral**: últimas 24 h / 7 dias, usuários e equipamentos com mais
  eventos, últimas falhas.
- **Eventos**: filtros por período, usuário, equipamento, tipo
  (`authen`/`author`/`acct`), resultado (`permitido`/`negado`/`start`/`stop`)
  e texto do comando; **Exportar CSV**.
- **Sessões**: pares start/stop com duração.
- Páginas por usuário (`/usuario/NOME`) e por equipamento (`/equipamento/IP`).

Fonte: `/var/log/tacacs/eventos.tsv` no volume `provedor-tacacs-logs`
(campos por TAB: `data_hora tipo nas_ip usuario porta origem resultado detalhe`),
também visível com `sudo ./provedor logs tacacs`. Retenção no painel:
`PAINEL_RETENCAO_DIAS` (365).
