#!/bin/sh
# FreeRADIUS 엔트리포인트: 환경변수/시크릿으로 clients.conf, rlm_perl.ini 를 tmpfs 에 생성
set -eu

die() { echo "[radius] 오류: $*" >&2; exit 1; }

RUN_DIR=/tmp/raddb
mkdir -p "$RUN_DIR"
chmod 0700 "$RUN_DIR"
umask 077

: "${PI_VALIDATE_URL:?PI_VALIDATE_URL 이 필요합니다 (예: https://pi.example.local:8443/validate/check)}"
: "${PALOALTO_IPS:?PALOALTO_IPS 가 필요합니다 (Palo Alto 방화벽의 RADIUS 요청 출발지 IP)}"

SECRET_FILE="${RADIUS_SECRET_FILE:-/run/secrets/radius_client_secret}"
[ -r "$SECRET_FILE" ] || die "$SECRET_FILE 를 읽을 수 없습니다."
SECRET=$(tr -d '\r\n' < "$SECRET_FILE")
[ "${#SECRET}" -ge 16 ] || die "RADIUS 공유 비밀은 16자 이상이어야 합니다."
case "$SECRET" in
  *\"*|*\\*) die "RADIUS 공유 비밀에 \" 또는 \\ 문자를 쓸 수 없습니다." ;;
esac

CA_FILE="${PI_CA_FILE:-/etc/pi-ca/ca.crt}"
if [ "${PI_TLS_VERIFY:-true}" = "true" ]; then
  SSL_CHECK=true
  [ -r "$CA_FILE" ] || die "privacyIDEA 인증서 검증용 CA($CA_FILE)를 읽을 수 없습니다."
  # LWP::UserAgent 가 이 CA 번들로 서버 인증서와 호스트 이름을 검증한다
  export PERL_LWP_SSL_CA_FILE="$CA_FILE"
  export HTTPS_CA_FILE="$CA_FILE"
else
  SSL_CHECK=false
  echo "[radius] 경고: PI_TLS_VERIFY=false - privacyIDEA 서버 인증서를 검증하지 않습니다!" >&2
fi

# ---- clients.conf -----------------------------------------------------------
{
  echo "# 자동 생성 파일 - 수정하지 마세요 (PALOALTO_IPS 환경변수로 관리)"
  n=0
  for ip in $(echo "$PALOALTO_IPS" | tr ',' ' '); do
    n=$((n + 1))
    case "$ip" in
      *[!0-9a-fA-F.:/]*) die "PALOALTO_IPS 형식 오류: $ip" ;;
    esac
    cat <<CLIENT
client paloalto-$n {
	ipaddr = $ip
	secret = "$SECRET"
	shortname = paloalto-$n
	nas_type = other
	require_message_authenticator = ${RADIUS_REQUIRE_MESSAGE_AUTHENTICATOR:-auto}
	limit_proxy_state = ${RADIUS_LIMIT_PROXY_STATE:-auto}
	virtual_server = privacyidea
	limit {
		max_connections = 16
	}
}
CLIENT
  done
  if [ "${RADIUS_ALLOW_LOCALHOST_TEST:-false}" = "true" ]; then
    cat <<CLIENT
client localhost-test {
	ipaddr = 127.0.0.1
	secret = "$SECRET"
	require_message_authenticator = no
	virtual_server = privacyidea
}
CLIENT
  fi
} > "$RUN_DIR/clients.conf"

# ---- rlm_perl.ini -----------------------------------------------------------
case "$PI_VALIDATE_URL" in
  https://*) ;;
  *) [ "${PI_ALLOW_HTTP:-false}" = "true" ] || die "PI_VALIDATE_URL 은 https:// 여야 합니다." ;;
esac

{
  echo "[Default]"
  echo "URL = $PI_VALIDATE_URL"
  [ -n "${PI_REALM:-}" ] && echo "REALM = $PI_REALM"
  echo "SSL_CHECK = $SSL_CHECK"
  echo "TIMEOUT = ${PI_TIMEOUT:-10}"
  # DEBUG=true 는 비밀번호가 로그에 남으므로 사용 금지
  echo "DEBUG = false"
  # 팔로알토가 보내는 실제 사용자 공인 IP 를 privacyIDEA 의 client 로 전달
  [ -n "${PI_CLIENT_ATTRIBUTE-PaloAlto-Client-Source-IP}" ] && \
    echo "CLIENTATTRIBUTE = ${PI_CLIENT_ATTRIBUTE-PaloAlto-Client-Source-IP}"
  if [ -n "${PI_GROUP_ATTRIBUTE:-}" ]; then
    # privacyIDEA 사용자 속성(예: AD memberOf 의 DN 목록)에서 그룹 이름(CN)을 뽑아
    # PaloAlto-User-Group 으로 돌려준다. (privacyIDEA 쪽 add_user_in_response 정책 필요)
    echo ""
    echo "[Attribute PaloAlto-User-Group]"
    echo "dir = user"
    echo "userAttribute = ${PI_GROUP_ATTRIBUTE}"
    echo "regex = ${PI_GROUP_REGEX:-^CN=([^,]+),}"
    echo "prefix ="
    echo "suffix ="
  fi
} > "$RUN_DIR/rlm_perl.ini"

exec "$@"
