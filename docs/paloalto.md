# Palo Alto 설정 (GlobalProtect / 관리자 로그인)

PAN-OS 10.x/11.x 웹 UI 기준입니다. 메뉴 이름은 버전에 따라 조금 다를 수 있습니다.

## 0. 먼저 확인할 값

```bash
./scripts/setup.sh info
```

- RADIUS 서버 IP: 올인원이면 privacyIDEA 서버(NAS) IP, 분리형이면 FreeRADIUS 를 띄운 시놀로지 IP
- 포트: `1812/UDP`
- 공유 비밀: `secrets/radius_client_secret` 내용 (`sudo cat secrets/radius_client_secret`)

## 1. RADIUS 출발지 IP 고정 (서비스 경로)

**Device → Setup → Services → Service Route Configuration → Customize → RADIUS**

RADIUS 요청을 보낼 인터페이스/IP 를 지정합니다. 이 IP 가 `.env` 의 `PALOALTO_IPS` 입니다.
지정하지 않으면 관리 인터페이스(MGT) IP 로 나갑니다. HA 구성이면 두 장비의 IP 를 모두 넣으세요.

## 2. RADIUS 서버 프로필

**Device → Server Profiles → RADIUS → Add**

| 항목 | 값 | 비고 |
|---|---|---|
| Profile Name | `PI-RADIUS` | |
| Timeout (sec) | `10` | privacyIDEA 응답은 보통 1초 미만 |
| Retries | `1` | 재전송이 많으면 같은 OTP 가 두 번 제출되어 "재사용" 으로 거부될 수 있음 |
| Retrieve user group from RADIUS | 필요할 때만 | 아래 6번 참고 |
| Authentication Protocol | **PAP** | privacyIDEA 가 비밀번호 원문을 확인해야 하므로 PAP 필수. RADIUS 구간은 공유 비밀로 보호되며, FreeRADIUS↔privacyIDEA 구간은 TLS |
| Servers → Name / RADIUS Server / Secret / Port | `privacyidea` / 서버 IP / 공유 비밀 / `1812` | |

> BlastRADIUS(CVE-2024-3596): 패치된 PAN-OS 는 `Message-Authenticator` 를 보냅니다. FreeRADIUS 는
> 기본 `auto` (한 번이라도 받으면 그 뒤로 필수) 입니다. PAN-OS 가 최신이면 `.env` 에서
> `RADIUS_REQUIRE_MESSAGE_AUTHENTICATOR=yes` 로 바꿔 강제하세요.

## 3. 인증 프로필

**Device → Authentication Profile → Add**

| 항목 | 값 |
|---|---|
| Name | `AP-PrivacyIDEA` |
| Type | RADIUS |
| Server Profile | `PI-RADIUS` |
| User Domain | 비움 (realm 은 FreeRADIUS 가 `PI_REALM` 으로 붙임) |
| Username Modifier | `%USERINPUT%` |
| Advanced → Allow List | `all` (또는 VPN 허용 그룹) |

> 사용자가 `DOMAIN\user` 또는 `user@domain` 형태로 입력한다면 Username Modifier 를 조정하거나,
> privacyIDEA 의 `splitAtSign` 설정(기본 켜짐)을 활용하세요.

## 4. GlobalProtect 에 적용

**Network → GlobalProtect → Portals → (포털) → Authentication → Client Authentication**
**Network → GlobalProtect → Gateways → (게이트웨이) → Authentication → Client Authentication**

- Authentication Profile: `AP-PrivacyIDEA`
- Authentication Message: 예) `회사 계정 비밀번호를 입력하세요. 다음 화면에서 OTP 를 입력합니다.`

**OTP 를 두 번 묻지 않게 (사용자 편의)** — 포털과 게이트웨이가 각각 인증하면 OTP 를 두 번 입력해야 합니다.

- Portal → Agent → (설정) → Authentication → **Generate cookie for authentication override** 체크
- Gateway → Agent → Client Settings → (설정) → Authentication Override → **Accept cookie for authentication override** 체크, Cookie Lifetime 예: 8~24시간
- 두 곳 모두 같은 *Certificate to Encrypt/Decrypt Cookie* 지정

동작: GlobalProtect 앱에서 ID/비밀번호 입력 → "Enter the 6-digit code ..." 창 → OTP 입력 → 연결.
(앱 버전에 따라 한 칸에 `비밀번호+OTP6자리` 로 입력해도 됩니다.)

OTP 안내 문구는 `.env` 의 `PI_CHALLENGE_TEXT` 로 바꾸고 `./scripts/setup.sh bootstrap` 하면 됩니다.

## 5. 방화벽 관리자 로그인에 2FA (선택)

**Device → Setup → Management → Authentication Settings → Authentication Profile** = `AP-PrivacyIDEA`
또는 **Device → Administrators** 에서 관리자별 Authentication Profile 지정.

- 반드시 **로컬 비상 관리자 계정**을 하나 남겨 두세요. (privacyIDEA/NAS 장애 시 잠김 방지)
- RADIUS 로 관리자 역할을 내려주려면 `PaloAlto-Admin-Role` VSA 가 필요합니다. privacyIDEA 사용자 속성을
  매핑하려면 `radius/` 의 `rlm_perl.ini` 매핑을 확장해야 하므로, 처음에는 PAN-OS 에서 관리자 계정을
  로컬로 만들고 인증만 RADIUS 로 하는 방식을 권장합니다.

## 6. 사용자 그룹 전달 (선택)

GlobalProtect 정책을 AD 그룹별로 나누려면 privacyIDEA 가 돌려준 사용자 그룹을 `PaloAlto-User-Group`
속성으로 보낼 수 있습니다. (`PI_USERSTORE=ldap` 필요)

1. privacyIDEA `.env` 와 (분리형이면) 시놀로지 `radius/.env` 양쪽에 `PI_GROUP_ATTRIBUTE=memberOf`
2. privacyIDEA 서버에서 `./scripts/setup.sh bootstrap` → `add_user_in_response` 정책이 추가됨
3. RADIUS 컨테이너 재시작 (`docker compose up -d radius` 또는 시놀로지에서 `docker compose up -d`)
4. RADIUS 서버 프로필에서 *Retrieve user group from RADIUS* 체크

`memberOf` 의 `CN=VPN-Users,OU=Groups,DC=example,DC=local` 에서 `VPN-Users` 만 뽑아 보냅니다
(`PI_GROUP_REGEX` 로 변경 가능). 그룹이 여러 개면 각각 하나의 속성으로 전달됩니다.

## 7. 테스트

PAN-OS CLI

```
> test authentication authentication-profile AP-PrivacyIDEA username 홍길동 password
Enter password :
...
Authentication challenge received: Enter the 6-digit code from your authenticator app
Enter challenge response : 123456
Authentication succeeded for user "홍길동"
```

privacyIDEA WebUI → **Audit** 에서 같은 시각의 `POST /validate/check` 를 확인합니다.
Client 열에 VPN 사용자의 **공인 IP** 가 보이면 `PaloAlto-Client-Source-IP` 전달이 정상입니다.
이 경우 `.env` 의 `PI_CA_IP_ENFORCE=true` 로 바꾸고 `./scripts/setup.sh bootstrap` 하면
패스워드 스프레이/사용자 열거 IP 차단이 기록 모드에서 실제 차단으로 바뀝니다.
(Client 가 방화벽 IP 로만 보이면 IP 차단은 켜지 마세요. 방화벽 IP 는 항상 차단 예외로 등록되어 있습니다.)

## 문제 해결

| 증상 | 확인 |
|---|---|
| 항상 타임아웃 | FreeRADIUS 로그 `unknown client` → `PALOALTO_IPS`, DSM 방화벽, 서비스 경로 |
| 비밀번호 단계에서 거부 | privacyIDEA Audit 의 info 열: `wrong otp pin` = AD 비밀번호 오류, `user is locked` = 잠김(`./scripts/pi.sh unlock 사용자`) |
| OTP 단계에서 거부 | 휴대폰 시간 자동 동기화 확인, 같은 코드 재사용 금지(30초 뒤 새 코드), 토큰 실패횟수 초과 여부 |
| 토큰이 없는 사용자 | 기본은 거부. 도입 기간에만 `PI_ROLLOUT_PASSTHRU=true` |
| OTP 를 두 번 물어봄 | 4번의 인증 쿠키 설정 |
