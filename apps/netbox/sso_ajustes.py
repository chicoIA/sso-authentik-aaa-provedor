# Ajustes do login SSO do NetBox (docs/netbox-sso.md), para rodar no nbshell do pod:
#
#   kubectl -n <ns> exec -i deploy/<netbox> -- /opt/netbox/venv/bin/python \
#       /opt/netbox/netbox/manage.py nbshell < apps/netbox/sso_ajustes.py
#
# Sem APLICAR=1 só mostra o que faria. Para gravar, trocar "-- /opt/..." por
# "-- env APLICAR=1 /opt/...". Pode rodar mais de uma vez.
#
# 1. Permissões dos grupos do SSO (criados no primeiro login pelo provedor_sso.papel):
#      SSO leitura  view em todos os objetos
#      SSO editor   view/add/change/delete em todos, menos usuários, grupos,
#                   permissões e tokens (isso fica com o netbox-admin)
# 2. Contas duplicadas: o social-auth cria "nome<hex>" quando já existe "nome" local.
#    Passa o vínculo SSO para a conta original (que guarda histórico e tokens) e
#    apaga a duplicada. Grupos e superusuário são acertados no próximo login SSO.
import os
import re

from core.models import ObjectType
from social_django.models import UserSocialAuth
from users.models import Group, ObjectPermission, User

APLICAR = os.environ.get("APLICAR") == "1"
print("MODO:", "APLICANDO" if APLICAR else "SÓ MOSTRANDO (APLICAR=1 para gravar)")

try:
    TIPOS = list(ObjectType.objects.public())
except AttributeError:
    TIPOS = list(ObjectType.objects.all())
SENSIVEIS = {"users", "auth", "authtoken", "social_django", "sessions", "admin", "contenttypes"}
PERMS = {
    "SSO leitura": (["view"], TIPOS),
    "SSO editor": (["view", "add", "change", "delete"],
                   [t for t in TIPOS if t.app_label not in SENSIVEIS]),
}

print("\n== Permissões ==")
for grupo, (acoes, tipos) in PERMS.items():
    nome = f"{grupo} (SSO)"
    print(f"{nome}: {acoes} em {len(tipos)} tipos de objeto")
    if not APLICAR:
        continue
    g, _ = Group.objects.get_or_create(name=grupo)
    p, _ = ObjectPermission.objects.get_or_create(name=nome, defaults={"actions": acoes})
    p.actions = acoes
    p.enabled = True
    p.description = "Gerenciada por apps/netbox/sso_ajustes.py (authentik netbox-*)"
    p.save()
    p.object_types.set(tipos)
    p.groups.add(g)

print("\n== Contas duplicadas pelo SSO ==")
achou = False
for s in UserSocialAuth.objects.select_related("user"):
    m = re.fullmatch(r"(.+?)([0-9a-f]{8,32})", s.user.username)
    if not m:
        continue
    orig = User.objects.filter(username=m.group(1)).exclude(pk=s.user.pk).first()
    if not orig:
        continue
    achou = True
    print(f"{s.user.username} -> {orig.username} (original superusuário={orig.is_superuser})")
    if APLICAR:
        dup = s.user
        s.user = orig
        s.save()
        orig.is_active = True
        orig.save()
        dup.delete()
if not achou:
    print("nenhuma")
print("\nOK" if APLICAR else "\nNada gravado.")
