# Pipeline do python-social-auth para o login SSO do NetBox (docs/netbox-sso.md).
# Copiar para o diretório netbox/netbox/ (ao lado do configuration.py) e incluir
# "netbox.provedor_sso.papel" no fim de SOCIAL_AUTH_PIPELINE.
#
# A cada login lê o claim "groups" do authentik e ajusta a conta:
#   netbox-admin    superusuário
#   netbox-editor   grupo "SSO editor" do NetBox (permissões dadas na tela do NetBox)
#   netbox-leitura  grupo "SSO leitura" do NetBox
# Quem não está em nenhum: o authentik já recusa antes (bindings da aplicação).
try:
    from users.models import Group  # NetBox 4.x
except ImportError:
    from django.contrib.auth.models import Group  # NetBox 3.x

GRUPOS = {"netbox-editor": "SSO editor", "netbox-leitura": "SSO leitura"}


def papel(response, user=None, *args, **kwargs):
    if user is None:
        return
    grupos = set(response.get("groups") or [])
    user.is_superuser = "netbox-admin" in grupos
    user.save()
    for sso, nome in GRUPOS.items():
        g, _ = Group.objects.get_or_create(name=nome)
        if sso in grupos:
            user.groups.add(g)
        else:
            user.groups.remove(g)
