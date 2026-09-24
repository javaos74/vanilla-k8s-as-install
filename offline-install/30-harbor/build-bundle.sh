#!/usr/bin/env bash
#---------------------------------------------------------------------
# 30-harbor : 오프라인 번들 빌드 (온라인 호스트에서 실행)
#
# 산출물: bundle/harbor-<ver>/ + .tar.gz  (약 700MB)
#
# 용도: 사내 컨테이너 레지스트리. UiPath Automation Suite 의 이미지 저장소.
#
# 왜 이미지를 따로 수집하지 않는가:
#   Harbor 는 **공식 오프라인 인스톨러**를 제공한다. 그 tgz 안에
#   harbor.v<ver>.tar.gz(전체 이미지)와 prepare/install.sh 가 들어 있다.
#   우리가 이미지를 개별로 모으면 업스트림이 검증한 조합을 재구성하는 셈이고
#   버전이 어긋날 위험만 생긴다. 인스톨러를 그대로 담고 우리 래퍼를 덧붙인다.
#
#   담는 것: 인스톨러 tgz + harbor.yml 템플릿 + systemd 유닛 + 기동 스크립트
#
# 내장 PostgreSQL / Redis 를 쓰므로 외부 DB 가 필요하지 않다.
# OS 의존 없음. docker / docker compose 는 10-k8s 번들에서 설치된다.
#---------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../00-common/common.sh"

require_online
require_cmds curl tar

BUNDLE_NAME="harbor-${HARBOR_VERSION}"
BUNDLE_DIR="${SCRIPT_DIR}/bundle/${BUNDLE_NAME}"
INSTALLER_DIR="${BUNDLE_DIR}/installer"
CONF_DIR="${BUNDLE_DIR}/conf"
SRC_DIR="${SCRIPT_DIR}/.src"

step "Harbor ${HARBOR_VERSION} 번들 빌드 (OS 공용)"
#---------------------------------------------------------------------
# 매 빌드에 다시 만드는 것은 먼저 지운다
#
# mkdir -p 만 쓰면 이전 빌드의 파일이 그대로 남아 새 아카이브에 실린다.
# 실측 사고: site.env 를 뺀 뒤 다시 빌드했는데도 이전 빌드의 site.env 가
# 번들에 남아 내부 IP·사내 호스트명이 그대로 들어갔다. SHA256SUMS 는 그것까지
# 포함해 만들어지므로 무결성 검사로도 걸러지지 않는다.
#
# debs / images / bin 은 의도적 다운로드 캐시라 남긴다. 아래는 매번
# 스크립트가 생성·복사하는 것들이므로 지워도 재빌드 비용이 없다.
#---------------------------------------------------------------------
rm -rf "${BUNDLE_DIR}/00-common" "${BUNDLE_DIR}/conf" "${BUNDLE_DIR}/90-verify"
rm -f  "${BUNDLE_DIR}"/*.sh "${BUNDLE_DIR}"/*.md \
       "${BUNDLE_DIR}/SHA256SUMS" "${BUNDLE_DIR}/BUNDLE-INFO"

mkdir -p "$INSTALLER_DIR" "$CONF_DIR" "$SRC_DIR"

#=====================================================================
# 1. 공식 오프라인 인스톨러
#=====================================================================
step "오프라인 인스톨러 다운로드 (약 700MB)"

TGZ="${SRC_DIR}/harbor-offline-installer-${HARBOR_VERSION}.tgz"
fetch "$HARBOR_OFFLINE_URL" "$TGZ"

# 내용 검증. 이미지 tar 가 없으면 온라인 인스톨러를 받은 것이다(설치 중 pull 시도).
step "인스톨러 내용 검증"
mapfile -t ENTRIES < <(tar tzf "$TGZ")
printf '    %s\n' "${ENTRIES[@]}"

IMAGE_TAR="harbor/harbor.${HARBOR_VERSION}.tar.gz"
printf '%s\n' "${ENTRIES[@]}" | grep -qx "$IMAGE_TAR" \
    || die "$(cat <<MSG
인스톨러에 이미지 아카이브(${IMAGE_TAR})가 없다.
오프라인 인스톨러가 아니라 온라인 인스톨러를 받은 것으로 보인다.
온라인 인스톨러는 설치 중 레지스트리에서 pull 하므로 에어갭에서 쓸 수 없다.
URL 확인: ${HARBOR_OFFLINE_URL}
MSG
)"
ok "이미지 아카이브 포함 확인: ${IMAGE_TAR}"

for must in "harbor/install.sh" "harbor/prepare" "harbor/harbor.yml.tmpl" "harbor/common.sh"; do
    printf '%s\n' "${ENTRIES[@]}" | grep -qx "$must" || die "인스톨러에 ${must} 가 없다"
done
ok "install.sh / prepare / harbor.yml.tmpl / common.sh 확인"

cp "$TGZ" "${INSTALLER_DIR}/"
ok "인스톨러 복사 ($(du -h "$TGZ" | cut -f1))"

#=====================================================================
# 2. harbor.yml 템플릿
#
# 업스트림 harbor.yml.tmpl 을 그대로 쓰지 않는다. 기본값이 우리 구성과
# 다르고(데이터 경로, trivy, 포트), 에어갭에서 문제가 되는 항목이 있다.
# 필요한 최소 구성만 명시적으로 쓴다.
#=====================================================================
step "harbor.yml 템플릿 생성"

cat > "${CONF_DIR}/harbor.yml.tmpl" <<'EOF'
#---------------------------------------------------------------------
# Harbor 설정 — 30-harbor/install.sh 가 템플릿에서 생성한다.
#
# 이 파일을 고친 뒤에는 반드시 prepare 를 다시 돌려야 반영된다.
# compose 파일이 이 값으로 생성되기 때문이다:
#   cd /opt/harbor && sudo ./prepare && sudo systemctl restart harbor
#---------------------------------------------------------------------

# 클라이언트가 접속할 이름. 인증서 SAN 과 반드시 일치해야 한다.
# IP 를 쓰면 docker login 이 인증서 검증에 실패하는 경우가 많다.
hostname: __HARBOR_HOSTNAME__

# HTTP 는 정의하지 않는다. 정의하면 80 으로도 열리고, docker 가
# 평문 레지스트리로 붙으려 해 insecure-registries 설정이 필요해진다.
https:
  port: 443
  certificate: __HARBOR_DIR__/certs/harbor.crt
  private_key: __HARBOR_DIR__/certs/harbor.key

# 초기 admin 비밀번호. 최초 기동 시에만 쓰인다.
# 이후 변경은 UI/API 로 하며 이 값을 고쳐도 반영되지 않는다.
harbor_admin_password: __HARBOR_ADMIN_PASSWORD__

# 내장 PostgreSQL. 외부 DB 를 쓰지 않으므로 별도 구성이 불필요하다.
database:
  password: __HARBOR_DB_PASSWORD__
  max_idle_conns: 100
  max_open_conns: 900
  conn_max_lifetime: 5m
  conn_max_idle_time: 0

# 이미지·DB·로그가 모두 여기 쌓인다. 별도 볼륨을 붙이는 것을 권장한다.
data_volume: __HARBOR_DATA_DIR__

trivy:
  # 에어갭에서는 취약점 DB 를 갱신할 수 없다. skip_update=true 로 두지 않으면
  # 기동 시 github.com 으로 나가려 하다 실패하고 trivy 가 계속 재시도한다.
  # (오프라인 검증에서 airgap-fwd-other 카운터를 올리는 원인이 된다)
  ignore_unfixed: false
  skip_update: true
  offline_scan: true
  security_check: vuln
  insecure: false

jobservice:
  max_job_workers: 10
  job_loggers:
    - STD_OUTPUT
    - FILE
  logger_sweeper_duration: 1

notification:
  webhook_job_max_retry: 3
  webhook_job_http_client_timeout: 3

log:
  level: info
  local:
    rotate_count: 50
    rotate_size: 200M
    location: /var/log/harbor

_version: __HARBOR_YML_VERSION__

proxy:
  http_proxy:
  https_proxy:
  no_proxy:
  components:
    - core
    - jobservice
    - trivy

upload_purging:
  enabled: true
  age: 168h
  interval: 24h
  dryrun: false

cache:
  enabled: false
  expire_hours: 24
EOF
ok "harbor.yml.tmpl"

#=====================================================================
# 3. TLS 인증서용 openssl 설정
#
# 인증서는 타깃에서 만든다. SAN 에 타깃 호스트명·IP 가 들어가야 하고
# 그 값은 타깃에서만 알 수 있다.
#=====================================================================
cat > "${CONF_DIR}/harbor-openssl.cnf.tmpl" <<'EOF'
# Harbor 자가서명 서버 인증서용 설정
[req]
default_bits       = 4096
prompt             = no
default_md         = sha256
distinguished_name = dn
x509_extensions    = v3_req

[dn]
C  = KR
O  = Vanilla K8s
OU = Harbor
CN = __HARBOR_HOSTNAME__

[v3_req]
basicConstraints = CA:FALSE
keyUsage         = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName   = @alt_names

[alt_names]
DNS.1 = __HARBOR_HOSTNAME__
DNS.2 = localhost
IP.1  = __HARBOR_HOST_IP__
IP.2  = 127.0.0.1
EOF
ok "harbor-openssl.cnf.tmpl"

#=====================================================================
# 4. 기동 스크립트 — harbor-log 를 먼저 띄운다
#
# 이 스크립트가 있는 이유(실측 근거):
#   harbor-log 를 제외한 8개 컨테이너는 logging driver 가
#   syslog / tcp://localhost:1514 이고, 그 포트는 harbor-log 가 제공한다.
#   Docker 데몬의 restart 정책은 compose 의 depends_on 순서를 지키지 않고
#   부팅 시 9개를 동시에 기동한다. harbor-log 가 1514 를 바인드하기 전에
#   나머지가 뜨면 컨테이너 생성 단계에서
#     failed to initialize logging driver:
#     dial tcp 127.0.0.1:1514: connect: connection refused
#   로 exit 128 하고, 재시도 백오프를 소진한 뒤 영구 정지한다.
#   실제로 9개 중 8개가 미기동되어 443 리스너가 사라진 사례가 있다.
#
#   compose 의 `depends_on: - log` 는 "컨테이너 시작"까지만 보장하고
#   포트 수신 준비를 기다리지 않는다. 그래서 1514 대기를 여기서 명시한다.
#=====================================================================
step "기동 스크립트 / systemd 유닛 생성"

cat > "${CONF_DIR}/harbor-start.sh" <<'EOF'
#!/usr/bin/env bash
#---------------------------------------------------------------------
# Harbor 기동 스크립트 (systemd harbor.service 의 ExecStart)
#
# harbor-log(syslog 1514)를 먼저 띄우고 포트 수신을 확인한 뒤 나머지를
# 기동한다. 이유는 30-harbor/README.md 3절에 있다.
#
# 설치 위치: /usr/local/bin/harbor-start.sh (root:root 0755)
#---------------------------------------------------------------------
set -uo pipefail

COMPOSE_DIR=__HARBOR_DIR__
SYSLOG_HOST=127.0.0.1
SYSLOG_PORT=1514
WAIT_SYSLOG_SECS=60      # 1514 대기 상한
WAIT_READY_TRIES=90      # 전체 서비스 running 대기: 90 x 2s = 180s

log() { echo "[harbor-start] $*"; }

cd "$COMPOSE_DIR" || { log "FATAL: $COMPOSE_DIR 에 접근할 수 없음"; exit 1; }

#--- 1단계: syslog 수집기를 단독으로 먼저 기동 ------------------------
log "harbor-log 기동"
docker compose up -d log

#--- 2단계: 1514 가 실제로 연결을 받을 때까지 대기 --------------------
log "${SYSLOG_HOST}:${SYSLOG_PORT} 대기 (최대 ${WAIT_SYSLOG_SECS}s)"
syslog_ready=0
for ((i = 1; i <= WAIT_SYSLOG_SECS; i++)); do
    if timeout 1 bash -c ">/dev/tcp/${SYSLOG_HOST}/${SYSLOG_PORT}" 2>/dev/null; then
        log "${SYSLOG_PORT} 준비됨 (${i}s 경과)"
        syslog_ready=1
        break
    fi
    sleep 1
done
if ((syslog_ready == 0)); then
    log "FATAL: ${SYSLOG_PORT} 가 ${WAIT_SYSLOG_SECS}s 안에 열리지 않음. harbor-log 로그:"
    docker compose logs --tail 40 log 2>&1 || true
    exit 1
fi

#--- 3단계: 나머지 전체 기동 (compose depends_on 순서를 따른다) -------
log "나머지 서비스 기동"
docker compose up -d

#--- 4단계: 모든 서비스가 running 인지 확인 ---------------------------
mapfile -t services < <(docker compose config --services)
log "대상 서비스 ${#services[@]}개: ${services[*]}"

declare -a broken=()
for ((try = 1; try <= WAIT_READY_TRIES; try++)); do
    broken=()
    for svc in "${services[@]}"; do
        state=$(docker compose ps -a --format '{{.State}}' "$svc" 2>/dev/null | head -1)
        [[ "$state" == "running" ]] || broken+=("${svc}=${state:-missing}")
    done
    ((${#broken[@]} == 0)) && break
    sleep 2
done

if ((${#broken[@]} > 0)); then
    log "FATAL: running 상태가 아닌 서비스: ${broken[*]}"
    for entry in "${broken[@]}"; do
        svc=${entry%%=*}
        log "--- ${svc} 로그 ---"
        docker compose logs --tail 20 "$svc" 2>&1 || true
    done
    exit 1
fi

log "서비스 ${#services[@]}개 전부 running"

#--- 참고 정보: 외부 수신 포트 (실패로 보지 않음) ---------------------
if timeout 2 bash -c ">/dev/tcp/127.0.0.1/443" 2>/dev/null; then
    log "443 수신 정상"
else
    log "WARN: 443 이 아직 수신하지 않음 (proxy 헬스체크 진행 중일 수 있음)"
fi

log "완료"
EOF
ok "harbor-start.sh"

cat > "${CONF_DIR}/harbor.service" <<'EOF'
#---------------------------------------------------------------------
# Harbor 자동 기동 유닛
#
# 왜 systemd 유닛이 필요한가:
#   Docker 의 재시작 정책만으로는 compose 의 depends_on 순서가 지켜지지
#   않아 부팅 시 harbor-log 보다 다른 컨테이너가 먼저 떠서 죽는다.
#   기동 순서를 보장하려면 별도 오케스트레이션이 필요하다.
#   (40-haproxy 는 의존 대상이 없어 재시작 정책만으로 충분했다)
#---------------------------------------------------------------------
[Unit]
Description=Harbor container registry (docker compose)
Documentation=https://goharbor.io/docs/
# docker.socket 까지 Requires 하면 소켓 활성화와 꼬일 수 있어 service 만 건다
Requires=docker.service
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=__HARBOR_DIR__

# 기동: harbor-log -> 1514 대기 -> 나머지 -> 전 서비스 running 확인
ExecStart=/usr/local/bin/harbor-start.sh

# 종료: 컨테이너를 제거하지 않고 정지만 한다. down 은 네트워크와 컨테이너를
# 삭제하므로 재기동이 느려지고, harbor-db 의 정상 종료 시간도 필요하다.
ExecStop=/usr/bin/docker compose -f __HARBOR_DIR__/docker-compose.yml stop

# 기동 대기(1514 60s + 서비스 180s)를 모두 흡수할 수 있는 상한
TimeoutStartSec=300
TimeoutStopSec=180

StandardOutput=journal
StandardError=journal
SyslogIdentifier=harbor

[Install]
WantedBy=multi-user.target
EOF
ok "harbor.service"

#=====================================================================
# 5. 패키징
#=====================================================================
step "번들 패키징"
mkdir -p "${BUNDLE_DIR}/00-common"
cp "${SCRIPT_DIR}/../00-common/versions.env" "${BUNDLE_DIR}/00-common/"
if [[ -f "${SCRIPT_DIR}/../00-common/site.env" ]]; then
    cp "${SCRIPT_DIR}/../00-common/site.env" "${BUNDLE_DIR}/00-common/"
else
    cp "${SCRIPT_DIR}/../00-common/site.env.example" "${BUNDLE_DIR}/00-common/"
    warn "site.env 가 없어 예시 값으로 번들을 만든다. 타깃에서 값을 채워야 한다."
fi
cp "${SCRIPT_DIR}/../00-common/common.sh" "${BUNDLE_DIR}/00-common/"
cp "${SCRIPT_DIR}/install.sh"             "${BUNDLE_DIR}/"
cp "${SCRIPT_DIR}/README.md"              "${BUNDLE_DIR}/" 2>/dev/null || true
chmod +x "${BUNDLE_DIR}/install.sh"

cat > "${BUNDLE_DIR}/BUNDLE-INFO" <<EOF
bundle        : ${BUNDLE_NAME}
bundle_version: ${BUNDLE_VERSION}
built_at      : $(date -Is)
built_on      : $(hostname)
target_os     : Ubuntu 22.04 / 24.04 공용 (OS 의존 없음)
harbor        : ${HARBOR_VERSION} (공식 오프라인 인스톨러)
인스톨러      : harbor-offline-installer-${HARBOR_VERSION}.tgz
DB            : 내장 PostgreSQL (외부 DB 불필요)
포트          : 443 (HTTPS). HTTP 는 열지 않는다
기동          : systemd harbor.service + harbor-start.sh (1514 선행 대기)
trivy         : skip_update=true / offline_scan=true (에어갭)
EOF

write_manifest "$BUNDLE_DIR"

TARBALL="${SCRIPT_DIR}/bundle/${BUNDLE_NAME}.tar.gz"
tar -C "${SCRIPT_DIR}/bundle" -czf "$TARBALL" "$BUNDLE_NAME"
# `sha256sum -c` 가 읽을 수 있는 형식으로 쓴다. 해시만 남기면
# "no properly formatted checksum lines found" 로 검증 자체가 되지 않는다.
# 경로가 아니라 파일명만 넣어야 타깃에서 같은 디렉터리에 두고 검증할 수 있다.
( cd "$(dirname "$TARBALL")" && sha256sum "$(basename "$TARBALL")" ) > "${TARBALL}.sha256"

step "완료"
cat "${BUNDLE_DIR}/BUNDLE-INFO"
echo
ok "번들: ${TARBALL} ($(du -h "$TARBALL" | cut -f1))"
