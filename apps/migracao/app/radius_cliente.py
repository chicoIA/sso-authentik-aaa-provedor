"""Cliente RADIUS mínimo (PAP) só com a biblioteca padrão, para o "verificar --radius"."""

import hashlib
import hmac
import os
import socket
import struct

from fabricantes import FABRICANTES

# Atributos RFC que costumam voltar nas respostas: código -> (nome, tipo)
PADRAO = {
    6: ("Service-Type", "integer"),
    7: ("Framed-Protocol", "integer"),
    8: ("Framed-IP-Address", "ipaddr"),
    9: ("Framed-IP-Netmask", "ipaddr"),
    10: ("Framed-Routing", "integer"),
    11: ("Filter-Id", "string"),
    12: ("Framed-MTU", "integer"),
    13: ("Framed-Compression", "integer"),
    14: ("Login-IP-Host", "ipaddr"),
    15: ("Login-Service", "integer"),
    16: ("Login-TCP-Port", "integer"),
    18: ("Reply-Message", "string"),
    22: ("Framed-Route", "string"),
    25: ("Class", "string"),
    27: ("Session-Timeout", "integer"),
    28: ("Idle-Timeout", "integer"),
    29: ("Termination-Action", "integer"),
    62: ("Port-Limit", "integer"),
    85: ("Acct-Interim-Interval", "integer"),
    88: ("Framed-Pool", "string"),
}
# Atributos que o outpost/protocolo põe na resposta e que não vêm do daloRADIUS.
IGNORADOS = {"Message-Authenticator", "Proxy-State", "State", "EAP-Message"}
ENUMS = {
    "Service-Type": {1: "Login-User", 2: "Framed-User", 3: "Callback-Login-User",
                     4: "Callback-Framed-User", 5: "Outbound-User", 6: "Administrative-User",
                     7: "NAS-Prompt-User"},
    "Framed-Protocol": {1: "PPP", 2: "SLIP"},
}
POR_VENDOR = {(v[0], v[3]): (nome, v[4]) for nome, v in FABRICANTES.items()}


class ErroRadius(Exception):
    pass


def _valor(nome, tipo, bruto):
    if tipo in ("integer", "ipaddr") and len(bruto) == 4:
        if tipo == "ipaddr":
            return ".".join(str(b) for b in bruto)
        n = struct.unpack(">I", bruto)[0]
        return ENUMS.get(nome, {}).get(n, str(n))
    return bruto.decode("utf-8", "replace")


def decodificar(dados):
    """Bytes de atributos -> {nome: [valores como texto]}."""
    atributos = {}
    i = 0
    while i + 2 <= len(dados):
        tipo, tam = dados[i], dados[i + 1]
        if tam < 2 or i + tam > len(dados):
            break
        bruto = dados[i + 2:i + tam]
        i += tam
        if tipo == 26 and len(bruto) > 6:
            vendor = struct.unpack(">I", bruto[:4])[0]
            sub = bruto[4:]
            codigo, tam_sub = sub[0], sub[1]
            nome, tp = POR_VENDOR.get((vendor, codigo), (f"Vendor-{vendor}-{codigo}", "string"))
            atributos.setdefault(nome, []).append(_valor(nome, tp, sub[2:tam_sub]))
        elif tipo == 80:
            continue
        else:
            nome, tp = PADRAO.get(tipo, (f"Atributo-{tipo}", "string"))
            if nome in IGNORADOS:
                continue
            atributos.setdefault(nome, []).append(_valor(nome, tp, bruto))
    return atributos


def _cifrar_senha(senha, segredo, autenticador):
    senha = senha.encode()
    if len(senha) > 128:
        raise ErroRadius("senha maior que 128 bytes não cabe no PAP")
    senha += b"\0" * (-len(senha) % 16 or (16 if not senha else 0))
    saida, anterior = b"", autenticador
    for i in range(0, len(senha), 16):
        chave = hashlib.md5(segredo + anterior).digest()
        bloco = bytes(a ^ b for a, b in zip(senha[i:i + 16], chave))
        saida += bloco
        anterior = bloco
    return saida


def autenticar(host, porta, segredo, usuario, senha, tentativas=3, timeout=5):
    """Access-Request PAP. Retorna ('accept'|'reject'|'outro', {atributos})."""
    segredo = segredo.encode()
    ident = os.urandom(1)[0]
    autenticador = os.urandom(16)
    attrs = b""
    for tipo, valor in ((1, usuario.encode()), (32, b"migracao"),
                        (2, _cifrar_senha(senha, segredo, autenticador))):
        attrs += struct.pack("BB", tipo, len(valor) + 2) + valor
    attrs += struct.pack("BB", 80, 18) + b"\0" * 16
    cab = struct.pack(">BBH", 1, ident, 20 + len(attrs)) + autenticador
    ma = hmac.new(segredo, cab + attrs, hashlib.md5).digest()
    pacote = cab + attrs[:-16] + ma
    ultimo = None
    for _ in range(tentativas):
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
            sock.settimeout(timeout)
            sock.sendto(pacote, (host, porta))
            try:
                resp, _ = sock.recvfrom(4096)
            except socket.timeout:
                ultimo = ErroRadius("sem resposta do outpost (timeout)")
                continue
        codigo, rid, tam = struct.unpack(">BBH", resp[:4])
        if rid != ident or tam > len(resp):
            raise ErroRadius("resposta com identificador inválido")
        esperado = hashlib.md5(resp[:4] + autenticador + resp[20:tam] + segredo).digest()
        if resp[4:20] != esperado:
            raise ErroRadius("autenticador da resposta inválido: AUTHENTIK_RADIUS_SECRET incorreto?")
        nome = {2: "accept", 3: "reject"}.get(codigo, "outro")
        return nome, decodificar(resp[20:tam])
    raise ultimo
