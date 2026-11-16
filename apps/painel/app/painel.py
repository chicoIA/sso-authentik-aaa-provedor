"""Painel TACACS+ da Exemplo: ingestão de eventos.tsv em SQLite + telas + login OIDC."""
import csv
import io
import json
import os
import secrets
import sqlite3
import threading
import time
from datetime import datetime, timedelta, timezone
from urllib.parse import urlencode
from zoneinfo import ZoneInfo

import requests
from flask import (Flask, Response, abort, jsonify, redirect, render_template,
                   request, session, url_for)

LOG = os.environ.get("PAINEL_LOG_EVENTOS", "/var/log/tacacs/eventos.tsv")
DB = os.environ.get("PAINEL_DB", "/dados/painel.db")
RETENCAO_DIAS = int(os.environ.get("PAINEL_RETENCAO_DIAS", "365") or 365)
INTERVALO = float(os.environ.get("PAINEL_INTERVALO_S", "2"))
TZ = ZoneInfo(os.environ.get("TZ", "America/Sao_Paulo"))
MODO_TESTE = os.environ.get("PAINEL_MODO_TESTE") == "1" and os.environ.get("PAINEL_BIND") in ("127.0.0.1", "::1")
URL_EXTERNA = os.environ.get("PAINEL_URL_EXTERNA", "http://100.66.80.196:9049").rstrip("/")
AK_EXT = os.environ.get("AUTHENTIK_URL_EXTERNA", "https://100.66.80.196:9443").rstrip("/")
AK_INT = os.environ.get("PAINEL_AUTHENTIK_INTERNO", "").rstrip("/") or AK_EXT
CLIENT_ID = os.environ.get("PAINEL_OIDC_CLIENT_ID", "painel-tacacs")
SECRET = os.environ.get("PAINEL_OIDC_SECRET", "")
SLUG = os.environ.get("PAINEL_OIDC_SLUG", "painel-tacacs")
VERIFICAR_TLS = os.environ.get("PAINEL_OIDC_VERIFICAR_TLS", "0") in ("1", "true", "sim")
GRUPOS = {g.strip() for g in os.environ.get("PAINEL_GRUPOS", "painel-tacacs,tacacs-admin").split(",") if g.strip()}
TAM_PAG = 50
LIMITE_CSV = 100000

app = Flask(__name__)
app.secret_key = os.environ.get("PAINEL_SECRET_KEY") or secrets.token_hex(32)  # sem a variável, sessões caem a cada reinício
app.config.update(SESSION_COOKIE_HTTPONLY=True, SESSION_COOKIE_SAMESITE="Lax",
                  SESSION_COOKIE_SECURE=URL_EXTERNA.startswith("https"),
                  PERMANENT_SESSION_LIFETIME=timedelta(hours=12))

# ---------------------------------------------------------------- banco
SCHEMA = """
CREATE TABLE IF NOT EXISTS eventos(id INTEGER PRIMARY KEY, ts INTEGER NOT NULL, data_hora TEXT, tipo TEXT,
  nas_ip TEXT, usuario TEXT, porta TEXT, origem TEXT, resultado TEXT, detalhe TEXT);
CREATE INDEX IF NOT EXISTS ix_ev_ts ON eventos(ts);
CREATE INDEX IF NOT EXISTS ix_ev_usr ON eventos(usuario, ts);
CREATE INDEX IF NOT EXISTS ix_ev_nas ON eventos(nas_ip, ts);
CREATE TABLE IF NOT EXISTS sessoes(id INTEGER PRIMARY KEY, nas_ip TEXT, usuario TEXT, porta TEXT, origem TEXT,
  inicio INTEGER, fim INTEGER, ultima INTEGER);
CREATE INDEX IF NOT EXISTS ix_se_chave ON sessoes(nas_ip, usuario, porta, fim);
CREATE INDEX IF NOT EXISTS ix_se_ini ON sessoes(inicio);
CREATE TABLE IF NOT EXISTS estado(chave TEXT PRIMARY KEY, valor TEXT);
"""


def conectar():
    c = sqlite3.connect(DB, timeout=30)
    c.row_factory = sqlite3.Row
    c.execute("PRAGMA journal_mode=WAL")
    c.execute("PRAGMA synchronous=NORMAL")
    return c


def iniciar_db():
    os.makedirs(os.path.dirname(DB), exist_ok=True)
    with conectar() as c:
        c.executescript(SCHEMA)


def get_estado(c, k, padrao=None):
    r = c.execute("SELECT valor FROM estado WHERE chave=?", (k,)).fetchone()
    return r[0] if r else padrao


def set_estado(c, k, v):
    c.execute("INSERT INTO estado(chave,valor) VALUES(?,?) ON CONFLICT(chave) DO UPDATE SET valor=excluded.valor", (k, str(v)))


# ---------------------------------------------------------------- ingestão
def parse_ts(s):
    d = datetime.fromisoformat(s.strip().replace("Z", "+00:00"))
    if d.tzinfo is None:
        d = d.replace(tzinfo=TZ)
    return int(d.timestamp())


def aplicar_linha(c, linha):
    """Grava uma linha do TSV. Retorna True se válida."""
    p = linha.rstrip("\r\n").split("\t")
    if len(p) < 7:
        return False
    p += [""] * (8 - len(p))
    try:
        ts = parse_ts(p[0])
    except ValueError:
        return False
    _, tipo, nas, usr, porta, origem, res, det = p[:8]
    det = "\t".join(p[7:]) if len(p) > 8 else det
    c.execute("INSERT INTO eventos(ts,data_hora,tipo,nas_ip,usuario,porta,origem,resultado,detalhe) VALUES(?,?,?,?,?,?,?,?,?)",
              (ts, p[0], tipo, nas, usr, porta, origem, res, det))
    if tipo == "acct":
        if res == "start":
            c.execute("INSERT INTO sessoes(nas_ip,usuario,porta,origem,inicio,ultima) VALUES(?,?,?,?,?,?)", (nas, usr, porta, origem, ts, ts))
        elif res in ("stop", "update"):
            r = c.execute("SELECT id FROM sessoes WHERE nas_ip=? AND usuario=? AND porta=? AND fim IS NULL ORDER BY inicio DESC LIMIT 1",
                          (nas, usr, porta)).fetchone()
            if r and res == "stop":
                c.execute("UPDATE sessoes SET fim=?, ultima=? WHERE id=?", (ts, ts, r[0]))
            elif r:
                c.execute("UPDATE sessoes SET ultima=? WHERE id=?", (ts, r[0]))
            elif res == "stop":  # stop sem start visto (início antes da retenção ou do painel)
                c.execute("INSERT INTO sessoes(nas_ip,usuario,porta,origem,fim,ultima) VALUES(?,?,?,?,?,?)", (nas, usr, porta, origem, ts, ts))
    return True


def ingerir_uma_vez():
    """Lê o que há de novo no arquivo. Trata rotação (inode novo) e truncamento. Retorna nº de linhas."""
    try:
        st = os.stat(LOG)
    except FileNotFoundError:
        return 0
    c = conectar()
    try:
        pos = int(get_estado(c, "pos", 0))
        ino = get_estado(c, "inode")
        if ino is not None and (ino != str(st.st_ino) or st.st_size < pos):
            pos = 0  # rotacionado ou truncado: recomeça do início do arquivo novo
        if st.st_size == pos and ino == str(st.st_ino):
            return 0
        n = 0
        with open(LOG, "rb") as f:
            f.seek(pos)
            c.execute("BEGIN")
            while True:
                linha = f.readline()
                if not linha or not linha.endswith(b"\n"):
                    break  # linha incompleta: espera o resto
                pos += len(linha)
                if aplicar_linha(c, linha.decode("utf-8", "replace")):
                    n += 1
                if n and n % 5000 == 0:
                    set_estado(c, "pos", pos); set_estado(c, "inode", st.st_ino); c.commit(); c.execute("BEGIN")
            set_estado(c, "pos", pos)
            set_estado(c, "inode", st.st_ino)
            if n:
                set_estado(c, "ultima_ingestao", int(time.time()))
                set_estado(c, "total_ingerido", int(get_estado(c, "total_ingerido", 0)) + n)
            c.commit()
        return n
    finally:
        c.close()


def limpar_retencao():
    corte = int(time.time()) - RETENCAO_DIAS * 86400
    with conectar() as c:
        c.execute("DELETE FROM eventos WHERE ts<?", (corte,))
        c.execute("DELETE FROM sessoes WHERE COALESCE(fim,inicio,ultima)<?", (corte,))


def laco_ingestao():
    ultima_limpeza = 0
    while True:
        try:
            ingerir_uma_vez()
            if time.time() - ultima_limpeza > 3600:
                limpar_retencao(); ultima_limpeza = time.time()
        except Exception as e:  # nunca derruba o painel
            print("erro na ingestão:", repr(e), flush=True)
        time.sleep(INTERVALO)


iniciar_db()
if os.environ.get("PAINEL_SEM_INGESTAO") != "1":
    threading.Thread(target=laco_ingestao, daemon=True).start()

# ---------------------------------------------------------------- login OIDC
def _http(metodo, url, **kw):
    return requests.request(metodo, url, timeout=10, verify=VERIFICAR_TLS, **kw)


@app.before_request
def exigir_login():
    if MODO_TESTE or request.endpoint in ("saude", "login", "callback", "static", "negado"):
        return None
    if session.get("usuario"):
        return None
    session["destino"] = request.full_path.rstrip("?") if request.method == "GET" else "/"
    return redirect(url_for("login"))


@app.after_request
def cabecalhos(r):
    r.headers["X-Content-Type-Options"] = "nosniff"
    r.headers["X-Frame-Options"] = "DENY"
    r.headers["Referrer-Policy"] = "same-origin"
    r.headers["Content-Security-Policy"] = "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; frame-ancestors 'none'"
    return r


@app.route("/login")
def login():
    if not SECRET:
        return Response("PAINEL_OIDC_SECRET não configurado.", 503)
    estado = secrets.token_urlsafe(24)
    session["oidc_estado"] = estado
    q = urlencode({"response_type": "code", "client_id": CLIENT_ID, "redirect_uri": URL_EXTERNA + "/auth/callback",
                   "scope": "openid email profile", "state": estado})
    return redirect(f"{AK_EXT}/application/o/authorize/?{q}")


@app.route("/auth/callback")
def callback():
    esperado = session.pop("oidc_estado", None)
    if not esperado or not secrets.compare_digest(esperado, request.args.get("state", "")) or not request.args.get("code"):
        return redirect(url_for("login"))
    try:
        # Troca do código e userinfo pelo canal interno: o token é recebido direto do authentik
        # (TLS/rede confiável), então não dependemos do "iss" do id_token (que muda conforme o host usado).
        t = _http("POST", f"{AK_INT}/application/o/token/", data={
            "grant_type": "authorization_code", "code": request.args["code"],
            "redirect_uri": URL_EXTERNA + "/auth/callback", "client_id": CLIENT_ID, "client_secret": SECRET})
        t.raise_for_status()
        u = _http("GET", f"{AK_INT}/application/o/userinfo/", headers={"Authorization": "Bearer " + t.json()["access_token"]})
        u.raise_for_status()
        info = u.json()
    except (requests.RequestException, ValueError, KeyError) as e:
        print("falha no login OIDC:", type(e).__name__, flush=True)
        return Response("Falha ao falar com o authentik. Tente novamente.", 502)
    grupos = set(info.get("groups") or [])
    if not (grupos & GRUPOS):
        session.clear()
        return redirect(url_for("negado"))
    destino = session.pop("destino", "/")
    session.clear()
    session.permanent = True
    session["usuario"] = info.get("preferred_username") or info.get("sub", "?")
    session["nome"] = info.get("name") or session["usuario"]
    return redirect(destino if destino.startswith("/") and not destino.startswith("//") else "/")


@app.route("/acesso-negado")
def negado():
    return render_template("negado.html", grupos=sorted(GRUPOS)), 403


@app.route("/sair", methods=["POST"])
def sair():
    session.clear()
    return redirect(url_for("login") if not MODO_TESTE else "/")


# ---------------------------------------------------------------- consultas
def fmt_ts(ts):
    return datetime.fromtimestamp(ts, TZ).strftime("%d/%m/%Y %H:%M:%S") if ts else "-"


def fmt_dur(s):
    if s is None:
        return "-"
    s = int(s); h, r = divmod(s, 3600); m, s = divmod(r, 60)
    return f"{h}h{m:02d}m{s:02d}s" if h else f"{m}m{s:02d}s"


app.jinja_env.filters["ts"] = fmt_ts
app.jinja_env.filters["dur"] = fmt_dur


def _parse_data(s, fim=False):
    if not s:
        return None
    for f in ("%Y-%m-%dT%H:%M", "%Y-%m-%d"):
        try:
            d = datetime.strptime(s, f).replace(tzinfo=TZ)
            if fim and f == "%Y-%m-%d":
                d += timedelta(days=1)
            return int(d.timestamp())
        except ValueError:
            pass
    return None


FILTROS = ("de", "ate", "usuario", "nas", "tipo", "resultado", "q")


def filtros_req(extra=None):
    f = {k: (request.args.get(k) or "").strip() for k in FILTROS}
    f.update(extra or {})
    where, par = [], []
    d, a = _parse_data(f["de"]), _parse_data(f["ate"], True)
    if d: where.append("ts>=?"); par.append(d)
    if a: where.append("ts<?"); par.append(a)
    if f["usuario"]: where.append("usuario=?"); par.append(f["usuario"])
    if f["nas"]: where.append("nas_ip=?"); par.append(f["nas"])
    if f["tipo"] in ("authen", "author", "acct"): where.append("tipo=?"); par.append(f["tipo"])
    if f["resultado"]: where.append("resultado=?"); par.append(f["resultado"])
    if f["q"]:
        where.append("detalhe LIKE ? ESCAPE '\\'")
        par.append("%" + f["q"].replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_") + "%")
    return f, (" WHERE " + " AND ".join(where)) if where else "", par


def pagina_int():
    try:
        return max(1, int(request.args.get("p", "1")))
    except ValueError:
        return 1


def consulta_eventos(c, f, w, par, p):
    total = c.execute("SELECT COUNT(*) FROM eventos" + w, par).fetchone()[0]
    linhas = c.execute("SELECT * FROM eventos" + w + " ORDER BY ts DESC, id DESC LIMIT ? OFFSET ?", par + [TAM_PAG, (p - 1) * TAM_PAG]).fetchall()
    return total, linhas


def qs_sem_p():
    return urlencode({k: v for k, v in request.args.items() if k != "p" and v})


@app.route("/saude")
def saude():
    try:
        c = conectar()
        n = c.execute("SELECT COUNT(*) FROM eventos").fetchone()[0]
        est = {k: get_estado(c, k) for k in ("pos", "ultima_ingestao", "total_ingerido")}
        c.close()
    except sqlite3.Error:
        return jsonify(status="erro"), 500
    return jsonify(status="ok", eventos=n, posicao=int(est["pos"] or 0), total_ingerido=int(est["total_ingerido"] or 0),
                   ultima_ingestao=int(est["ultima_ingestao"]) if est["ultima_ingestao"] else None,
                   arquivo_existe=os.path.exists(LOG))


@app.route("/")
def geral():
    periodo = "7d" if request.args.get("periodo") == "7d" else "24h"
    agora = int(time.time())
    c = conectar()
    try:
        cont = {}
        for nome, seg in (("24h", 86400), ("7d", 7 * 86400)):
            ini = agora - seg
            q = lambda tipo, res: c.execute("SELECT COUNT(*) FROM eventos WHERE ts>=? AND tipo=? AND resultado=?", (ini, tipo, res)).fetchone()[0]
            cont[nome] = dict(login_ok=q("authen", "permitido"), login_neg=q("authen", "negado"),
                              cmd_ok=q("author", "permitido"), cmd_neg=q("author", "negado"),
                              acct=c.execute("SELECT COUNT(*) FROM eventos WHERE ts>=? AND tipo='acct'", (ini,)).fetchone()[0])
        ini = agora - (86400 if periodo == "24h" else 7 * 86400)
        top_u = c.execute("SELECT usuario, COUNT(*) n, SUM(resultado='negado') neg FROM eventos WHERE ts>=? AND usuario!='' GROUP BY usuario ORDER BY n DESC LIMIT 10", (ini,)).fetchall()
        top_n = c.execute("SELECT nas_ip, COUNT(*) n, SUM(resultado='negado') neg FROM eventos WHERE ts>=? AND nas_ip!='' GROUP BY nas_ip ORDER BY n DESC LIMIT 10", (ini,)).fetchall()
        falhas = c.execute("SELECT * FROM eventos WHERE ts>=? AND resultado='negado' ORDER BY ts DESC, id DESC LIMIT 15", (ini,)).fetchall()
        ultimo = get_estado(c, "ultima_ingestao")
    finally:
        c.close()
    return render_template("geral.html", periodo=periodo, cont=cont, top_u=top_u, top_n=top_n, falhas=falhas,
                           ultimo=int(ultimo) if ultimo else None)


@app.route("/eventos")
def eventos():
    f, w, par = filtros_req()
    p = pagina_int()
    c = conectar()
    try:
        total, linhas = consulta_eventos(c, f, w, par, p)
    finally:
        c.close()
    return render_template("eventos.html", f=f, total=total, linhas=linhas, p=p, paginas=max(1, -(-total // TAM_PAG)), qs=qs_sem_p(),
                           titulo="Eventos", base=url_for("eventos"))


def _celula(v):
    v = "" if v is None else str(v)
    return "'" + v if v[:1] in ("=", "+", "-", "@", "\t", "\r") else v  # evita injeção de fórmula no Excel


@app.route("/eventos.csv")
def eventos_csv():
    f, w, par = filtros_req()
    c = conectar()

    def gerar():
        try:
            buf = io.StringIO(); wr = csv.writer(buf, delimiter=";")
            wr.writerow(["data_hora", "tipo", "equipamento", "usuario", "porta", "origem", "resultado", "detalhe"])
            for r in c.execute("SELECT * FROM eventos" + w + " ORDER BY ts DESC, id DESC LIMIT ?", par + [LIMITE_CSV]):
                wr.writerow([_celula(x) for x in (fmt_ts(r["ts"]), r["tipo"], r["nas_ip"], r["usuario"], r["porta"], r["origem"], r["resultado"], r["detalhe"])])
                if buf.tell() > 32768:
                    yield buf.getvalue(); buf.seek(0); buf.truncate()
            yield buf.getvalue()
        finally:
            c.close()
    return Response(gerar(), mimetype="text/csv; charset=utf-8",
                    headers={"Content-Disposition": "attachment; filename=eventos-tacacs.csv"})


def _sessoes(c, extra_w="", extra_p=(), p=1):
    w = " WHERE 1=1" + extra_w
    abertas = request.args.get("estado")
    if abertas == "abertas": w += " AND fim IS NULL"
    elif abertas == "encerradas": w += " AND fim IS NOT NULL"
    total = c.execute("SELECT COUNT(*) FROM sessoes" + w, extra_p).fetchone()[0]
    linhas = c.execute("SELECT *, CASE WHEN inicio IS NOT NULL AND fim IS NOT NULL THEN fim-inicio END dur FROM sessoes" + w +
                       " ORDER BY COALESCE(inicio,fim) DESC, id DESC LIMIT ? OFFSET ?", list(extra_p) + [TAM_PAG, (p - 1) * TAM_PAG]).fetchall()
    return total, linhas


@app.route("/sessoes")
def sessoes():
    ex, par = "", []
    u, n = (request.args.get("usuario") or "").strip(), (request.args.get("nas") or "").strip()
    if u: ex += " AND usuario=?"; par.append(u)
    if n: ex += " AND nas_ip=?"; par.append(n)
    p = pagina_int()
    c = conectar()
    try:
        total, linhas = _sessoes(c, ex, par, p)
    finally:
        c.close()
    return render_template("sessoes.html", total=total, linhas=linhas, p=p, paginas=max(1, -(-total // TAM_PAG)), qs=qs_sem_p(),
                           u=u, n=n, estado=request.args.get("estado", ""), base=url_for("sessoes"))


def _pagina_entidade(campo, valor, rotulo):
    ini = int(time.time()) - 7 * 86400
    p = pagina_int()
    c = conectar()
    try:
        f, w, par = filtros_req({campo_filtro[campo]: valor})
        total, linhas = consulta_eventos(c, f, w, par, p)
        outro = "nas_ip" if campo == "usuario" else "usuario"
        resumo = c.execute(f"SELECT {outro} chave, COUNT(*) n, SUM(resultado='negado') neg, MAX(ts) ultimo FROM eventos WHERE {campo}=? AND ts>=? AND {outro}!='' GROUP BY {outro} ORDER BY n DESC LIMIT 10", (valor, ini)).fetchall()
        tot7 = c.execute(f"SELECT COUNT(*), COALESCE(SUM(resultado='negado'),0), MAX(ts) FROM eventos WHERE {campo}=? AND ts>=?", (valor, ini)).fetchone()
        stotal, sess = _sessoes(c, f" AND {campo}=?", [valor], 1)
    finally:
        c.close()
    if total == 0 and not sess:
        abort(404)
    return render_template("entidade.html", rotulo=rotulo, valor=valor, campo=campo, resumo=resumo, tot7=tot7, f=f, total=total, linhas=linhas, p=p,
                           paginas=max(1, -(-total // TAM_PAG)), qs=qs_sem_p(), sess=sess[:10], base=request.path,
                           campo_q=urlencode({campo_filtro[campo]: valor}))


campo_filtro = {"usuario": "usuario", "nas_ip": "nas"}


@app.route("/usuario/<path:nome>")
def pagina_usuario(nome):
    return _pagina_entidade("usuario", nome, "Usuário")


@app.route("/equipamento/<path:ip>")
def pagina_equipamento(ip):
    return _pagina_entidade("nas_ip", ip, "Equipamento")
