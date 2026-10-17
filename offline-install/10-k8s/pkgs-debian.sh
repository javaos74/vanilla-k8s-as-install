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
    # 전이 의존성 — 빌드 호스트 상태와 무관하게 계산한다
    #
    # 예전에는 `apt-get install --download-only --reinstall` 로 채웠다. 이 방식은
    # **빌드 호스트에 이미 설치된 의존성을 받지 않는다**(apt 가 충족된 것으로 본다).
    # 그래서 번들 내용이 빌드 호스트 상태에 따라 달라졌다.
    #
    # 실측 사고 두 건:
    #   1) CP 로 쓰던 노드에서 빌드 -> deb 23 -> 19개
    #      (docker-ce-rootless-extras / libnfsidmap1 / pigz / rpcbind 누락)
    #   2) 깨끗한 컨테이너인데도 빌드 도구 skopeo 를 먼저 설치하면서
    #      containernetworking-plugins -> iptables / nftables 의존 라이브러리가
    #      함께 깔렸다. 26.04 번들에서 libip4tc2 / libip6tc2 /
    #      libnetfilter-conntrack3 / libnfnetlink0 / libnftables1 / libnftnl11
    #      6개가 빠졌고, ubuntu-server-minimal 노드에서 iptables / nftables /
    #      conntrack / kubelet / docker-ce 가 "dependency problems" 로 미구성됐다.
    #      예전의 오염 검사는 정해진 6개 패키지만 봤기 때문에 잡지 못했다.
    #
    # 지금 방식: **빈 dpkg 상태**를 apt 에 주고 폐쇄집합을 계산한 뒤 기준선을 뺀다.
    #   기준선 = 타깃 노드가 이미 갖고 있다고 가정하는 것
    #          = ubuntu-server-minimal + Essential/required 패키지의 폐쇄집합
    #   번들   = 폐쇄집합(기준선 + 대상 패키지) - 폐쇄집합(기준선) + 명시 패키지
    # 기준선과 대상을 함께 풀어야 "a | b" 같은 대안 의존성이 기준선 쪽 선택을
    # 따른다. 따로 풀면 기준선에 b 가 있는데 a 를 번들에 넣는 일이 생긴다.
    #
    # 빌드 호스트에 무엇이 깔려 있든 결과가 같으므로 예전의 "깨끗한 호스트"
    # 검사(--allow-dirty-host)는 더 필요 없다. 인자는 호환성을 위해 받기만 한다.
    #-----------------------------------------------------------------
    ((ALLOW_DIRTY_HOST)) && log "--allow-dirty-host 는 더 이상 필요 없다(의존성을 호스트 상태와 무관하게 계산한다)."

    local EMPTY_STATUS
    EMPTY_STATUS="$(mktemp)"
    # 빈 상태 파일로 "아무것도 설치되지 않은 시스템"을 가정해 받을 파일 목록만 뽑는다.
    # --print-uris 는 다운로드하지 않는다. NoLocking 은 일반 사용자 실행을 위해서다.
    _apt_closure() {
        apt-get -qq -o Dir::State::status="$EMPTY_STATUS" -o Debug::NoLocking=1 \
            install --print-uris -y "$@" 2>/dev/null \
            | awk '/^'\''/ {print $2}' | sort -u
    }
    # Essential: yes 또는 Priority: required 인 패키지. 의존성으로 선언되지 않아도
    # 모든 Ubuntu 에 깔려 있다(bash, coreutils, sed 등).
    local -a BASE_PKGS=(ubuntu-server-minimal)
    mapfile -t -O 1 BASE_PKGS < <(apt-cache dumpavail 2>/dev/null | awk '
        /^Package: /  { p = $2 }
        /^Essential: yes/ || /^Priority: required/ { req[p] = 1 }
        /^$/          { p = "" }
        END           { for (k in req) print k }' | sort -u)

    log "의존성 폐쇄집합 계산 (기준선: ubuntu-server-minimal + Essential/required ${#BASE_PKGS[@]}개)"
    local base_list joint_list
    base_list="$(_apt_closure "${BASE_PKGS[@]}")"
    joint_list="$(_apt_closure "${BASE_PKGS[@]}" "${PINNED_DEBS[@]}" "${OS_DEPS[@]}")"
    rm -f "$EMPTY_STATUS"
    [[ -n "$base_list" && -n "$joint_list" ]] \
        || die "apt 로 의존성 폐쇄집합을 계산하지 못했다. apt-get update 상태와 저장소를 확인할 것."

    # 파일명(이름_버전_아키텍처.deb, epoch 의 ':' 는 %3a)에서 이름=버전 을 만든다.
    local -a EXTRA_SPECS=()
    local f n rest v
    while read -r f; do
        [[ -n "$f" ]] || continue
        n="${f%%_*}"; rest="${f#*_}"; v="${rest%_*}"; v="${v//%3a/:}"
        EXTRA_SPECS+=("${n}=${v}")
    done < <(comm -13 <(echo "$base_list") <(echo "$joint_list"))
    log "기준선 $(wc -l <<<"$base_list")개 / 기준선+대상 $(wc -l <<<"$joint_list")개 -> 추가 ${#EXTRA_SPECS[@]}개"

    if ((${#EXTRA_SPECS[@]} > 0)); then
        download_debs "전이 의존성" "${EXTRA_SPECS[@]}" \
            || die "전이 의존성을 받지 못했다. 빠진 채로 두면 타깃에서 dpkg 의존성 오류가 난다."
    fi

    PKG_COUNT="$(find "$DEB_DIR" -name '*.deb' | wc -l)"
    # 기준선 대비 계산이므로 호스트에 따라 줄지 않는다. 크게 적으면 저장소 문제다.
    if (( PKG_COUNT < 20 )); then
        warn "deb 가 ${PKG_COUNT}개뿐이다. 저장소 상태(apt-get update)를 확인할 것."
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
