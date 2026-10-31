# privacyIDEA 보안 강화 Docker 환경 (Palo Alto 2차 인증 + 시놀로지 FreeRADIUS)

Palo Alto(GlobalProtect VPN, 관리자 로그인)의 2차 인증을 privacyIDEA 로 처리하기 위한
**보안 강화 + 설치 자동화** Docker 구성입니다. 설치 스크립트 한 번으로 TLS 인증서, 비밀값,
관리자 계정, 인증/잠금 정책까지 안전한 기본값으로 만들어 줍니다.

```
 [사용자 GlobalProtect]
        │ ① ID/비밀번호   ③ OTP 6자리
        ▼
 [Palo Alto 방화벽] ──RADIUS(UDP 1812, PAP)──▶ [FreeRADIUS 3.2 + privacyIDEA 플러그인]   ← 시놀로지 또는 같은 서버
                                                  │ HTTPS (사설 CA 검증, 호스트명 검증)
                                                  ▼
                                   [Nginx: TLS1.2/1.3 · 속도제한 · IP 허용목록 · 보안헤더]
                                                  │ 내부 전용 네트워크
                                                  ▼
                                   [privacyIDEA 3.14 (gunicorn, 비루트)] ──▶ [MariaDB 11.4 (외부 차단)]
                                                  │ (선택) LDAPS
                                                  ▼
                                        [AD / 시놀로지 LDAP Server]
```

인증 흐름: 비밀번호(AD/LDAP) 확인 → **Access-Challenge** 로 OTP 요청 → OTP 확인 → Access-Accept.
사용자가 한 칸에 `비밀번호+OTP` 를 이어서 입력해도 동작합니다.

## 무엇이 강화되었나

| 영역 | 기본 privacyIDEA 설치 | 이 구성 |
|---|---|---|
| 통신 | HTTP 또는 자체서명 TLS, RADIUS 플러그인은 인증서 **검증 안 함**(`SSL_CHECK=false`) | 사설 CA 자동 발급, Nginx TLS1.2/1.3 전용, FreeRADIUS → privacyIDEA 인증서·호스트명 **검증 강제** |
| 비밀값 | `pi.cfg` 에 평문 PEPPER/SECRET_KEY/DB 비밀번호 | 전부 Docker secrets 파일(0400, 컨테이너별 UID 소유), 랜덤 자동 생성, git 제외 |
| 컨테이너 | root 실행 | 모든 컨테이너 비루트·읽기 전용 루트FS·`cap_drop: ALL`·`no-new-privileges`·메모리/PID 제한 |
| 네트워크 | DB/앱 노출 가능 | DB·앱은 **외부 라우팅 없는 내부망**, 외부에는 Nginx 와 RADIUS 포트만 노출 |
| 무차별 대입 | 토큰 실패 횟수만 | 토큰 10회 실패 잠금(10분 후 자동 해제) + **조건부 접근**: 비밀번호 10회 실패 시 사용자 15분 잠금, OTP 3/5/10회 실패 시 단계별 잠금, 분당 실패 제한, 스프레이/사용자 열거 IP 차단(기록 모드로 시작) + Nginx 로그인 속도 제한 |
| IP 위조 | X-Forwarded-For 를 그대로 신뢰하기 쉬움 | Nginx 가 XFF 를 **덮어쓰고**, privacyIDEA 는 Nginx→RADIUS 경로만 신뢰. Palo Alto 가 보낸 **실제 사용자 공인 IP**(`PaloAlto-Client-Source-IP`)로 감사·차단 |
| 정보 노출 | VPN 거부 메시지에 "사용자를 찾을 수 없음" 등 내부 메시지 노출 | RADIUS 거부 메시지를 `Authentication failed` 로 통일, `GET /validate`(비밀번호가 URL/로그에 남음) 차단, 로그에서 쿼리스트링 제거 |
| RADIUS | 기본 사이트·EAP 등 수십 개 모듈 활성 | privacyIDEA 전용 가상서버 1개만, 허용된 방화벽 IP 만 클라이언트, BlastRADIUS(CVE-2024-3596) 대응 `Message-Authenticator`/`limit_proxy_state` |
| 공급망 | `pip install privacyidea` (버전·해시 미고정) | privacyIDEA 휠과 **모든 의존성 SHA-256 해시 고정**, 바이너리 휠만 사용, FreeRADIUS 플러그인 커밋+해시 고정 |
| 셀프서비스 | 설정에 따라 사용자가 토큰 삭제·추가 가능 | 사용자당 토큰 1개, 등록 시 OTP 확인 필수, 사용자 삭제 권한 없음(비밀번호만 탈취된 공격자가 토큰 교체 불가), WebUI 5분 자동 잠금 |
| 웹 보안 헤더 | 없음 | HSTS, CSP, X-Frame-Options, nosniff, Referrer/Permissions-Policy, COOP/CORP |

자세한 내용: [docs/security.md](docs/security.md)

## 빠른 시작

요구사항: Docker 24+ 와 docker compose v2 (시놀로지는 DSM 7.2 Container Manager), openssl, bash.

```bash
git clone https://github.com/bluewind201/Privacyidea_custome.git
cd Privacyidea_custome
sudo ./scripts/setup.sh          # 질문에 답하면 설치·기동·정책 적용까지 완료
```

설치가 끝나면 다음이 출력됩니다.

- WebUI 주소: `https://<PI_HOSTNAME>:8443/` (관리자 `admin`, 비밀번호는 `secrets/pi_admin_password`)
- Palo Alto RADIUS 서버 프로필에 넣을 값 (IP, 포트, 공유 비밀 파일 위치)

그다음 순서대로 진행하세요.

1. **PC 에 사설 CA 등록**: `certs/ca.crt` 를 "신뢰할 수 있는 루트 인증 기관"에 설치 (또는 회사 인증서로 교체, 아래 참고)
2. **관리자 비밀번호 변경**: `./scripts/pi.sh admin-password`
3. **사용자 저장소 연결**: AD/시놀로지 LDAP 을 쓰려면 `.env` 의 `PI_USERSTORE=ldap` 과 `LDAP_*` 를 채우고 `./scripts/setup.sh bootstrap`
4. **FreeRADIUS 를 시놀로지에 설치**: [docs/synology-freeradius.md](docs/synology-freeradius.md)
5. **Palo Alto 설정**: [docs/paloalto.md](docs/paloalto.md)
6. **사용자 토큰 등록**: 사용자가 `https://<PI_HOSTNAME>:8443/` 에 AD 비밀번호로 로그인 → *Token Enrollment* → TOTP → 인증 앱(Google/Microsoft Authenticator 등)으로 QR 스캔 → 표시된 6자리 입력

## 디렉터리 구조

```
docker-compose.yml        전체 스택 (db, privacyidea, nginx, radius[선택])
.env.example              모든 설정값 (setup.sh 가 .env 생성)
privacyidea/              privacyIDEA 이미지 (Dockerfile, gunicorn, pi.cfg, 초기화 스크립트)
nginx/                    리버스 프록시 설정 (TLS, 속도 제한, 허용 대역, 보안 헤더)
radius/                   FreeRADIUS + privacyIDEA 플러그인 이미지
  docker-compose.yml      ← 시놀로지에서 RADIUS 만 따로 실행할 때
scripts/setup.sh          설치 / 정책 재적용 / 상태 / 정보
scripts/pi.sh             운영: 잠금 해제, 백업, 정리, pi-manage
secrets/  certs/          자동 생성되는 비밀값과 인증서 (git 에 올라가지 않음)
docs/                     시놀로지, Palo Alto, 보안, 운영 문서
```

## 자주 쓰는 명령

```bash
./scripts/setup.sh info              # Palo Alto 설정값 다시 보기
./scripts/setup.sh bootstrap         # .env 수정 후 정책/설정 다시 적용
./scripts/pi.sh status               # 상태
./scripts/pi.sh logs privacyidea     # 로그
./scripts/pi.sh locked               # 잠긴 사용자 / 차단 IP
./scripts/pi.sh unlock 홍길동         # 잠금 해제
./scripts/pi.sh backup               # 암호화 백업 (DB + 시크릿) → backups/
./scripts/pi.sh maintenance          # 로그 정리 (작업 스케줄러에 매일 등록 권장)
```

운영 상세: [docs/operations.md](docs/operations.md)

## 회사 인증서 사용

자동 생성된 사설 CA 대신 회사 CA/공인 인증서를 쓰려면 설치 전에 `certs/server.crt`(체인 포함),
`certs/server.key` 를 넣고, FreeRADIUS 가 검증할 수 있도록 발급 CA 를 `certs/ca.crt` 로 넣으세요.
setup.sh 는 이미 있는 파일을 덮어쓰지 않습니다. 인증서 SAN 에 `PI_HOSTNAME` 이 반드시 포함되어야 합니다.

## 주의

- `secrets/enckey` 를 잃어버리면 모든 토큰을 다시 등록해야 합니다. **반드시 `pi.sh backup` 으로 백업**하세요.
- `PI_ROLLOUT_PASSTHRU=true` 는 토큰이 없는 사용자를 비밀번호만으로 통과시킵니다. 도입 기간에만 쓰고 끄세요.
- privacyIDEA 는 AGPLv3, FreeRADIUS 플러그인은 GPLv2 입니다. 이 저장소는 원본을 수정하지 않고 빌드 시 받아 씁니다.
