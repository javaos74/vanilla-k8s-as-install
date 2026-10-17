#!/usr/bin/env bash
#---------------------------------------------------------------------
# 10-k8s : OS 패키지 번들 수집 — debian 계열 (Ubuntu)
#
# build-bundle.sh 가 OS_FAMILY=debian 일 때 source 한다. 빌드 전용이며 번들에는
# 들어가지 않는다. 분리 전 build-bundle.sh 의 1·2절을 그대로 옮긴 것이다.
#
# 제공 함수 (build-bundle.sh 가 호출한다):
#   pkgs_prepare_build_host        빌드 호스트에 apt 저장소 등록 + apt-get update
#   pkgs_download <패키지 디렉터리>  deb 다운로드·의존성·오염 검사. PKG_COUNT 설정
#
# 이 스크립트가 빌드 호스트에 남기는 변경:
#   - /etc/apt/sources.list.d/{kubernetes,docker}.list 및 keyring 추가 (멱등)
#---------------------------------------------------------------------

#=====================================================================
# 1. 빌드 호스트에 apt 저장소 등록 (멱등)
#=====================================================================
pkgs_prepare_build_host() {
    require_cmds dpkg dpkg-deb

    local CODENAME
    CODENAME="$(detect_codename)"

    step "apt 저장소 등록 (빌드 호스트)"

    sudo install -d -m 0755 /etc/apt/keyrings

    if [[ ! -f /etc/apt/keyrings/kubernetes-apt-keyring.gpg ]]; then
        log "k8s 서명키 등록"
        curl -fsSL "$K8S_APT_KEY_URL" \
            | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
    fi
    echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] ${K8S_APT_REPO}/ /" \
        | sudo tee /etc/apt/sources.list.d/kubernetes.list >/dev/null

    if [[ ! -f /etc/apt/keyrings/docker.gpg ]]; then
        log "docker 서명키 등록"
        curl -fsSL "$DOCKER_APT_KEY_URL" \
            | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    fi
    echo "deb [arch=${BUNDLE_ARCH} signed-by=/etc/apt/keyrings/docker.gpg] ${DOCKER_REPO} ${CODENAME} stable" \
        | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null

    log "apt-get update"
    sudo apt-get update -qq
}

#=====================================================================
# 2. deb 다운로드
#=====================================================================
pkgs_download() {
    local DEB_DIR="$1"
    local CODENAME OSVER
    CODENAME="$(detect_codename)"
    OSVER="$(codename_to_osversion "$CODENAME")"

    step "deb 다운로드"

    # 버전을 못 박아 내려받는다. 저장소에 더 새 버전이 생겨도 번들은 고정된다.
    # docker-ce / docker-ce-cli 는 apt 버전 문자열에 epoch "5:" 가 붙는다(실측).
    local DOCKER_SUFFIX="${DOCKER_DEB_REVISION}~ubuntu.${OSVER}~${CODENAME}"
    local -a PINNED_DEBS=(
        "kubeadm=${K8S_PKG_VERSION}"
        "kubelet=${K8S_PKG_VERSION}"
        "kubectl=${K8S_PKG_VERSION}"
        "cri-tools=${CRI_TOOLS_PKG_VERSION}"
        "kubernetes-cni=${KUBERNETES_CNI_PKG_VERSION}"
        "containerd.io=${CONTAINERD_VERSION}-${DOCKER_SUFFIX}"
        "docker-ce=${DOCKER_DEB_EPOCH}${DOCKER_VERSION}-${DOCKER_SUFFIX}"
        "docker-ce-cli=${DOCKER_DEB_EPOCH}${DOCKER_VERSION}-${DOCKER_SUFFIX}"
        "docker-buildx-plugin=${DOCKER_BUILDX_VERSION}-${DOCKER_SUFFIX}"
        "docker-compose-plugin=${DOCKER_COMPOSE_VERSION}-${DOCKER_SUFFIX}"
    )

    # OS 기본 패키지지만 최소 설치 이미지에는 없을 수 있는 것들.
    # 이미 빌드 호스트에 설치돼 있어도 apt-get download 는 항상 받아온다.
    local -a OS_DEPS=(
        conntrack socat ebtables ethtool iptables iproute2 kmod
        nfs-common          # 50-nfs-csi 단계에서 필요
        nftables            # 90-verify 에어갭 전환에 필요
    )

    # apt-get download 는 인자 중 하나라도 해석에 실패하면 전체를 중단한다.
    # 그래서 패키지별로 호출하고 실패 목록을 모아 한 번에 보고한다.
    download_debs() {
        local label="$1"; shift
        local -a failed=()
        log "${label} (${#@}개)"
        for spec in "$@"; do
            if ! ( cd "$DEB_DIR" && apt-get download "$spec" >/dev/null 2>&1 ); then
                failed+=("$spec")
            fi
        done
        if ((${#failed[@]} > 0)); then
            for f in "${failed[@]}"; do
                warn "다운로드 실패: ${f}  (apt-cache madison ${f%%=*} 로 실제 버전 확인)"
            done
            return 1
        fi
        ok "${label} 완료"
    }

    download_debs "고정 버전 패키지" "${PINNED_DEBS[@]}" \
        || die "고정 버전 패키지를 받지 못했다. versions.env 의 버전 핀을 확인할 것."
    download_debs "OS 의존 패키지" "${OS_DEPS[@]}" \
        || warn "일부 OS 패키지를 받지 못했다. 타깃에 이미 설치돼 있으면 문제되지 않는다."

    #-----------------------------------------------------------------
    # 빌드 호스트는 **깨끗해야** 한다
    #
    # 아래 `apt-get install --download-only --reinstall` 은 명시한 패키지는 다시
    # 받지만, **이미 설치된 전이 의존성은 받지 않는다**(apt 가 충족된 것으로 본다).
    # 그래서 k8s/docker 가 이미 설치된 호스트에서 빌드하면 번들에 구멍이 생긴다.
    #
    # 실측: CP 로 쓰던 노드에서 다시 빌드했더니 deb 가 23개 -> 19개로 줄었다.
    #   docker-ce-rootless-extras / libnfsidmap1 / pigz / rpcbind 누락
    # 이 번들로 깨끗한 타깃에 설치하면 dpkg 의존성 오류가 난다.
    #
    # 폐쇄집합을 직접 계산해 채우는 방법은 쓰지 않는다. libc6 같은 기반 패키지까지
    # 끌어와 타깃에서 dpkg -i 로 기반 라이브러리를 바꿔버릴 위험이 있다.
    # 대신 오염을 감지해 멈춘다. --allow-dirty-host 로 넘길 수 있지만 권장하지 않는다.
    #-----------------------------------------------------------------
    local -a DIRTY=()
    local _p
    for _p in kubelet kubeadm kubectl containerd.io docker-ce nfs-common; do
        if pkg_installed "$_p"; then DIRTY+=("$_p"); fi
    done
    if ((${#DIRTY[@]} > 0)); then
        warn "빌드 호스트에 이미 설치된 대상 패키지가 있다: ${DIRTY[*]}"
        warn "이 상태로 빌드하면 **전이 의존성이 누락된 불완전한 번들**이 된다."
        if ((ALLOW_DIRTY_HOST)); then
            warn "--allow-dirty-host 가 지정돼 계속한다. 번들 완전성을 직접 확인할 것."
        else
            die "$(cat <<'MSG'
깨끗한 호스트에서 빌드할 것. 설치 대상과 같은 OS 의 새 VM 이면 된다.

이 검사가 있는 이유:
  apt 는 이미 설치된 의존성을 다시 내려받지 않는다. 그래서 설치가 끝난
  노드에서 번들을 만들면 그 노드에 이미 있는 패키지만큼 번들에 구멍이 생기고,
  깨끗한 타깃에서 dpkg 의존성 오류로 드러난다.

정말 이 호스트에서 만들어야 한다면:
  ./build-bundle.sh --allow-dirty-host
MSG
)"
        fi
    fi

    # 위에서 받지 못한 추가 의존성을 apt 가 계산해 채운다.
    # (예: docker-ce 가 요구하는 libslirp / pigz 등 OS 버전마다 다르다)
    log "잔여 의존성 계산 및 다운로드"
    mkdir -p "${DEB_DIR}/partial"
    sudo apt-get install -y --download-only --reinstall \
         -o Dir::Cache::archives="${DEB_DIR}" \
         "${PINNED_DEBS[@]}" "${OS_DEPS[@]}" >/dev/null 2>&1 || \
      warn "일부 의존성 다운로드를 건너뜀(이미 최신이거나 충돌). 설치 단계에서 확인된다."
    sudo chown -R "$(id -u):$(id -g)" "$DEB_DIR" 2>/dev/null || true
    rm -rf "${DEB_DIR}/partial" "${DEB_DIR}/lock"

    PKG_COUNT="$(find "$DEB_DIR" -name '*.deb' | wc -l)"
    # 깨끗한 24.04 서버에서 23개, 컨테이너(ubuntu-server-minimal 기반)에서 33개였다.
    # 크게 적으면 빌드 호스트 오염을 의심할 것.
    if (( PKG_COUNT < 20 )); then
        warn "deb 가 ${PKG_COUNT}개뿐이다. 깨끗한 호스트에서는 23개 이상이었다."
        warn "빌드 호스트 오염으로 전이 의존성이 누락됐을 수 있다."
    fi

    #-----------------------------------------------------------------
    # 핵심 시스템 패키지가 섞이면 중단한다
    #
    # 반대 방향의 오염도 위험하다. 빌드 환경이 **너무 최소**면(예: 최소
    # 컨테이너 이미지) 실제 서버에 기본 포함된 것들까지 의존성으로 끌려온다.
    # 그 번들을 타깃에서 dpkg -i 하면 systemd·libc6 같은 기반 패키지를 덮어써
    # 시스템을 망칠 수 있다.
    #
    # 실측: ubuntu:24.04 최소 이미지에서 빌드하니 deb 101개가 되고 systemd /
    # systemd-sysv / perl / python3 / dbus / openssh-client / libc6 가 포함됐다.
    # ubuntu-server-minimal 을 먼저 설치해 기반을 맞추면 33개로 줄고 이들이 빠진다.
    #-----------------------------------------------------------------
    local CORE_PKG_RE='^(systemd|systemd-sysv|systemd-dev|systemd-resolved|systemd-timesyncd|libsystemd-shared|libnss-systemd|libpam-systemd|libc6|libc-bin|perl|perl-base|perl-modules[-.0-9]*|python3|python3-minimal|python3\.[0-9]+|python3\.[0-9]+-minimal|dbus|dbus-bin|dbus-daemon|openssh-client|apparmor|libssl[0-9]|zlib1g|libstdc\+\+[0-9]+|libgcc-s[0-9]+|tzdata)_'
    local -a CORE_HITS=()
    mapfile -t CORE_HITS < <(cd "$DEB_DIR" && ls *.deb 2>/dev/null | grep -E "$CORE_PKG_RE" || true)
    if ((${#CORE_HITS[@]} > 0)); then
        local h
        for h in "${CORE_HITS[@]}"; do warn "핵심 시스템 패키지: ${h}"; done
        die "$(cat <<'MSG'
번들에 핵심 시스템 패키지가 섞였다. 이 번들을 쓰면 타깃이 손상될 수 있다.

원인은 빌드 환경이 실제 대상보다 **너무 최소**라는 것이다. 실제 서버에 기본
포함된 패키지가 없어서 apt 가 그것들까지 의존성으로 받아 왔다.

컨테이너에서 빌드한다면 기반 패키지를 먼저 맞출 것:
  apt-get install -y ubuntu-server-minimal

00-common/build-in-container.sh 는 이 작업을 대신 한다.
MSG
)"
    fi
    ok "핵심 시스템 패키지 미포함 확인"
    [[ "$PKG_COUNT" -gt 0 ]] || die "deb 를 하나도 받지 못했다"
    ok "deb ${PKG_COUNT}개 ($(du -sh "$DEB_DIR" | cut -f1))"
}
