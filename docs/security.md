# 보안 설계

## 위협과 대응

| 위협 | 대응 | 위치 |
|---|---|---|
| VPN 계정 비밀번호 대입 | 비밀번호 10회 연속 실패 → 사용자 15분 잠금 / 분당 10회 실패 → 일시 거부 | 조건부 접근 `Password Brute-Force`, `Per-User Failed-Attempt Rate Limit` |
| 비밀번호는 탈취, OTP 대입 | OTP 3회 실패 10분, 5회 30분, 10회 **영구 잠금** (관리자 해제) + 토큰 실패횟수 10회 잠금 | `MFA Brute-Force`, 시스템 설정 `DefaultMaxFailCount` |
| 비밀번호 스프레이 / 사용자 열거 | 한 IP 가 5분간 20명 이상 비밀번호 실패 또는 10명 이상 없는 사용자 → 1시간 IP 차단 (기본 **기록 모드**) | `Password Spraying`, `User Enumeration`, `PI_CA_IP_ENFORCE` |
| 비밀번호만 탈취 후 공격자 토큰 등록 | 사용자당 토큰 1개, 사용자는 토큰 삭제 불가, 등록 시 OTP 확인 필수, WebUI 는 내부망만 | `hard-enrollment`, `hard-user-selfservice`, Nginx `PI_WEB_ALLOWED_NETS` |
| 토큰 없는 사용자 우회 | 토큰이 없으면 거부 (passthru 기본 꺼짐) | `hard-authentication` |
| 클라이언트 IP 위조로 차단 회피 | Nginx 가 `X-Forwarded-For` 덮어쓰기, privacyIDEA 는 `Nginx > RADIUS > client` 경로만 신뢰 | `OverrideAuthorizationClient` |
| 방화벽 IP 차단에 의한 전체 장애 | Nginx, RADIUS, Palo Alto IP 는 **절대 차단 안 함** 목록 | `PI_CONDITIONAL_ACCESS_NEVER_BLOCK` |
| RADIUS 위조 (BlastRADIUS) | FreeRADIUS 3.2.7, `require_message_authenticator`, `limit_proxy_state` | `radius/` |
| 미등록 장비의 RADIUS 요청 | `PALOALTO_IPS` 외 요청 무시, `/validate` 는 RADIUS 서버 IP 만 허용 | `clients.conf`, Nginx `allow-validate` |
| FreeRADIUS↔privacyIDEA 중간자 | TLS + 사설 CA 검증 + 호스트명 검증 (실패 시 **거부**) | `PERL_LWP_SSL_CA_FILE`, `SSL_CHECK=true` |
| 비밀번호 로그 유출 | `GET /validate/*` 405, 액세스 로그에 쿼리스트링 미기록, 플러그인 DEBUG 강제 off | Nginx, gunicorn, `rlm_perl.ini` |
| 내부 정보 노출 | RADIUS 거부 메시지 통일, `/healthz` 외부 차단, Nginx 버전 숨김·백엔드 `Server`/`X-Powered-By` 헤더 제거 | `sites-enabled/privacyidea`, Nginx |
| 웹 공격 (XSS, 클릭재킹) | CSP(`script-src 'self'` + 해시 1개), `frame-ancestors 'none'`, HSTS 등 | Nginx |
| WebUI 세션 탈취 | 5분 무활동 잠금, JWT 30분 | `hard-webui` |
| 컨테이너 탈출 / 권한 상승 | 비루트, 읽기 전용 루트FS, `cap_drop: ALL`, `no-new-privileges`, PID/메모리 제한 | `docker-compose.yml` |
| DB 직접 공격 | DB 는 `internal: true` 네트워크, 원격 root 금지, `local-infile=0` | `db` 서비스 |
| 공급망 변조 | PyPI 휠/의존성 SHA-256 고정, 플러그인 커밋+해시 고정 | Dockerfile |
| 비밀값 유출 | 비밀값은 `secrets/`(0700) 파일, 컨테이너별 UID 0400, `.gitignore`, 백업은 AES-256 암호화 | `setup.sh`, `pi.sh backup` |
| 감사 로그 위변조 | RSA 3072 서명 감사 로그 | `audit_key_private` |

## 네트워크

```
 외부/사내망 ──8443/TCP──▶ nginx ─┐
                                  │ pi_backend (internal: true, 인터넷 X)
 Palo Alto ──1812/UDP──▶ radius ─▶ nginx ─▶ privacyidea ─▶ db
                       (pi_frontend)          │
                                              └─ pi_egress ─▶ LDAP/SMTP (나가는 연결만)
```

- privacyIDEA(8080)와 DB(3306)는 호스트에 포트가 없습니다.
- RADIUS 컨테이너도 Nginx 를 거쳐야 하므로 속도 제한·허용 목록이 동일하게 적용됩니다.

## 비밀값 목록 (`secrets/`)

| 파일 | 용도 | 잃어버리면 |
|---|---|---|
| `enckey` | 토큰 시드/비밀값 암호화 (96 바이트) | **모든 토큰 재등록** |
| `audit_key_private/public` | 감사 로그 서명 | 기존 감사 로그 서명 검증 불가 |
| `pi_pepper` | 관리자 비밀번호 해시 | 관리자 비밀번호 재설정 |
| `pi_secret_key` | JWT 서명 | 로그인 세션 무효화 (문제 없음) |
| `db_password`, `db_root_password` | MariaDB | DB 접근 불가 |
| `radius_client_secret` | Palo Alto ↔ FreeRADIUS 공유 비밀 | 양쪽 다시 설정 |
| `pi_admin_password` | 초기 관리자 비밀번호 | `pi.sh admin-password` |
| `ca.key` | 사설 CA (컨테이너에 마운트 안 함) | 인증서 재발급 시 새 CA 배포 |

## 운영 전 체크리스트

- [ ] `./scripts/pi.sh admin-password` 로 초기 관리자 비밀번호 변경
- [ ] `PI_WEB_ALLOWED_NETS` 를 관리자/사용자 PC 대역으로 좁히기 (기본은 사설망 전체)
- [ ] LDAP 은 `ldaps://` + `LDAP_TLS_VERIFY=true` + `LDAP_CA_FILE`
- [ ] Palo Alto 최신 PAN-OS 확인 후 `RADIUS_REQUIRE_MESSAGE_AUTHENTICATOR=yes`
- [ ] Audit 의 Client 가 실제 사용자 IP 인지 확인 후 `PI_CA_IP_ENFORCE=true`
- [ ] `PI_ROLLOUT_PASSTHRU=false` 확인
- [ ] 모든 사용자 토큰 등록 후 셀프서비스가 필요 없으면 `PI_USER_SELFSERVICE=false`
- [ ] `./scripts/pi.sh backup` 결과물을 NAS 외부(오프라인)에도 보관, 백업 암호 별도 보관
- [ ] DSM/호스트 방화벽에서 1812/UDP 를 Palo Alto IP 로만 제한
- [ ] Palo Alto 로컬 비상 관리자 계정 유지
- [ ] 작업 스케줄러에 `pi.sh maintenance`(매일), `pi.sh backup`(매일/매주) 등록

## 알려진 한계

- RADIUS 구간(Palo Alto ↔ FreeRADIUS)은 PAP + 공유 비밀(MD5 기반)입니다. 같은 사내망/관리망에 두고,
  가능하면 두 장비를 같은 L2 또는 전용 VLAN 에 두세요. (RadSec 은 PAN-OS 지원 여부에 따라 추후 검토)
- 관리자(로컬 DB 관리자)의 WebUI 로그인은 privacyIDEA 자체 2FA 가 적용되지 않습니다.
  IP 허용 목록으로 보호하고 강한 비밀번호를 쓰세요. 필요하면 관리자용 realm 을 만들어
  `SUPERUSER_REALM`(`PI_SUPERUSER_REALM`) + `login_mode=privacyIDEA` 정책으로 관리자도 OTP 를 쓰게 할 수 있습니다.
- 첫 토큰 등록은 AD 비밀번호만으로 이루어집니다. 위험이 크면 셀프서비스를 끄고 관리자가 등록해 QR 을 전달하세요.
