"""gunicorn 진입점: 환경변수와 /run/secrets 만으로 설정되는 Docker 앱을 생성한다."""
from privacyidea.app import create_docker_app

application = create_docker_app()
