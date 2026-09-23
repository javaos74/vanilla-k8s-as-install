#!/usr/bin/env bash
#---------------------------------------------------------------------
# 20-minio : 오프라인 번들 빌드 (온라인 호스트에서 실행)
#
# 산출물: bundle/minio-<릴리스>/ + .tar.gz
#
# 용도: UiPath Automation Suite 의 오브젝트 스토리지. S3 호환.
#       단일 노드 · 단일 드라이브(SNSD) 구성, TLS 활성.
#
# 중요 — 왜 컨테이너 이미지만 담는가:
#   MinIO 오픈소스(server/mc/KES)가 아카이브되어 dl.min.io 가 410 Gone 을
#   반환한다. 바이너리 배포 경로가 사라졌고 GitHub 릴리스에도 에셋이 없다.
#   현재 살아 있는 유일한 경로가 quay.io 컨테이너 이미지다.
#   따라서 deb/tarball 설치는 불가능하고 컨테이너로만 구성한다.
#   보안 업데이트는 더 이상 제공되지 않는다 — 폐쇄망 운용을 전제로 한다.
#
# OS 의존 없음(이미지 + 설정뿐). 22.04 / 24.04 공용.
# docker / docker compose 는 10-k8s 번들에서 설치된다.
#---------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../00-common/common.sh"

require_online
require_cmds curl tar openssl

MINIO_TAG="${MINIO_IMAGE##*:}"
BUNDLE_NAME="minio-${MINIO_TAG}"
BUNDLE_DIR="${SCRIPT_DIR}/bundle/${BUNDLE_NAME}"
IMG_DIR="${BUNDLE_DIR}/images"
CONF_DIR="${BUNDLE_DIR}/conf"

step "MinIO ${MINIO_TAG} 번들 빌드 (OS 공용)"
mkdir -p "$IMG_DIR" "$CONF_DIR"

if ! command -v skopeo >/dev/null 2>&1; then
    log "skopeo 설치(빌드 도구)"
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq skopeo
fi
ok "skopeo $(skopeo --version | awk '{print $3}')"

#=====================================================================
# 1. 이미지
#
# mc(MinIO Client)도 함께 담는다. 이유가 두 가지다.
#   1) compose healthcheck 가 서버 이미지 안의 mc 를 쓴다.
#   2) install.sh 의 판정에서 버킷 생성·쓰기·읽기 왕복 검증에 쓴다.
#      별도 컨테이너로 돌리면 서버 이미지를 건드리지 않고 검증할 수 있다.
#=====================================================================
step "이미지 다운로드"

MINIO_IMAGES=("$MINIO_IMAGE" "$MINIO_MC_IMAGE")
for img in "${MINIO_IMAGES[@]}"; do
    out="${IMG_DIR}/$(image_to_filename "$img").tar"
    if [[ -s "$out" ]]; then
        log "이미 존재: $(basename "$out")"
    else
        log "이미지 받기: $img"
        skopeo copy --retry-times 5 "docker://${img}" \
            "docker-archive:${out}.part:${img}" >/dev/null \
            || die "이미지 받기 실패: $img"
        mv "${out}.part" "$out"
    fi
    ok "$(basename "$out") ($(du -h "$out" | cut -f1))"
done
printf '%s\n' "${MINIO_IMAGES[@]}" > "${CONF_DIR}/images.list"

# 다이제스트를 기록해 둔다. 아카이브된 배포라 태그가 사라질 수 있어,
# 나중에 "우리가 받은 것이 무엇인지" 증명할 근거가 필요하다.
{
    echo "# 빌드 시점에 확인한 이미지 다이제스트"
    for img in "${MINIO_IMAGES[@]}"; do
        d="$(skopeo inspect "docker://${img}" 2>/dev/null \
             | python3 -c 'import sys,json;print(json.load(sys.stdin).get("Digest",""))' 2>/dev/null)"
        echo "${img} ${d}"
    done
} > "${CONF_DIR}/images.digests"
ok "다이제스트 기록: conf/images.digests"

#=====================================================================
# 2. compose 템플릿
#
# 왜 docker compose 인가(40-haproxy 는 docker run 을 쓴다):
#   MinIO 는 env_file(자격증명) + 인증서 볼륨 + healthcheck 를 함께 써야 한다.
#   docker run 으로도 가능하지만 자격증명이 명령행에 노출되고(ps 로 보인다)
#   재현성이 떨어진다. compose 파일로 두면 값이 파일에 남고 diff 가 된다.
#   compose 플러그인은 10-k8s 번들에 포함돼 있다.
#=====================================================================
step "compose 템플릿 생성"

# __로 감싼 값은 install.sh 가 치환한다.
cat > "${CONF_DIR}/docker-compose.yml.tmpl" <<'EOF'
#---------------------------------------------------------------------
# MinIO — 단일 노드 단일 드라이브(SNSD), TLS 활성
#
# 이 파일은 20-minio/install.sh 가 템플릿에서 생성한다.
# 직접 고친 뒤에는 다음으로 반영한다:
#   sudo docker compose -f /opt/minio/docker-compose.yml up -d
#
# 이미지는 MinIO Community Edition 의 마지막 quay.io 릴리스로 고정돼 있다.
# 업스트림이 아카이브되어 갱신 경로가 없다(README 1절).
#---------------------------------------------------------------------
services:
  minio:
    image: __MINIO_IMAGE__
    container_name: minio
    restart: unless-stopped
    # --certs-dir: TLS 인증서 위치. public.crt / private.key 를 찾는다.
    # --console-address: 웹 콘솔을 9001 로 분리한다. 지정하지 않으면
    #                    임의 포트를 잡아 방화벽 규칙을 고정할 수 없다.
    command: server /data --certs-dir /certs --console-address ":9001"
    env_file:
      - __MINIO_DIR__/minio.env
    ports:
      - "9000:9000"   # S3 API (HTTPS)
      - "9001:9001"   # 웹 콘솔 (HTTPS)
    extra_hosts:
      # 사내 DNS 에 이 이름이 없을 수 있다. 컨테이너 안에서도 해석되게 박아둔다.
      # MINIO_SERVER_URL 이 이 이름을 쓰므로 자기 참조에 필요하다.
      - "__MINIO_HOSTNAME__:__MINIO_HOST_IP__"
    volumes:
      - __MINIO_DATA_DIR__:/data
      - __MINIO_DIR__/certs:/certs:ro
    healthcheck:
      # mc 의 내장 "local" alias 는 http://localhost:9000 을 가리키므로
      # TLS 전용 서버에서는 동작하지 않는다. https alias 를 따로 만든다.
      # --insecure: 자가서명 인증서를 쓰기 때문이다.
      # $$ 는 compose 의 변수 확장을 피하고 컨테이너 셸에 $ 로 전달하기 위함이다.
      test:
        - CMD-SHELL
        - mc --insecure alias set hc https://localhost:9000 "$$MINIO_ROOT_USER" "$$MINIO_ROOT_PASSWORD" >/dev/null 2>&1 && mc --insecure ready hc >/dev/null 2>&1
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 20s
    logging:
      driver: json-file
      options:
        max-size: "20m"
        max-file: "5"
EOF
ok "docker-compose.yml.tmpl"

#=====================================================================
# 3. env 템플릿
#=====================================================================
cat > "${CONF_DIR}/minio.env.tmpl" <<'EOF'
#---------------------------------------------------------------------
# MinIO 자격증명 및 엔드포인트
#
# 이 파일은 root 만 읽을 수 있어야 한다(0600). install.sh 가 권한을 맞춘다.
# 자격증명을 바꾸면 컨테이너를 재생성해야 반영된다.
#---------------------------------------------------------------------

# 루트 자격증명. MINIO_ROOT_USER 는 3자 이상, PASSWORD 는 8자 이상이어야
# MinIO 가 기동한다. 짧으면 기동 직후 종료되고 로그에만 이유가 남는다.
MINIO_ROOT_USER=__MINIO_ROOT_USER__
MINIO_ROOT_PASSWORD=__MINIO_ROOT_PASSWORD__

# 클라이언트에게 알려줄 자기 주소.
# 이것을 설정하지 않으면 콘솔이 localhost 로 리다이렉트를 만들어
# 외부 브라우저에서 접속이 끊긴다.
MINIO_SERVER_URL=https://__MINIO_HOSTNAME__:9000
MINIO_BROWSER_REDIRECT_URL=https://__MINIO_HOSTNAME__:9001

# 가상 호스트 스타일 버킷 주소(bucket.host)를 쓰려면 필요하다.
MINIO_DOMAIN=__MINIO_HOSTNAME__

# 리전. UiPath AS 는 S3 클라이언트에 리전을 요구한다.
MINIO_REGION=__MINIO_REGION__
EOF
ok "minio.env.tmpl"

#=====================================================================
# 4. TLS 인증서 생성용 openssl 설정
#
# 인증서는 빌드 시점이 아니라 install.sh 에서 만든다. SAN 에 타깃 노드의
# 호스트명과 IP 가 들어가야 하고, 그 값은 타깃에서만 알 수 있기 때문이다.
# 빌드 호스트에서 만들면 SAN 이 맞지 않아 클라이언트가 거부한다.
#=====================================================================
cat > "${CONF_DIR}/minio-openssl.cnf.tmpl" <<'EOF'
# MinIO 자가서명 서버 인증서용 설정
# install.sh 가 __로 감싼 값을 치환한 뒤 openssl req 에 넘긴다.
[req]
default_bits       = 4096
prompt             = no
default_md         = sha256
distinguished_name = dn
x509_extensions    = v3_req

[dn]
C  = KR
O  = Vanilla K8s
OU = MinIO
CN = __MINIO_HOSTNAME__

[v3_req]
basicConstraints = CA:FALSE
keyUsage         = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName   = @alt_names

[alt_names]
DNS.1 = __MINIO_HOSTNAME__
DNS.2 = localhost
IP.1  = __MINIO_HOST_IP__
IP.2  = 127.0.0.1
EOF
ok "minio-openssl.cnf.tmpl"

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
minio         : ${MINIO_IMAGE}
mc            : ${MINIO_MC_IMAGE}
구성          : 단일 노드 단일 드라이브(SNSD), TLS 활성
포트          : 9000(S3 API) / 9001(콘솔)
리전          : ${MINIO_REGION}
재시작 정책   : unless-stopped
주의          : 업스트림 아카이브됨. 보안 업데이트 없음(README 1절)
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
