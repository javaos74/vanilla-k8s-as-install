#!/usr/bin/env bash
#---------------------------------------------------------------------
# 10-k8s : OS 패키지 번들 수집 — rhel 계열 (RHEL / Rocky 9)
#
# build-bundle.sh 가 OS_FAMILY=rhel 일 때 source 한다. 빌드 전용이며 번들에는
# 들어가지 않는다. pkgs-debian.sh 와 같은 함수를 제공한다.
#
#   pkgs_prepare_build_host        빌드 호스트에 k8s · docker rpm 저장소 등록
#   pkgs_download <패키지 디렉터리>  rpm 다운로드. PKG_COUNT 설정
#
# 이 스크립트가 빌드 호스트에 남기는 변경:
#   - /etc/yum.repos.d/vk8s-{kubernetes,docker}.repo (멱등)
#
# 빌드 호스트는 대상과 같은 RHEL 주 버전이어야 하고, 대상과 같은 저장소
# (RHEL 은 구독/RHUI, Rocky 는 공식 미러)에 접근할 수 있어야 한다.
#---------------------------------------------------------------------

# 타깃이 이미 갖고 있다고 가정하는 기준선. comps 그룹 core = "Minimal Install" 의
# 핵심이며 RHEL 클라우드 이미지에도 들어 있다(실측: Azure RHEL 9.6 에서 core 의
# 358개 중 펌웨어·microcode 등 15개만 없었다).
RHEL_BASELINE_GROUPS=(core)

pkgs_prepare_build_host() {
    require_cmds dnf rpm rpm2cpio cpio python3
    local major; major="${OS_VERSION_ID%%.*}"

    step "dnf 저장소 등록 (빌드 호스트)"
    sudo tee /etc/yum.repos.d/vk8s-kubernetes.repo >/dev/null <<EOF
# vanilla-k8s 10-k8s 번들 빌드용. 10-k8s/pkgs-rhel.sh 가 만들었다.
[vk8s-kubernetes]
name=Kubernetes ${K8S_MINOR} (vanilla-k8s build)
baseurl=${K8S_RPM_REPO}
enabled=1
gpgcheck=1
gpgkey=${K8S_RPM_KEY_URL}
EOF
    # \$releasever 를 쓰지 않고 주 버전을 박는다. RHUI EUS 는 releasever 가 9.6 처럼
    # 부 버전까지 들어가는데 docker 저장소 경로는 rhel/9 뿐이다.
    sudo tee /etc/yum.repos.d/vk8s-docker.repo >/dev/null <<EOF
# vanilla-k8s 10-k8s 번들 빌드용. 10-k8s/pkgs-rhel.sh 가 만들었다.
[vk8s-docker]
name=Docker CE (vanilla-k8s build)
baseurl=${DOCKER_RPM_REPO}/${major}/x86_64/stable
enabled=1
gpgcheck=1
gpgkey=${DOCKER_RPM_KEY_URL}
EOF
    log "dnf makecache"
    sudo dnf -q -y makecache >/dev/null || die "dnf makecache 실패. 저장소(구독/RHUI) 접근을 확인할 것."
    ok "저장소: vk8s-kubernetes, vk8s-docker"
}

pkgs_download() {
    local RPM_DIR="$1"
    local major; major="${OS_VERSION_ID%%.*}"
    local el="el${major}"

    step "rpm 의존성 계산 및 다운로드"

    # 버전을 못 박는다. 저장소에 더 새 버전이 생겨도 번들은 고정된다.
    local -a PINNED=(
        "kubeadm-${K8S_VERSION}-${K8S_RPM_RELEASE}"
        "kubelet-${K8S_VERSION}-${K8S_RPM_RELEASE}"
        "kubectl-${K8S_VERSION}-${K8S_RPM_RELEASE}"
        "cri-tools-${CRI_TOOLS_PKG_VERSION%%-*}-${K8S_RPM_RELEASE}"
        "kubernetes-cni-${CNI_PLUGINS_VERSION}-${K8S_RPM_RELEASE}"
        "containerd.io-${CONTAINERD_VERSION}-${CONTAINERD_DEB_REVISION}.${el}"
        "docker-ce-${DOCKER_VERSION}-${DOCKER_DEB_REVISION}.${el}"
        "docker-ce-cli-${DOCKER_VERSION}-${DOCKER_DEB_REVISION}.${el}"
        "docker-buildx-plugin-${DOCKER_BUILDX_VERSION}-1.${el}"
        "docker-compose-plugin-${DOCKER_COMPOSE_VERSION}-1.${el}"
    )
    # OS 패키지. 기준선(@core)에 있어도 번들에 넣는다. 클라우드 이미지가 기준선을 다
    # 갖고 있지 않을 수 있다(실측: Rocky 9.8 Azure 이미지에 nftables 가 없어
    # "No match for argument: nftables" 로 설치 실패). 설치는 이름으로 하므로(install.list)
    # 타깃에 이미 있는 패키지는 버전이 바뀌지 않는다.
    local -a OS_DEPS=(
        conntrack-tools socat ethtool iptables-nft iproute kmod
        nfs-utils           # 50-nfs-csi 단계에서 필요
        nftables            # 90-verify 에어갭 전환에 필요
    )

    #-----------------------------------------------------------------
    # 빈 rpmdb 로 폐쇄집합을 계산하고 기준선을 뺀다(rpm-closure.py).
    #   번들 = 폐쇄집합(기준선 + 대상) - 폐쇄집합(기준선)
    # 빌드 호스트에 무엇이 깔려 있든 결과가 같다. pkgs-debian.sh 와 같은 원리다.
    #
    # 버전 결합 패키지(기준선과 '=' 로 묶인 것)와 커널 부속 모듈은 같은 부 버전의
    # 모든 빌드를 넣는다. 타깃의 기준선 패치 수준이 빌드 시점 저장소보다 낮아도
    # 설치 시 dnf 가 맞는 빌드를 고른다(rpm-closure.py 머리말 참고).
    #-----------------------------------------------------------------
    local minor="${OS_VERSION_ID#*.}"; [[ "$minor" == "$OS_VERSION_ID" ]] && minor=0
    local dist="el${major}_${minor}"
    # RHEL 10 은 br_netfilter 가 kernel-modules-extra 로 옮겨졌다(실측: RHEL 10.2 Azure,
    # modprobe: FATAL: Module br_netfilter not found). 커널 빌드마다 다른 패키지라
    # 타깃 커널을 미리 알 수 없으므로 같은 부 버전의 모든 빌드를 넣는다.
    local -a allver=()
    ((major >= 10)) && allver+=(--all-versions kernel-modules-extra)

    local closure="${SCRIPT_DIR}/rpm-closure.py"
    local -a gargs=() pargs=()
    local g s
    for g in "${RHEL_BASELINE_GROUPS[@]}"; do gargs+=(--group "$g"); done
    for s in "${PINNED[@]}" "${OS_DEPS[@]}"; do pargs+=(--pkg "$s"); done

    log "의존성 폐쇄집합 계산 (기준선: @${RHEL_BASELINE_GROUPS[*]}, dist ${dist})"
    local out
    out="$(sudo python3 "$closure" "${gargs[@]}" "${pargs[@]}" --dist "$dist" "${allver[@]}")" \
        || die "rpm 폐쇄집합 계산 실패. versions.env 의 rpm 버전 핀과 저장소를 확인할 것."

    local -a EXTRA=() MULTI=()
    mapfile -t EXTRA < <(awk -F'\t' '$1=="EXTRA"{print $3}' <<<"$out")
    mapfile -t MULTI < <(awk -F'\t' '$1=="COUPLED"||$1=="ALLVER"{print $3}' <<<"$out" | sort -u)
    ((${#EXTRA[@]} > 0)) || die "번들에 넣을 rpm 이 없다(계산 오류)"
    log "번들 ${#EXTRA[@]}개 + 추가 빌드 ${#MULTI[@]}개 (버전 결합: $(awk -F'\t' '$1=="COUPLED"{print $2}' <<<"$out" | sort -u | tr '\n' ' ')$( ((major>=10)) && echo '/ kernel-modules-extra'))"

    log "rpm 다운로드"
    sudo dnf -q -y --disableexcludes=all download --destdir "$RPM_DIR" "${EXTRA[@]}" "${MULTI[@]}" >/dev/null \
        || die "rpm 다운로드 실패"
    sudo chown -R "$(id -u):$(id -g)" "$RPM_DIR" 2>/dev/null || true

    # 받은 파일과 계산 결과가 일치하는지. 하나라도 빠지면 번들에 구멍이 생긴다.
    local -a missing=()
    local nevra name
    for nevra in "${EXTRA[@]}"; do
        name="${nevra%-*:*}"         # 이름 = 마지막 '-<에포크>:' 앞
        compgen -G "${RPM_DIR}/$(pkg_file_glob "$name")" >/dev/null || missing+=("$name")
    done
    ((${#missing[@]} == 0)) || die "받지 못한 rpm: ${missing[*]}"

    # 설치는 번들을 로컬 저장소로 놓고 "이름으로" 한다(os/rhel.sh pkg_install_bundle_dir).
    # 그래야 같은 이름의 여러 빌드 중 타깃에 맞는 것을 dnf 가 고른다.
    # install.list = 설치 요청 목록. 핀 버전 + OS 패키지 이름(이미 있으면 dnf 가 건너뛴다).
    printf '%s\n' "${PINNED[@]}" "${OS_DEPS[@]}" > "${RPM_DIR}/install.list"
    pkg_install_build_tool createrepo_c
    createrepo_c -q --update "$RPM_DIR" >/dev/null || die "createrepo_c 실패"
    ok "로컬 저장소 메타데이터 생성 (repodata/)"

    PKG_COUNT="$(find "$RPM_DIR" -maxdepth 1 -name '*.rpm' | wc -l)"

    # 안전망: 기반 시스템 패키지가 섞이면 중단한다(타깃의 glibc/systemd 를 바꾸지 않게).
    local CORE_RE='^(glibc|glibc-common|systemd|systemd-libs|systemd-udev|dbus|dbus-libs|openssl|openssl-libs|python3|python3-libs|rpm|rpm-libs|dnf|libdnf|bash|coreutils|util-linux|kernel|kernel-core|selinux-policy|selinux-policy-targeted|libselinux|openssh|openssh-server|NetworkManager|redhat-release|rocky-release)-[0-9]'
    local -a hits=()
    mapfile -t hits < <(cd "$RPM_DIR" && find . -maxdepth 1 -name '*.rpm' -printf '%f\n' | grep -E "$CORE_RE" || true)
    if ((${#hits[@]} > 0)); then
        local h; for h in "${hits[@]}"; do warn "기반 시스템 패키지: $h"; done
        die "번들에 기반 시스템 패키지가 섞였다. 기준선(RHEL_BASELINE_GROUPS)을 확인할 것."
    fi
    ok "기반 시스템 패키지 미포함 확인"
    ok "rpm ${PKG_COUNT}개 ($(du -sh "$RPM_DIR" | cut -f1))"
}
