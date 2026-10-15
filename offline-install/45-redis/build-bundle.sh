#!/usr/bin/env bash
# Redis OSS 단일 노드 오프라인 번들 빌드
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../00-common/common.sh"

require_online
require_cmds curl tar

REDIS_TAG="${REDIS_IMAGE##*:}"
BUNDLE_NAME="redis-${REDIS_TAG}"
BUNDLE_DIR="${SCRIPT_DIR}/bundle/${BUNDLE_NAME}"
IMG_DIR="${BUNDLE_DIR}/images"
CONF_DIR="${BUNDLE_DIR}/conf"

step "Redis OSS ${REDIS_TAG} 번들 빌드"
rm -rf "${BUNDLE_DIR}/00-common" "${BUNDLE_DIR}/conf" "${BUNDLE_DIR}/90-verify"
rm -f "${BUNDLE_DIR}"/*.sh "${BUNDLE_DIR}"/*.md \
      "${BUNDLE_DIR}/SHA256SUMS" "${BUNDLE_DIR}/BUNDLE-INFO"
mkdir -p "$IMG_DIR" "$CONF_DIR"

if ! command -v skopeo >/dev/null 2>&1; then
    log "skopeo 설치(빌드 도구)"
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq skopeo
fi
ok "skopeo $(skopeo --version | awk '{print $3}')"

step "공식 이미지 확인 및 다운로드"
REDIS_DIGEST="$(skopeo inspect --override-arch amd64 --override-os linux \
    --format '{{.Digest}}' "docker://${REDIS_IMAGE}")" \
    || die "Redis 이미지 digest 조회 실패: ${REDIS_IMAGE}"
[[ "$REDIS_DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]] || die "올바르지 않은 이미지 digest: ${REDIS_DIGEST}"
REDIS_REPOSITORY="${REDIS_IMAGE%%:*}"
IMG_TAR="${IMG_DIR}/$(image_to_filename "$REDIS_IMAGE").tar"
if [[ -s "$IMG_TAR" ]]; then
    log "이미 존재: $(basename "$IMG_TAR")"
else
    rm -f "${IMG_TAR}.part"
    skopeo copy --override-arch amd64 --override-os linux --retry-times 5 \
        "docker://${REDIS_REPOSITORY}@${REDIS_DIGEST}" \
        "docker-archive:${IMG_TAR}.part:${REDIS_IMAGE}" >/dev/null \
        || die "이미지 받기 실패: ${REDIS_REPOSITORY}@${REDIS_DIGEST}"
    mv "${IMG_TAR}.part" "$IMG_TAR"
fi
ok "$(basename "$IMG_TAR") ($(du -h "$IMG_TAR" | cut -f1))"
printf '%s\n' "$REDIS_IMAGE" > "${CONF_DIR}/images.list"
printf '# 빌드 시점 이미지 digest\n%s %s\n' "$REDIS_IMAGE" "$REDIS_DIGEST" > "${CONF_DIR}/images.digests"

cat > "${CONF_DIR}/docker-compose.yml.tmpl" <<'EOF'
services:
  redis:
    image: __REDIS_IMAGE__
    container_name: redis
    restart: unless-stopped
    ports:
      - "__REDIS_BIND_IP__:__REDIS_PORT__:6379"
    volumes:
      - __REDIS_DATA_DIR__:/data
      - /opt/redis/redis.conf:/usr/local/etc/redis/redis.conf:ro
      - /opt/redis/certs:/etc/redis/certs:ro
    command: ["redis-server", "/usr/local/etc/redis/redis.conf"]
    stop_grace_period: 1m
    healthcheck:
      test:
        - CMD-SHELL
        - >-
          REDISCLI_AUTH="$$(sed -n 's/^requirepass //p' /usr/local/etc/redis/redis.conf)"
          redis-cli --tls --cacert /etc/redis/certs/ca.crt -h localhost -p 6379 ping
          | grep -qx PONG
      interval: 10s
      timeout: 5s
      retries: 6
      start_period: 15s
    logging:
      driver: json-file
      options:
        max-size: "20m"
        max-file: "5"
EOF

mkdir -p "${BUNDLE_DIR}/00-common"
cp "${SCRIPT_DIR}/../00-common/versions.env" "${BUNDLE_DIR}/00-common/"
if [[ -f "${SCRIPT_DIR}/../00-common/site.env" ]]; then
    cp "${SCRIPT_DIR}/../00-common/site.env" "${BUNDLE_DIR}/00-common/"
else
    cp "${SCRIPT_DIR}/../00-common/site.env.example" "${BUNDLE_DIR}/00-common/"
    warn "site.env 가 없어 예시 값으로 번들을 만든다. 타깃 환경에 맞게 수정할 것."
fi
cp "${SCRIPT_DIR}/../00-common/common.sh" "${BUNDLE_DIR}/00-common/"
cp "${SCRIPT_DIR}/install.sh" "${BUNDLE_DIR}/"
cp "${SCRIPT_DIR}/README.md" "${BUNDLE_DIR}/"
chmod +x "${BUNDLE_DIR}/install.sh"

cat > "${BUNDLE_DIR}/BUNDLE-INFO" <<EOF
bundle        : ${BUNDLE_NAME}
bundle_version: ${BUNDLE_VERSION}
built_at      : $(date -Is)
built_on      : $(hostname)
target_os     : Ubuntu 22.04 / 24.04 공용 (Docker 의존)
image         : ${REDIS_IMAGE}
digest        : ${REDIS_DIGEST}
listener      : TLS only, port ${REDIS_PORT}
mode          : Redis OSS single node
EOF

write_manifest "$BUNDLE_DIR"
TARBALL="${SCRIPT_DIR}/bundle/${BUNDLE_NAME}.tar.gz"
tar -C "${SCRIPT_DIR}/bundle" -czf "$TARBALL" "$BUNDLE_NAME"
(cd "$(dirname "$TARBALL")" && sha256sum "$(basename "$TARBALL")") > "${TARBALL}.sha256"
step "완료"
cat "${BUNDLE_DIR}/BUNDLE-INFO"
echo
ok "번들: ${TARBALL} ($(du -h "$TARBALL" | cut -f1))"
