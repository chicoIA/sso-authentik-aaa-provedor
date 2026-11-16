"""Teste do cálculo de atributos e do mapeamento (roda dentro da imagem, ver teste_unitario.sh).

Usa o MariaDB descartável com tests/daloradius_exemplo.sql (DALO_DB_* do ambiente).
"""
import os
import sys
import tempfile
from argparse import Namespace

sys.path.insert(0, "/app")
import migrar_daloradius as m  # noqa: E402


def confere(cond, msg):
    if not cond:
        print(f"FALHA: {msg}")
        sys.exit(1)
    print(f"ok: {msg}")


# --- arquivo users (conteúdo fictício no formato do FreeRADIUS) ---------------
with tempfile.NamedTemporaryFile("w", suffix=".users", delete=False) as f:
    f.write('# comentario\ndatacom\tCleartext-Password := "teste-fixo"\n\tService-Type = Administrative-User,\n'
            '\tReply-Message = "ola, mundo"\n\nDEFAULT\tFramed-Protocol == PPP\n\tFramed-Protocol = PPP,\n'
            '\tFramed-Compression = Van-Jacobson-TCP-IP\n')
    arq = f.name
ent = m.ler_arquivo_users(arq)
confere(list(ent) == ["datacom"], "arquivo users: DEFAULT ignorado")
confere(len(ent["datacom"][1]) == 2, "arquivo users: dois itens de resposta (vírgula dentro de aspas preservada)")
u = {}
m.incorporar_arquivo_users(u, arq)
confere(u["datacom"].senha == "teste-fixo" and u["datacom"].reply[0] == "Service-Type = Administrative-User",
        "datacom: senha e resposta migradas")
os.unlink(arq)

# --- semântica de := = += ----------------------------------------------------
r = {}
m.aplicar_linhas(r, ["A := 1", "A = 2", "B = 3", "B = 4", "C += x", "C += y", "D == z"])
confere(r == {"A": ["1"], "B": ["3"], "C": ["x", "y"]}, "operadores :=, =, += e == iguais ao mapping")

# --- avisos de senha sem revelar a senha -------------------------------------
confere("senha igual ao usuário" in m.avaliar_senha("zabbix", "zabbix"), "senha igual ao usuário")
confere(not any("segredo" in a for a in m.avaliar_senha("segredo-longo-123", "x")), "aviso não repete a senha")

# --- banco de exemplo ---------------------------------------------------------
args = Namespace(db_socket="", db_host=os.environ["DALO_DB_HOST"], db_porta="3306",
                 db_usuario=os.environ["DALO_DB_USER"], db_senha=os.environ["DALO_DB_PASS"],
                 db_nome="radius", db_cnf="")
con = m.conectar_mysql(args)
us, gr = m.ler_daloradius(con)
m.finalizar(us, gr)
try:
    with con.cursor() as c:
        c.execute("DELETE FROM radcheck")
    gravou = True
except Exception:
    gravou = False
confere(not gravou, "sessão é somente leitura (DELETE recusado)")

confere(us["carlos"].ativo is False and us["ana"].ativo is False, "Reject e Expiration vencida desativam")
confere(us["joao"].ativo and us["joao"].senha == "SenhaJoao#2024", "usuário ativo com senha")
confere(us["pedro"].senha is None, "senha em hash não é migrada")
confere(any("';'" in a for a in us["tecnico1"].avisos), "aviso de ';' na senha")
confere(gr["noc"].prioridade == 1 and gr["campo"].prioridade == 2, "prioridade do grupo")

esp = m.resposta_daloradius(us["joao"], gr)
confere(esp == {"Service-Type": ["Administrative-User"], "Mikrotik-Group": ["full"],
                "Huawei-Exec-Privilege": ["15"], "Cisco-AVPair": ["shell:priv-lvl=15"]},
        "resposta do daloRADIUS para joao (grupo noc)")
esp_m = m.resposta_daloradius(us["maria"], gr)
confere(esp_m["Reply-Message"] == ["Bem-vinda, Maria"] and esp_m["Mikrotik-Group"] == ["read"],
        "radreply do usuário + grupo suporte")

# O que o authentik calcularia com os dados migrados bate com o daloRADIUS (exceto atributo desconhecido).
sup = m.suportados_envio()
grupos_ak = [{"name": n, "attributes": {"radius_reply": g.reply, "radius_prioridade": g.prioridade}}
             for n, g in gr.items()]
for nome in ("joao", "maria"):
    usr = us[nome]
    obtido = m.resposta_authentik({"radius_reply": usr.reply},
                                  [g for g in grupos_ak if g["name"] in [n for _, n in usr.grupos]], sup)
    difs = m.comparar_respostas(m.resposta_daloradius(usr, gr), obtido)
    confere(difs == [] if nome == "joao" else difs == ["falta Fabricante-Desconhecido-Attr = ['x']"],
            f"verificar: cálculo do authentik de {nome} "
            f"{'igual' if nome == 'joao' else 'aponta o atributo que o authentik não envia'}")

# Tabela de fabricantes igual à do blueprint, se estiver montado.
bp = "/blueprint-radius/02-radius-equipamentos.yaml"
if os.path.exists(bp):
    import re
    achados = set(re.findall(r'^\s+"([A-Za-z0-9-]+)": \(\d+,', open(bp, encoding="utf-8").read(), re.M))
    confere(achados == set(m.FABRICANTES), "FABRICANTES igual ao blueprint do app radius")
print("TUDO OK")
