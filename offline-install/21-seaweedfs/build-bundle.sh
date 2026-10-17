#!/usr/bin/env bash
#---------------------------------------------------------------------
# 21-seaweedfs : 오프라인 번들 빌드 (온라인 호스트에서 실행)
#
# 산출물: bundle/seaweedfs-<버전>/ + .tar.gz
#
# 용도: MinIO(20-minio) 대안 검토. S3 호환 오브젝트 스토리지.
#       단일 노드 `weed server` (master + volume + filer + S3 게이트웨이를
#       한 프로세스로) 구성, S3 API 는 TLS 전용.
#
# 왜 MinIO 대안인가:
#   MinIO 오픈소스는 AGPL-3.0 이고 업스트림이 아카이브되어 보안 업데이트가
#   없다(20-minio/README.md 1절). SeaweedFS 는 Apache-2.0 이며 릴리스가
#   계속 나온다. 이미지 라벨로 라이선스를 확인한다(아래 1절).
#
# OS 의존 없음(이미지 + 설정뿐). 22.04 / 24.04 / 26.04 공용.
# docker / docker compose 는 10-k8s 번들에서 설치된다.
#---------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../00-common/common.sh"

require_online
require_cmds curl tar python3

WEED_TAG="${SEAWEEDFS_IMAGE##*:}"
BUNDLE_NAME="seaweedfs-${WEED_TAG}"
BUNDLE_DIR="${SCRIPT_DIR}/bundle/${BUNDLE_NAME}"
IMG_DIR="${BUNDLE_DIR}/images"
CONF_DIR="${BUNDLE_DIR}/conf"

step "SeaweedFS ${WEED_TAG} 번들 빌드 (OS 공용)"
#---------------------------------------------------------------------
# 매 빌드에 다시 만드는 것은 먼저 지운다 (20-minio 와 같은 이유).
# 이전 빌드의 site.env 등이 남아 새 아카이브에 실리는 사고를 막는다.
# images/ 는 의도적 다운로드 캐시라 남긴다.
#---------------------------------------------------------------------
rm -rf "${BUNDLE_DIR}/00-common" "${BUNDLE_DIR}/conf" "${BUNDLE_DIR}/90-verify"
rm -f  "${BUNDLE_DIR}"/*.sh "${BUNDLE_DIR}"/*.md \
       "${BUNDLE_DIR}/SHA256SUMS" "${BUNDLE_DIR}/BUNDLE-INFO"

mkdir -p "$IMG_DIR" "$CONF_DIR"

if ! command -v skopeo >/dev/null 2>&1; then
    log "skopeo 설치(빌드 도구)"
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq skopeo
fi
ok "skopeo $(skopeo --version | awk '{print $3}')"

#=====================================================================
# 1. 이미지
#
# 태그가 아니라 versions.env 의 amd64 다이제스트로 받는다. skopeo 가
# 받은 내용을 다이제스트로 검증하므로 레지스트리가 바꿔치기해도 걸러진다.
# docker-archive 에는 태그 이름을 붙여 둔다 — docker load 후 compose 가
# 태그로 이미지를 찾기 때문이다.
#
# AWS CLI 이미지도 함께 담는다. install.sh 판정에서 버킷 생성·업로드·
# 다운로드 왕복을 실제 S3 클라이언트로 확인하기 위해서다. mc 는 AGPL 이라
# 쓰지 않는다.
#=====================================================================
step "이미지 다운로드 (다이제스트 핀)"

# amd64 자식 매니페스트 다이제스트를 태그에서 다시 찾아 핀과 비교한다.
# 태그가 움직였으면 알려주되, 받는 것은 여전히 핀이다(재현성 우선).
amd64_digest_of() {
    skopeo inspect --raw "docker://$1" 2>/dev/null | python3 -c '
import sys, json
d = json.load(sys.stdin)
for m in d.get("manifests", []):
    p = m.get("platform", {})
    if p.get("os") == "linux" and p.get("architecture") == "amd64":
        print(m["digest"]); break'
}

# 형식: <태그 참조>|<핀 다이제스트>
IMAGES=(
    "${SEAWEEDFS_IMAGE}|${SEAWEEDFS_IMAGE_DIGEST}"
    "${SEAWEEDFS_CLIENT_IMAGE}|${SEAWEEDFS_CLIENT_IMAGE_DIGEST}"
)
: > "${CONF_DIR}/images.list"
{
    echo "# 빌드 시점 이미지 다이제스트 (linux/amd64 매니페스트)"
} > "${CONF_DIR}/images.digests"

for entry in "${IMAGES[@]}"; do
    IFS='|' read -r img pin <<<"$entry"
    [[ "$pin" =~ ^sha256:[0-9a-f]{64}$ ]] || die "versions.env 의 다이제스트 형식 오류: ${img} ${pin}"

    cur="$(amd64_digest_of "$img" || true)"
    if [[ -z "$cur" ]]; then
        warn "태그의 amd64 다이제스트를 확인하지 못했다: ${img} (핀으로 진행)"
    elif [[ "$cur" != "$pin" ]]; then
        warn "태그가 움직였다: ${img}"
        warn "  핀   : ${pin}"
        warn "  현재 : ${cur}"
        warn "  핀 이미지를 받는다. 갱신하려면 versions.env 를 고칠 것."
    else
        ok "태그 = 핀 일치: ${img}"
    fi

    out="${IMG_DIR}/$(image_to_filename "$img").tar"
    if [[ -s "$out" ]]; then
        log "이미 존재: $(basename "$out")"
    else
        log "이미지 받기: ${img%%:*}@${pin}"
        rm -f "${out}.part"
        skopeo copy --retry-times 5 \
            "docker://${img%:*}@${pin}" \
            "docker-archive:${out}.part:${img}" >/dev/null \
            || die "이미지 받기 실패: ${img%:*}@${pin}"
        mv "${out}.part" "$out"
    fi
    ok "$(basename "$out") ($(du -h "$out" | cut -f1))"
    echo "$img" >> "${CONF_DIR}/images.list"
    echo "${img} ${pin}" >> "${CONF_DIR}/images.digests"
done

# 라이선스 확인. 대안 검토의 핵심 근거이므로 빌드 로그와 BUNDLE-INFO 에 남긴다.
WEED_LICENSE="$(skopeo inspect "docker://${SEAWEEDFS_IMAGE%:*}@${SEAWEEDFS_IMAGE_DIGEST}" 2>/dev/null \
    | python3 -c 'import sys,json;print((json.load(sys.stdin).get("Labels") or {}).get("org.opencontainers.image.licenses",""))' 2>/dev/null || true)"
if [[ "$WEED_LICENSE" == "Apache-2.0" ]]; then
    ok "SeaweedFS 이미지 라이선스 라벨: ${WEED_LICENSE}"
else
    warn "SeaweedFS 이미지 라이선스 라벨이 예상과 다르다: '${WEED_LICENSE}' (Apache-2.0 기대)"
fi

#=====================================================================
# 2. compose 템플릿
#
# 포트는 S3(HTTPS) 하나만 연다. master(9333) / volume(8080) / filer(8888)
# 는 **인증이 없다.** 호스트에 공개하면 S3 자격증명을 우회해 파일을 읽고
# 지울 수 있으므로 컨테이너 루프백에만 묶는다.
#   -ip=127.0.0.1 -ip.bind=127.0.0.1 : 내부 구성요소는 루프백
#   -s3.ip.bind=0.0.0.0              : S3 만 컨테이너 밖(포트 매핑)으로
#
# -master.telemetry=false : 기본값 true 이면 저장량 10GiB 이후 하루 한 번
#   telemetry.seaweedfs.com 으로 익명 통계를 보낸다(기동 로그로 확인).
#   에어갭에서는 어차피 실패하지만 90-verify 유출 카운터를 올리고, 사내망
#   정책상 외부 전송 시도 자체를 없애는 편이 낫다. 로그의 안내는 `-telemetry`
#   지만 `weed server` 에서는 `-master.telemetry` 다(`-telemetry` 는
#   "flag provided but not defined" 로 기동 실패, 실측).
#
# stop_grace_period 1m : 정상 종료에 약 26초가 걸린다(실측). compose 기본
#   10초면 SIGKILL 로 끊겨 쓰기 중인 볼륨이 정리되지 않는다.
#
# -volume.max=0 : 볼륨 개수를 디스크 여유 공간으로 자동 산정한다.
#   이미지 entrypoint 가 -master.volumeSizeLimitMB=1024 를 끼워 넣으므로
#   (컨테이너 ps 로 확인) 볼륨 하나가 1GB 다. 기본값 8 이면 약 8GB 에서
#   쓰기가 멈춘다.
#=====================================================================
step "compose 템플릿 생성"

# __로 감싼 값은 install.sh 가 치환한다.
cat > "${CONF_DIR}/docker-compose.yml.tmpl" <<'EOF'
#---------------------------------------------------------------------
# SeaweedFS — 단일 노드 weed server (master+volume+filer+S3), S3 TLS 전용
#
# 이 파일은 21-seaweedfs/install.sh 가 템플릿에서 생성한다.
# 직접 고친 뒤에는 다음으로 반영한다:
#   sudo docker compose -f /opt/weed/docker-compose.yml up -d
#---------------------------------------------------------------------
services:
  seaweedfs:
    image: __SEAWEEDFS_IMAGE__
    container_name: seaweedfs
    restart: unless-stopped
    stop_grace_period: 1m
    command:
      - server
      - -dir=/data
      - -ip=127.0.0.1
      - -ip.bind=127.0.0.1
      - -volume.max=0
      - -master.telemetry=false
      - -s3
      - -s3.ip.bind=0.0.0.0
      - -s3.port=__SEAWEEDFS_S3_PORT__
      - -s3.config=/etc/seaweedfs/s3.json
      - -s3.cert.file=/certs/weed.crt
      - -s3.key.file=/certs/weed.key
      # 가상 호스트 스타일 버킷 주소(<bucket>.<host>). 인증서에 *.<host> 가 있다.
      - -s3.domainName=__WEED_HOSTNAME__
    ports:
      - "__SEAWEEDFS_S3_PORT__:__SEAWEEDFS_S3_PORT__"   # S3 API (HTTPS)
    volumes:
      - __WEED_DATA_DIR__:/data
      - __WEED_DIR__/s3.json:/etc/seaweedfs/s3.json:ro
      - __WEED_DIR__/certs:/certs:ro
    healthcheck:
      # 인증 없이 응답하는 S3 헬스 엔드포인트. -k: 컨테이너 안에는 사내 CA 가 없다.
      test: ["CMD-SHELL", "curl -fsk https://localhost:__SEAWEEDFS_S3_PORT__/healthz >/dev/null"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 30s
    logging:
      driver: json-file
      options:
        max-size: "20m"
        max-file: "5"
EOF
ok "docker-compose.yml.tmpl"

#=====================================================================
# 3. S3 자격증명 템플릿
#
# SeaweedFS 는 S3 자격증명을 환경변수가 아니라 JSON(-s3.config)으로 받는다.
# install.sh 가 치환 후 0600 + seaweed uid 소유로 둔다.
#=====================================================================
cat > "${CONF_DIR}/s3.json.tmpl" <<'EOF'
{
  "identities": [
    {
      "name": "__WEED_ROOT_USER__",
      "credentials": [
        {
          "accessKey": "__WEED_ROOT_USER__",
          "secretKey": "__WEED_ROOT_PASSWORD__"
        }
      ],
      "actions": ["Admin", "Read", "List", "Tagging", "Write"]
    }
  ]
}
EOF
ok "s3.json.tmpl"

#=====================================================================
# 4. 패키징
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
cp "${SCRIPT_DIR}/README.md"              "${BUNDLE_DIR}/" 2>/dev/null || true
# install.sh 는 아직 검토 단계라 없을 수 있다. 있으면 싣는다.
if [[ -f "${SCRIPT_DIR}/install.sh" ]]; then
    cp "${SCRIPT_DIR}/install.sh" "${BUNDLE_DIR}/"
    chmod +x "${BUNDLE_DIR}/install.sh"
else
    warn "install.sh 가 아직 없다. 번들에는 이미지와 템플릿만 들어간다(README 6절)."
fi

cat > "${BUNDLE_DIR}/BUNDLE-INFO" <<EOF
bundle        : ${BUNDLE_NAME}
bundle_version: ${BUNDLE_VERSION}
built_at      : $(date -Is)
built_on      : $(hostname)
target_os     : Ubuntu 22.04 / 24.04 / 26.04 공용 (OS 의존 없음)
seaweedfs     : ${SEAWEEDFS_IMAGE}@${SEAWEEDFS_IMAGE_DIGEST}
client        : ${SEAWEEDFS_CLIENT_IMAGE}@${SEAWEEDFS_CLIENT_IMAGE_DIGEST}
license       : ${WEED_LICENSE:-unknown} (이미지 라벨)
구성          : 단일 노드 weed server (master+volume+filer+S3), S3 TLS 전용
포트          : ${SEAWEEDFS_S3_PORT}(S3 API, HTTPS). 내부 포트는 공개하지 않음
리전          : ${SEAWEEDFS_REGION}
재시작 정책   : unless-stopped
EOF

write_manifest "$BUNDLE_DIR"

TARBALL="${SCRIPT_DIR}/bundle/${BUNDLE_NAME}.tar.gz"
tar -C "${SCRIPT_DIR}/bundle" -czf "$TARBALL" "$BUNDLE_NAME"
# `sha256sum -c` 가 읽을 수 있는 형식(파일명만)으로 쓴다.
( cd "$(dirname "$TARBALL")" && sha256sum "$(basename "$TARBALL")" ) > "${TARBALL}.sha256"

step "완료"
cat "${BUNDLE_DIR}/BUNDLE-INFO"
echo
ok "번들: ${TARBALL} ($(du -h "$TARBALL" | cut -f1))"
