# 운영 가이드

## 사용자와 토큰

### 사용자 저장소

- **LDAP/AD (권장)**: `.env` 에 `PI_USERSTORE=ldap`, `LDAP_*` 입력, 바인드 비밀번호는 `secrets/ldap_bind_password`,
  LDAPS CA 는 `certs/ldap/` 에 넣고 `LDAP_CA_FILE=/etc/privacyidea/ldap-ca/파일명` → `./scripts/setup.sh bootstrap`
  - Active Directory: `LDAP_PRESET=ad` (로그인 이름 `sAMAccountName`)
  - 시놀로지 LDAP Server: `LDAP_PRESET=openldap`, 예) `LDAP_URI=ldaps://nas.example.local`,
    `LDAP_BASE_DN=dc=example,dc=local`, `LDAP_BIND_DN=uid=svc-pi,cn=users,dc=example,dc=local`
- **internal**: WebUI → Users → 사용자 추가 (privacyIDEA DB 에 저장, 비밀번호도 privacyIDEA 가 관리)

### 토큰 등록 방법

1. **셀프서비스 (기본)**: 사용자가 `https://<PI_HOSTNAME>:8443/` 에 AD 비밀번호로 로그인 →
   Token Enrollment → TOTP → QR 스캔 → 6자리 입력으로 확인. 사용자당 1개.
2. **관리자 등록**: WebUI → Tokens → Enroll Token → 사용자 지정 → QR 을 사용자에게 전달.
3. **휴대폰 분실/교체**: 관리자가 기존 토큰 삭제(또는 비활성화) → 사용자가 다시 등록.

### 잠금 해제

```bash
./scripts/pi.sh locked                # 잠긴 사용자, 차단 IP 보기
./scripts/pi.sh unlock 홍길동          # 사용자 잠금 해제 (조건부 접근)
./scripts/pi.sh unblock 203.0.113.5   # IP 차단 해제
```

토큰 자체의 실패 횟수 초과는 10분 뒤 자동 해제되며, 즉시 풀려면 WebUI → Tokens → 해당 토큰 → *Reset Fail Counter*.

## 설정 변경

1. `.env` 수정
2. `./scripts/setup.sh bootstrap` (컨테이너 재생성 + 정책 재적용)

`hard-` 로 시작하는 정책은 bootstrap 때마다 `.env` 값으로 덮어써집니다. WebUI 에서 직접 바꾸고 싶은
정책은 다른 이름으로 새로 만드세요. 조건부 접근 정책은 이미 있으면 건드리지 않으므로 WebUI
(*Conditional Access*)에서 자유롭게 조정할 수 있습니다.

## 백업과 복원

```bash
./scripts/pi.sh backup
# 비대화식 (작업 스케줄러): 암호 파일을 root 만 읽게 만들고
PI_BACKUP_PASSPHRASE_FILE=/root/.pi-backup-pass ./scripts/pi.sh backup
```

`backups/privacyidea-날짜.tar.gz.enc` 에 DB 덤프 + `secrets/` + `certs/` + `.env` 가 AES-256 으로 암호화되어
저장되고, 30일 지난 파일은 삭제됩니다. NAS 밖(Hyper Backup 대상, 오프라인 저장소)에도 보관하세요.

복원 (새 서버)

```bash
openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 -in privacyidea-XXXX.tar.gz.enc | tar -xzf - -C /복원폴더
cd 저장소; cp -a /복원폴더/{secrets,certs,.env} .
sudo ./scripts/setup.sh secrets            # 권한만 다시 맞춤 (기존 파일 유지)
docker compose up -d db
docker compose exec -T db sh -c 'mariadb -uroot -p"$(cat /run/secrets/db_root_password)" privacyidea' < /복원폴더/privacyidea.sql
docker compose up -d
```

## 정기 작업 (시놀로지 작업 스케줄러)

제어판 → 작업 스케줄러 → 생성 → 예약된 작업 → 사용자 정의 스크립트, 사용자 `root`

| 작업 | 주기 | 스크립트 |
|---|---|---|
| 로그 정리 | 매일 03:00 | `/volume1/docker/privacyidea/scripts/pi.sh maintenance` |
| 백업 | 매일 03:30 | `PI_BACKUP_PASSPHRASE_FILE=/root/.pi-backup-pass /volume1/docker/privacyidea/scripts/pi.sh backup` |

maintenance 는 감사 로그(50만 건 초과 시 30만 건으로, 180일 초과 삭제), 인증 로그(90일),
만료된 잠금/차단을 정리합니다.

## 업데이트

```bash
git pull
docker compose build --pull
docker compose up -d          # 시작 시 DB 스키마 자동 업그레이드 (PI_AUTO_MIGRATE)
./scripts/setup.sh bootstrap
```

privacyIDEA 버전을 올릴 때는 `privacyidea/Dockerfile` 의 `PI_VERSION` 과 `PI_WHEEL_SHA256`
(https://pypi.org/project/privacyidea/#files 의 wheel SHA256)을 함께 바꾸고, 먼저 백업하세요.

## 인증서 갱신

서버 인증서는 825일 유효합니다. 만료 전에

```bash
mv certs/server.crt certs/server.crt.old && mv certs/server.key certs/server.key.old
sudo ./scripts/setup.sh secrets      # 같은 CA 로 재발급 (CA 는 10년)
docker compose restart nginx
```

CA 가 같으므로 FreeRADIUS 와 PC 쪽은 바꿀 필요가 없습니다.

## 로그와 문제 해결

```bash
./scripts/pi.sh logs privacyidea     # 앱
./scripts/pi.sh logs nginx           # 접속 (IP, 경로, 상태코드)
./scripts/pi.sh logs radius          # RADIUS
```

| 증상 | 원인 / 조치 |
|---|---|
| 브라우저 403 | 접속 PC 대역이 `PI_WEB_ALLOWED_NETS` 에 없음. Nginx 로그의 client 가 `172.31.250.1` 이면 시놀로지 Docker 의 출발지 변환 → `docs/synology-freeradius.md` 마지막 절 |
| 브라우저 429 | 로그인 시도 과다 (1분에 10회) → 잠시 후 재시도 |
| RADIUS 403 (`request failed: 403`) | RADIUS 서버 IP 가 `PI_RADIUS_SOURCES` 에 없음 |
| `db` 로그에 `/run/secrets/db_root_password: Permission denied` | 시놀로지 공유 폴더 ACL 때문에 컨테이너 UID 가 시크릿을 못 읽음 → `sudo ./scripts/setup.sh secrets` (ACL 제거 + 권한 재설정 + 읽기 확인) 후 `sudo docker compose up -d` |
| `privacyidea` 컨테이너 재시작 반복 | `docker compose logs privacyidea` - 시크릿 권한(`sudo ./scripts/setup.sh secrets`) 또는 DB 연결 |
| 사용자 IP 가 방화벽 IP 로만 보임 | Palo Alto 가 `PaloAlto-Client-Source-IP` 를 보내지 않는 구성 → IP 차단(`PI_CA_IP_ENFORCE`)은 끈 상태 유지 |
| 디버그가 필요 | `.env` 에서 `PI_LOGLEVEL=DEBUG` → `docker compose up -d`, **확인 후 즉시 INFO 로 복귀** (요청 값이 로그에 남을 수 있음) |

## 웹 화면 (한국어 / 디자인)

- 브라우저 언어가 한국어면 한국어 화면이 나옵니다. 언어 메뉴에서 바꿀 수도 있습니다.
  번역은 `privacyidea/webui-ko/ko.json` 에 있으며, 이미지를 빌드할 때 한국어 화면 묶음(`browser/ko`)이 만들어집니다.
  privacyIDEA 버전을 올리면 빌드 로그의 `[ko] 번역 대상 N 곳 중 M 곳 번역` 비율을 확인하세요.
  80% 아래로 떨어지면 빌드가 실패합니다.
- 디자인은 `.env` 의 `PI_WEBUI_THEME` 로 고릅니다.
  - `profile` (기본): 미색 배경, 흰 카드, 검정 알약 버튼. 사이드바 위쪽이 프로필 카드 모양 (topmate 스타일)
  - `top`: 사이드바 없이 상단 메뉴 + 가운데 정렬 본문, 보라 포인트
  - `rail`: 좁은 보라 아이콘 레일 사이드바, 연보라 배경
  - `glass`: 보라/파랑 그라데이션 배경, 유리 질감 왼쪽 사이드바, 반투명 카드
  - `none`: privacyIDEA 원본 디자인
  - 바꾼 뒤에는 `docker compose build privacyidea && docker compose up -d` 를 실행하세요.
  - 스타일은 `privacyidea/webui-ko/themes/` 에 있습니다.
    `base.css`(공통 간격/카드) + `sidebar.css`(사이드바 배치) + 시안별 색상 파일을 합쳐 씁니다.
  - 화면 폭이 1000px 보다 좁으면 사이드바 대신 상단 메뉴로 바뀝니다.
