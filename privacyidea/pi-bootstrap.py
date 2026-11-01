#!/opt/privacyidea/bin/python
"""
privacyIDEA 초기/재설정 스크립트 (멱등)

컨테이너 안에서 실행한다:
    docker compose exec privacyidea pi-bootstrap.py

환경변수(.env)를 읽어 다음을 만든다. 여러 번 실행해도 안전하며, 실행할 때마다
.env 의 값으로 정책을 다시 맞춘다(관리자가 같은 이름의 정책을 바꿨다면 덮어씀).

  1. 로컬 관리자 계정 (없을 때만 생성, /run/secrets/pi_admin_password 사용)
  2. 사용자 저장소(resolver) + realm (internal SQL 또는 LDAP/AD/Synology LDAP)
  3. 보안 시스템 설정 (실패 횟수 잠금, 프록시/클라이언트 IP 매핑)
  4. 인증/등록/셀프서비스/WebUI 정책
  5. 조건부 접근(무차별 대입 잠금, IP 차단) 정책
"""
import copy
import os
import sys

from privacyidea.app import create_app
from privacyidea.models import db


def env(name, default=""):
    """빈 문자열도 '미설정'으로 취급 (compose 의 ${VAR:-} 대응)"""
    return os.environ.get(name, "").strip() or default


def env_bool(name, default="false"):
    return env(name, default).lower() in ("1", "true", "yes", "on")


def read_secret(name):
    path = f"/run/secrets/{name}"
    try:
        with open(path) as f:
            return f.read().strip()
    except OSError:
        return None


def log(msg):
    print(f"[bootstrap] {msg}", flush=True)


# --------------------------------------------------------------------------
# 1. 관리자
# --------------------------------------------------------------------------
def ensure_admin():
    from privacyidea.lib.auth import create_db_admin, get_db_admin

    username = env("PI_ADMIN_USER", "admin")
    if get_db_admin(username):
        log(f"관리자 '{username}' 이미 존재 - 건너뜀")
        return
    password = read_secret("pi_admin_password")
    if not password:
        sys.exit("[bootstrap] 오류: /run/secrets/pi_admin_password 가 없습니다.")
    create_db_admin(username, env("PI_ADMIN_EMAIL") or None, password)
    log(f"관리자 '{username}' 생성")


# --------------------------------------------------------------------------
# 2. 사용자 저장소 / realm
# --------------------------------------------------------------------------
LDAP_PRESETS = {
    # Active Directory
    "ad": {
        "LOGINNAMEATTRIBUTE": "sAMAccountName",
        "LDAPSEARCHFILTER": "(&(objectClass=user)(objectCategory=person))",
        "USERINFO": ('{"username": "sAMAccountName", "phone": "telephoneNumber", '
                     '"mobile": "mobile", "email": "mail", "surname": "sn", '
                     '"givenname": "givenName", "memberOf": "memberOf"}'),
        "UIDTYPE": "objectGUID",
    },
    # Synology LDAP Server / OpenLDAP
    "openldap": {
        "LOGINNAMEATTRIBUTE": "uid",
        "LDAPSEARCHFILTER": "(objectClass=posixAccount)",
        "USERINFO": ('{"username": "uid", "phone": "telephoneNumber", "mobile": "mobile", '
                     '"email": "mail", "surname": "sn", "givenname": "givenName"}'),
        "UIDTYPE": "entryUUID",
    },
}


def ensure_userstore():
    from privacyidea.lib.realm import get_realms, set_default_realm, set_realm
    from privacyidea.lib.resolver import get_resolver_list, save_resolver

    realm = env("PI_REALM", "corp")
    store = env("PI_USERSTORE", "internal").lower()
    resolver = f"{realm}-{store}"

    if store == "internal":
        if resolver not in get_resolver_list():
            # privacyIDEA DB 안에 users_<name> 테이블을 만드는 편집 가능한 SQL resolver
            from click.testing import CliRunner
            from privacyidea.cli.pimanage.pi_config import resolver_create_internal
            res = CliRunner().invoke(resolver_create_internal, [resolver], catch_exceptions=False)
            if res.exit_code != 0:
                sys.exit(f"[bootstrap] internal resolver 생성 실패: {res.output}")
            log(f"internal resolver '{resolver}' 생성")
    elif store == "ldap":
        preset = LDAP_PRESETS.get(env("LDAP_PRESET", "ad"), LDAP_PRESETS["ad"])
        bind_pw = read_secret("ldap_bind_password") or ""
        params = {
            "resolver": resolver,
            "type": "ldapresolver",
            "LDAPURI": env("LDAP_URI"),
            "LDAPBASE": env("LDAP_BASE_DN"),
            "BINDDN": env("LDAP_BIND_DN"),
            "BINDPW": bind_pw,
            "AUTHTYPE": "Simple",
            "LOGINNAMEATTRIBUTE": env("LDAP_LOGIN_ATTR") or preset["LOGINNAMEATTRIBUTE"],
            "LDAPSEARCHFILTER": env("LDAP_SEARCH_FILTER") or preset["LDAPSEARCHFILTER"],
            "USERINFO": preset["USERINFO"],
            "UIDTYPE": env("LDAP_UIDTYPE") or preset["UIDTYPE"],
            "SCOPE": "SUBTREE",
            "TIMEOUT": "5",
            "SIZELIMIT": "500",
            "CACHE_TIMEOUT": "120",
            "NOREFERRALS": "True",
            # 그룹(memberOf) 은 여러 값을 그대로 돌려줘야 Palo Alto 그룹 매핑이 가능
            "MULTIVALUEATTRIBUTES": '["mobile", "memberOf"]',
            "EDITABLE": "False",
            "START_TLS": str(env_bool("LDAP_START_TLS")),
            "TLS_VERIFY": str(env_bool("LDAP_TLS_VERIFY", "true")),
            "TLS_VERSION": "2",
            "TLS_CA_FILE": env("LDAP_CA_FILE"),
        }
        if not params["LDAPURI"] or not params["LDAPBASE"]:
            sys.exit("[bootstrap] 오류: PI_USERSTORE=ldap 이면 LDAP_URI, LDAP_BASE_DN 이 필요합니다.")
        if params["LDAPURI"].lower().startswith("ldap://") and not env_bool("LDAP_START_TLS"):
            log("경고: 평문 LDAP 입니다. ldaps:// 또는 LDAP_START_TLS=true 를 권장합니다.")
        save_resolver(params)
        log(f"LDAP resolver '{resolver}' 설정 ({params['LDAPURI']})")
    else:
        sys.exit(f"[bootstrap] 알 수 없는 PI_USERSTORE: {store}")

    if realm not in get_realms():
        set_realm(realm, [{"name": resolver}])
        log(f"realm '{realm}' 생성")
    set_default_realm(realm)
    return realm


# --------------------------------------------------------------------------
# 3. 시스템 설정
# --------------------------------------------------------------------------
def build_override_client():
    """
    privacyIDEA 가 '진짜' 클라이언트 IP 를 판단하는 신뢰 경로를 만든다.

      Nginx > 0.0.0.0/0
          Nginx 가 덮어쓴 X-Forwarded-For(브라우저 IP)를 신뢰
      Nginx > RADIUS 서버 > 0.0.0.0/0
          RADIUS 서버가 보낸 client 파라미터(= Palo Alto 가 알려준 사용자 공인 IP,
          없으면 NAS-IP)를 신뢰

    그 밖의 출발지가 보낸 X-Forwarded-For / client 값은 무시된다.
    """
    if env("PI_OVERRIDE_CLIENT"):
        return env("PI_OVERRIDE_CLIENT")
    nginx_ip = env("PI_NGINX_BACKEND_IP")
    if not nginx_ip:
        return ""
    paths = [f"{nginx_ip} > 0.0.0.0/0"]
    for src in env("PI_RADIUS_SOURCES").replace(",", " ").split():
        paths.append(f"{nginx_ip} > {src} > 0.0.0.0/0")
    return ", ".join(paths)


def ensure_system_config():
    from privacyidea.lib.config import set_privacyidea_config

    settings = {
        # 토큰별 실패 횟수 제한 → 초과 시 토큰 잠김
        "DefaultMaxFailCount": env("PI_TOKEN_MAX_FAIL", "10"),
        # 잠긴 토큰 자동 해제(분). 0 이면 관리자만 해제
        "failcounter_clear_timeout": env("PI_FAILCOUNTER_CLEAR_MINUTES", "10"),
        # 틀린 PIN(=비밀번호)도 실패 횟수 증가
        "IncFailCountOnFalsePin": "True",
        "PrependPin": "True",
        "splitAtSign": "True",
    }
    settings["OverrideAuthorizationClient"] = override = build_override_client()
    for key, value in settings.items():
        set_privacyidea_config(key, value)
    log("시스템 설정 적용"
        + (f" (OverrideAuthorizationClient = {override})" if override else ""))


# --------------------------------------------------------------------------
# 4. 정책
# --------------------------------------------------------------------------
def ensure_policies(realm):
    from privacyidea.lib.policy import delete_policy, get_policies, set_policy

    issuer = env("PI_TOKEN_ISSUER", "PaloAlto-VPN")
    challenge_text = env("PI_CHALLENGE_TEXT", "Enter the 6-digit code from your authenticator app")
    selfservice = env_bool("PI_USER_SELFSERVICE", "true")
    passthru = env_bool("PI_ROLLOUT_PASSTHRU", "false")

    auth_actions = [
        # 비밀번호(PIN)는 사용자 저장소(AD/LDAP) 비밀번호로 검증
        "otppin=userstore",
        # 팔로알토: 1단계 비밀번호 → Access-Challenge → 2단계 OTP
        "challenge_response=hotp totp",
        f"challenge_text={challenge_text}",
        # 인증 성공 시 사용자의 모든 토큰 실패 횟수 초기화
        "reset_all_user_tokens",
    ]
    if passthru:
        # 롤아웃 기간 전용: 토큰이 없는 사용자는 비밀번호만으로 통과
        auth_actions.append("passthru")
        log("경고: PI_ROLLOUT_PASSTHRU=true - 토큰 없는 사용자는 1단계 인증만으로 통과합니다!")

    policies = {
        "hard-authentication": dict(scope="authentication", action=", ".join(auth_actions),
                                    realm=realm, priority=10,
                                    description="Palo Alto RADIUS: AD password + OTP challenge"),
        "hard-enrollment": dict(scope="enrollment", action=", ".join([
            f"tokenissuer={issuer}",
            "tokenlabel={user}@{realm}",
            # 사용자당 토큰 1개: 비밀번호만 탈취한 공격자가 추가 토큰을 등록하지 못하게 함
            f"max_token_per_user={env('PI_MAX_TOKEN_PER_USER', '1')}",
            # 등록 시 첫 OTP 값을 입력해야 활성화 (잘못 스캔된 QR 방지)
            "verify_enrollment=totp hotp",
        ]), realm=realm, priority=10, description="Token enrollment defaults"),
        "hard-webui": dict(scope="webui", action=", ".join([
            "login_mode=userstore",
            f"logout_time={env('PI_WEBUI_LOGOUT_SECONDS', '300')}",
            "timeout_action=lockscreen",
            f"jwt_validity={env('PI_WEBUI_JWT_SECONDS', '1800')}",
            "hide_welcome_info",
            "tokenwizard",
        ]), priority=10, description="WebUI session hardening"),
    }
    if env("PI_GROUP_ATTRIBUTE"):
        # 인증 성공 응답에 사용자 속성(예: memberOf)을 포함 → FreeRADIUS 가 PaloAlto-User-Group 으로 변환
        policies["hard-authorization"] = dict(scope="authorization", action="add_user_in_response",
                                              realm=realm, priority=10,
                                              description="Return user attributes for Palo Alto group mapping")
    if selfservice:
        # 셀프서비스: TOTP 등록/재동기화만 허용. 삭제·PIN 변경·HOTP 등은 관리자만.
        policies["hard-user-selfservice"] = dict(scope="user", action=", ".join([
            "enrollTOTP", "resync", "disable", "enable", "setdescription",
        ]), realm=realm, priority=10, description="User self-service (TOTP only, no delete)")

    for name, kwargs in policies.items():
        set_policy(name=name, active=True, **kwargs)
        log(f"정책 '{name}' 적용 ({kwargs['scope']})")

    for name in ("hard-user-selfservice", "hard-authorization"):
        if name not in policies and get_policies(name=name):
            delete_policy(name)
            log(f"정책 '{name}' 삭제 (.env 에서 비활성화됨)")


# --------------------------------------------------------------------------
# 5. 조건부 접근 (무차별 대입/스프레이 방어)
# --------------------------------------------------------------------------
def ensure_conditional_access():
    from privacyidea.lib.conditional_access.engine import ConditionalAccessAction
    from privacyidea.lib.conditional_access.policy import (create_conditional_access_policy,
                                                            list_conditional_access_policies)
    from privacyidea.lib.conditional_access.policy_template import (MFA_BRUTEFORCE,
                                                                     PASSWORD_BRUTEFORCE,
                                                                     PASSWORD_SPRAYING,
                                                                     USER_ENUMERATION,
                                                                     USER_FAILED_RATE_LIMITING)

    # IP 대상 정책은 실제 사용자 IP 가 privacyIDEA 에 전달될 때만 의미가 있다.
    # 팔로알토가 보내는 PaloAlto-Client-Source-IP 가 전달되지 않으면 모든 요청이
    # 방화벽 IP 하나로 보이므로, 기본값은 dry-run(기록만) 이다.
    ip_enforce = env_bool("PI_CA_IP_ENFORCE", "false")

    existing = {p["name"] for p in list_conditional_access_policies()}
    used_priorities = {p.get("priority") for p in list_conditional_access_policies()}
    priority = 100
    for template, is_ip in ((PASSWORD_BRUTEFORCE, False), (MFA_BRUTEFORCE, False),
                            (USER_FAILED_RATE_LIMITING, False),
                            (PASSWORD_SPRAYING, True), (USER_ENUMERATION, True)):
        policy = copy.deepcopy(template.policy)
        # SMTP 가 없는 기본 환경에서는 관리자 메일 알림 액션 제거
        if not env("PI_SMTP_IDENTIFIER"):
            for stage in policy["stages"]:
                stage["actions"] = [a for a in stage["actions"]
                                    if a["action_type"] != ConditionalAccessAction.EMAIL_ADMIN]
        else:
            for stage in policy["stages"]:
                for a in stage["actions"]:
                    if a["action_type"] == ConditionalAccessAction.EMAIL_ADMIN:
                        a["action_value"]["smtp_identifier"] = env("PI_SMTP_IDENTIFIER")
        if is_ip:
            policy["dry_run"] = not ip_enforce
        while priority in used_priorities:
            priority += 1
        if policy["name"] in existing:
            log(f"조건부 접근 '{policy['name']}' 이미 존재 - 건너뜀")
            continue
        create_conditional_access_policy(priority=priority, **policy)
        used_priorities.add(priority)
        log(f"조건부 접근 '{policy['name']}' 생성"
            + (" [dry-run]" if policy.get("dry_run") else ""))


def main():
    app = create_app(config_name="docker", silent=True)
    with app.app_context():
        ensure_admin()
        realm = ensure_userstore()
        ensure_system_config()
        ensure_policies(realm)
        ensure_conditional_access()
        db.session.commit()
    log("완료")


if __name__ == "__main__":
    main()
