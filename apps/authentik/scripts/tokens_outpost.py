#!/usr/bin/env python3
"""Busca os tokens dos outposts provedor-radius e provedor-ldap e grava no .env.

Rode depois que o authentik subir e aplicar os blueprints:

    python3 apps/authentik/scripts/tokens_outpost.py           # só confere
    python3 apps/authentik/scripts/tokens_outpost.py --gravar  # grava AUTHENTIK_RADIUS_TOKEN / AUTHENTIK_LDAP_TOKEN

Os tokens nunca são impressos.
"""

import argparse
import json
import os
import re
import sys
import urllib.error
import urllib.request
from pathlib import Path

RAIZ = Path(__file__).resolve().parents[3]
API = "http://127.0.0.1:9000/api/v3"
OUTPOSTS = {
    "provedor-radius": "AUTHENTIK_RADIUS_TOKEN",
    "provedor-ldap": "AUTHENTIK_LDAP_TOKEN",
}


def ler_env(caminho):
    valores = {}
    if not caminho.exists():
        return valores
    for linha in caminho.read_text(encoding="utf-8").splitlines():
        linha = linha.strip()
        if not linha or linha.startswith("#") or "=" not in linha:
            continue
        chave, valor = linha.split("=", 1)
        valor = valor.strip()
        if len(valor) >= 2 and valor[0] == valor[-1] and valor[0] in "'\"":
            valor = valor[1:-1]
        valores[chave.strip()] = valor
    return valores


def chamar(caminho, token):
    pedido = urllib.request.Request(
        API + caminho, headers={"Authorization": f"Bearer {token}", "Accept": "application/json"}
    )
    with urllib.request.urlopen(pedido, timeout=30) as resposta:
        return json.loads(resposta.read())


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--env", default=str(RAIZ / ".env"))
    parser.add_argument("--gravar", action="store_true", help="grava os tokens no .env")
    args = parser.parse_args()

    env_path = Path(args.env)
    token = os.environ.get("AUTHENTIK_BOOTSTRAP_TOKEN") or ler_env(env_path).get("AUTHENTIK_BOOTSTRAP_TOKEN")
    if not token or token.startswith("<"):
        sys.exit("AUTHENTIK_BOOTSTRAP_TOKEN não definido no .env")

    encontrados = {}
    try:
        outposts = chamar("/outposts/instances/?page_size=100", token)["results"]
        for outpost in outposts:
            variavel = OUTPOSTS.get(outpost["name"])
            if not variavel:
                continue
            identificador = f"ak-outpost-{outpost['pk']}-api"
            try:
                encontrados[variavel] = chamar(f"/core/tokens/{identificador}/view_key/", token)["key"]
                print(f"{outpost['name']}: token lido")
            except urllib.error.HTTPError as erro:
                print(f"{outpost['name']}: não consegui ler o token (HTTP {erro.code})", file=sys.stderr)
    except (urllib.error.URLError, OSError) as erro:
        sys.exit(f"Falha ao falar com o authentik em {API}: {getattr(erro, 'reason', erro)}")

    if not encontrados:
        sys.exit("Nenhum outpost provedor-radius/provedor-ldap encontrado. Os blueprints já foram aplicados?")

    if args.gravar:
        texto = env_path.read_text(encoding="utf-8") if env_path.exists() else ""
        for variavel, chave in encontrados.items():
            if re.search(rf"^{variavel}=.*$", texto, re.M):
                texto = re.sub(rf"^{variavel}=.*$", lambda _: f"{variavel}={chave}", texto, flags=re.M)
            else:
                texto += ("" if texto.endswith("\n") or not texto else "\n") + f"{variavel}={chave}\n"
        env_path.write_text(texto, encoding="utf-8")
        os.chmod(env_path, 0o600)
        print(f"Gravado em {env_path}: {', '.join(sorted(encontrados))}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
