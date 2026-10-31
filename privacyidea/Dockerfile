# syntax=docker/dockerfile:1
#
# privacyIDEA 하드닝 이미지
#  - PyPI 휠과 모든 의존성을 SHA-256 해시로 고정 (--require-hashes)
#  - 바이너리 휠만 사용(--only-binary), 런타임에는 venv 만 복사
#  - 비루트(uid 10001) 실행, pip/setuptools 제거
#  - PID 1 은 compose 의 init: true (tini) 가 담당
#
ARG PYTHON_IMAGE=python:3.12-slim-trixie

FROM ${PYTHON_IMAGE} AS builder

ARG PI_VERSION=3.14
ARG PI_WHEEL_SHA256=86a24cbffa8a7316eab93eb220b4d8710ea68af2390990d0dddd58d7bd6947b1

ENV PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_CACHE_DIR=1 \
    PYTHONDONTWRITEBYTECODE=1

RUN python -m venv /opt/privacyidea

WORKDIR /build
COPY requirements-extra.txt ./

# 1) privacyIDEA 휠을 해시 검증하며 다운로드
# 2) 휠에 포함된 pip-compile 결과(requirements.txt, 전부 해시 포함)로 의존성 설치
# 3) privacyIDEA 자체는 --no-deps 로 설치 (의존성은 이미 해시 검증됨)
RUN echo "privacyidea==${PI_VERSION} --hash=sha256:${PI_WHEEL_SHA256}" > pi-wheel.txt \
 && /opt/privacyidea/bin/pip download --no-deps --require-hashes -r pi-wheel.txt -d wheel \
 && /opt/privacyidea/bin/python -m zipfile -e wheel/privacyidea-${PI_VERSION}-py3-none-any.whl wheel/x \
 && cp wheel/x/privacyidea-${PI_VERSION}.data/data/lib/privacyidea/requirements.txt requirements-pi.txt \
 && /opt/privacyidea/bin/pip install --only-binary=:all: --require-hashes -r requirements-pi.txt -r requirements-extra.txt \
 && /opt/privacyidea/bin/pip install --no-deps --no-index wheel/privacyidea-${PI_VERSION}-py3-none-any.whl \
 && /opt/privacyidea/bin/pi-manage --help >/dev/null \
 && { /opt/privacyidea/bin/pip uninstall -y pip setuptools wheel || true; } \
 && find /opt/privacyidea -name '__pycache__' -prune -exec rm -rf {} +


FROM ${PYTHON_IMAGE}

LABEL org.opencontainers.image.title="privacyidea-hardened" \
      org.opencontainers.image.description="Hardened privacyIDEA for Palo Alto + FreeRADIUS"

ENV PATH=/opt/privacyidea/bin:$PATH \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PI_CONFIG_NAME=docker

# 베이스 이미지의 OS 보안 패치 적용 (오프라인 빌드 시 --build-arg APT_UPGRADE=false)
ARG APT_UPGRADE=true
RUN if [ "$APT_UPGRADE" = "true" ]; then \
      apt-get update && apt-get upgrade -y && rm -rf /var/lib/apt/lists/*; \
    fi \
 && groupadd --system --gid 10001 privacyidea \
 && useradd --system --uid 10001 --gid 10001 --home-dir /nonexistent --no-create-home \
            --shell /usr/sbin/nologin privacyidea \
 && mkdir -p /etc/privacyidea /opt/pi-docker && chmod 0755 /opt/pi-docker \
 && chown root:privacyidea /etc/privacyidea && chmod 0750 /etc/privacyidea

COPY --from=builder /opt/privacyidea /opt/privacyidea
COPY --chmod=0644 gunicorn.conf.py /opt/pi-docker/gunicorn.conf.py
COPY --chmod=0644 wsgi.py /opt/pi-docker/wsgi.py
COPY --chmod=0644 pi.cfg /etc/privacyidea/pi.cfg
COPY --chmod=0755 entrypoint.sh /usr/local/bin/entrypoint.sh
COPY --chmod=0755 pi-bootstrap.py /usr/local/bin/pi-bootstrap.py

USER 10001:10001
WORKDIR /opt/pi-docker
EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
  CMD ["python", "-c", "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8080/healthz/livez', timeout=4).status == 200 else 1)"]

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["gunicorn", "-c", "/opt/pi-docker/gunicorn.conf.py", "wsgi:application"]
