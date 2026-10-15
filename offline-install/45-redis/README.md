# 45-redis — Redis OSS 단일 노드 오프라인 설치

공식 Redis OSS 이미지를 번들로 받아 에어갭 노드 한 대에 설치한다. plain TCP를 비활성화하고 TLS·비밀번호 인증을 사용하며, AOF/RDB 데이터를 호스트 경로에 보존한다.

> **UiPath 지원 범위 확인:** 이 번들은 독립적인 Redis OSS 서비스 설치 도구다. UiPath Automation Suite Linux의 기본 Redis 구성이나 Redis Enterprise HAA와 동등한 구성·고가용성을 제공하지 않는다. 외부 Redis OSS를 AS 서비스 endpoint로 연결할 수 있는지, 지원 버전과 TLS/auth 파라미터는 해당 AS 버전의 공식 지원 조건을 확인해야 한다. Redis OSS 단일 노드는 고가용성이 아니다.

## 설정

`offline-install/00-common/site.env`에서 다음 값을 지정한다.

| 변수 | 기본값 | 설명 |
|---|---|---|
| `REDIS_DATA_DIR` | `/data/redis` | 호스트 데이터 디렉터리. 별도 디스크/LVM 경로 권장 |
| `REDIS_HOSTNAME` | `redis.example.internal` | 클라이언트 접속 DNS 이름 및 인증서 SAN |
| `REDIS_HOST_IP` | 자동 탐지 | 노출할 호스트 IPv4 주소. Redis 접속 DNS와 같은 인터페이스 사용 |
| `REDIS_PORT` | `6379` | TLS 전용으로 노출할 포트 |
| `REDIS_PASSWORD` | 자동 생성 | 직접 지정 시 영문자·숫자·`_`·`-` 32~128자 |

`05-certs/make-certs.sh` 및 `deploy-certs.sh`에 Redis 인증서 발급·배치가 포함된다. 해당 인증서가 없으면 설치기가 로컬 CA와 서버 인증서를 만든다. 클라이언트가 연결할 때는 그 CA 인증서를 신뢰해야 한다.

## 빌드 및 설치

```bash
# 온라인 빌드 호스트
cd offline-install/45-redis
./build-bundle.sh

# 생성된 bundle/redis-<태그>.tar.gz 와 .sha256 를 타깃으로 전송
sha256sum -c redis-*.tar.gz.sha256
tar xzf redis-*.tar.gz
cd redis-*
sudo ./install.sh --check-only
sudo ./install.sh
```

타깃에는 `10-k8s` 단계가 설치한 Docker Engine과 Compose 플러그인이 필요하다. 이미지 pull 없이 번들에 포함된 tar에서 이미지를 적재한다.

## 관리

```bash
sudo ./install.sh --check-only
sudo ./install.sh --test-restart
sudo docker compose -f /opt/redis/docker-compose.yml logs
sudo ./install.sh --uninstall
```

`--uninstall`은 컨테이너만 제거하며 `/opt/redis` 설정·인증서와 `REDIS_DATA_DIR`은 보존한다. 비밀번호는 `/opt/redis/redis.conf`의 `requirepass` 항목에 저장되고 파일 권한은 `0600`이다. 생성된 값을 안전한 보관소에 옮겨두고, 방화벽에서는 설정한 Redis 포트를 필요한 내부 클라이언트에만 허용한다.

TLS URI 형식은 `rediss://:<password>@<REDIS_HOSTNAME>:<REDIS_PORT>`이며, 앱이 CA 검증을 수행한다면 설치에서 사용한 CA 인증서를 신뢰하도록 설정한다.
