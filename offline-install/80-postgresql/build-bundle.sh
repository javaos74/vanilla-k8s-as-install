#!/usr/bin/env bash
#---------------------------------------------------------------------
# 80-postgresql : 오프라인 번들 빌드 (온라인 호스트에서 실행)
#
# 산출물: bundle/postgresql-<ver>/ + .tar.gz
#
# 용도: UiPath Automation Suite 일부 구성요소용 PostgreSQL.
#       (Harbor 는 내장 PostgreSQL 을 쓰므로 이 단계와 무관하다)
#
# 왜 공식 이미지인가:
#   업스트림이 유지·보안 갱신을 계속하므로 자체 빌드보다 낫다.
#   베이스 OS 를 jammy 로 맞춰야 하는 제약이 있을 때만
#   versions.env 의 POSTGRES_IMAGE 를 POSTGRES_JAMMY_IMAGE 로 바꾼다.
#   (공식 이미지는 Debian bookworm 기반이다)
#
# TLS 를 반드시 켠다 — 이유는 README 2절. AS 의 temporal-sql-tool 이
# SQL_TLS=true 로 실행되므로 평문 서버에는 붙지 못한다.
#
# OS 의존 없음. docker / docker compose 는 10-k8s 번들에서 설치된다.
#---------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../00-common/common.sh"

require_online
require_cmds curl tar

PG_TAG="${POSTGRES_IMAGE##*:}"
BUNDLE_NAME="postgresql-${PG_TAG}"
BUNDLE_DIR="${SCRIPT_DIR}/bundle/${BUNDLE_NAME}"
IMG_DIR="${BUNDLE_DIR}/images"
CONF_DIR="${BUNDLE_DIR}/conf"

step "PostgreSQL ${PG_TAG} 번들 빌드"
mkdir -p "$IMG_DIR" "$CONF_DIR"

if ! command -v skopeo >/dev/null 2>&1; then
    log "skopeo 설치(빌드 도구)"
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq skopeo
fi
ok "skopeo $(skopeo --version | awk '{print $3}')"

#=====================================================================
# 1. 이미지 (다이제스트 고정)
#=====================================================================
step "이미지 다운로드"

IMG_REF="${POSTGRES_IMAGE%%:*}@${POSTGRES_IMAGE_DIGEST}"
IMG_TAR="${IMG_DIR}/$(image_to_filename "$POSTGRES_IMAGE").tar"

if [[ -s "$IMG_TAR" ]]; then
    log "이미 존재: $(basename "$IMG_TAR")"
else
    log "받는 중: ${IMG_REF}"
    skopeo copy --retry-times 5 "docker://${IMG_REF}" \
        "docker-archive:${IMG_TAR}.part:${POSTGRES_IMAGE}" >/dev/null \
        || die "이미지 받기 실패: ${IMG_REF}"
    mv "${IMG_TAR}.part" "$IMG_TAR"
fi
ok "$(basename "$IMG_TAR") ($(du -h "$IMG_TAR" | cut -f1))"

echo "$POSTGRES_IMAGE" > "${CONF_DIR}/images.list"
cat > "${CONF_DIR}/images.digests" <<EOF
# 빌드 시점에 확인한 이미지 다이제스트
${POSTGRES_IMAGE} ${POSTGRES_IMAGE_DIGEST}
EOF

#=====================================================================
# 2. compose 템플릿
#
# 튜닝 값과 TLS 설정은 운영 중인 환경에서 검증된 조합이다.
# 각 항목의 근거는 아래 주석과 README 에 있다.
#=====================================================================
step "compose 템플릿 생성"

cat > "${CONF_DIR}/docker-compose.yml.tmpl" <<'EOF'
#---------------------------------------------------------------------
# PostgreSQL — 단일 노드, TLS 활성
#
# 이 파일은 80-postgresql/install.sh 가 템플릿에서 생성한다.
# 고친 뒤에는 다음으로 반영한다:
#   sudo docker compose -f /opt/postgresql/docker-compose.yml up -d
#---------------------------------------------------------------------
services:
  postgres:
    image: __POSTGRES_IMAGE__
    container_name: postgres
    restart: unless-stopped
    ports:
      # 사내망에만 노출한다. 방화벽/보안그룹에서 5432 를 인터넷에 열지 말 것.
      - "__POSTGRES_PORT__:5432"
    env_file:
      - __PG_DIR__/postgres.env
    command:
      - postgres
      #--- 접속·메모리 ------------------------------------------------
      - -c
      - max_connections=200
      - -c
      - shared_buffers=2GB
      - -c
      - effective_cache_size=6GB
      - -c
      - work_mem=16MB
      - -c
      - maintenance_work_mem=512MB
      - -c
      - wal_compression=on
      #--- 인증 -------------------------------------------------------
      # md5 가 아니라 scram-sha-256 을 쓴다. md5 는 취약하고 최신
      # 클라이언트는 기본으로 scram 을 요구한다.
      - -c
      - password_encryption=scram-sha-256
      #--- 시간대 -----------------------------------------------------
      - -c
      - log_timezone=__PG_TZ__
      - -c
      - timezone=__PG_TZ__
      #--- TLS --------------------------------------------------------
      # UiPath AS 의 temporal-sql-tool(taas-temporal-schema 잡)이
      # SQL_TLS=true 로 실행되므로 평문 서버에는 붙지 못한다.
      # 다만 SQL_TLS_DISABLE_HOST_VERIFICATION=true 도 함께 설정하므로
      # 자가서명 인증서로 충분하다(CA 체인·호스트명 검증을 하지 않는다).
      - -c
      - ssl=on
      - -c
      - ssl_cert_file=/etc/postgresql/certs/server.crt
      - -c
      - ssl_key_file=/etc/postgresql/certs/server.key
      - -c
      - ssl_min_protocol_version=TLSv1.2
    volumes:
      - __PG_DATA_DIR__:/var/lib/postgresql/data
      # 인증서는 컨테이너의 postgres uid 소유여야 한다. 아니면 기동이 실패한다.
      - __PG_DIR__/certs:/etc/postgresql/certs:ro
    # PostgreSQL 은 공유 메모리를 쓴다. 기본 64MB 로는 shared_buffers 를
    # 크게 잡을 때 부족하다.
    shm_size: "1gb"
    stop_grace_period: 1m
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres -d postgres"]
      interval: 10s
      timeout: 5s
      retries: 6
      start_period: 30s
    logging:
      driver: json-file
      options:
        max-size: "20m"
        max-file: "5"
EOF
ok "docker-compose.yml.tmpl"

cat > "${CONF_DIR}/postgres.env.tmpl" <<'EOF'
#---------------------------------------------------------------------
# PostgreSQL 환경변수 — root 만 읽을 수 있어야 한다(0600).
#---------------------------------------------------------------------
POSTGRES_USER=__PG_SUPERUSER__
POSTGRES_PASSWORD=__PG_PASSWORD__
POSTGRES_DB=postgres

# 초기화 시 인코딩과 체크섬. 체크섬은 나중에 켤 수 없으므로 처음에 켠다.
POSTGRES_INITDB_ARGS=--encoding=UTF8 --data-checksums

# 공식 이미지는 PGDATA 하위 디렉터리를 쓰라고 권고한다. 볼륨 루트에 바로
# 초기화하면 lost+found 등이 있을 때 initdb 가 거부한다.
PGDATA=/var/lib/postgresql/data/pgdata

TZ=__PG_TZ__
EOF
ok "postgres.env.tmpl"

cat > "${CONF_DIR}/pg-openssl.cnf.tmpl" <<'EOF'
# PostgreSQL 자가서명 서버 인증서용 설정
[req]
default_bits       = 4096
prompt             = no
default_md         = sha256
distinguished_name = dn
x509_extensions    = v3_req

[dn]
C  = KR
O  = Vanilla K8s
OU = PostgreSQL
CN = __PG_HOSTNAME__

[v3_req]
basicConstraints = CA:FALSE
keyUsage         = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName   = @alt_names

[alt_names]
DNS.1 = __PG_HOSTNAME__
DNS.2 = localhost
IP.1  = __PG_HOST_IP__
IP.2  = 127.0.0.1
EOF
ok "pg-openssl.cnf.tmpl"

#=====================================================================
# 3. 패키징
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
image         : ${POSTGRES_IMAGE}
digest        : ${POSTGRES_IMAGE_DIGEST}
포트          : ${POSTGRES_PORT}
TLS           : 활성 (자가서명). AS 의 SQL_TLS=true 요구를 충족
인증          : scram-sha-256
재시작 정책   : unless-stopped
대안 이미지   : ${POSTGRES_JAMMY_IMAGE} (베이스 OS 를 jammy 로 맞춰야 할 때)
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
