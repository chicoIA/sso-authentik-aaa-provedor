# TACACS+ (tac_plus-ng, Marc Huber) com backend MAVIS LDAP (Perl Net::LDAP).
# Compilado a partir de um commit FIXO do repositório (não use "master" solto).
# Para atualizar: escolha um commit, troque TACPLUS_COMMIT e rode ./provedor up tacacs.

ARG DEBIAN_TAG=12-slim

# ---------- estágio 1: compilação ----------
FROM debian:${DEBIAN_TAG} AS build
ARG TACPLUS_REPO=https://github.com/MarcJHuber/event-driven-servers
# 2026-09-14, anterior a qualquer mudança recente do upstream
ARG TACPLUS_COMMIT=d020c75ff6336806e8cd31fee06da8d8d7eec384
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates git make patch perl clang libc6-dev \
      libpcre2-dev libc-ares-dev libssl-dev \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /src
RUN git init -q . \
 && git fetch -q --depth 1 "$TACPLUS_REPO" "$TACPLUS_COMMIT" \
 && git checkout -q FETCH_HEAD \
 && test "$(git rev-parse HEAD)" = "$TACPLUS_COMMIT"
# Ajuste mínimo no script MAVIS LDAP: falha na busca de um grupo não derruba o login.
COPY mavis_tacplus-ng_ldap.patch /tmp/mavis_tacplus-ng_ldap.patch
RUN patch mavis/perl/mavis_tacplus-ng_ldap.pl /tmp/mavis_tacplus-ng_ldap.patch
# Só o tac_plus-ng (com spawnd e MAVIS); sem a documentação.
RUN ./configure --without-doc --prefix=/usr/local --installroot=/pacote tac_plus-ng \
 && make -j2 \
 && make install \
 && ls -l /pacote/usr/local/sbin /pacote/usr/local/lib/mavis

# ---------- estágio 2: imagem final ----------
FROM debian:${DEBIAN_TAG}
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      perl libnet-ldap-perl libio-socket-ssl-perl \
      libpcre2-8-0 libc-ares2 libssl3 libcrypt1 tzdata ca-certificates util-linux \
 && rm -rf /var/lib/apt/lists/* \
 && groupadd -r -g 4949 tacacs \
 && useradd -r -u 4949 -g tacacs -d /nonexistent -s /usr/sbin/nologin tacacs \
 && mkdir -p /var/log/tacacs /etc/tacacs /run/tacacs \
 && chown tacacs:tacacs /var/log/tacacs /run/tacacs
COPY --from=build /pacote/usr/local/ /usr/local/
RUN ln -sf libmavis.so.0.1 /usr/local/lib/libmavis.so && ldconfig
COPY tac_plus-ng.cfg.modelo /etc/tacacs/tac_plus-ng.cfg.modelo
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod 0755 /usr/local/bin/entrypoint.sh
EXPOSE 4949/tcp
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
