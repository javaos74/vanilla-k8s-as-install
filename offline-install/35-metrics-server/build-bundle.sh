#!/usr/bin/env bash
#---------------------------------------------------------------------
# 35-metrics-server : 오프라인 번들 빌드 (온라인 호스트에서 실행)
#
# 산출물: bundle/metrics-server-<버전>/ + .tar.gz
#
# 담는 것: metrics-server 이미지(docker-archive) + 매니페스트 템플릿 + install.sh
# 설치는 이미지를 **로컬 Harbor 에 올린 뒤** 그 주소로 배포한다(install.sh).
# OS 의존 없음. 22.04 / 24.04 / 26.04 / el9 / el10 공용.
#---------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../00-common/common.sh"

require_online
require_cmds curl tar

BUNDLE_NAME="metrics-server-${METRICS_SERVER_VERSION}"
BUNDLE_DIR="${SCRIPT_DIR}/bundle/${BUNDLE_NAME}"
IMG_DIR="${BUNDLE_DIR}/images"
CONF_DIR="${BUNDLE_DIR}/conf"

step "Metrics Server ${METRICS_SERVER_VERSION} 번들 빌드 (OS 공용)"
# 매번 다시 만드는 것은 지운다(이전 빌드의 site.env 잔존 방지). images/ 는 캐시.
rm -rf "${BUNDLE_DIR}/00-common" "${BUNDLE_DIR}/conf" "${BUNDLE_DIR}/90-verify"
rm -f  "${BUNDLE_DIR}"/*.sh "${BUNDLE_DIR}"/*.md \
       "${BUNDLE_DIR}/SHA256SUMS" "${BUNDLE_DIR}/BUNDLE-INFO"
mkdir -p "$IMG_DIR" "$CONF_DIR"

if ! command -v skopeo >/dev/null 2>&1; then
    log "skopeo 설치(빌드 도구)"
    pkg_install_build_tool skopeo
fi
ok "skopeo $(skopeo --version | awk '{print $3}')"

#=====================================================================
# 1. 이미지 — 태그가 아니라 다이제스트로 받는다
#=====================================================================
step "이미지 다운로드 (다이제스트 핀)"
SRC="$METRICS_SERVER_SOURCE_IMAGE"
PIN="$METRICS_SERVER_SOURCE_DIGEST"
[[ "$PIN" =~ ^sha256:[0-9a-f]{64}$ ]] || die "versions.env 의 METRICS_SERVER_SOURCE_DIGEST 형식 오류: ${PIN}"

# 태그가 움직였는지 알려준다(받는 것은 핀).
CUR="$(skopeo inspect --override-os linux --override-arch amd64 --format '{{.Digest}}' "docker://${SRC}" 2>/dev/null || true)"
if [[ -n "$CUR" && "$CUR" != "$PIN" ]]; then
    # 단일 아키텍처 매니페스트면 inspect 다이제스트 = 핀. 멀티아치 인덱스면 다를 수 있다.
    warn "태그 다이제스트가 핀과 다르다: ${CUR} (핀 ${PIN} 으로 받는다)"
else
    ok "태그 = 핀 일치: ${SRC}"
fi

OUT="${IMG_DIR}/$(image_to_filename "$SRC").tar"
if [[ -s "$OUT" ]]; then
    log "이미 존재: $(basename "$OUT")"
else
    rm -f "${OUT}.part"
    skopeo copy --override-os linux --override-arch amd64 --retry-times 5 \
        "docker://${SRC%:*}@${PIN}" "docker-archive:${OUT}.part:${SRC}" >/dev/null \
        || die "이미지 받기 실패: ${SRC%:*}@${PIN}"
    mv "${OUT}.part" "$OUT"
fi
ok "$(basename "$OUT") ($(du -h "$OUT" | cut -f1))"
printf '%s %s\n' "$SRC" "$PIN" > "${CONF_DIR}/image.source"

#=====================================================================
# 2. 매니페스트 템플릿
#=====================================================================
cp "${SCRIPT_DIR}/conf/components.yaml.tmpl" "${CONF_DIR}/"
grep -q '__METRICS_SERVER_IMAGE__' "${CONF_DIR}/components.yaml.tmpl" \
    || die "매니페스트 템플릿에 __METRICS_SERVER_IMAGE__ 가 없다"
ok "conf/components.yaml.tmpl"

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
cp -R "${SCRIPT_DIR}/../00-common/os"     "${BUNDLE_DIR}/00-common/"
cp "${SCRIPT_DIR}/install.sh"             "${BUNDLE_DIR}/"
cp "${SCRIPT_DIR}/README.md"              "${BUNDLE_DIR}/" 2>/dev/null || true
chmod +x "${BUNDLE_DIR}/install.sh"

cat > "${BUNDLE_DIR}/BUNDLE-INFO" <<EOF
bundle        : ${BUNDLE_NAME}
bundle_version: ${BUNDLE_VERSION}
built_at      : $(date -Is)
built_on      : $(hostname)
target_os     : 공용 (OS 의존 없음)
source_image  : ${SRC}@${PIN}
harbor_image  : <HARBOR_HOSTNAME>/${METRICS_SERVER_HARBOR_PROJECT}/${METRICS_SERVER_HARBOR_REPO}:${SRC##*:}
EOF

write_manifest "$BUNDLE_DIR"
TARBALL="${SCRIPT_DIR}/bundle/${BUNDLE_NAME}.tar.gz"
tar -C "${SCRIPT_DIR}/bundle" -czf "$TARBALL" "$BUNDLE_NAME"
( cd "$(dirname "$TARBALL")" && sha256sum "$(basename "$TARBALL")" ) > "${TARBALL}.sha256"

step "완료"
cat "${BUNDLE_DIR}/BUNDLE-INFO"
echo
ok "번들: ${TARBALL} ($(du -h "$TARBALL" | cut -f1))"
