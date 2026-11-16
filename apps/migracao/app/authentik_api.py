"""Cliente mínimo da API do authentik (só biblioteca padrão)."""

import json
import os
import ssl
import urllib.error
import urllib.parse
import urllib.request


def carregar_env(caminho=".env"):
    """Lê um arquivo KEY=VALUE (formato do docker compose) para os.environ.

    Variáveis já definidas no ambiente têm prioridade.
    """
    if not caminho or not os.path.exists(caminho):
        return
    with open(caminho, encoding="utf-8") as arquivo:
        for linha in arquivo:
            linha = linha.strip()
            if not linha or linha.startswith("#") or "=" not in linha:
                continue
            chave, valor = linha.split("=", 1)
            valor = valor.strip()
            if len(valor) >= 2 and valor[0] == valor[-1] and valor[0] in "'\"":
                valor = valor[1:-1]
            os.environ.setdefault(chave.strip(), valor)


class ErroAPI(Exception):
    def __init__(self, metodo, caminho, status, corpo):
        super().__init__(f"{metodo} {caminho} -> HTTP {status}: {corpo}")
        self.status = status
        self.corpo = corpo


class Authentik:
    def __init__(self, url, token, inseguro=False, simular=False):
        self.base = url.rstrip("/") + "/api/v3/"
        self.token = token
        self.simular = simular
        self.contexto = None
        if inseguro:
            self.contexto = ssl.create_default_context()
            self.contexto.check_hostname = False
            self.contexto.verify_mode = ssl.CERT_NONE

    def requisicao(self, metodo, caminho, dados=None, parametros=None):
        url = self.base + caminho.lstrip("/")
        if parametros:
            url += "?" + urllib.parse.urlencode(parametros)
        corpo = None
        cabecalhos = {
            "Authorization": f"Bearer {self.token}",
            "Accept": "application/json",
        }
        if dados is not None:
            corpo = json.dumps(dados).encode()
            cabecalhos["Content-Type"] = "application/json"
        pedido = urllib.request.Request(url, data=corpo, method=metodo, headers=cabecalhos)
        try:
            with urllib.request.urlopen(pedido, context=self.contexto, timeout=30) as resposta:
                conteudo = resposta.read()
        except urllib.error.HTTPError as erro:
            raise ErroAPI(metodo, caminho, erro.code, erro.read().decode(errors="replace")) from None
        if not conteudo:
            return None
        return json.loads(conteudo)

    def get(self, caminho, **parametros):
        return self.requisicao("GET", caminho, parametros=parametros or None)

    def listar(self, caminho, **parametros):
        parametros.setdefault("page_size", 100)
        pagina = 1
        while True:
            dados = self.get(caminho, page=pagina, **parametros)
            yield from dados["results"]
            if not dados["pagination"]["next"]:
                return
            pagina = dados["pagination"]["next"]

    def escrever(self, metodo, caminho, dados=None):
        """POST/PATCH/PUT/DELETE; em modo simulação só retorna None."""
        if self.simular:
            return None
        return self.requisicao(metodo, caminho, dados=dados)
