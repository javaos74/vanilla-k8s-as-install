#!/usr/bin/env bash
#---------------------------------------------------------------------
# OS 계열 구현: rhel (RHEL / Rocky / AlmaLinux 9)
#
# os/detect.sh 가 OS_FAMILY=rhel 일 때 source 한다. 인터페이스 설명은
# detect.sh 에 있다. 검증: RHEL 9.6 Azure 이미지(SELinux enforcing, firewalld 활성).
#---------------------------------------------------------------------

# shellcheck disable=SC2034

PKG_EXT="rpm"
PKG_BUNDLE_SUBDIR="rpms"
PKG_NFS_CLIENT="nfs-utils"
PKG_NFS_SERVER="nfs-utils"
PKG_REMOVE_HINT="sudo dnf remove"

#--- PATH ---------------------------------------------------------------
# RHEL 의 sudo secure_path 에는 /usr/local/bin 이 없다(Ubuntu 에는 있다).
# helm / podman-static 이 /usr/local/bin 에 설치되므로 sudo ./install.sh 안에서
# command -v podman / helm 이 실패한다. 계열 파일을 읽을 때 앞에 붙인다.
case ":${PATH}:" in
    *:/usr/local/bin:*) ;;
    *) PATH="/usr/local/sbin:/usr/local/bin:${PATH}" ;;
esac
export PATH

#--- 판별 ---------------------------------------------------------------
_rhel_major() { echo "${OS_VERSION_ID%%.*}"; }

# 번들 태그 el<주버전>. 지원 목록 밖이면 즉시 중단한다.
os_bundle_tag() {
    local m; m="$(_rhel_major)"
    [[ -n "$m" ]] || die "VERSION_ID 를 확인할 수 없음 (ID=${OS_ID:-?})"
    grep -qw "$m" <<<"$SUPPORTED_RHEL_MAJORS" \
        || die "지원하지 않는 RHEL 계열 버전: ${OS_ID} ${OS_VERSION_ID} (지원 주 버전: ${SUPPORTED_RHEL_MAJORS})"
    echo "el${m}"
}

os_label() {
    local tag name
    tag="$(os_bundle_tag)"
    name="$(. /etc/os-release && echo "${NAME:-$OS_ID}")"
    echo "${name} ${OS_VERSION_ID} (${tag})"
}

os_native_arch() {
    case "$(uname -m)" in
        x86_64)  echo amd64 ;;
        aarch64) echo arm64 ;;
        *)       uname -m ;;
    esac
}

#--- 패키지 -------------------------------------------------------------
# rpm 에는 "설정 파일만 남은" 상태가 없다. 설치돼 있으면 참.
pkg_installed() { rpm -q --quiet "$1"; }

pkg_install_build_tool() { sudo dnf install -y -q "$@"; }

pkg_install_online() { dnf install -y "$@"; }

# 번들의 rpm 을 저장소 없이 설치한다.
#   번들에 repodata/ 와 install.list 가 있으면 번들을 **로컬 저장소**로 놓고 이름으로
#   설치한다. 같은 이름의 여러 빌드(버전 결합 패키지, 커널 부속 모듈) 중 타깃의 기준선
#   패키지와 맞는 것을 dnf 가 고르게 하기 위해서다(10-k8s/rpm-closure.py 머리말).
#   없으면(예전 번들) 디렉터리의 rpm 을 전부 설치한다.
#   --disablerepo='*'      : 인터넷/사내 저장소를 쓰지 않는다(에어갭 검증 조건)
#   --disableexcludes=all  : pkg_hold 가 dnf.conf 에 넣은 excludepkgs 가 재실행 시
#                            번들 패키지까지 걸러내지 않게 한다
#   gpgcheck=0             : docker/k8s 서명키는 타깃에 없다. 무결성은 SHA256SUMS 로 본다
_rhel_bundle_dnf() {
    local dir="$1"; shift
    dnf -y --disablerepo='*' --disableexcludes=all \
        --repofrompath="vk8s-bundle,file://$(realpath "$dir")" --enablerepo=vk8s-bundle \
        --setopt=vk8s-bundle.gpgcheck=0 --setopt=vk8s-bundle.metadata_expire=-1 "$@"
}

pkg_install_bundle_dir() {
    local dir="$1"
    if [[ -d "${dir}/repodata" && -f "${dir}/install.list" ]]; then
        local -a want=()
        mapfile -t want < <(grep -v '^\s*$' "${dir}/install.list")
        _rhel_bundle_dnf "$dir" install "${want[@]}" \
            || die "rpm 설치 실패. 타깃 기준선(@core) 패키지가 없거나 빌드 호스트와 부 버전이 다를 수 있다."
    else
        dnf -y --disablerepo='*' --disableexcludes=all install "$dir"/*.rpm \
            || die "rpm 설치 실패. 번들이 다른 RHEL 주 버전용이거나 기준선(@core) 패키지가 없을 수 있다."
    fi
}

# br_netfilter 등 k8s 가 쓰는 커널 모듈이 없으면 번들에서 채운다(modprobe 전에 호출).
#   RHEL 10: br_netfilter 가 kernel-modules-extra 로 옮겨졌다. 실행 중 커널과 정확히 같은
#   빌드가 필요하므로 번들에 같은 부 버전의 모든 빌드를 넣고 여기서 고른다.
os_kernel_modules_prepare() {
    local dir="$1" k; k="$(uname -r)"
    modinfo br_netfilter >/dev/null 2>&1 && return 0
    [[ -d "${dir}/repodata" ]] || die "br_netfilter 모듈이 없고 번들 저장소도 없다 (커널 ${k})"
    log "br_netfilter 없음 — 번들에서 kernel-modules-extra-${k} 설치"
    _rhel_bundle_dnf "$dir" install "kernel-modules-extra-${k}" \
        || die "번들에 커널 ${k} 용 kernel-modules-extra 가 없다. 빌드 호스트와 같은 부 버전 커널인지 확인할 것."
    modinfo br_netfilter >/dev/null 2>&1 || die "kernel-modules-extra 설치 후에도 br_netfilter 가 없다"
    ok "kernel-modules-extra-${k}"
}

pkg_install_file() {
    dnf -y -q --disablerepo='*' --disableexcludes=all install "$1" >/dev/null
}

# 자동 업그레이드 제외. dnf versionlock 플러그인은 기본 설치에 없어서
# /etc/dnf/dnf.conf [main] 의 excludepkgs 를 쓴다(k8s 공식 문서의 RHEL 방식과 같다).
pkg_hold() {
    local conf=/etc/dnf/dnf.conf cur p
    cur="$(sed -n 's/^excludepkgs=//p' "$conf" 2>/dev/null | head -1)"
    for p in "$@"; do
        grep -qw -- "$p" <<<"$cur" || cur="${cur:+$cur }$p"
    done
    if grep -q '^excludepkgs=' "$conf" 2>/dev/null; then
        sed -i "s|^excludepkgs=.*|excludepkgs=${cur}|" "$conf"
    else
        sed -i "/^\[main\]/a excludepkgs=${cur}" "$conf"
    fi
}

pkg_is_held() {
    local cur; cur="$(sed -n 's/^excludepkgs=//p' /etc/dnf/dnf.conf 2>/dev/null | head -1)"
    grep -qw -- "$1" <<<"$cur"
}

# 이름-버전-릴리스.아키텍처.rpm. 이름에 '-' 가 있어도 버전은 숫자로 시작한다.
pkg_file_glob() { echo "${1}-[0-9]*.rpm"; }

pkg_extract() {
    local f; f="$(realpath "$1")"
    ( cd "$2" && rpm2cpio "$f" | cpio -idm --quiet )
}

#--- CA 신뢰 저장소 -----------------------------------------------------
ca_trust_anchor_file() { echo "/etc/pki/ca-trust/source/anchors/${1}.crt"; }

ca_trust_update() { update-ca-trust extract; }

ca_trust_bundle_file() { echo "/etc/pki/tls/certs/ca-bundle.crt"; }

#--- SELinux 레이블 --------------------------------------------------
# 임시 디렉터리(/tmp, user_tmp_t)에서 옮긴 파일은 그 레이블을 달고 올 수 있다.
# 정책 기본값(file_contexts)으로 되돌린다.
os_restore_file_labels() {
    command -v selinuxenabled >/dev/null 2>&1 && selinuxenabled || return 0
    restorecon -R "$@" 2>/dev/null || warn "restorecon 실패: $*"
}

#--- k8s 노드 준비 ------------------------------------------------------
# firewalld 가 켜져 있으면 k8s · Cilium 포트를 열고 파드 대역을 trusted 로 둔다.
#
# 왜 필요한가: 파드 → apiserver 는 Service(10.96.0.1) → 노드 IP:6443 으로
# DNAT 되어 호스트 INPUT 으로 들어온다. 파드 인터페이스는 firewalld 존에 없어
# 기본 존(public)으로 분류되고, public 은 ssh 등만 허용하므로 CoreDNS 같은
# 일반 파드가 apiserver 에 닿지 못한다. hostNetwork 파드(cilium 등)는 영향이 없어
# 증상이 "CoreDNS 만 안 뜬다" 로 나타난다.
#
# firewalld 를 끄지 않는다. 운영 정책상 끌 수 없는 현장이 많다.
os_k8s_host_prepare() {
    if systemctl is-active --quiet firewalld 2>/dev/null; then
        local z p
        z="$(firewall-cmd --get-default-zone)"
        log "firewalld 활성 — 존 ${z} 에 k8s 포트 개방, 파드 대역 ${POD_CIDR} 를 trusted 로"
        for p in 6443/tcp 2379-2380/tcp 10250/tcp 10257/tcp 10259/tcp \
                 8472/udp 4240/tcp 4244/tcp 30000-32767/tcp; do
            firewall-cmd -q --permanent --zone="$z" --add-port="$p"
        done
        firewall-cmd -q --permanent --zone=trusted --add-source="$POD_CIDR"
        firewall-cmd -q --reload
        ok "firewalld 규칙 적용 (존 ${z})"
    else
        log "firewalld 비활성 — 방화벽 설정을 건너뛴다"
    fi
    # SELinux 는 enforcing 을 유지한다. containerd.io 가 의존하는 container-selinux
    # 정책이 번들에 들어 있다. 상태만 기록한다.
    if command -v getenforce >/dev/null 2>&1; then
        log "SELinux: $(getenforce)"
    fi
}
