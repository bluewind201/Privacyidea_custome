#!/bin/sh
# privacyIDEA 컨테이너 엔트리포인트
#  - 필수 시크릿 존재 여부 확인
#  - DB 가 응답할 때까지 대기
#  - PI_AUTO_MIGRATE=true 이면 스키마 생성/업그레이드
set -eu

for f in enckey audit_key_private audit_key_public; do
  if [ ! -r "/run/secrets/$f" ]; then
    echo "[entrypoint] 오류: /run/secrets/$f 를 읽을 수 없습니다. scripts/setup.sh 를 먼저 실행하세요." >&2
    exit 1
  fi
done

if [ "${PI_DB_HOST:-}" != "" ]; then
  i=0
  until python - <<'PY'
import os, socket, sys
s = socket.socket()
s.settimeout(2)
try:
    s.connect((os.environ["PI_DB_HOST"], int(os.environ.get("PI_DB_PORT", "3306"))))
except OSError:
    sys.exit(1)
PY
  do
    i=$((i + 1))
    if [ "$i" -ge 60 ]; then
      echo "[entrypoint] 오류: DB(${PI_DB_HOST}) 에 연결할 수 없습니다." >&2
      exit 1
    fi
    sleep 2
  done
fi

if [ "${PI_AUTO_MIGRATE:-true}" = "true" ] && [ "$1" = "gunicorn" ]; then
  # 최초 기동: 테이블 생성 + 리비전 스탬프 / 이후: 최신 스키마로 업그레이드 (멱등)
  if pi-manage db current 2>/dev/null | grep -Eq '^[0-9a-f]{8,}'; then
    echo "[entrypoint] DB 스키마 업그레이드 확인"
    pi-manage db upgrade
  else
    echo "[entrypoint] 신규 DB: 테이블 생성"
    pi-manage setup create_tables
  fi
fi

exec "$@"
