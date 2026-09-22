# Config Sync (Forgejo) for Home Assistant.
#
# Home Assistant's Alpine base image (bashio and s6 included), plus git and
# the OpenSSH client. Same base tag and digest as the HA SOC apps; bump the
# tag and digest together (docker buildx imagetools inspect).
ARG BUILD_FROM=ghcr.io/home-assistant/base:3.24@sha256:93ef607824e3f27e868f11b10938283a98bf880ed57bcf8eaa81c6c2d521f6f5
FROM ${BUILD_FROM}

# git: the sync engine. openssh-client: ssh transport and ssh-keygen for the
# generated deploy key. ca-certificates: public CAs for HTTPS remotes; a
# private CA comes from the operator via ca_certificate_file. jq reads the
# list options bashio cannot iterate. Nothing else that opens a connection
# is added; BusyBox's own network applets are removed from the PATH.
RUN apk upgrade --no-cache \
    && apk add --no-cache \
        bash \
        ca-certificates \
        git \
        jq \
        openssh-client \
    && rm -f /usr/bin/tempio /usr/bin/nc /usr/bin/wget /usr/bin/telnet /usr/bin/ftpget /usr/bin/ftpput /usr/bin/tftp

COPY rootfs /
RUN chmod 0755 \
    /etc/services.d/config_sync/run \
    /etc/services.d/config_sync/finish \
    /usr/local/bin/config_sync.sh \
    /usr/local/bin/config_sync_askpass

LABEL \
    org.opencontainers.image.title="Config Sync (Forgejo)" \
    org.opencontainers.image.description="Two-way git synchronization of the Home Assistant configuration directory with a Forgejo repository." \
    org.opencontainers.image.source="https://github.com/trooperthorn/ha_app_config_sync" \
    org.opencontainers.image.licenses="MIT"
