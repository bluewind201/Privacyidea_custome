# 시놀로지 NAS 에서 FreeRADIUS 연결하기

## 왜 DSM 의 "RADIUS Server" 패키지를 그대로 쓰지 않나

DSM 패키지 센터의 **RADIUS Server** 는 FreeRADIUS 기반이지만 DSM 로컬/도메인/LDAP 사용자 비밀번호만
확인하도록 고정되어 있습니다. privacyIDEA 연동에 필요한 `rlm_perl` 모듈과 플러그인을 넣을 수 없고,
SSH 로 설정 파일을 고쳐도 패키지 업데이트 때 덮어써집니다.

그래서 이 저장소는 **FreeRADIUS 3.2.7 + privacyIDEA 플러그인**을 컨테이너로 만들어
시놀로지 **Container Manager** 에서 실행합니다. DSM 의 RADIUS Server 패키지는 **중지**하거나
(같은 UDP 1812 포트를 사용) 컨테이너 포트를 바꿔야 합니다.

## 배치 방식 선택

| 방식 | 구성 | 언제 |
|---|---|---|
| **A. 올인원** | 시놀로지 한 대에 privacyIDEA + DB + Nginx + FreeRADIUS 전부 | 서버가 NAS 뿐일 때 (가장 간단) |
| **B. 분리형** | privacyIDEA 는 리눅스 서버/VM, FreeRADIUS 만 시놀로지 | 이미 privacyIDEA 서버가 있거나 NAS 메모리가 적을 때 |

공통 준비

1. DSM 7.2 이상, **Container Manager** 설치
2. 제어판 → 터미널 및 SNMP → **SSH 활성화** (작업 후 다시 꺼도 됩니다)
3. 패키지 센터 → RADIUS Server → **중지** (설치되어 있다면)
4. `File Station` 에서 `docker` 공유 폴더 생성 (보통 `/volume1/docker`)

> 메모리: 올인원은 최소 2GB 여유 RAM 권장. 부족하면 `.env` 의 `PI_DB_MEM_LIMIT`, `PI_APP_MEM_LIMIT`,
> `GUNICORN_WORKERS=1` 로 줄이세요.

---

## A. 올인원 (시놀로지 한 대에 전부)

```bash
ssh 관리자계정@NAS_IP
sudo -i
cd /volume1/docker
git clone https://github.com/bluewind201/Privacyidea_custome.git privacyidea   # git 이 없으면 zip 업로드 후 압축 해제
cd privacyidea
./scripts/setup.sh
```

질문에 답할 때

- **HTTPS 포트**: `8443` (DSM 이 443/5001 사용)
- **Palo Alto 출발지 IP**: 방화벽이 RADIUS 를 보내는 인터페이스 IP (Palo Alto 문서의 *서비스 경로* 참고)
- **FreeRADIUS 위치**: `1` (이 서버에서 같이 실행)

완료 후 Container Manager → 컨테이너 목록에 `privacyidea-db-1`, `privacyidea-privacyidea-1`,
`privacyidea-nginx-1`, `privacyidea-radius-1` 이 보이면 정상입니다.

Palo Alto 의 RADIUS 서버 IP 는 **NAS IP**, 포트는 `1812` 입니다.

---

## B. 분리형 (시놀로지에는 FreeRADIUS 만)

### 1) privacyIDEA 서버에서

```bash
sudo ./scripts/setup.sh
#  - FreeRADIUS 위치: 2 (다른 장비)
#  - FreeRADIUS 장비 IP: 시놀로지 NAS IP   ← /validate 접근 허용 + 신뢰 경로에 등록됨
```

시놀로지로 옮길 파일 두 개를 확인합니다.

- `certs/ca.crt` (privacyIDEA 인증서를 검증할 CA)
- `secrets/radius_client_secret` (Palo Alto 와 FreeRADIUS 가 공유할 비밀)

### 2) 시놀로지에서

```bash
ssh 관리자계정@NAS_IP
sudo -i
mkdir -p /volume1/docker/pi-radius && cd /volume1/docker/pi-radius
# 저장소의 radius/ 폴더 내용을 여기에 복사 (File Station 업로드 또는 git clone 후 cp -r radius/. .)
cp .env.example .env
vi .env                         # 아래 값 수정
```

| 항목 | 값 |
|---|---|
| `PI_HOSTNAME` | privacyIDEA 인증서의 이름 (예: `pi.example.local`) |
| `PI_SERVER_IP` | privacyIDEA 서버 IP (DNS 가 없어도 이 IP 로 연결) |
| `PI_VALIDATE_URL` | `https://pi.example.local:8443/validate/check` |
| `PI_REALM` | privacyIDEA 쪽 `PI_REALM` 과 동일 |
| `PALOALTO_IPS` | Palo Alto 의 RADIUS 출발지 IP |

비밀값과 CA 를 넣고 권한을 맞춥니다 (컨테이너는 UID 101 로 실행).

```bash
mkdir -p secrets
vi secrets/radius_client_secret      # privacyIDEA 서버의 같은 파일 내용 붙여넣기
cp /어딘가/ca.crt ./ca.crt
chown 101:101 secrets/radius_client_secret && chmod 0400 secrets/radius_client_secret
chmod 0700 secrets && chmod 0644 ca.crt
```

기동 (둘 중 하나)

- **Container Manager**: 프로젝트 → 생성 → 경로 `/volume1/docker/pi-radius` → "기존 docker-compose.yml 사용" → 빌드 후 시작
- **SSH**: `docker compose up -d --build` (구버전 DSM 은 `docker-compose up -d --build`)

로그에서 `Ready to process requests` 가 보이면 정상입니다.

```bash
docker compose logs -f radius
```

---

## DSM 방화벽 (권장)

제어판 → 보안 → 방화벽 → 규칙 편집

| 포트 | 프로토콜 | 허용 출발지 |
|---|---|---|
| 1812 | UDP | Palo Alto 방화벽 IP 만 |
| 8443, 8080 | TCP | 내부 관리/사용자 대역 (올인원일 때) |

컨테이너 안의 FreeRADIUS 도 `PALOALTO_IPS` 외의 요청은 무시하지만, 앞단에서 한 번 더 막는 것이 좋습니다.

## 연결 테스트

1. Palo Alto CLI 에서

   ```
   test authentication authentication-profile PI-RADIUS username 사용자 password
   ```

   비밀번호 입력 → OTP 입력 요청이 나오면 OTP 입력 → `Authentication succeeded`.

2. 실패하면 FreeRADIUS 로그를 봅니다.

   | 로그 | 원인 / 조치 |
   |---|---|
   | `Ignoring request ... from unknown client 1.2.3.4` | `PALOALTO_IPS` 에 그 IP 추가 (Palo Alto 서비스 경로 확인) |
   | `certificate verify failed` | `ca.crt` 가 privacyIDEA 서버의 `certs/ca.crt` 와 다르거나, `PI_HOSTNAME` 이 인증서 SAN 과 다름 |
   | `Can't connect to ...` | `PI_SERVER_IP`/포트/방화벽 확인 |
   | `privacyIDEA request failed: 403` | privacyIDEA `.env` 의 `PI_RADIUS_SOURCES` 에 NAS IP 추가 후 `./scripts/setup.sh bootstrap` |
   | `Received packet ... with invalid Message-Authenticator` / 응답 없음 | 공유 비밀 불일치 |

3. privacyIDEA WebUI → *Audit* 에서 `POST /validate/check` 기록과 Client(사용자 공인 IP)를 확인합니다.

## 업데이트

```bash
cd /volume1/docker/pi-radius     # 또는 올인원 폴더
git pull                          # (분리형은 새 radius/ 폴더 복사)
docker compose build --pull && docker compose up -d
```

## 참고: DSM 커널 경고

일부 DSM 버전에서 `Your kernel does not support ... pids limit` / `memory swap` 경고가 나올 수 있습니다.
기능에는 영향이 없습니다. 만약 컨테이너가 시작되지 않는 오류가 나면 `docker-compose.yml` 의
해당 서비스에서 `pids_limit` 줄을 지우세요.

## 참고: 시놀로지에서 접속 IP 가 `172.31.250.1` 로 보이는 경우

DSM 의 Docker 는 포트 포워딩 시 출발지 IP 를 브리지 게이트웨이(`172.31.250.1`)로 바꿔 넘기는 경우가 있습니다.
Nginx 로그의 `client:` 가 실제 PC IP 가 아니라 `172.31.250.1` 이면 이 경우입니다.

- 증상: WebUI `403 Forbidden` (`access forbidden by rule, client: 172.31.250.1`),
  RADIUS 는 `unknown client 172.31.250.1` 로 요청 무시
- 조치
  1. `.env` → `PI_WEB_ALLOWED_NETS=172.31.250.1/32 <사내 대역>` 후 `sudo docker compose up -d nginx`
  2. RADIUS 를 쓰면 `.env` → `PALOALTO_IPS=<방화벽 IP> 172.31.250.1` 후 `sudo docker compose up -d radius`
  3. 컨테이너가 출발지를 구분하지 못하므로 **DSM 방화벽**으로 대신 제한:
     TCP 8443 → 관리자/사용자 PC 대역만, UDP 1812 → Palo Alto IP 만 (위 *DSM 방화벽* 표)
- 사용자 공인 IP 는 Palo Alto 가 `PaloAlto-Client-Source-IP` 속성으로 보내므로 잠금·감사 로그에는 영향이 없습니다.
  `172.31.250.1` 은 Nginx/RADIUS 와 같이 IP 차단 예외에 넣어 두세요 (`PI_NEVER_BLOCK_EXTRA=172.31.250.1`).
