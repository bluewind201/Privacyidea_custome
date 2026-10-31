# gunicorn 설정 - 모든 값은 환경변수로 덮어쓸 수 있다.
import os

bind = "0.0.0.0:8080"
workers = int(os.environ.get("GUNICORN_WORKERS", "2"))
threads = int(os.environ.get("GUNICORN_THREADS", "4"))
worker_class = "gthread"
timeout = int(os.environ.get("GUNICORN_TIMEOUT", "60"))
graceful_timeout = 30
keepalive = 5

# 메모리 누수/장기 실행 프로세스 위험 완화를 위해 주기적으로 워커 재시작
max_requests = 2000
max_requests_jitter = 200

# 읽기 전용 루트 파일시스템에서도 동작하도록 하트비트 파일은 tmpfs 사용
worker_tmp_dir = "/dev/shm"

# X-Forwarded-Proto 는 앞단 Nginx 에서만 신뢰한다 (내부 백엔드 네트워크 대역)
forwarded_allow_ips = os.environ.get("GUNICORN_FORWARDED_ALLOW_IPS", "127.0.0.1")

# 요청 크기 제한 (헤더 남용 방지)
limit_request_line = 4094
limit_request_fields = 100
limit_request_field_size = 8190

# 로그는 stdout/stderr 로. 쿼리스트링(%(q)s)은 비밀번호가 섞일 수 있으므로 남기지 않는다.
accesslog = "-"
errorlog = "-"
loglevel = os.environ.get("GUNICORN_LOGLEVEL", "info")
access_log_format = '%({x-forwarded-for}i)s "%(m)s %(U)s" %(s)s %(B)s %(M)sms "%(a)s"'

proc_name = "privacyidea"

# 런타임 제어 소켓 비활성화 (불필요한 로컬 제어 인터페이스 제거, 읽기 전용 FS 대응)
control_socket_disable = True
