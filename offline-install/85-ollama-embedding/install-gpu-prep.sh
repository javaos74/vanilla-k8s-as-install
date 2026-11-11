#!/usr/bin/env bash
#---------------------------------------------------------------------
# 85-ollama-embedding : GPU 사전 준비 오프라인 설치 (GPU VM 에서 root 로 실행)
#
#   sudo ./install-gpu-prep.sh               # 사전 확인 + 설치 + 판정. 재부팅은 안내만 한다
#   sudo ./install-gpu-prep.sh --dry-run     # 사전 확인 + apt 시뮬레이션만. 아무것도 바꾸지 않는다
#   sudo ./install-gpu-prep.sh --check-only  # 판정만(재부팅 뒤). 아무것도 바꾸지 않는다
#
# 번들: ollama-embedding-gpu-prep-<코드네임>-<커널>.tar.gz (build-gpu-prep.sh, README 3절)
#   NVIDIA 드라이버 + 번들 커널용 Ubuntu prebuilt 모듈(DKMS 없음), nvidia-container-toolkit,
#   Docker Engine. apt 원본은 번들의 debs/(flat 저장소) 하나뿐이고 인터넷을 쓰지 않는다.
#
# 바꾸는 것:
#   - deb 설치 (번들 저장소만 원본으로 쓰는 apt)
#   - Docker 엔진·containerd 가 없을 때 Docker 설치와 enable
#   - docker 런타임에 nvidia 가 없을 때: /etc/docker/daemon.json 에 nvidia 런타임 등록
#     (기존 파일은 .bak.<시각> 으로 복사), docker 재시작
# 바꾸지 않는 것: 커널, 방화벽, apt 원본 목록(/etc/apt/sources.list*), 재부팅
#
# nouveau 차단은 nvidia-kernel-common-<브랜치> 패키지가 한다(/lib/modprobe.d/
# nvidia-graphics-drivers.conf 설치와 initramfs 재생성). 이 스크립트는 결과를 판정만 한다.
#---------------------------------------------------------------------
BUNDLE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMON_FILE="${BUNDLE_ROOT}/00-common/common.sh"
if [[ ! -f "$COMMON_FILE" ]]; then
    printf 'ERROR: 번들 공통 파일을 찾을 수 없습니다: %s\n' "$COMMON_FILE" >&2
    printf '빌드 산출물 ollama-embedding-gpu-prep-<코드네임>-<커널>.tar.gz 를 압축 해제한 디렉터리에서 install-gpu-prep.sh 를 실행하세요.\n' >&2
    printf '예: tar xzf ollama-embedding-gpu-prep-noble-7.0.0-1014-aws.tar.gz && cd ollama-embedding-gpu-prep-noble-7.0.0-1014-aws && sudo ./install-gpu-prep.sh --dry-run\n' >&2
    exit 1
fi
source "$COMMON_FILE"

MODE="install"
case "${1:-}" in
    --dry-run)    MODE="dry-run" ;;
    --check-only) MODE="check" ;;
    "")           MODE="install" ;;
    *)            die "알 수 없는 인자: $1 (--dry-run | --check-only)" ;;
esac

require_root

CONF_DIR="${BUNDLE_ROOT}/conf"
DEB_DIR="${BUNDLE_ROOT}/debs"
for f in target-kernel codename gpu.specs docker.specs packages.list; do
    [[ -s "${CONF_DIR}/${f}" ]] \
        || die "번들의 conf/${f} 가 없다. GPU 사전 준비 번들을 압축 해제한 디렉터리인지 확인할 것."
done
BUNDLE_KVER="$(head -n 1 "${CONF_DIR}/target-kernel")"
BUNDLE_CN="$(head -n 1 "${CONF_DIR}/codename")"
GPU_SPECS=()
while IFS= read -r l; do [[ -z "$l" ]] || GPU_SPECS+=("$l"); done < "${CONF_DIR}/gpu.specs"
DOCKER_SPECS=()
while IFS= read -r l; do [[ -z "$l" ]] || DOCKER_SPECS+=("$l"); done < "${CONF_DIR}/docker.specs"
[[ "$DEB_DIR" != *[[:space:]]* ]] \
    || die "번들 경로에 공백이 있다: ${DEB_DIR}. apt 원본 줄이 깨지므로 공백 없는 경로에 압축 해제할 것."

# 이 중 하나라도 설치돼 있거나 dockerd 가 있으면 Docker 는 설치하지 않고 그대로 둔다
# (10-k8s 노드와 기존 Docker 호스트를 건드리지 않는다).
DOCKER_PKGS=(docker-ce docker-ce-cli docker.io docker-engine moby-engine containerd.io containerd podman-docker)
# 시뮬레이션에서 거부하는 설치 대상. 커널을 바꾸거나 DKMS 로 빌드하는 설치는 하지 않는다.
KERNEL_PKG_RE='^(linux-image-|linux-image-unsigned-|linux-headers-|linux-modules-[0-9]|linux-modules-extra-)'
DKMS_PKG_RE='^(dkms|nvidia-dkms-.*)$'

INSTALL_DOCKER=0
TOP=()

#=====================================================================
# 번들 apt
#
# 원본은 번들 debs/ 하나다. 호스트의 원본 목록(/etc/apt/sources.list*)과 목록 캐시
# (/var/lib/apt/lists), pkgcache 를 읽거나 쓰지 않는다. dpkg 상태와 extended_states
# (자동 설치 표시)는 호스트 것을 쓴다.
# dpkg -i *.deb 를 쓰지 않는 이유: 번들에는 대상에 이미 있는 패키지의 다른 버전이 들어
# 있을 수 있다(예: git). dpkg -i 는 그 패키지를 바꾸지만 apt 는 설치된 버전이 의존성을
# 만족하면 그대로 둔다. 최상위 패키지만 지정하고 나머지는 apt 가 번들에서 고른다.
#=====================================================================
APT_TMP=""
APT_BUNDLE_OPTS=()
trap '[[ -z "$APT_TMP" ]] || rm -rf "$APT_TMP"' EXIT

bundle_apt_update() {
    APT_TMP="$(mktemp -d)"
    mkdir -p "${APT_TMP}/lists/partial"
    printf 'deb [trusted=yes] file:%s ./\n' "$DEB_DIR" > "${APT_TMP}/sources.list"
    APT_BUNDLE_OPTS=(
        -o "Dir::Etc::sourcelist=${APT_TMP}/sources.list"
        -o Dir::Etc::sourceparts=/dev/null
        -o "Dir::State::Lists=${APT_TMP}/lists"
        -o Dir::Cache::pkgcache=
        -o Dir::Cache::srcpkgcache=
        -o APT::Install-Recommends=true
        -o APT::Sandbox::User=root
        -o DPkg::Lock::Timeout=900
        -o Acquire::Languages=none
    )
    apt-get "${APT_BUNDLE_OPTS[@]}" -qq update \
        || die "번들 저장소로 apt-get update 를 하지 못했다: ${DEB_DIR}"
}

#=====================================================================
# 상태 도우미
#=====================================================================
# "이름 버전" 줄. 지웠거나(config-files) 기록만 있는(not-installed) 것은 뺀다.
installed_pkgs() {
    { dpkg-query -W -f="\${db:Status-Status} \${Package} \${Version}\n" "$@" 2>/dev/null || true; } \
        | awk '$1 != "not-installed" && $1 != "config-files" {print $2, $3}'
}

# lsmod 출력을 변수에 담아 파이프를 없앤다(common.sh ctr_missing_images 참고).
module_loaded() {
    local m
    m="$(lsmod 2>/dev/null)" || return 1
    awk -v n="$1" '$1 == n {f = 1} END {exit !f}' <<<"$m"
}
nouveau_not_loaded() { ! module_loaded nouveau; }

kernel_is_bundle() { [[ "$(uname -r)" == "$BUNDLE_KVER" ]]; }

# GRUB 기본 항목은 /boot/vmlinuz-* 중 가장 높은 버전이다. unattended-upgrades 등으로
# 새 커널이 들어왔으면 재부팅 뒤 번들 모듈이 없는 커널로 뜬다. 재부팅 전에 잡는다.
next_boot_kernel() {
    local f
    for f in /boot/vmlinuz-*; do
        if [[ -e "$f" ]]; then echo "${f#/boot/vmlinuz-}"; fi
    done | sort -V | tail -n 1
}
next_boot_is_bundle() { [[ "$(next_boot_kernel)" == "$BUNDLE_KVER" ]]; }

pkg_version_is() {
    [[ "$(dpkg-query -W -f="\${db:Status-Status} \${Version}" "$1" 2>/dev/null || true)" == "installed $2" ]]
}

nouveau_blacklisted() {
    local c
    c="$(modprobe -c 2>/dev/null)" || return 1
    grep -qx 'blacklist nouveau' <<<"$c"
}

initramfs_has_nvidia_conf() {
    local l
    l="$(lsinitramfs "/boot/initrd.img-${BUNDLE_KVER}" 2>/dev/null)" || return 1
    grep -q '/nvidia-graphics-drivers\.conf$' <<<"$l"
}

ctk_version_ok() {
    local v
    v="$(nvidia-ctk --version 2>/dev/null)" || return 1
    [[ "$v" == *"version ${NVIDIA_CTK_VERSION%-*}"* ]]
}

nvidia_smi_gpu() {
    local l
    l="$(nvidia-smi -L 2>/dev/null)" || return 1
    [[ "$l" == *"GPU "* ]]
}

driver_version_ok() {
    local out v
    out="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null)" || return 1
    [[ -n "$out" ]] || return 1
    while IFS= read -r v; do
        [[ "${v//[[:space:]]/}" == "$NVIDIA_DRIVER_VERSION" ]] || return 1
    done <<<"$out"
}

docker_usable() { command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; }

docker_has_nvidia_runtime() {
    local rt
    rt="$(docker info -f '{{json .Runtimes}}' 2>/dev/null)" || return 1
    [[ "$rt" == *'"nvidia":'* ]]
}

# 10-k8s install.sh 와 같은 경고. docker 를 재시작하면 실행 중인 컨테이너도 함께 다시 뜬다.
warn_running_containers() {
    local n
    n="$(docker ps -q 2>/dev/null | grep -c . || true)"
    if [[ "${n:-0}" -gt 0 ]]; then
        warn "docker 컨테이너 ${n}개가 실행 중이다."
        warn "nvidia 런타임을 등록하면서 docker 데몬을 재시작하므로 이들도 함께 다시 뜬다."
        docker ps --format '    {{.Names}}' 2>/dev/null | head -12 || true
    fi
}

#=====================================================================
# 사전 확인 (install · dry-run 공통, 모두 읽기 전용)
#=====================================================================
preflight() {
    step "사전 확인 (번들: Ubuntu ${BUNDLE_CN}, 커널 ${BUNDLE_KVER})"
    verify_manifest "$BUNDLE_ROOT"

    # 커널을 가장 먼저 본다. prebuilt 모듈은 커널 ABI 마다 다른 패키지라 다른 커널에는
    # 설치할 수 없다. 이 앞에서는 아무것도 바꾸지 않는다.
    local cur
    cur="$(uname -r)"
    [[ "$cur" == "$BUNDLE_KVER" ]] \
        || die "커널이 번들과 다르다: 지금 ${cur} / 번들 ${BUNDLE_KVER}. NVIDIA prebuilt 커널 모듈은 커널 버전에 묶여 이 번들로는 설치할 수 없다. 아무것도 바꾸지 않았다. 같은 Ubuntu 버전의 온라인 호스트에서 './build-gpu-prep.sh --kernel ${cur}' 로 이 커널용 번들을 만들 것(README 3절, 4.2절). 커널을 바꾸거나 DKMS 로 빌드하지 않는다."
    ok "커널 ${cur} = 번들 커널"

    [[ "$OS_FAMILY" == debian ]] \
        || die "Ubuntu 전용 번들이다(지금 ID=${OS_ID:-?}). 아무것도 바꾸지 않았다."
    local cn
    cn="$(detect_codename)"
    [[ "$cn" == "$BUNDLE_CN" ]] \
        || die "Ubuntu 버전이 번들과 다르다: 지금 ${cn} / 번들 ${BUNDLE_CN}. 아무것도 바꾸지 않았다."
    detect_arch >/dev/null
    ok "Ubuntu ${cn} / ${BUNDLE_ARCH}"

    if ! pkg_installed "linux-image-${cur}" && ! pkg_installed "linux-image-unsigned-${cur}"; then
        die "지금 커널이 Ubuntu 커널 패키지가 아니다(linux-image-${cur} 가 설치돼 있지 않다). 아무것도 바꾸지 않았다."
    fi
    ok "커널 패키지 linux-image-${cur} 설치됨"

    # GPU 유무는 참고로만 본다. 없어도 멈추지 않는다.
    local v gpu=0
    for v in /sys/bus/pci/devices/*/vendor; do
        if [[ -r "$v" && "$(cat "$v")" == 0x10de ]]; then gpu=1; break; fi
    done
    if ((gpu)); then ok "NVIDIA PCI 장치(vendor 0x10de) 있음"; else warn "NVIDIA PCI 장치(vendor 0x10de)가 보이지 않는다."; fi

    # 기존 NVIDIA 드라이버. 번들과 이름·버전이 같은 것만 있으면 재실행으로 본다.
    # DKMS 드라이버가 있는 호스트(asw 등)에 prebuilt 모듈이 겹치면 모듈이 두 벌이 된다.
    # 시뮬레이션의 Remv 검사로는 이것을 못 잡는다.
    local have name ver
    local -a foreign=()
    have="$(awk '{print $1, $2}' "${CONF_DIR}/packages.list")"
    while read -r name ver; do
        [[ -n "$name" ]] || continue
        grep -qxF "${name} ${ver}" <<<"$have" || foreign+=("${name} ${ver}")
    done < <(installed_pkgs 'nvidia-driver-*' 'nvidia-headless-*' 'nvidia-dkms-*' \
                            'nvidia-kernel-common-*' 'linux-modules-nvidia-*')
    if ((${#foreign[@]} > 0)); then
        for v in "${foreign[@]}"; do warn "번들과 다른 NVIDIA 드라이버 패키지: ${v}"; done
        die "이 호스트에는 다른 NVIDIA 드라이버가 이미 있다. 이 번들은 드라이버가 없는 호스트용이다. 아무것도 바꾸지 않았다."
    fi
    ok "번들과 다른 NVIDIA 드라이버 없음"

    local p
    local -a found=()
    for p in "${DOCKER_PKGS[@]}"; do
        if pkg_installed "$p"; then found+=("$p"); fi
    done
    if command -v dockerd >/dev/null 2>&1; then found+=("$(command -v dockerd)"); fi
    TOP=("${GPU_SPECS[@]}")
    if ((${#found[@]} > 0)); then
        INSTALL_DOCKER=0
        log "Docker 는 설치하지 않는다. 이미 있다: ${found[*]}"
    else
        INSTALL_DOCKER=1
        TOP+=("${DOCKER_SPECS[@]}")
        log "Docker 엔진·containerd 가 없다 -> 번들의 Docker 도 설치한다 (docker-ce ${DOCKER_VERSION}, containerd.io ${CONTAINERD_VERSION})"
    fi

    step "apt 시뮬레이션 (원본 = 번들 저장소만)"
    bundle_apt_update
    local out rc=0
    out="$(apt-get "${APT_BUNDLE_OPTS[@]}" -s install "${TOP[@]}" 2>&1)" || rc=$?
    if ((rc != 0)); then
        tail -n 30 <<<"$out" | sed 's/^/    /' >&2
        die "번들 저장소만으로 의존성이 풀리지 않는다(apt rc=${rc}). 대상 Ubuntu 버전이 번들과 다르거나 기준선 패키지가 번들보다 오래됐다(README 11절). 아무것도 바꾸지 않았다."
    fi
    local line pkg
    local -a inst=() upg=() remv=() bad=()
    while IFS= read -r line; do
        case "$line" in
            "Inst "*)
                pkg="${line#Inst }"; pkg="${pkg%% *}"
                if [[ "$line" == "Inst ${pkg} ["* ]]; then upg+=("$pkg"); else inst+=("$pkg"); fi
                pkg="${pkg%%:*}"
                if [[ "$pkg" =~ $KERNEL_PKG_RE || "$pkg" =~ $DKMS_PKG_RE ]]; then bad+=("$pkg"); fi
                ;;
            "Remv "*)
                pkg="${line#Remv }"; remv+=("${pkg%% *}")
                ;;
        esac
    done <<<"$out"
    if ((${#remv[@]} > 0 || ${#bad[@]} > 0)); then
        for p in "${remv[@]}"; do warn "제거 대상: ${p}"; done
        for p in "${bad[@]}"; do warn "커널·dkms 패키지 설치 대상: ${p}"; done
        die "번들 설치가 패키지 제거 ${#remv[@]}건, 커널·dkms 패키지 ${#bad[@]}건을 일으킨다. 커널을 바꾸거나 DKMS 로 빌드하는 설치는 하지 않는다. 아무것도 바꾸지 않았다."
    fi
    ok "새로 설치 ${#inst[@]} / 업그레이드 ${#upg[@]} / 제거 0 / 커널·dkms 패키지 0"
    if ((${#upg[@]} > 0)); then log "  업그레이드: ${upg[*]}"; fi
}

#=====================================================================
# docker 에 nvidia 런타임 등록 (없을 때만)
#=====================================================================
register_nvidia_runtime() {
    step "docker 에 nvidia 런타임 등록"
    if ! docker_usable; then
        warn "docker 를 쓸 수 없어 nvidia 런타임 등록을 건너뛴다. Docker 를 준비한 뒤 다시 실행할 것."
        return 0
    fi
    if docker_has_nvidia_runtime; then
        log "변경 없음: docker 런타임에 nvidia 가 이미 있다"
        return 0
    fi
    command -v nvidia-ctk >/dev/null 2>&1 || die "nvidia-ctk 가 없다. toolkit 설치를 확인할 것."
    if [[ -f /etc/docker/daemon.json ]]; then
        local bak
        bak="/etc/docker/daemon.json.bak.$(date +%Y%m%d-%H%M%S)"
        cp -a /etc/docker/daemon.json "$bak"
        log "기존 파일 백업: ${bak}"
    fi
    nvidia-ctk runtime configure --runtime=docker || die "nvidia-ctk runtime configure --runtime=docker 실패"
    systemctl restart docker || die "docker 재시작 실패"
    retry_until 60 docker info || die "docker 재시작 뒤 데몬이 응답하지 않는다"
    docker_has_nvidia_runtime \
        || die "등록한 뒤에도 docker 런타임에 nvidia 가 없다. /etc/docker/daemon.json 을 확인할 것."
    ok "docker 런타임에 nvidia 등록 (/etc/docker/daemon.json, docker 재시작)"
}

#=====================================================================
# 판정
#   $1 = install: 드라이버 동작 항목은 nvidia 모듈이 이미 적재돼 있을 때만 본다(재부팅 전)
#        check  : 모든 항목
#=====================================================================
run_checks() {
    local mode="$1" spec
    step "판정: 설치 상태"
    check "커널 = 번들 커널 (${BUNDLE_KVER})"                    kernel_is_bundle
    check "다음 부팅 커널 = 번들 커널 (/boot/vmlinuz-* 최신)"     next_boot_is_bundle
    for spec in "${GPU_SPECS[@]}"; do
        check "패키지 ${spec%%=*} = ${spec#*=}" pkg_version_is "${spec%%=*}" "${spec#*=}"
    done
    check "nouveau 차단 설정 (modprobe -c: blacklist nouveau)"   nouveau_blacklisted
    check "initramfs(${BUNDLE_KVER})에 nvidia-graphics-drivers.conf" initramfs_has_nvidia_conf
    check "nvidia-ctk ${NVIDIA_CTK_VERSION%-*}"                  ctk_version_ok
    check "docker 사용 가능"                                      docker info
    check "docker compose 사용 가능"                              docker compose version
    check "docker 런타임에 nvidia"                                docker_has_nvidia_runtime

    if [[ "$mode" == check ]] || module_loaded nvidia; then
        step "판정: 드라이버 동작"
        check "nouveau 미적재"                                    nouveau_not_loaded
        check "nvidia 모듈 적재"                                  module_loaded nvidia
        check "nvidia-smi -L 에 GPU"                              nvidia_smi_gpu
        check "드라이버 버전 = ${NVIDIA_DRIVER_VERSION} (nvidia-smi)" driver_version_ok
    fi

    # nvidia-smi 는 드라이버와 통신하지 못하면 오류 문구를 stdout 에 쓰고 실패한다.
    # 성공했을 때만 값을 쓴다(재부팅 전에는 "?").
    local dv drv="" gpus="" out
    dv="$(docker version -f '{{.Server.Version}}' 2>/dev/null || true)"
    if out="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null)"; then
        drv="${out%%$'\n'*}"
    fi
    if out="$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null)"; then
        gpus="$(paste -sd, - <<<"$out")"
    fi
    log "docker ${dv:-?} / 드라이버 ${drv:-?} / GPU ${gpus:-?}"
    check_summary
}

#=====================================================================
# 설치
#=====================================================================
do_install() {
    preflight
    if ((INSTALL_DOCKER == 0)) && docker_usable && ! docker_has_nvidia_runtime; then
        warn_running_containers
    fi

    step "설치 (원본 = 번들 저장소만, 최상위 패키지 ${#TOP[@]}개)"
    DEBIAN_FRONTEND=noninteractive apt-get "${APT_BUNDLE_OPTS[@]}" install -y "${TOP[@]}" \
        || die "apt 설치 실패. 위 apt 출력을 확인할 것."
    ok "deb 설치 완료"
    if ((INSTALL_DOCKER)); then
        systemctl enable --now docker || die "docker 서비스를 켜지 못했다"
        ok "docker 서비스 enable + 기동"
    fi

    register_nvidia_runtime

    local rc=0
    run_checks install || rc=$?
    echo
    if module_loaded nvidia; then
        ok "nvidia 모듈이 적재돼 있다. 재부팅 없이 GPU 를 쓸 수 있다."
    else
        local why="nvidia 모듈 미적재"
        if module_loaded nouveau; then why="nouveau 적재 중 / nvidia 모듈 미적재"; fi
        warn "재부팅이 필요하다(${why}). 이 설치는 커널 패키지를 바꾸지 않았다."
        log  "  sudo reboot"
        log  "  재부팅 뒤: sudo ./install-gpu-prep.sh --check-only"
    fi
    exit "$rc"
}

case "$MODE" in
    check)   run_checks check; exit $? ;;
    dry-run) preflight; ok "dry-run: 바꾼 것 없음"; exit 0 ;;
    install) do_install ;;
esac
