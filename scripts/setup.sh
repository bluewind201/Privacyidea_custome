#!/usr/bin/env bash
# =============================================================================
#  privacyIDEA 하드닝 스택 설치/관리 스크립트
#
#  사용법 (프로젝트 루트에서, 시놀로지는 sudo 로):
#    ./scripts/setup.sh              최초 설치 (질문 → .env/시크릿/인증서 생성 → 기동 → 정책 적용)
#    ./scripts/setup.sh -y           질문 없이 .env(.env.example) 값으로 설치
#    ./scripts/setup.sh --no-build   이미 빌드된 이미지로 설치 (오프라인/사전 빌드 시)
#    ./scripts/setup.sh bootstrap    .env 를 바꾼 뒤 정책/설정만 다시 적용
#    ./scripts/setup.sh secrets      시크릿/인증서만 생성 (이미 있으면 유지)
#    ./scripts/setup.sh status       상태 확인
#    ./scripts/setup.sh info         Palo Alto/RADIUS 설정에 필요한 값 출력
#
#  기존 시크릿/인증서는 절대 덮어쓰지 않는다. (enckey 를 잃으면 모든 토큰이 무효화됨)
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SECRETS="$ROOT/secrets"
CERTS="$ROOT/certs"
ENV_FILE="$ROOT/.env"
ASSUME_YES=false
SKIP_BUILD=false

PI_UID=10001
DB_UID=999
NGINX_UID=101
RADIUS_UID=101

c_info()  { printf '\033[1;34m[*]\033[0m %s\n' "$*"; }
c_ok()    { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
c_warn()  { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
c_err()   { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; }
die()     { c_err "$*"; exit 1; }

is_root() { [ "$(id -u)" -eq 0 ]; }

# ---------------------------------------------------------------------------
# docker compose 명령 탐지 (시놀로지 Container Manager 는 docker-compose 일 수 있음)
# ---------------------------------------------------------------------------
compose() {
  if docker compose version >/dev/null 2>&1; then
    docker compose "$@"
  elif command -v docker-compose >/dev/null 2>&1; then
    docker-compose "$@"
  else
    die "docker compose 를 찾을 수 없습니다. Docker / Container Manager 를 설치하세요."
  fi
}

need() { command -v "$1" >/dev/null 2>&1 || die "'$1' 명령이 필요합니다."; }

# ---------------------------------------------------------------------------
# .env 읽기/쓰기
# ---------------------------------------------------------------------------
env_get() {
  local key="$1"
  [ -f "$ENV_FILE" ] || return 0
  grep -E "^${key}=" "$ENV_FILE" | tail -n1 | cut -d= -f2- || true
}

env_set() {
  local key="$1" value="$2" tmp
  tmp="$(mktemp)"
  if grep -qE "^${key}=" "$ENV_FILE"; then
    awk -v k="$key" -v v="$value" 'BEGIN{FS=OFS="="} $1==k {print k "=" v; next} {print}' \
      "$ENV_FILE" > "$tmp"
  else
    cat "$ENV_FILE" > "$tmp"
    printf '%s=%s\n' "$key" "$value" >> "$tmp"
  fi
  cat "$tmp" > "$ENV_FILE"
  rm -f "$tmp"
}

ask() {
  # ask KEY "질문" [기본값]
  local key="$1" question="$2" def cur answer
  cur="$(env_get "$key")"
  def="${3:-$cur}"
  if $ASSUME_YES; then
    env_set "$key" "$def"
    return
  fi
  read -r -p "$question [${def}]: " answer || true
  env_set "$key" "${answer:-$def}"
}

valid_ip_list() {
  local item
  for item in $(echo "$1" | tr ',' ' '); do
    [[ "$item" =~ ^[0-9a-fA-F.:]+(/[0-9]{1,3})?$ ]] || return 1
  done
}

configure_env() {
  if [ ! -f "$ENV_FILE" ]; then
    cp "$ROOT/.env.example" "$ENV_FILE"
    chmod 0600 "$ENV_FILE"
    c_ok ".env 생성 (.env.example 복사)"
  else
    c_info "기존 .env 사용 - 엔터를 누르면 현재 값을 유지합니다."
  fi

  local default_ip
  default_ip="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
  [ "$(env_get PI_SERVER_IP)" = "192.168.0.10" ] && [ -n "$default_ip" ] && env_set PI_SERVER_IP "$default_ip"

  echo
  c_info "기본 설정"
  ask PI_HOSTNAME   "privacyIDEA 접속 호스트 이름 (DNS/hosts 에 등록할 이름)"
  ask PI_SERVER_IP  "이 서버의 IP (인증서에 포함)"
  ask PI_HTTPS_PORT "HTTPS 포트 (시놀로지는 443 대신 8443 권장)"
  ask PI_WEB_ALLOWED_NETS "WebUI 접근 허용 대역 (공백 구분)"

  echo
  c_info "Palo Alto / RADIUS"
  ask PALOALTO_IPS "Palo Alto 방화벽의 RADIUS 요청 출발지 IP (공백 구분)"
  local mode
  if $ASSUME_YES; then
    mode="$( [ -n "$(env_get COMPOSE_PROFILES)" ] && echo local || echo remote )"
  else
    read -r -p "FreeRADIUS 위치: [1] 이 서버에서 같이 실행  [2] 시놀로지 등 다른 장비 (기본 1): " mode || true
    case "${mode:-1}" in 2) mode=remote ;; *) mode=local ;; esac
  fi
  if [ "$mode" = "local" ]; then
    env_set COMPOSE_PROFILES radius
    local internal_ip
    internal_ip="$(env_get PI_RADIUS_INTERNAL_IP)"
    case " $(env_get PI_RADIUS_SOURCES) " in
      *" ${internal_ip:-172.31.250.20} "*) ;;
      *) env_set PI_RADIUS_SOURCES "${internal_ip:-172.31.250.20} $(env_get PI_RADIUS_SOURCES)" ;;
    esac
  else
    env_set COMPOSE_PROFILES ""
    ask PI_RADIUS_SOURCES "FreeRADIUS 를 실행할 장비(시놀로지 NAS)의 IP"
  fi

  echo
  c_info "사용자 저장소"
  ask PI_REALM "realm 이름"
  ask PI_USERSTORE "사용자 저장소 (internal | ldap)"
  if [ "$(env_get PI_USERSTORE)" = "ldap" ]; then
    ask LDAP_PRESET  "LDAP 종류 (ad | openldap[시놀로지 LDAP Server])"
    ask LDAP_URI     "LDAP URI (ldaps:// 권장)"
    ask LDAP_BASE_DN "Base DN"
    ask LDAP_BIND_DN "Bind DN (서비스 계정)"
    if [ ! -s "$SECRETS/ldap_bind_password" ] && ! $ASSUME_YES; then
      local pw
      read -r -s -p "Bind 비밀번호 (secrets/ldap_bind_password 에 저장): " pw; echo
      mkdir -p "$SECRETS"
      printf '%s' "$pw" > "$SECRETS/ldap_bind_password"
    fi
  fi

  for k in PALOALTO_IPS PI_RADIUS_SOURCES PI_WEB_ALLOWED_NETS; do
    valid_ip_list "$(env_get "$k")" || die "$k 형식이 잘못되었습니다: $(env_get "$k")"
  done

  if [ -z "$(env_get PI_NODE_UUID)" ]; then
    env_set PI_NODE_UUID "$(cat /proc/sys/kernel/random/uuid 2>/dev/null || openssl rand -hex 16 | sed -E 's/(.{8})(.{4})(.{4})(.{4})(.{12})/\1-\2-\3-\4-\5/')"
  fi
  c_ok ".env 저장 완료"
}

# ---------------------------------------------------------------------------
# 시크릿 / 인증서
# ---------------------------------------------------------------------------
rand_alnum() { openssl rand -base64 96 | LC_ALL=C tr -dc 'A-Za-z0-9' | cut -c1-"$1"; }

new_secret() {
  # new_secret 파일명 생성명령...
  local f="$SECRETS/$1"; shift
  if [ -s "$f" ]; then
    return 0
  fi
  "$@" > "$f"
  c_ok "시크릿 생성: secrets/$(basename "$f")"
}

generate_secrets() {
  need openssl
  mkdir -p "$SECRETS"
  chmod 0700 "$SECRETS"
  umask 077

  new_secret db_password          rand_alnum 40
  new_secret db_root_password     rand_alnum 40
  new_secret pi_pepper            rand_alnum 48
  new_secret pi_secret_key        rand_alnum 64
  new_secret pi_admin_password    rand_alnum 20
  # Palo Alto 공유 비밀: 특수문자 없이 32자 (PAN-OS 최대 64자)
  new_secret radius_client_secret rand_alnum 32
  new_secret enckey               head -c 96 /dev/urandom
  if [ ! -s "$SECRETS/audit_key_private" ]; then
    openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:3072 -out "$SECRETS/audit_key_private" 2>/dev/null
    openssl pkey -in "$SECRETS/audit_key_private" -pubout -out "$SECRETS/audit_key_public"
    c_ok "시크릿 생성: secrets/audit_key_private, audit_key_public (RSA 3072)"
  fi
  [ -f "$SECRETS/ldap_bind_password" ] || : > "$SECRETS/ldap_bind_password"
}

generate_certs() {
  local host ip
  host="$(env_get PI_HOSTNAME)"; ip="$(env_get PI_SERVER_IP)"
  [ -n "$host" ] || die "PI_HOSTNAME 이 비어 있습니다."
  mkdir -p "$CERTS" "$CERTS/ldap"
  umask 077

  if [ ! -s "$CERTS/ca.crt" ]; then
    # 사설 CA: 키는 secrets/ 에만 보관하고 어떤 컨테이너에도 마운트하지 않는다
    openssl req -x509 -new -nodes -newkey ec -pkeyopt ec_paramgen_curve:P-256 \
      -keyout "$SECRETS/ca.key" -out "$CERTS/ca.crt" -days 3650 -sha256 \
      -subj "/O=privacyIDEA Docker/CN=privacyIDEA Local CA" \
      -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
      -addext "keyUsage=critical,keyCertSign,cRLSign" 2>/dev/null
    c_ok "사설 CA 생성: certs/ca.crt (PC/방화벽에 신뢰 CA 로 등록)"
  fi

  if [ ! -s "$CERTS/server.crt" ]; then
    [ -s "$SECRETS/ca.key" ] || die "certs/server.crt 가 없고 secrets/ca.key 도 없습니다. 직접 발급한 인증서를 certs/server.crt, certs/server.key 로 넣으세요."
    local san="DNS:${host},DNS:localhost"
    [ -n "$ip" ] && san="${san},IP:${ip}"
    local ext; ext="$(mktemp)"
    cat > "$ext" <<EOF
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=${san}
EOF
    openssl req -new -nodes -newkey ec -pkeyopt ec_paramgen_curve:P-256 \
      -keyout "$CERTS/server.key" -out "$CERTS/server.csr" -subj "/CN=${host}" 2>/dev/null
    openssl x509 -req -in "$CERTS/server.csr" -CA "$CERTS/ca.crt" -CAkey "$SECRETS/ca.key" \
      -CAcreateserial -CAserial "$SECRETS/ca.srl" -out "$CERTS/server.crt" -days 825 -sha256 \
      -extfile "$ext" 2>/dev/null
    rm -f "$ext" "$CERTS/server.csr"
    c_ok "서버 인증서 생성: certs/server.crt (SAN: ${san})"
  fi
}

strip_synology_acl() {
  # 시놀로지 공유 폴더(/volume1/...)는 Windows 식 ACL 이 상속되어, chown/chmod 를 해도
  # 컨테이너 UID(999, 10001, 101)가 파일을 읽지 못한다 ("Permission denied").
  # secrets/ 와 certs/ 에서만 ACL 을 제거해 일반 리눅스 권한으로 되돌린다.
  command -v synoacltool >/dev/null 2>&1 || return 0
  is_root || { c_warn "시놀로지 ACL 제거는 root 권한이 필요합니다: sudo ./scripts/setup.sh secrets"; return 0; }
  local p
  for p in "$SECRETS" "$CERTS"; do
    [ -e "$p" ] || continue
    synoacltool -del "$p" >/dev/null 2>&1 || true
    find "$p" -mindepth 1 -exec synoacltool -del {} \; >/dev/null 2>&1 || true
  done
  c_ok "시놀로지 ACL 제거: secrets/, certs/"
}

# 각 컨테이너 UID 로 실제로 파일을 읽어 본다. (권한 문제를 기동 전에 잡기 위함)
check_secret_access() {
  local img; img="$(env_get PI_DB_IMAGE 2>/dev/null || true)"; img="${img:-mariadb:11.4}"
  docker image inspect "$img" >/dev/null 2>&1 || docker pull -q "$img" >/dev/null 2>&1 || return 0
  local bad=0 spec uid file
  for spec in \
      "$DB_UID:$SECRETS/db_root_password" "$DB_UID:$SECRETS/db_password" \
      "$PI_UID:$SECRETS/db_password" "$PI_UID:$SECRETS/enckey" "$PI_UID:$SECRETS/pi_pepper" \
      "$PI_UID:$SECRETS/pi_secret_key" "$PI_UID:$SECRETS/audit_key_private" \
      "$NGINX_UID:$CERTS/server.key" "$RADIUS_UID:$SECRETS/radius_client_secret"; do
    uid="${spec%%:*}"; file="${spec#*:}"
    [ -f "$file" ] || continue
    if ! docker run --rm --network none --user "$uid:$uid" -v "$file:/check:ro" \
           --entrypoint cat "$img" /check >/dev/null 2>&1; then
      c_err "UID $uid 가 ${file#"$ROOT"/} 를 읽을 수 없습니다."
      bad=1
    fi
  done
  if [ "$bad" -ne 0 ]; then
    c_err "sudo ./scripts/setup.sh secrets 로 다시 시도하고, 계속되면 아래 결과를 확인하세요:"
    c_err "  sudo ls -ln secrets certs ; sudo synoacltool -get secrets/db_root_password"
    return 1
  fi
  c_ok "컨테이너별 시크릿 읽기 확인"
}

fix_permissions() {
  # 각 컨테이너는 서로 다른 비루트 UID 로 실행되므로 파일 소유자를 맞춘다.
  # 시크릿 디렉터리는 0700 이라 호스트의 다른 사용자는 접근할 수 없다.
  strip_synology_acl
  chmod 0700 "$SECRETS"
  chmod 0644 "$CERTS/ca.crt" "$CERTS/server.crt"
  if is_root; then
    local f
    for f in pi_pepper pi_secret_key pi_admin_password enckey audit_key_private \
             audit_key_public ldap_bind_password; do
      chown "$PI_UID:$PI_UID" "$SECRETS/$f"; chmod 0400 "$SECRETS/$f"
    done
    chown "$DB_UID:$DB_UID" "$SECRETS/db_root_password"; chmod 0400 "$SECRETS/db_root_password"
    # DB 와 privacyIDEA 가 함께 읽는 파일
    chown "root:root" "$SECRETS/db_password"; chmod 0444 "$SECRETS/db_password"
    chown "$RADIUS_UID:$RADIUS_UID" "$SECRETS/radius_client_secret"; chmod 0400 "$SECRETS/radius_client_secret"
    chown "$NGINX_UID:$NGINX_UID" "$CERTS/server.key"; chmod 0400 "$CERTS/server.key"
    chown root:root "$SECRETS/ca.key" 2>/dev/null && chmod 0400 "$SECRETS/ca.key" || true
  else
    c_warn "root 가 아니므로 시크릿을 0444 로 둡니다 (secrets/ 디렉터리 자체는 0700)."
    c_warn "운영 환경에서는 sudo ./scripts/setup.sh secrets 로 소유자를 컨테이너 UID 로 맞추세요."
    find "$SECRETS" -type f ! -name 'ca.key' ! -name 'ca.srl' -exec chmod 0444 {} +
    chmod 0444 "$CERTS/server.key"
  fi
}

# ---------------------------------------------------------------------------
# 기동 / 부트스트랩
# ---------------------------------------------------------------------------
wait_healthy() {
  local svc="$1" i cid state
  for i in $(seq 1 90); do
    cid="$(compose ps -q "$svc" 2>/dev/null || true)"
    if [ -n "$cid" ]; then
      state="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$cid" 2>/dev/null || true)"
      [ "$state" = "healthy" ] && return 0
    fi
    sleep 2
  done
  compose logs --tail=50 "$svc" >&2 || true
  die "$svc 가 정상 상태가 되지 않았습니다."
}

start_stack() {
  c_info "이미지 빌드 및 컨테이너 기동 (처음에는 수 분 걸립니다)"
  $SKIP_BUILD || compose build
  compose up -d
  wait_healthy privacyidea
  wait_healthy nginx
  c_ok "privacyIDEA / Nginx 정상"
}

bootstrap() {
  c_info "관리자 / 사용자 저장소 / 보안 정책 적용"
  compose exec -T privacyidea pi-bootstrap.py
}

print_info() {
  local host port profiles
  host="$(env_get PI_HOSTNAME)"; port="$(env_get PI_HTTPS_PORT)"; profiles="$(env_get COMPOSE_PROFILES)"
  cat <<EOF

=====================================================================
 privacyIDEA 설치 정보
=====================================================================
 WebUI           : https://${host}:${port}/
 관리자 계정     : $(env_get PI_ADMIN_USER)
 관리자 비밀번호 : secrets/pi_admin_password 파일 (sudo cat 으로 확인 후 WebUI 에서 변경 권장)
 사설 CA 인증서  : certs/ca.crt  → PC, Palo Alto 에 신뢰 CA 로 등록

 [Palo Alto RADIUS 서버 프로필]
   서버 IP       : $( [ -n "$profiles" ] && env_get PI_SERVER_IP || echo "시놀로지 NAS IP" )
   포트          : $(env_get RADIUS_AUTH_PORT) (UDP)
   공유 비밀     : secrets/radius_client_secret 파일 내용
   인증 프로토콜 : PAP
   타임아웃/재시도: 10초 / 1회  (OTP 챌린지 입력 시간을 고려해 넉넉히)
   허용된 방화벽 : $(env_get PALOALTO_IPS)

 자세한 절차: docs/paloalto.md, docs/synology-freeradius.md
=====================================================================
EOF
}

status() {
  compose ps
}

main() {
  local cmd="install"
  while [ $# -gt 0 ]; do
    case "$1" in
      -y|--yes) ASSUME_YES=true ;;
      --no-build) SKIP_BUILD=true ;;
      install|bootstrap|secrets|status|info) cmd="$1" ;;
      -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
      *) die "알 수 없는 인자: $1" ;;
    esac
    shift
  done

  need docker
  case "$cmd" in
    install)
      configure_env
      generate_secrets
      generate_certs
      fix_permissions
      check_secret_access || die "시크릿 권한 문제로 설치를 중단합니다."
      start_stack
      bootstrap
      print_info
      ;;
    secrets)
      [ -f "$ENV_FILE" ] || configure_env
      generate_secrets
      generate_certs
      fix_permissions
      check_secret_access || exit 1
      ;;
    bootstrap)
      # .env 변경 사항을 컨테이너 환경변수에 반영한 뒤 적용
      compose up -d
      wait_healthy privacyidea
      bootstrap
      ;;
    status) status ;;
    info) print_info ;;
  esac
}

main "$@"
