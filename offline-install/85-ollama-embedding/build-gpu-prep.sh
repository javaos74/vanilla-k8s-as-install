#!/usr/bin/env bash
#---------------------------------------------------------------------
# 85-ollama-embedding : GPU 사전 준비 번들 빌드 (온라인 빌드 호스트에서 일반 사용자로 실행)
#
#   ./build-gpu-prep.sh                              # 대상 커널 = 이 호스트의 uname -r
#   ./build-gpu-prep.sh --kernel 6.8.0-147-generic   # 다른 커널용
#
# 산출물: bundle/ollama-embedding-gpu-prep-<코드네임>-<커널>.tar.gz (+ .sha256)
#   - debs/  NVIDIA 드라이버(nvidia-driver-<브랜치>-open), 대상 커널용 Ubuntu prebuilt 모듈과
#            같은 버전의 flavour 메타, nvidia-container-toolkit, Docker Engine 과 그 의존 deb.
#            flat apt 저장소(Packages, Packages.gz, Release)로 만든다
#   - conf/  target-kernel, codename, gpu.specs, docker.specs, packages.list
#   - install-gpu-prep.sh, README.md, 00-common (site.env 는 넣지 않는다)
#
# 빌드 호스트 요건 (README 3절 "GPU 사전 준비 번들"):
#   - 대상과 같은 Ubuntu 코드네임, amd64. 대상 커널로 부팅돼 있을 필요는 없다
#     (같은 릴리스 아카이브에 그 커널용 모듈이 있으면 된다)
#   - 인터넷: Ubuntu 아카이브(restricted 포함), download.docker.com, nvidia.github.io
#   - sudo·Docker 불필요
#
# 이 스크립트가 빌드 호스트에 남기는 변경: 없음 (apt-ftparchive 가 없을 때만 apt-utils 설치)
#   의존성 계산과 다운로드는 임시 디렉터리에 따로 둔 apt 설정으로 한다. 호스트의 apt
#   원본 목록·상태·캐시는 쓰지 않는다(Ubuntu 원본 목록만 복사해 읽는다).
#---------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../00-common/common.sh"

usage() {
    cat <<'EOF'
사용법: ./build-gpu-prep.sh [--kernel <커널>]
  --kernel <커널>  대상 노드의 uname -r 값 (기본: 이 호스트의 uname -r)
                   예: 7.0.0-1014-aws, 6.8.0-147-generic
EOF
}

KVER=""
while (($# > 0)); do
    case "$1" in
        --kernel)  [[ $# -ge 2 && -n "${2:-}" ]] \
                       || die "--kernel 에 커널 버전이 필요하다 (예: --kernel 6.8.0-147-generic)"
                   KVER="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *)         usage >&2; die "알 수 없는 인자: $1" ;;
    esac
done
[[ -n "$KVER" ]] || KVER="$(uname -r)"
KVER_RE='^[0-9]+\.[0-9]+\.[0-9]+-[0-9]+-[a-z0-9]+([.-][a-z0-9]+)*$'
[[ "$KVER" =~ $KVER_RE ]] \
    || die "커널 형식이 Ubuntu 커널(uname -r)과 다르다: '${KVER}' (예: 7.0.0-1014-aws, 6.8.0-147-generic)"
# flavour = 커널 ABI 뒤 부분 (7.0.0-1014-aws -> aws, 6.8.0-147-generic -> generic)
FLAVOUR="${KVER#*-*-}"

require_online
require_nonroot_build
require_cmds apt-get apt-cache curl tar sha256sum gzip dpkg-deb
[[ "$OS_FAMILY" == debian ]] \
    || die "Ubuntu 빌드 호스트가 필요하다(지금 ID=${OS_ID:-?}). 대상과 같은 Ubuntu 버전에서 빌드할 것."
CN="$(detect_codename)"
OSVER="$(codename_to_osversion "$CN")"
detect_arch >/dev/null
if ! command -v apt-ftparchive >/dev/null 2>&1; then
    log "apt-utils 설치(빌드 도구, apt-ftparchive)"
    pkg_install_build_tool apt-utils
fi

#=====================================================================
# 1. 별도 apt 설정
#
# 호스트 apt 를 쓰지 않는 이유(charles-weed 실측 두 건):
#   1) 호스트에 docker.sources(Signed-By docker.asc)가 있으면 10-k8s 방식(docker.list +
#      docker.gpg)으로 저장소를 더할 때 Signed-By 가 충돌한다.
#   2) 호스트 /var/cache/apt/archives 에 deb 이 있으면 --print-uris 가 그 패키지를 빼고
#      출력한다. 같은 계산이 캐시를 쓰면 5개, 비우면 150개였다.
# 그래서 상태·목록·캐시·원본·선호도를 모두 임시 디렉터리로 돌린다. 명령행 -o 는
# apt.conf.d 보다 우선한다.
#=====================================================================
step "별도 apt 설정 (Ubuntu ${OSVER} ${CN}, 대상 커널 ${KVER})"
APT_ROOT="$(mktemp -d)"
trap 'rm -rf "$APT_ROOT"' EXIT
mkdir -p "${APT_ROOT}/state/lists/partial" "${APT_ROOT}/cache/archives/partial" \
         "${APT_ROOT}/sources.list.d" "${APT_ROOT}/preferences.d" "${APT_ROOT}/keys"
: > "${APT_ROOT}/status"
: > "${APT_ROOT}/sources.list"
: > "${APT_ROOT}/preferences"

[[ -f /etc/apt/sources.list || -f /etc/apt/sources.list.d/ubuntu.sources ]] \
    || die "Ubuntu apt 원본(/etc/apt/sources.list, /etc/apt/sources.list.d/ubuntu.sources)이 없다."
if [[ -f /etc/apt/sources.list ]]; then
    cp /etc/apt/sources.list "${APT_ROOT}/sources.list"
fi
if [[ -f /etc/apt/sources.list.d/ubuntu.sources ]]; then
    cp /etc/apt/sources.list.d/ubuntu.sources "${APT_ROOT}/sources.list.d/"
fi
curl -fsSL --retry 3 "$DOCKER_APT_KEY_URL" -o "${APT_ROOT}/keys/docker.asc" \
    || die "Docker apt 서명키를 받지 못했다: ${DOCKER_APT_KEY_URL}"
curl -fsSL --retry 3 "$NVIDIA_CTK_KEY_URL" -o "${APT_ROOT}/keys/nvidia-container-toolkit.asc" \
    || die "nvidia-container-toolkit apt 서명키를 받지 못했다: ${NVIDIA_CTK_KEY_URL}"
echo "deb [arch=${BUNDLE_ARCH} signed-by=${APT_ROOT}/keys/docker.asc] ${DOCKER_REPO} ${CN} stable" \
    > "${APT_ROOT}/sources.list.d/docker.list"
echo "deb [signed-by=${APT_ROOT}/keys/nvidia-container-toolkit.asc] ${NVIDIA_CTK_REPO}/${BUNDLE_ARCH} /" \
    > "${APT_ROOT}/sources.list.d/nvidia-container-toolkit.list"

APT_OPTS=(
    -o "Dir::State=${APT_ROOT}/state"
    -o "Dir::State::status=${APT_ROOT}/status"
    -o "Dir::Cache=${APT_ROOT}/cache"
    -o "Dir::Etc::sourcelist=${APT_ROOT}/sources.list"
    -o "Dir::Etc::sourceparts=${APT_ROOT}/sources.list.d"
    -o "Dir::Etc::preferences=${APT_ROOT}/preferences"
    -o "Dir::Etc::preferencesparts=${APT_ROOT}/preferences.d"
    -o "APT::Architecture=${BUNDLE_ARCH}"
    -o "APT::Architectures=${BUNDLE_ARCH}"
    -o Debug::NoLocking=1
    -o APT::Install-Recommends=true
    -o APT::Install-Suggests=false
)

log "apt-get update (임시 apt 상태)"
apt-get "${APT_OPTS[@]}" -qq update \
    || die "apt-get update 실패. 빌드 호스트의 인터넷과 저장소(Ubuntu·Docker·NVIDIA)를 확인할 것."
ok "저장소: Ubuntu(호스트 원본 복사), ${DOCKER_REPO} ${CN}, ${NVIDIA_CTK_REPO}/${BUNDLE_ARCH}"

#=====================================================================
# 2. 버전 결정
#=====================================================================
step "버전 결정"

# apt-cache madison 의 버전 열만 뽑는다. 여러 포켓에 있으면 여러 줄이다.
madison_versions() {
    { apt-cache "${APT_OPTS[@]}" madison "$1" 2>/dev/null || true; } \
        | awk -F'|' '{gsub(/[[:space:]]/, "", $2); if ($2 != "") print $2}'
}
show_madison() {
    warn "apt-cache madison $1:"
    { apt-cache "${APT_OPTS[@]}" madison "$1" 2>&1 || true; } | sed 's/^/    /' >&2
}

DRV_PKG="nvidia-driver-${NVIDIA_DRIVER_BRANCH}-open"
DRV_VER=""
while read -r v; do
    if [[ "$v" == "${NVIDIA_DRIVER_VERSION}-"* ]]; then DRV_VER="$v"; break; fi
done < <(madison_versions "$DRV_PKG")
if [[ -z "$DRV_VER" ]]; then
    show_madison "$DRV_PKG"
    die "${DRV_PKG} ${NVIDIA_DRIVER_VERSION}-* 가 Ubuntu 아카이브(restricted)에 없다. 빌드 호스트의 Ubuntu 원본에 restricted 가 있는지, versions.env 의 NVIDIA_DRIVER_VERSION 을 확인할 것."
fi
ok "드라이버 ${DRV_PKG} ${DRV_VER}"

# 커널별 prebuilt 모듈. 커널 ABI 마다 이름이 다른 패키지라 보통 버전이 하나뿐이다.
LRM_PKG="linux-modules-nvidia-${NVIDIA_DRIVER_BRANCH}-open-${KVER}"
LRM_VER="$({ apt-cache "${APT_OPTS[@]}" policy "$LRM_PKG" 2>/dev/null || true; } \
    | awk '$1 == "Candidate:" {print $2; exit}')"
if [[ -z "$LRM_VER" || "$LRM_VER" == "(none)" ]]; then
    die "이 커널(${KVER})용 Ubuntu prebuilt 모듈 ${LRM_PKG} 이 저장소에 없다. 아카이브에서 빠졌거나 Ubuntu 커널이 아니다. DKMS 로 대신하지 않는다."
fi
ok "커널 모듈 ${LRM_PKG} ${LRM_VER} (Ubuntu prebuilt)"

# flavour 메타는 모듈과 **같은 버전**이어야 한다. 이 메타가 nvidia-dkms-<브랜치>-open 을
# Provides 해서 DKMS 없이 의존성이 풀린다. 메타를 빼면 nvidia-driver 가 nvidia-dkms 로
# 풀리고, 다른 버전의 메타는 그 버전의 커널을 끌어온다(2026-11-11 실측).
META_PKG="linux-modules-nvidia-${NVIDIA_DRIVER_BRANCH}-open-${FLAVOUR}"
if ! grep -qxF "$LRM_VER" <<<"$(madison_versions "$META_PKG")"; then
    show_madison "$META_PKG"
    CANDS=()
    while read -r c; do
        [[ -n "$c" && "$c" != "$LRM_PKG" ]] || continue
        if grep -qxF "$LRM_VER" <<<"$(madison_versions "$c")"; then CANDS+=("$c"); fi
    done < <({ apt-cache "${APT_OPTS[@]}" rdepends "$LRM_PKG" 2>/dev/null || true; } \
                 | awk 'NR > 2 {gsub(/[[:space:]|]/, ""); if ($0 != "") print}' | LC_ALL=C sort -u)
    die "flavour 메타 ${META_PKG} 에 모듈과 같은 버전 ${LRM_VER} 이 없다. 메타 없이 설치하면 nvidia-dkms 로 풀리고, 다른 버전의 메타는 다른 커널을 끌어온다. 같은 버전(${LRM_VER})을 가진 메타 후보: ${CANDS[*]:-없음}"
fi
ok "flavour 메타 ${META_PKG} ${LRM_VER} (모듈과 같은 버전)"

CTK_SPECS=()
for p in nvidia-container-toolkit nvidia-container-toolkit-base libnvidia-container-tools libnvidia-container1; do
    CTK_SPECS+=("${p}=${NVIDIA_CTK_VERSION}")
done
# pkgs-debian.sh(10-k8s)의 PINNED_DEBS 와 같은 형식이다. docker-ce-rootless-extras 도
# docker-ce 와 같은 버전으로 고정한다. 고정하지 않으면 Recommends 로 최신이 들어온다.
DOCKER_SUFFIX="${DOCKER_DEB_REVISION}~ubuntu.${OSVER}~${CN}"
DOCKER_SPECS=(
    "containerd.io=${CONTAINERD_VERSION}-${DOCKER_SUFFIX}"
    "docker-ce=${DOCKER_DEB_EPOCH}${DOCKER_VERSION}-${DOCKER_SUFFIX}"
    "docker-ce-cli=${DOCKER_DEB_EPOCH}${DOCKER_VERSION}-${DOCKER_SUFFIX}"
    "docker-ce-rootless-extras=${DOCKER_DEB_EPOCH}${DOCKER_VERSION}-${DOCKER_SUFFIX}"
    "docker-buildx-plugin=${DOCKER_BUILDX_VERSION}-${DOCKER_SUFFIX}"
    "docker-compose-plugin=${DOCKER_COMPOSE_VERSION}-${DOCKER_SUFFIX}"
)
GPU_SPECS=("${DRV_PKG}=${DRV_VER}" "${LRM_PKG}=${LRM_VER}" "${META_PKG}=${LRM_VER}" "${CTK_SPECS[@]}")
ok "toolkit ${NVIDIA_CTK_VERSION} / docker-ce ${DOCKER_VERSION} / containerd.io ${CONTAINERD_VERSION}"

#=====================================================================
# 3. 의존성 폐쇄집합
#
# pkgs-debian.sh(10-k8s)와 같은 방식이다. 빈 dpkg 상태에서 폐쇄집합을 계산하고 기준선을 뺀다.
#   기준선 = Essential/required + ubuntu-server-minimal + linux-image-<대상 커널>
#   번들   = 폐쇄집합(기준선 + 대상) - 폐쇄집합(기준선)
# 다른 점: 호스트 apt 대신 1절의 별도 apt 설정을 쓰고, 기준선에 대상 커널 이미지를 더한다.
# 대상은 이미 그 커널로 돌고 있다. 기준선에 없으면 linux-modules-<커널>(148MB)과
# linux-image 가 번들에 끌려 들어온다.
#=====================================================================
step "의존성 폐쇄집합 (빈 dpkg 상태)"
_apt_closure() {
    local out
    out="$(apt-get "${APT_OPTS[@]}" -qq install --print-uris -y "$@" 2>&1)" \
        || { tail -n 30 <<<"$out" >&2; return 1; }
    awk '/^'\''/ {print $2}' <<<"$out" | LC_ALL=C sort -u
}
BASE_PKGS=()
mapfile -t BASE_PKGS < <({ apt-cache "${APT_OPTS[@]}" dumpavail 2>/dev/null || true; } | awk '
    /^Package: /  { p = $2 }
    /^Essential: yes/ || /^Priority: required/ { req[p] = 1 }
    /^$/          { p = "" }
    END           { for (k in req) print k }' | LC_ALL=C sort -u)
((${#BASE_PKGS[@]} > 0)) || die "apt-cache dumpavail 에서 Essential/required 패키지를 찾지 못했다."
log "기준선: Essential/required ${#BASE_PKGS[@]}개 + ubuntu-server-minimal + linux-image-${KVER}"
BASE_PKGS+=(ubuntu-server-minimal "linux-image-${KVER}")

base_list="$(_apt_closure "${BASE_PKGS[@]}")" \
    || die "기준선 폐쇄집합을 계산하지 못했다. 위 apt 출력을 확인할 것(linux-image-${KVER} 가 아카이브에 있는지)."
joint_list="$(_apt_closure "${BASE_PKGS[@]}" "${GPU_SPECS[@]}" "${DOCKER_SPECS[@]}")" \
    || die "기준선 + 대상 폐쇄집합을 계산하지 못했다. 위 apt 출력을 확인할 것(versions.env 의 Docker·toolkit 핀)."
[[ -n "$base_list" && -n "$joint_list" ]] \
    || die "apt 로 의존성 폐쇄집합을 계산하지 못했다. 저장소 상태를 확인할 것."

# 파일명(이름_버전_아키텍처.deb, epoch 의 ':' 는 %3a)에서 이름=버전 을 만든다.
EXTRA_FILES=()
mapfile -t EXTRA_FILES < <(LC_ALL=C comm -13 <(echo "$base_list") <(echo "$joint_list") | grep . || true)
EXTRA_SPECS=()
for f in "${EXTRA_FILES[@]}"; do
    n="${f%%_*}"; rest="${f#*_}"; v="${rest%_*}"; v="${v//%3a/:}"
    EXTRA_SPECS+=("${n}=${v}")
done
log "기준선 $(wc -l <<<"$base_list")개 / 기준선+대상 $(wc -l <<<"$joint_list")개 -> 추가 ${#EXTRA_SPECS[@]}개"
((${#EXTRA_SPECS[@]} > 0)) || die "추가할 deb 이 없다. 저장소 상태를 확인할 것."

EXTRA_TEXT="$(printf '%s\n' "${EXTRA_SPECS[@]}")"
for spec in "${GPU_SPECS[@]}" "${DOCKER_SPECS[@]}"; do
    grep -qxF "$spec" <<<"$EXTRA_TEXT" \
        || die "최상위 패키지 ${spec} 가 추가 목록에 없다(기준선에 이미 있거나 다른 버전으로 풀렸다)."
done
ok "최상위 패키지 ${#GPU_SPECS[@]} + ${#DOCKER_SPECS[@]}개 모두 추가 목록에 있다"

# 대상에 이미 있는 기반 패키지, 커널, DKMS 가 번들에 섞이면 중단한다.
# CORE_PKG_RE 는 pkgs-debian.sh 와 같다(파일명 기준).
CORE_PKG_RE='^(systemd|systemd-sysv|systemd-dev|systemd-resolved|systemd-timesyncd|libsystemd-shared|libnss-systemd|libpam-systemd|libc6|libc-bin|perl|perl-base|perl-modules[-.0-9]*|python3|python3-minimal|python3\.[0-9]+|python3\.[0-9]+-minimal|dbus|dbus-bin|dbus-daemon|openssh-client|apparmor|libssl[0-9]|zlib1g|libstdc\+\+[0-9]+|libgcc-s[0-9]+|tzdata)_'
KERNEL_PKG_RE='^(linux-image-|linux-image-unsigned-|linux-headers-|linux-modules-[0-9]|linux-modules-extra-)'
DKMS_PKG_RE='^(dkms|nvidia-dkms-[^_]*)_'
reject_hits() {   # $1=정규식 $2=설명
    local -a hits=()
    local h
    mapfile -t hits < <(printf '%s\n' "${EXTRA_FILES[@]}" | grep -E "$1" || true)
    ((${#hits[@]} == 0)) && return 0
    for h in "${hits[@]}"; do warn "${2}: ${h}"; done
    return 1
}
reject_hits "$CORE_PKG_RE" "핵심 시스템 패키지" \
    || die "번들에 핵심 시스템 패키지가 섞였다. 대상의 기반 패키지를 덮어쓸 수 있다. 버전 핀과 아카이브 상태를 확인할 것."
reject_hits "$KERNEL_PKG_RE" "커널 패키지" \
    || die "번들에 커널 패키지가 섞였다. 커널을 바꾸는 번들은 만들지 않는다. 메타 버전(${META_PKG} ${LRM_VER})과 대상 커널을 확인할 것."
reject_hits "$DKMS_PKG_RE" "DKMS 패키지" \
    || die "번들에 dkms 가 섞였다. 메타가 nvidia-dkms-${NVIDIA_DRIVER_BRANCH}-open 을 Provides 하지 않는 버전이다."
ok "핵심 시스템·커널·DKMS 패키지 미포함 확인"

#=====================================================================
# 4. deb 다운로드와 flat apt 저장소
#=====================================================================
BUNDLE_NAME="ollama-embedding-gpu-prep-${CN}-${KVER}"
BUNDLE_DIR="${SCRIPT_DIR}/bundle/${BUNDLE_NAME}"
DEB_DIR="${BUNDLE_DIR}/debs"
CONF_DIR="${BUNDLE_DIR}/conf"

step "deb 다운로드 (${#EXTRA_SPECS[@]}개) -> bundle/${BUNDLE_NAME}/debs"
# 커널·버전마다 내용이 달라 캐시로 남기지 않는다. 이전 산출물이 섞이지 않게 새로 만든다.
rm -rf "$BUNDLE_DIR"
mkdir -p "$DEB_DIR" "$CONF_DIR" "${BUNDLE_DIR}/00-common"

# pkgs-debian.sh 의 download_debs 와 같은 방식이다. apt-get download 는 인자 하나라도
# 해석에 실패하면 전체를 중단하므로 패키지별로 받고 실패 목록을 모은다.
FAILED=()
for spec in "${EXTRA_SPECS[@]}"; do
    ( cd "$DEB_DIR" && apt-get "${APT_OPTS[@]}" -qq download "$spec" >/dev/null 2>&1 ) \
        || FAILED+=("$spec")
done
if ((${#FAILED[@]} > 0)); then
    for f in "${FAILED[@]}"; do warn "다운로드 실패: ${f}"; done
    die "deb ${#FAILED[@]}개를 받지 못했다."
fi
DEB_COUNT="$(find "$DEB_DIR" -maxdepth 1 -name '*.deb' | wc -l | tr -d ' ')"
[[ "$DEB_COUNT" == "${#EXTRA_SPECS[@]}" ]] \
    || die "받은 deb ${DEB_COUNT}개가 추가 목록 ${#EXTRA_SPECS[@]}개와 다르다."
ok "deb ${DEB_COUNT}개 ($(du -sh "$DEB_DIR" | cut -f1))"

step "flat apt 저장소 (debs/Packages, Packages.gz, Release)"
# Release 를 debs/ 안에 바로 쓰면 apt-ftparchive 가 쓰는 중인 자기 자신을 목록에 넣는다.
( cd "$DEB_DIR" \
  && apt-ftparchive packages . > Packages \
  && gzip -9nk Packages \
  && apt-ftparchive release . > "${APT_ROOT}/Release" ) \
    || die "apt-ftparchive 로 저장소 색인을 만들지 못했다."
mv "${APT_ROOT}/Release" "${DEB_DIR}/Release"
IDX_COUNT="$(grep -c '^Package: ' "${DEB_DIR}/Packages" || true)"
[[ "$IDX_COUNT" == "$DEB_COUNT" ]] || die "Packages 항목 ${IDX_COUNT}개가 deb ${DEB_COUNT}개와 다르다."
ok "Packages ${IDX_COUNT}개 항목"

#=====================================================================
# 5. conf/, 설치 도구, BUNDLE-INFO
#=====================================================================
step "번들 구성"
printf '%s\n' "$KVER" > "${CONF_DIR}/target-kernel"
printf '%s\n' "$CN"   > "${CONF_DIR}/codename"
printf '%s\n' "${GPU_SPECS[@]}"    > "${CONF_DIR}/gpu.specs"
printf '%s\n' "${DOCKER_SPECS[@]}" > "${CONF_DIR}/docker.specs"
# 줄마다 "패키지 버전 바이트", 이름순
for deb in "$DEB_DIR"/*.deb; do
    printf '%s %s\n' "$(dpkg-deb -W --showformat="\${Package} \${Version}" "$deb")" "$(stat -c %s "$deb")"
done | LC_ALL=C sort > "${CONF_DIR}/packages.list"

# site.env 는 넣지 않는다. 이 번들은 사이트 값을 쓰지 않고, 내부 IP 가 번들에 실리지 않게 한다.
cp "${SCRIPT_DIR}/../00-common/versions.env" \
   "${SCRIPT_DIR}/../00-common/site.env.example" \
   "${SCRIPT_DIR}/../00-common/common.sh" "${BUNDLE_DIR}/00-common/"
cp -R "${SCRIPT_DIR}/../00-common/os" "${BUNDLE_DIR}/00-common/"
cp "${SCRIPT_DIR}/install-gpu-prep.sh" "${SCRIPT_DIR}/README.md" "${BUNDLE_DIR}/"
chmod +x "${BUNDLE_DIR}/install-gpu-prep.sh"

DEB_BYTES="$(awk '{s += $3} END {printf "%d", s}' "${CONF_DIR}/packages.list")"
DEB_MIB="$(awk -v b="$DEB_BYTES" 'BEGIN {printf "%.1f", b / 1048576}')"
cat > "${BUNDLE_DIR}/BUNDLE-INFO" <<EOF
bundle        : ${BUNDLE_NAME}
bundle_version: ${BUNDLE_VERSION}
built_at      : $(date -Is)
built_on      : $(hostname) / $(os_label) / ${BUNDLE_ARCH}
target_os     : Ubuntu ${OSVER} (${CN}) ${BUNDLE_ARCH}
target_kernel : ${KVER}
driver        : ${DRV_PKG} ${DRV_VER}
kernel_module : ${LRM_PKG} ${LRM_VER} (Ubuntu prebuilt, DKMS 없음)
module_meta   : ${META_PKG} ${LRM_VER}
toolkit       : nvidia-container-toolkit ${NVIDIA_CTK_VERSION} (+ nvidia-container-toolkit-base, libnvidia-container-tools, libnvidia-container1)
docker        : docker-ce ${DOCKER_VERSION} / containerd.io ${CONTAINERD_VERSION} / buildx ${DOCKER_BUILDX_VERSION} / compose ${DOCKER_COMPOSE_VERSION} (Docker 엔진·containerd 가 없을 때만 설치)
debs          : ${DEB_COUNT}개, ${DEB_MIB} MiB (${DEB_BYTES} B), flat apt 저장소
EOF

write_manifest "$BUNDLE_DIR"

step "아카이브"
TARBALL="${SCRIPT_DIR}/bundle/${BUNDLE_NAME}.tar.gz"
rm -f "$TARBALL" "${TARBALL}.sha256"
if command -v pigz >/dev/null 2>&1; then
    tar -C "${SCRIPT_DIR}/bundle" -I pigz -cf "$TARBALL" "$BUNDLE_NAME"
else
    tar -C "${SCRIPT_DIR}/bundle" -czf "$TARBALL" "$BUNDLE_NAME"
fi
(cd "$(dirname "$TARBALL")" && sha256sum "$(basename "$TARBALL")") > "${TARBALL}.sha256"
cat "${BUNDLE_DIR}/BUNDLE-INFO"
echo
ok "번들: ${TARBALL} ($(du -h "$TARBALL" | cut -f1))"

step "완료"
echo "  타깃으로 옮길 파일: $(basename "$TARBALL") 와 $(basename "$TARBALL").sha256"
echo "  대상 노드(Ubuntu ${OSVER}, 커널 ${KVER}, 드라이버 없음)에서:"
echo "    sha256sum -c $(basename "$TARBALL").sha256"
echo "    tar xzf $(basename "$TARBALL") && cd ${BUNDLE_NAME}"
echo "    sudo ./install-gpu-prep.sh --dry-run"
echo "    sudo ./install-gpu-prep.sh && sudo reboot"
echo "    sudo ./install-gpu-prep.sh --check-only"
