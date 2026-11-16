# FreeRADIUS na frente do authentik (substitui o FreeRADIUS do daloRADIUS na virada):
#   - atende os equipamentos com os mesmos NAS/segredos (tabela "nas", só leitura)
#   - PAP: encaminha ao outpost RADIUS do authentik, com cache curto em memória
#   - CHAP/MS-CHAP: modo legado pelo SQL do daloRADIUS (radcheck/radgroup*)
#   - accounting/post-auth: log (teste) ou radacct/radpostauth (produção)
FROM freeradius/freeradius-server:3.2.10

# Valores padrão (o compose sobrescreve). Também permitem "freeradius -XC" na imagem.
ENV FR_PORTA_AUTH=1812 \
    FR_PORTA_ACCT=1813 \
    FR_CACHE_TTL=300 \
    FR_CACHE_RESERVA_TTL=604800 \
    FR_CACHE_TRAVA_TTL=25 \
    FR_PORTA_REVALIDA=18121 \
    FR_CHAP_LEGADO=sim \
    FR_GRAVAR_SQL=nao \
    FR_EXIGIR_MSGAUTH=no \
    AUTHENTIK_OUTPOST_IP=127.0.0.1 \
    OUTPOST_RADIUS_PORTA=18120

# Sites padrão e EAP padrão (depende do inner-tunnel) saem; entra o EAP mínimo.
RUN rm -f /etc/freeradius/sites-enabled/default \
          /etc/freeradius/sites-enabled/inner-tunnel \
          /etc/freeradius/mods-enabled/eap \
 # O FreeRADIUS 3.2.10 passou a exigir Message-Authenticator de todos os clientes
 # (proteção BlastRADIUS). O 3.2.1 de produção não exigia e os equipamentos atuais
 # (Mikrotik, Huawei...) podem não enviar: mantém o comportamento de hoje.
 && grep -c '^\s*require_message_authenticator = yes' /etc/freeradius/radiusd.conf | grep -qx 1 \
 && sed -i 's|^\(\s*\)require_message_authenticator = yes|\1require_message_authenticator = $ENV{FR_EXIGIR_MSGAUTH}|' /etc/freeradius/radiusd.conf \
 && sed -i 's|^\(\s*\)max_servers = 32|\1max_servers = 128|' /etc/freeradius/radiusd.conf \
 && grep -q 'max_servers = 128' /etc/freeradius/radiusd.conf

COPY raddb/ /etc/freeradius/
COPY docker-entrypoint.sh /usr/local/bin/provedor-entrypoint
RUN chmod 0755 /usr/local/bin/provedor-entrypoint \
 && ln -sf ../sites-available/provedor /etc/freeradius/sites-enabled/provedor \
 && ln -sf ../mods-available/sql /etc/freeradius/mods-enabled/sql \
 && ln -sf ../mods-available/provedor /etc/freeradius/mods-enabled/provedor \
 && ln -sf ../mods-available/eap /etc/freeradius/mods-enabled/eap \
 && chown -R freerad:freerad /etc/freeradius

HEALTHCHECK --interval=30s --timeout=5s --retries=3 \
  CMD echo "Message-Authenticator = 0x00" | radclient -r 1 -t 3 127.0.0.1:${FR_PORTA_AUTH} status "$FR_SEGREDO_LOCAL" >/dev/null || exit 1

# Log em stdout: "docker compose logs freeradius".
ENTRYPOINT ["/usr/local/bin/provedor-entrypoint"]
CMD ["freeradius", "-f", "-l", "stdout"]
