# syntax=docker/dockerfile:1
#
# FreeRADIUS 3.2 + privacyIDEA rlm_perl 플러그인 (시놀로지 Container Manager 용)
#  - 공식 freeradius/freeradius-server 이미지 기반 (BlastRADIUS 대응 3.2.5+)
#  - 플러그인은 커밋 고정 + SHA-256 검증
#  - freerad(비루트)로 실행, 기본 사이트/EAP 등 불필요한 모듈 전부 제거
#
ARG FREERADIUS_IMAGE=freeradius/freeradius-server:3.2.7
FROM ${FREERADIUS_IMAGE}

ARG PI_RADIUS_PLUGIN_COMMIT=d4c789fcc1ba14396d8c7e436f66cb0d1962295e
ARG PI_RADIUS_PLUGIN_SHA256=d5b54a94ebb844ec83f5ee744aff2246d833ba62411a94d25b5d3265bd2bcfbf

RUN apt-get update \
 && apt-get upgrade -y \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      ca-certificates \
      libconfig-inifiles-perl libdata-dump-perl libtry-tiny-perl libjson-perl \
      liburi-encode-perl libwww-perl liblwp-protocol-https-perl \
 && rm -rf /var/lib/apt/lists/*

ADD --checksum=sha256:${PI_RADIUS_PLUGIN_SHA256} \
    https://raw.githubusercontent.com/privacyidea/FreeRADIUS/${PI_RADIUS_PLUGIN_COMMIT}/privacyidea_radius.pm \
    /usr/share/privacyidea/freeradius/privacyidea_radius.pm

# 최소 구성: 기본 사이트/모듈을 모두 비활성화하고 privacyIDEA 사이트만 사용
RUN chmod 0644 /usr/share/privacyidea/freeradius/privacyidea_radius.pm \
 && rm -f /etc/raddb/sites-enabled/* /etc/raddb/mods-enabled/* \
 && ln -s ../mods-available/always /etc/raddb/mods-enabled/always \
 && rm -rf /etc/raddb/certs/* \
 && ln -sf /tmp/raddb/clients.conf /etc/raddb/clients.conf \
 && sed -i \
      -e 's#^run_dir = .*#run_dir = /tmp/raddb#' \
      -e 's#^logdir = .*#logdir = /tmp/raddb#' \
      -e 's#^\(\s*\)status_server = yes#\1status_server = no#' \
      -e 's#^\(\s*\)require_message_authenticator = .*#\1require_message_authenticator = auto#' \
      -e 's#^\(\s*\)limit_proxy_state = .*#\1limit_proxy_state = auto#' \
      /etc/raddb/radiusd.conf \
 && : > /etc/raddb/proxy.conf

COPY --chmod=0644 raddb/mods-enabled/ /etc/raddb/mods-enabled/
COPY --chmod=0644 raddb/sites-enabled/ /etc/raddb/sites-enabled/
COPY --chmod=0755 entrypoint.sh /usr/local/bin/pi-radius-entrypoint.sh

RUN chown -R root:freerad /etc/raddb \
 && find /etc/raddb -type d -exec chmod 0750 {} + \
 && find /etc/raddb -type f -exec chmod 0640 {} +

USER freerad
EXPOSE 1812/udp

HEALTHCHECK --interval=60s --timeout=5s --start-period=20s --retries=3 \
  CMD ["sh", "-c", "grep -qx freeradius /proc/[0-9]*/comm"]

ENTRYPOINT ["/usr/local/bin/pi-radius-entrypoint.sh"]
CMD ["freeradius", "-f", "-l", "stdout"]
