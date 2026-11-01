#!/usr/bin/env bash
# =============================================================================
#  privacyIDEA 운영 도우미
#
#    ./scripts/pi.sh status                 컨테이너 상태
#    ./scripts/pi.sh logs [서비스]           로그 보기 (privacyidea | nginx | radius | db)
#    ./scripts/pi.sh locked                 잠긴 사용자 / 차단된 IP 목록
#    ./scripts/pi.sh unlock 사용자 [realm]   사용자 잠금 해제
#    ./scripts/pi.sh unblock IP             IP 차단 해제
#    ./scripts/pi.sh admin-password         관리자 비밀번호 변경 (프롬프트 입력)
#    ./scripts/pi.sh backup                 DB + 시크릿 암호화 백업 → backups/
#    ./scripts/pi.sh maintenance            감사로그/인증로그/만료 잠금 정리 (작업 스케줄러용)
#    ./scripts/pi.sh manage ...             pi-manage 명령 직접 실행
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

compose() {
  if docker compose version >/dev/null 2>&1; then docker compose "$@"; else docker-compose "$@"; fi
}
pim() { compose exec -T privacyidea pi-manage "$@" 2>&1 | grep -v '^\[20'; }
env_get() { grep -E "^$1=" .env 2>/dev/null | tail -n1 | cut -d= -f2- || true; }

cmd="${1:-help}"; shift || true
case "$cmd" in
  status) compose ps ;;
  logs)   compose logs --tail=200 -f "$@" ;;
  locked)
    pim conditionalaccess list-locked-users
    pim conditionalaccess list-blocked-ips
    ;;
  unlock)
    [ $# -ge 1 ] || { echo "사용법: $0 unlock 사용자 [realm]"; exit 1; }
    pim conditionalaccess unlock-user "$1" --realm "${2:-$(env_get PI_REALM)}"
    ;;
  unblock)
    [ $# -ge 1 ] || { echo "사용법: $0 unblock IP"; exit 1; }
    pim conditionalaccess unblock-ip "$1"
    ;;
  admin-password)
    user="$(env_get PI_ADMIN_USER)"; user="${user:-admin}"
    read -r -s -p "새 관리자 비밀번호 ($user, 12자 이상): " p1; echo
    read -r -s -p "다시 입력: " p2; echo
    [ "$p1" = "$p2" ] || { echo "불일치"; exit 1; }
    [ "${#p1}" -ge 12 ] || { echo "12자 이상 입력하세요"; exit 1; }
    printf '%s' "$p1" | compose exec -T privacyidea sh -c \
      'read -r p; pi-manage admin change "$0" --password "$p"' "$user" 2>&1 | grep -v '^\[20'
    ;;
  backup)
    mkdir -p backups; chmod 0700 backups
    ts="$(date +%Y%m%d-%H%M%S)"
    tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
    compose exec -T db sh -c \
      'exec mariadb-dump --single-transaction --routines -uroot -p"$(cat /run/secrets/db_root_password)" privacyidea' \
      > "$tmp/privacyidea.sql"
    cp -a secrets certs .env "$tmp/"
    # enckey 가 없으면 DB 의 토큰 비밀값을 복호화할 수 없으므로 시크릿을 함께 보관하되 암호화한다
    if [ -n "${PI_BACKUP_PASSPHRASE_FILE:-}" ] && [ -r "$PI_BACKUP_PASSPHRASE_FILE" ]; then
      pass_opt=(-pass "file:$PI_BACKUP_PASSPHRASE_FILE")
    else
      pass_opt=()
      echo "백업 암호를 입력하세요 (복원 시 필요, 분실하면 복구 불가):"
    fi
    tar -C "$tmp" -czf - . | openssl enc -aes-256-cbc -pbkdf2 -iter 600000 -salt "${pass_opt[@]}" \
      -out "backups/privacyidea-$ts.tar.gz.enc"
    chmod 0600 "backups/privacyidea-$ts.tar.gz.enc"
    # 30일 지난 백업 삭제
    find backups -name 'privacyidea-*.tar.gz.enc' -mtime +30 -delete
    echo "백업 완료: backups/privacyidea-$ts.tar.gz.enc"
    echo "복호화: openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 -in <파일> | tar -xzf -"
    ;;
  maintenance)
    # 감사 로그: 50만 건 초과 시 30만 건으로 정리, 180일 이상 삭제
    pim audit rotate --highwatermark 500000 --lowwatermark 300000
    pim audit rotate --age 180
    pim authlog cleanup --age 90
    pim conditionalaccess purge-expired-locks
    pim conditionalaccess purge-expired-blocks
    ;;
  manage) pim "$@" ;;
  *) sed -n '2,15p' "$0" ;;
esac
