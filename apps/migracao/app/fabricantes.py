"""Atributos de fabricante que o property mapping do authentik sabe enviar.

CÓPIA da tabela FABRICANTES de apps/radius/blueprints/02-radius-equipamentos.yaml.
Se adicionar um atributo lá, adicione aqui (tests/teste_calculo.py compara os dois
quando o blueprint está montado em /blueprint-radius).
nome no FreeRADIUS: (vendor id, vendor, atributo, código, tipo)
"""

FABRICANTES = {
    "Mikrotik-Group": (14988, "Mikrotik", "Group", 3, "string"),
    "Huawei-Exec-Privilege": (2011, "Huawei", "Exec-Privilege", 29, "integer"),
    "Cisco-AVPair": (9, "Cisco", "AVPair", 1, "string"),
    "Juniper-Local-User-Name": (2636, "Juniper", "Local-User-Name", 1, "string"),
    "Juniper-Allow-Commands": (2636, "Juniper", "Allow-Commands", 2, "string"),
    "Juniper-Deny-Commands": (2636, "Juniper", "Deny-Commands", 3, "string"),
    "Fortinet-Group-Name": (12356, "Fortinet", "Group-Name", 1, "string"),
    "Fortinet-Vdom-Name": (12356, "Fortinet", "Vdom-Name", 3, "string"),
    "Fortinet-Access-Profile": (12356, "Fortinet", "Access-Profile", 6, "string"),
    "H3C-Exec-Privilege": (25506, "H3C", "Exec-Privilege", 29, "integer"),
    "HP-Privilege-Level": (11, "HP", "Privilege-Level", 1, "integer"),
    "HP-Command-String": (11, "HP", "Command-String", 2, "string"),
    "ZTE-SW-Privilege": (3902, "ZTE", "SW-Privilege", 104, "integer"),
    "Timetra-Profile": (6527, "Timetra", "Profile", 4, "string"),
    "Ruckus-User-Groups": (25053, "Ruckus", "User-Groups", 1, "string"),
    "Brocade-Auth-Role": (1588, "Brocade", "Auth-Role", 1, "string"),
}
