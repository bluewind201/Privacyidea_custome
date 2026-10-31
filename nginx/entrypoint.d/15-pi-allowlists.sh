#!/bin/sh
# 환경변수의 허용 대역 목록을 Nginx allow/deny 포함 파일로 변환한다.
#   PI_WEB_ALLOWED_NETS      : WebUI/관리 API 에 접근 가능한 대역
#   PI_VALIDATE_ALLOWED_NETS : /validate (RADIUS 서버) 에 접근 가능한 대역
set -eu

out=/etc/nginx/conf.d

gen() {
  file="$1"; nets="$2"
  {
    echo "# 자동 생성 - 수정하지 마세요"
    for net in $(echo "$nets" | tr ',' ' '); do
      case "$net" in
        *[!0-9a-fA-F.:/]*) echo "[nginx] 잘못된 대역: $net" >&2; exit 1 ;;
      esac
      echo "allow $net;"
    done
    echo "deny all;"
  } > "$out/$file"
}

gen allow-web.inc      "${PI_WEB_ALLOWED_NETS:-127.0.0.1/32}"
gen allow-validate.inc "${PI_VALIDATE_ALLOWED_NETS:-127.0.0.1/32}"
