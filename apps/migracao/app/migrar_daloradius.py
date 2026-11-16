#!/usr/bin/env python3
"""Migra usuários, grupos e atributos RADIUS do daloRADIUS para o authentik.

Roda várias vezes até a virada (idempotente). Comandos:

    relatorio                    só lê; markdown SEM senhas
    aplicar --simular            mostra o que faria
    aplicar [--atualizar-senhas] cria/atualiza grupos e usuários no authentik
    verificar [--radius]         compara o esperado com o que está no authentik

Fontes (somente leitura): banco radius (SELECT) e o arquivo "users" do
FreeRADIUS atual (usuário datacom etc.; entradas DEFAULT são ignoradas).

Mapeamento:
    radcheck  Cleartext-Password  -> senha (só na criação; --atualizar-senhas regrava)
    radcheck  Auth-Type := Reject / Expiration vencida / grupo com Auth-Type := Reject
                                  -> usuário desativado (o grupo desativador não é criado)
    radcheck  (demais)            -> attributes.radius_check (só registro)
    radreply  + arquivo users     -> attributes.radius_reply do usuário
    radusergroup                  -> grupos de mesmo nome; todo usuário vai também em radius-equipamentos
    radgroupreply                 -> attributes.radius_reply do grupo (lista "Atributo op valor")
    radusergroup.priority         -> attributes.radius_prioridade do grupo (menor valor)
    userinfo                      -> nome, e-mail e attributes.daloradius
    usuários ficam no path "daloradius"; usernames com @ são literais.
Usuários que sumiram do daloRADIUS são listados, nunca apagados.
A tabela nas NÃO é lida (segredos intocáveis), só contada.
"""

import argparse
import os
import re
import sys
from collections import Counter
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path

from authentik_api import Authentik, ErroAPI, carregar_env
from fabricantes import FABRICANTES

AQUI = Path(__file__).resolve().parent
DICIONARIO = AQUI / "dicionario_authentik.txt"
GRUPO_ACESSO = "radius-equipamentos"
PRIORIDADE_PADRAO = 1000

SENHA_TEXTO = ("Cleartext-Password", "User-Password")
SENHA_HASH = (
    "Crypt-Password", "MD5-Password", "SMD5-Password", "SHA-Password", "SSHA-Password",
    "SHA2-Password", "SSHA2-256-Password", "SSHA2-512-Password", "NT-Password",
    "LM-Password", "Password-With-Header",
)
RESTRICOES = {
    "Simultaneous-Use": "limite de sessões simultâneas (não existe no authentik)",
    "Login-Time": "horário permitido (usar policy de horário no authentik)",
    "NAS-IP-Address": "restrição por equipamento (usar providers separados)",
    "NAS-Identifier": "restrição por equipamento (usar providers separados)",
    "Huntgroup-Name": "restrição por huntgroup (usar providers separados)",
    "Calling-Station-Id": "restrição por origem (usar policy de rede no authentik)",
}
SENHAS_FRACAS = {
    "123456", "1234567", "12345678", "123456789", "1234", "12345", "admin", "admin123",
    "senha", "senha123", "password", "passw0rd", "qwerty", "mudar", "mudar123", "changeme",
    "teste", "teste123", "root", "master", "default", "abc123",
}
FORMATOS_DATA = (
    "%d %b %Y %H:%M:%S", "%d %b %Y %H:%M", "%d %b %Y",
    "%b %d %Y %H:%M:%S", "%b %d %Y %H:%M", "%b %d %Y",
    "%Y-%m-%d %H:%M:%S", "%Y-%m-%d",
)
OPS = r"(:=|==|\+=|=~|!=|!~|<=|>=|=\*|!\*|<|>|=)"


@dataclass
class Grupo:
    nome: str
    reply: list = field(default_factory=list)
    check: list = field(default_factory=list)
    prioridade: int | None = None
    desativa: bool = False  # radgroupcheck Auth-Type := Reject


@dataclass
class Usuario:
    username: str
    senha: str | None = None
    tipo_senha: str | None = None
    ativo: bool = True
    expiracao: str | None = None
    reply: list = field(default_factory=list)
    check: list = field(default_factory=list)
    grupos: list = field(default_factory=list)  # [(prioridade, nome)]
    info: dict = field(default_factory=dict)
    avisos: list = field(default_factory=list)
    origem: str = "banco"

    @property
    def nome(self):
        nome = " ".join(p for p in (self.info.get("firstname"), self.info.get("lastname")) if p).strip()
        return nome or self.username

    @property
    def email(self):
        return (self.info.get("email") or "").strip()


# --------------------------------------------------------------------------
# Utilidades puras (testadas em tests/teste_calculo.py)
# --------------------------------------------------------------------------


def linha_radius(atributo, op, valor):
    """Formato usado no authentik: 'Atributo op valor'."""
    return f"{atributo.strip()} {(op or '=').strip()} {str(valor).strip()}"


def interpretar_data(texto):
    for formato in FORMATOS_DATA:
        try:
            return datetime.strptime(texto.strip(), formato)
        except ValueError:
            continue
    return None


def atributos_suportados():
    """(RFC do dicionário do authentik, fabricantes que o mapping sabe enviar)."""
    rfc = {
        linha.strip()
        for linha in DICIONARIO.read_text(encoding="utf-8").splitlines()
        if linha.strip() and not linha.startswith("#")
    }
    return rfc, set(FABRICANTES)


def ler_linha(linha):
    """Mesma regra do property mapping: (nome, op, valor) ou None."""
    partes = str(linha).strip().split(None, 2)
    if len(partes) != 3 or partes[1] not in (":=", "=", "+=", "=="):
        return None
    nome, op, valor = partes
    valor = valor.strip()
    if len(valor) >= 2 and valor[0] == valor[-1] and valor[0] in "'\"":
        valor = valor[1:-1]
    return nome, op, valor


def aplicar_linhas(resposta, linhas):
    """Mesma semântica do property mapping e do rlm_sql: ':=' troca, '+=' soma, '=' só se ausente."""
    if isinstance(linhas, str):
        linhas = [linhas]
    for linha in linhas or []:
        lido = ler_linha(linha)
        if not lido or lido[1] == "==":
            continue
        nome, op, valor = lido
        if op == ":=":
            resposta[nome] = [valor]
        elif op == "+=":
            resposta.setdefault(nome, []).append(valor)
        elif nome not in resposta:
            resposta[nome] = [valor]


def resposta_daloradius(usuario, grupos):
    """O que o daloRADIUS/FreeRADIUS devolveria: radreply, depois grupos por prioridade do usuário."""
    resposta = {}
    aplicar_linhas(resposta, usuario.reply)
    for _, nome in sorted(usuario.grupos):
        g = grupos.get(nome)
        if g is not None and not g.desativa:
            aplicar_linhas(resposta, g.reply)
    return resposta


def resposta_authentik(attrs_usuario, grupos_authentik, suportados):
    """Reproduz o property mapping com os dados que estão NO authentik.

    grupos_authentik: lista de dicts {name, attributes}. Atributos que o mapping
    não conhece são descartados (como no mapping real).
    """
    resposta = {}
    aplicar_linhas(resposta, (attrs_usuario or {}).get("radius_reply"))
    ordenados = sorted(
        grupos_authentik,
        key=lambda g: (int((g.get("attributes") or {}).get("radius_prioridade", PRIORIDADE_PADRAO)), g["name"]),
    )
    for g in ordenados:
        aplicar_linhas(resposta, (g.get("attributes") or {}).get("radius_reply"))
    return {k: v for k, v in resposta.items() if k in suportados}


def suportados_envio():
    rfc, fab = atributos_suportados()
    return rfc | fab


def tokenizar_itens(texto):
    """Separa 'A = x, B := "y, z"' por vírgulas fora de aspas."""
    itens, atual, aspas = [], "", None
    for c in texto:
        if aspas:
            atual += c
            if c == aspas:
                aspas = None
        elif c in "'\"":
            aspas = c
            atual += c
        elif c == ",":
            itens.append(atual.strip())
            atual = ""
        else:
            atual += c
    if atual.strip():
        itens.append(atual.strip())
    return [i for i in itens if i]


def separar_item(item):
    m = re.match(r"^([A-Za-z0-9_-]+)\s*" + OPS + r"\s*(.*)$", item)
    if not m:
        return None
    valor = m.group(3).strip()
    if len(valor) >= 2 and valor[0] == valor[-1] and valor[0] in "'\"":
        valor = valor[1:-1]
    return m.group(1), m.group(2), valor


def ler_arquivo_users(caminho):
    """Arquivo 'users' do FreeRADIUS: {nome: ([check], [reply])}, sem as entradas DEFAULT."""
    entradas, atual, fase = {}, None, None
    texto = Path(caminho).read_text(encoding="utf-8", errors="replace")
    for bruto in texto.splitlines():
        if not bruto.strip() or bruto.lstrip().startswith("#"):
            continue
        linha = bruto.rstrip()
        if not bruto[0].isspace():
            partes = linha.split(None, 1)
            atual = None if partes[0].upper().startswith("DEFAULT") else partes[0]
            fase = "check"
            if atual:
                entradas[atual] = ([], [])
            resto = partes[1] if len(partes) > 1 else ""
        else:
            resto = linha.strip()
        if atual is None:
            continue
        alvo = entradas[atual][0] if fase == "check" else entradas[atual][1]
        alvo.extend(tokenizar_itens(resto))
        if fase == "check" and not resto.endswith(","):
            fase = "reply"
    return entradas


def avaliar_senha(senha, username):
    """Avisos sobre a senha SEM revelá-la."""
    avisos = []
    if len(senha) < 8:
        avisos.append("senha curta (menos de 8 caracteres)")
    if senha.lower() == username.lower() or senha.lower() == username.split("@")[0].lower():
        avisos.append("senha igual ao usuário")
    elif senha.lower() in SENHAS_FRACAS:
        avisos.append("senha fraca (comum)")
    if ";" in senha:
        avisos.append("senha contém ';': trocar antes de ativar MFA (senha;código)")
    return avisos


# --------------------------------------------------------------------------
# Leitura do daloRADIUS
# --------------------------------------------------------------------------


def conectar_mysql(args):
    try:
        import pymysql
    except ImportError:
        sys.exit("PyMySQL não instalado (pip install -r app/requirements.txt)")
    opcoes = dict(database=args.db_nome, charset="utf8mb4", cursorclass=pymysql.cursors.DictCursor,
                  connect_timeout=10)
    if args.db_cnf and not args.db_usuario:
        opcoes["read_default_file"] = args.db_cnf
    else:
        opcoes.update(user=args.db_usuario, password=args.db_senha)
    if args.db_socket and os.path.exists(args.db_socket):
        opcoes["unix_socket"] = args.db_socket
    else:
        opcoes.update(host=args.db_host, port=int(args.db_porta))
    conexao = pymysql.connect(**opcoes)
    with conexao.cursor() as cur:  # defesa extra: a sessão não consegue gravar
        cur.execute("SET SESSION TRANSACTION READ ONLY")
        cur.execute("SET SESSION max_statement_time = 30")
    return conexao


def consultar(conexao, sql, opcional=False):
    import pymysql

    if not sql.lstrip().upper().startswith("SELECT"):
        raise RuntimeError("somente SELECT é permitido neste banco")
    try:
        with conexao.cursor() as cursor:
            cursor.execute(sql)
            return cursor.fetchall()
    except (pymysql.err.ProgrammingError, pymysql.err.OperationalError):
        if opcional:
            return []
        raise


def processar_check(u, atributo, op, valor, agora):
    """Interpreta um item de verificação (radcheck ou arquivo users) de um usuário."""
    if atributo in SENHA_TEXTO:
        u.senha, u.tipo_senha = valor, atributo
    elif atributo in SENHA_HASH:
        u.tipo_senha = atributo
        u.avisos.append(f"senha em {atributo}: criado SEM senha, defina uma nova")
    elif atributo == "Auth-Type":
        u.check.append(linha_radius(atributo, op, valor))
        if valor.lower() == "reject":
            u.ativo = False
            u.avisos.append("Auth-Type := Reject: criado desativado")
        elif valor.lower() == "accept":
            u.avisos.append("Auth-Type := Accept (entrava sem senha!): exige senha no authentik")
    elif atributo == "Expiration":
        u.expiracao = valor
        data = interpretar_data(valor)
        if data is None:
            u.avisos.append(f"Expiration '{valor}' em formato desconhecido: revise")
        elif data < agora:
            u.ativo = False
            u.avisos.append(f"expirado em {valor}: criado desativado")
        else:
            u.avisos.append(f"expira em {valor}: o authentik não expira sozinho, revise")
    else:
        u.check.append(linha_radius(atributo, op, valor))
        u.avisos.append(f"{atributo} {op} {valor}: {RESTRICOES.get(atributo, 'check item sem equivalente')}")


def ler_daloradius(conexao):
    usuarios: dict[str, Usuario] = {}
    grupos: dict[str, Grupo] = {}

    def usuario(nome):
        return usuarios.setdefault(nome, Usuario(username=nome))

    def grupo(nome):
        return grupos.setdefault(nome, Grupo(nome=nome))

    agora = datetime.now()
    for l in consultar(conexao, "SELECT username, attribute, op, value FROM radcheck ORDER BY id"):
        processar_check(usuario(l["username"]), l["attribute"], l["op"], l["value"], agora)

    for l in consultar(conexao, "SELECT username, attribute, op, value FROM radreply ORDER BY id"):
        usuario(l["username"]).reply.append(linha_radius(l["attribute"], l["op"], l["value"]))

    for l in consultar(conexao, "SELECT groupname, attribute, op, value FROM radgroupreply ORDER BY id"):
        grupo(l["groupname"]).reply.append(linha_radius(l["attribute"], l["op"], l["value"]))

    for l in consultar(conexao, "SELECT groupname, attribute, op, value FROM radgroupcheck ORDER BY id"):
        g = grupo(l["groupname"])
        g.check.append(linha_radius(l["attribute"], l["op"], l["value"]))
        if l["attribute"] == "Auth-Type" and str(l["value"]).lower() == "reject":
            g.desativa = True

    prioridades = {}
    for l in consultar(conexao, "SELECT username, groupname, priority FROM radusergroup ORDER BY priority, id"):
        g = grupo(l["groupname"])
        prio = int(l["priority"] or 0)
        g.prioridade = prio if g.prioridade is None else min(g.prioridade, prio)
        prioridades.setdefault(l["groupname"], set()).add(prio)
        usuario(l["username"]).grupos.append((prio, l["groupname"]))

    for l in consultar(conexao, "SELECT * FROM userinfo", opcional=True):
        if l.get("username") in usuarios:
            usuarios[l["username"]].info = {
                k: v for k, v in l.items() if v not in (None, "") and k != "portalloginpassword"
            }

    for nome, valores in prioridades.items():
        if len(valores) > 1:
            for u in usuarios.values():
                if any(n == nome for _, n in u.grupos):
                    u.avisos.append(f"grupo {nome} tem prioridades diferentes por usuário: o authentik usa a menor")
    return usuarios, grupos


def incorporar_arquivo_users(usuarios, caminho):
    """Acrescenta os usuários do arquivo 'users' que não estão no banco (ex.: datacom)."""
    agora = datetime.now()
    novos = []
    for nome, (check, reply) in ler_arquivo_users(caminho).items():
        if nome in usuarios:
            usuarios[nome].avisos.append("existe também no arquivo users: vale o do banco")
            continue
        u = Usuario(username=nome, origem="arquivo users")
        for item in check:
            p = separar_item(item)
            if p:
                processar_check(u, *p, agora)
        for item in reply:
            p = separar_item(item)
            if p:
                u.reply.append(linha_radius(*p))
        usuarios[nome] = u
        novos.append(nome)
    return novos


def finalizar(usuarios, grupos):
    """Passos que dependem de tudo já lido: grupo desativador, avisos de senha."""
    por_senha = Counter(u.senha for u in usuarios.values() if u.senha)
    for u in usuarios.values():
        for _, nome in u.grupos:
            if grupos[nome].desativa and u.ativo:
                u.ativo = False
                u.avisos.append(f"no grupo {nome} (Auth-Type := Reject): criado desativado")
        if u.tipo_senha is None:
            u.avisos.append("sem senha no radcheck: criado sem senha")
        if u.senha:
            u.avisos.extend(avaliar_senha(u.senha, u.username))
            if por_senha[u.senha] > 1:
                u.avisos.append(f"mesma senha de outros {por_senha[u.senha] - 1} usuário(s)")


def ler_chap_recente(conexao, dias=90):
    """Heurística opcional (--chap): radpostauth grava CHAP-Password como 0x<hex>. Só conta."""
    linhas = consultar(
        conexao,
        "SELECT username, COUNT(*) AS total FROM radpostauth "
        f"WHERE authdate > NOW() - INTERVAL {int(dias)} DAY "
        "AND pass LIKE '0x%' AND LENGTH(pass) >= 34 GROUP BY username",
        opcional=True,
    )
    return {l["username"]: l["total"] for l in linhas}


def carregar_fontes(args, com_conexao=True):
    conexao = conectar_mysql(args)
    usuarios, grupos = ler_daloradius(conexao)
    novos = []
    if args.arquivo_users and os.path.isfile(args.arquivo_users):
        novos = incorporar_arquivo_users(usuarios, args.arquivo_users)
    elif not args.sem_arquivo_users and args.comando != "relatorio":
        sys.exit(f"arquivo users do FreeRADIUS não encontrado em {args.arquivo_users} "
                 "(use --sem-arquivo-users para ignorar)")
    finalizar(usuarios, grupos)
    return conexao, usuarios, grupos, novos


# --------------------------------------------------------------------------
# Relatório (sem senhas)
# --------------------------------------------------------------------------


def relatorio(usuarios, grupos, total_nas, chap, arquivo_ok, saida):
    rfc, fabricantes = atributos_suportados()

    def suporte(linha):
        atributo = linha.split(None, 1)[0]
        if atributo in fabricantes:
            return "ok (fabricante)"
        if atributo in rfc:
            return "ok (RFC)"
        return "**NÃO enviado**: adicione em FABRICANTES (blueprint radius e app/fabricantes.py)"

    w = saida.write
    w("# Relatório de migração daloRADIUS -> authentik\n\n")
    w(f"Gerado em {datetime.now():%Y-%m-%d %H:%M}. Este relatório não contém senhas.\n\n")
    ativos = sum(1 for u in usuarios.values() if u.ativo)
    com_senha = sum(1 for u in usuarios.values() if u.senha)
    w(f"- Usuários: **{len(usuarios)}** ({ativos} ativos, {len(usuarios) - ativos} desativados, "
      f"{com_senha} com senha em texto)\n")
    w(f"- Grupos: **{len(grupos)}** ({sum(1 for g in grupos.values() if g.desativa)} só desativam usuários e não serão criados)\n")
    w(f"- NAS cadastrados: **{total_nas}** (a tabela nas não é lida nem alterada por esta ferramenta)\n")
    if not arquivo_ok:
        w("- **Arquivo users do FreeRADIUS não encontrado**: usuários como datacom não entraram.\n")
    w("\n")

    inventario = {}
    for fonte in list(grupos.values()) + list(usuarios.values()):
        for linha in fonte.reply:
            inventario.setdefault(linha.split(None, 1)[0], linha)
    w("## Atributos de resposta encontrados\n\n")
    if inventario:
        w("| Atributo | Exemplo | Envio pelo authentik |\n|---|---|---|\n")
        for atributo, exemplo in sorted(inventario.items()):
            w(f"| `{atributo}` | `{exemplo}` | {suporte(exemplo)} |\n")
    else:
        w("Nenhum atributo em radreply/radgroupreply.\n")
    w("\n## Grupos\n\n| Grupo | Prioridade | Membros | Resposta (radgroupreply) | radgroupcheck | Migração |\n")
    w("|---|---|---|---|---|---|\n")
    for g in sorted(grupos.values(), key=lambda g: g.nome):
        membros = sum(1 for u in usuarios.values() if any(n == g.nome for _, n in u.grupos))
        destino = "não criado: membros ficam desativados" if g.desativa else "criado com o mesmo nome"
        w(f"| {g.nome} | {g.prioridade if g.prioridade is not None else '-'} | {membros} | "
          f"{'<br>'.join(f'`{r}`' for r in g.reply) or '-'} | "
          f"{'<br>'.join(f'`{c}`' for c in g.check) or '-'} | {destino} |\n")
    w("\n## Usuários\n\n| Usuário | Origem | Nome | Grupos | Senha | Ativo | Resposta própria | Avisos |\n")
    w("|---|---|---|---|---|---|---|---|\n")
    for u in sorted(usuarios.values(), key=lambda u: u.username):
        avisos = list(u.avisos)
        if u.username in chap:
            avisos.append(f"usou CHAP {chap[u.username]}x nos últimos 90 dias: equipamento precisa de PAP")
        nomes = [n for _, n in sorted(u.grupos) if not grupos[n].desativa]
        w(f"| {u.username} | {u.origem} | {u.nome} | {', '.join(nomes) or '-'} | {u.tipo_senha or '-'} | "
          f"{'sim' if u.ativo else 'não'} | {'<br>'.join(f'`{r}`' for r in u.reply) or '-'} | "
          f"{'<br>'.join(avisos) or '-'} |\n")
    w("\n")
    if chap:
        w("## Atenção: CHAP\n\nEstes usuários autenticaram com CHAP recentemente. O authentik só aceita PAP: "
          "ajuste o equipamento antes da virada.\n\n")
        for nome, total in sorted(chap.items()):
            w(f"- {nome}: {total} logins CHAP\n")
        w("\n")


# --------------------------------------------------------------------------
# Aplicação no authentik
# --------------------------------------------------------------------------


def mesclar_atributos(existentes, novos):
    resultado = dict(existentes or {})
    for chave, valor in novos.items():
        if valor in (None, [], {}):
            resultado.pop(chave, None)
        else:
            resultado[chave] = valor
    return resultado


def buscar_um(ak, caminho, **filtros):
    for item in ak.listar(caminho, **filtros):
        if all(item.get(k) == v for k, v in filtros.items()):
            return item
    return None


def aplicar(ak, usuarios, grupos, args):
    migrado_em = datetime.now().isoformat(timespec="seconds")
    log = print
    if ak.simular:
        log("*** SIMULAÇÃO: nada será gravado no authentik ***")

    acesso = buscar_um(ak, "core/groups/", name=GRUPO_ACESSO)
    if acesso is None:
        log(f"grupo de acesso '{GRUPO_ACESSO}' não existe (o blueprint do app radius o cria): criando")
        acesso = ak.escrever("POST", "core/groups/", {"name": GRUPO_ACESSO}) or {"pk": None}

    pk_grupos = {}
    for g in sorted(grupos.values(), key=lambda g: g.nome):
        if g.desativa:
            log(f"grupo   ignorar   {g.nome} (Auth-Type := Reject: só desativa usuários)")
            continue
        novos = {
            "radius_reply": g.reply,
            "radius_check": g.check,
            "radius_prioridade": g.prioridade if g.prioridade is not None else PRIORIDADE_PADRAO,
            "daloradius": {"grupo": g.nome, "migrado_em": migrado_em},
        }
        existente = buscar_um(ak, "core/groups/", name=g.nome)
        if existente:
            log(f"grupo   atualizar {g.nome}")
            atributos = mesclar_atributos(existente.get("attributes"), novos)
            ak.escrever("PATCH", f"core/groups/{existente['pk']}/", {"attributes": atributos})
            pk_grupos[g.nome] = existente["pk"]
        else:
            log(f"grupo   criar     {g.nome}")
            criado = ak.escrever("POST", "core/groups/", {"name": g.nome, "attributes": mesclar_atributos({}, novos)})
            pk_grupos[g.nome] = criado["pk"] if criado else None

    erros = 0
    for u in sorted(usuarios.values(), key=lambda u: u.username):
        dados_dalo = {
            k: str(u.info[k])
            for k in ("department", "company", "workphone", "mobilephone", "notes", "creationdate")
            if k in u.info
        }
        dados_dalo["migrado_em"] = migrado_em
        dados_dalo["origem"] = u.origem
        novos = {
            "radius_reply": u.reply,
            "radius_check": u.check,
            "radius_expiracao": u.expiracao,
            "daloradius": dados_dalo,
        }
        try:
            existente = buscar_um(ak, "core/users/", username=u.username)
            if existente:
                log(f"usuário atualizar {u.username}{'' if u.ativo else ' (desativado)'}")
                nome = u.nome if u.info or not existente.get("name") else existente["name"]
                corpo = {"name": nome, "is_active": u.ativo,
                         "attributes": mesclar_atributos(existente.get("attributes"), novos)}
                if u.email:
                    corpo["email"] = u.email
                ak.escrever("PATCH", f"core/users/{existente['pk']}/", corpo)
                pk = existente["pk"]
                gravar_senha = args.atualizar_senhas
            else:
                log(f"usuário criar     {u.username}{'' if u.ativo else ' (desativado)'}")
                criado = ak.escrever("POST", "core/users/", {
                    "username": u.username, "name": u.nome, "email": u.email, "is_active": u.ativo,
                    "path": args.caminho_usuarios, "type": "internal",
                    "attributes": mesclar_atributos({}, novos),
                })
                pk = criado["pk"] if criado else None
                gravar_senha = True

            if gravar_senha and u.senha:
                log(f"        senha     {u.username}")
                ak.escrever("POST", f"core/users/{pk}/set_password/", {"password": u.senha})

            for _, nome_grupo in sorted(u.grupos):
                if pk_grupos.get(nome_grupo):
                    ak.escrever("POST", f"core/groups/{pk_grupos[nome_grupo]}/add_user/", {"pk": pk})
            if acesso.get("pk"):
                ak.escrever("POST", f"core/groups/{acesso['pk']}/add_user/", {"pk": pk})
        except ErroAPI as erro:
            erros += 1
            print(f"ERRO em {u.username}: {erro}", file=sys.stderr)

    existentes = {i["username"] for i in ak.listar("core/users/", path=args.caminho_usuarios)}
    sobrando = sorted(existentes - set(usuarios))
    if sobrando:
        log(f"\nUsuários no authentik (path {args.caminho_usuarios}) que não estão mais no daloRADIUS (não apagados):")
        for nome in sobrando:
            log(f"  - {nome}")
    log(f"\nConcluído: {len(grupos)} grupos, {len(usuarios)} usuários, {erros} erros.")
    return 1 if erros else 0


# --------------------------------------------------------------------------
# Verificação
# --------------------------------------------------------------------------


def normalizar(resposta):
    return {k: sorted(str(v) for v in vs) for k, vs in resposta.items()}


def comparar_respostas(esperada, obtida):
    """Lista de diferenças entre dois {atributo: [valores]}, sem imprimir segredos."""
    esperada, obtida = normalizar(esperada), normalizar(obtida)
    difs = []
    for k in sorted(set(esperada) | set(obtida)):
        if k not in obtida:
            difs.append(f"falta {k} = {esperada[k]}")
        elif k not in esperada:
            difs.append(f"sobra {k} = {obtida[k]}")
        elif esperada[k] != obtida[k]:
            difs.append(f"{k}: esperado {esperada[k]}, obtido {obtida[k]}")
    return difs


def verificar(ak, usuarios, grupos, args):
    suportados = suportados_envio()
    divergencias = []

    def dif(quem, texto):
        divergencias.append(f"{quem}: {texto}")

    por_nome = {}
    for g in grupos.values():
        if g.desativa:
            continue
        no_ak = buscar_um(ak, "core/groups/", name=g.nome)
        if no_ak is None:
            dif(f"grupo {g.nome}", "não existe no authentik")
            continue
        por_nome[g.nome] = no_ak
        a = no_ak.get("attributes") or {}
        if a.get("radius_reply") != g.reply:
            dif(f"grupo {g.nome}", f"radius_reply diferente (esperado {g.reply}, obtido {a.get('radius_reply')})")
        prio = g.prioridade if g.prioridade is not None else PRIORIDADE_PADRAO
        if a.get("radius_prioridade") != prio:
            dif(f"grupo {g.nome}", f"radius_prioridade esperado {prio}, obtido {a.get('radius_prioridade')}")

    nao_radius = 0
    for u in sorted(usuarios.values(), key=lambda u: u.username):
        no_ak = buscar_um(ak, "core/users/", username=u.username)
        if no_ak is None:
            dif(f"usuário {u.username}", "não existe no authentik")
            continue
        if no_ak.get("is_active") != u.ativo:
            dif(f"usuário {u.username}", f"ativo esperado {u.ativo}, obtido {no_ak.get('is_active')}")
        if u.email and no_ak.get("email") != u.email:
            dif(f"usuário {u.username}", "e-mail diferente")
        grupos_esperados = {n for _, n in u.grupos if not grupos[n].desativa} | {GRUPO_ACESSO}
        grupos_obtidos = {g["name"] for g in no_ak.get("groups_obj") or []}
        if grupos_esperados != grupos_obtidos:
            dif(f"usuário {u.username}",
                f"grupos: faltam {sorted(grupos_esperados - grupos_obtidos)}, sobram {sorted(grupos_obtidos - grupos_esperados)}")
        attrs = no_ak.get("attributes") or {}
        if attrs.get("radius_reply", []) != u.reply:
            dif(f"usuário {u.username}", "attributes.radius_reply diferente do esperado")
        esperada = resposta_daloradius(u, grupos)
        calculada = resposta_authentik(attrs, no_ak.get("groups_obj") or [], suportados)
        for d in comparar_respostas(esperada, calculada):
            dif(f"usuário {u.username}", f"resposta RADIUS calculada: {d}")

    if args.radius:
        divergencias += verificar_radius(usuarios, grupos, args)

    extras = sorted({i["username"] for i in ak.listar("core/users/", path=args.caminho_usuarios)} - set(usuarios))
    for nome in extras:
        print(f"aviso: {nome} está no authentik (path {args.caminho_usuarios}) e não no daloRADIUS")
    if divergencias:
        print(f"\n{len(divergencias)} divergência(s):")
        for d in divergencias:
            print(f"  - {d}")
        return 1
    print(f"OK: {len(usuarios)} usuários e {len(por_nome)} grupos conferem com o daloRADIUS"
          f"{' (incluindo login RADIUS real)' if args.radius else ''}.")
    return 0


def verificar_radius(usuarios, grupos, args):
    from radius_cliente import ErroRadius, autenticar

    segredo = os.environ.get("AUTHENTIK_RADIUS_SECRET")
    if not segredo:
        return ["AUTHENTIK_RADIUS_SECRET não definido: impossível testar o outpost"]
    host, _, porta = args.radius_alvo.partition(":")
    difs, testados = [], 0
    for u in sorted(usuarios.values(), key=lambda u: u.username):
        if not u.ativo or not u.senha:
            continue
        testados += 1
        try:
            resultado, obtida = autenticar(host, int(porta or 1812), segredo, u.username, u.senha)
        except (ErroRadius, OSError) as erro:
            difs.append(f"login RADIUS de {u.username}: {erro}")
            continue
        if resultado != "accept":
            difs.append(f"login RADIUS de {u.username}: esperado Access-Accept, obtido {resultado}")
            continue
        for d in comparar_respostas(resposta_daloradius(u, grupos), obtida):
            difs.append(f"login RADIUS de {u.username}: atributo {d}")
    print(f"login RADIUS testado em {testados} usuários ativos ({args.radius_alvo})")
    return difs


# --------------------------------------------------------------------------


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--env", default=os.environ.get("MIGRACAO_ENV", ""), help="arquivo .env opcional")
    sub = parser.add_subparsers(dest="comando", required=True)

    p_rel = sub.add_parser("relatorio", help="mostra o que será migrado (não altera nada)")
    p_rel.add_argument("--saida", help="arquivo .md (padrão: tela)")
    p_rel.add_argument("--chap", action="store_true", help="conta logins CHAP em radpostauth (consulta pesada)")
    p_apl = sub.add_parser("aplicar", help="cria/atualiza grupos e usuários no authentik")
    p_apl.add_argument("--simular", action="store_true", help="não grava nada, só mostra")
    p_apl.add_argument("--atualizar-senhas", action="store_true",
                       help="regrava a senha de usuários que já existem no authentik")
    p_ver = sub.add_parser("verificar", help="compara o esperado com o que está no authentik (exit 1 se divergir)")
    p_ver.add_argument("--radius", action="store_true",
                       help="testa login real de cada usuário ativo no outpost e compara os atributos")
    p_ver.add_argument("--radius-alvo", default=os.environ.get("MIGRACAO_RADIUS_ALVO", "127.0.0.1:18120"))

    for p in (p_rel, p_apl, p_ver):
        p.add_argument("--sem-arquivo-users", action="store_true", help="não exigir o arquivo users do FreeRADIUS")
    for p in (p_apl, p_ver):
        p.add_argument("--caminho-usuarios", default="daloradius", help="path dos usuários no authentik")
        p.add_argument("--authentik-url", help="padrão: AUTHENTIK_API_URL ou http://127.0.0.1:9000")
        p.add_argument("--token", help="padrão: AUTHENTIK_BOOTSTRAP_TOKEN")
        p.add_argument("--inseguro", action="store_true", help="não validar o certificado TLS")

    args = parser.parse_args(argv)
    carregar_env(args.env)
    e = os.environ.get
    args.db_socket = e("DALO_DB_SOCKET") or ""
    args.db_host = e("DALO_DB_HOST") or "127.0.0.1"
    args.db_porta = e("DALO_DB_PORT") or "3306"
    args.db_usuario = e("DALO_DB_USER") or ""
    args.db_senha = e("DALO_DB_PASS") or ""
    args.db_nome = e("DALO_DB_NAME") or "radius"
    args.db_cnf = e("DALO_DB_CNF") or ""
    args.arquivo_users = e("MIGRACAO_USERS_ARQUIVO", "/dados/users")
    if not args.db_usuario and not args.db_cnf:
        sys.exit("Defina DALO_DB_USER/DALO_DB_PASS (ou DALO_DB_CNF) no .env")

    conexao, usuarios, grupos, _ = carregar_fontes(args)

    if args.comando == "relatorio":
        chap = ler_chap_recente(conexao) if args.chap else {}
        total_nas = consultar(conexao, "SELECT COUNT(*) AS n FROM nas", opcional=True)
        total_nas = total_nas[0]["n"] if total_nas else 0
        arquivo_ok = os.path.isfile(args.arquivo_users)
        if args.saida:
            with open(args.saida, "w", encoding="utf-8") as f:
                relatorio(usuarios, grupos, total_nas, chap, arquivo_ok, f)
            print(f"Relatório gravado em {args.saida}")
        else:
            relatorio(usuarios, grupos, total_nas, chap, arquivo_ok, sys.stdout)
        return 0

    url = args.authentik_url or e("AUTHENTIK_API_URL") or "http://127.0.0.1:9000"
    token = args.token or e("AUTHENTIK_BOOTSTRAP_TOKEN")
    if not token:
        sys.exit("Informe --token ou AUTHENTIK_BOOTSTRAP_TOKEN")
    ak = Authentik(url, token, inseguro=args.inseguro, simular=getattr(args, "simular", False))
    if args.comando == "aplicar":
        return aplicar(ak, usuarios, grupos, args)
    return verificar(ak, usuarios, grupos, args)


if __name__ == "__main__":
    sys.exit(main())
