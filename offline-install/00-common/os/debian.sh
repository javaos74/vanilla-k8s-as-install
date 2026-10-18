#!/usr/bin/env bash
#---------------------------------------------------------------------
# OS 계열 구현: debian (Ubuntu 22.04 / 24.04 / 26.04)
#
# os/detect.sh 가 OS_FAMILY=debian 일 때 source 한다. 인터페이스 설명은
# detect.sh 에 있다. 여기 있는 명령은 분리 전 각 단계 스크립트에 흩어져 있던
# 것을 그대로 옮긴 것이다(동작 동일).
#---------------------------------------------------------------------

# shellcheck disable=SC2034

PKG_EXT="deb"
PKG_BUNDLE_SUBDIR="debs"
PKG_NFS_CLIENT="nfs-common"
PKG_NFS_SERVER="nfs-kernel-server"

#--- 판별 ---------------------------------------------------------------
# Ubuntu 코드네임(jammy/noble/resolute)을 반환. 지원 목록 밖이면 즉시 중단한다.
detect_codename() {
    local cn
    [[ -r /etc/os-release ]] || die "/etc/os-release 를 읽을 수 없음 (Ubuntu 가 아닌가?)"
    cn="$(. /etc/os-release && echo "${VERSION_CODENAME:-}")"
    [[ -n "$cn" ]] || die "VERSION_CODENAME 을 확인할 수 없음"
    grep -qw "$cn" <<<"$SUPPORTED_CODENAMES" \
        || die "지원하지 않는 OS: $cn (지원: $SUPPORTED_CODENAMES)"
    echo "$cn"
}

os_bundle_tag() { detect_codename; }

os_label() {
    local cn; cn="$(detect_codename)"
    echo "Ubuntu $(codename_to_osversion "$cn") (${cn})"
}

os_native_arch() { dpkg --print-architecture; }

#--- 패키지 -------------------------------------------------------------
# "설치 완료(installed)" 상태만 참이다.
#
# 예전에는 dpkg -s 를 썼는데, dpkg -s 는 패키지를 지우고 설정 파일만 남은
# 상태(config-files, dpkg -l 의 rc)에서도 0 을 반환한다. 그래서 nfs-common 을
# dpkg -r 한 노드에서 "이미 설치됨" 으로 보고 설치를 건너뛰었고 mount.nfs4 가
# 없는 채로 진행됐다(실측, Ubuntu Server 26.04).
pkg_installed() {
    [[ "$(dpkg-query -W -f='${db:Status-Status}' "$1" 2>/dev/null || true)" == "installed" ]]
}

pkg_install_build_tool() {
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@"
}

pkg_install_online() {
    DEBIAN_FRONTEND=noninteractive apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -o DPkg::Lock::Timeout=900 "$@"
}

# dpkg 로 한 번에 넣고 의존성 문제는 apt 로 정리한다(오프라인이라 다운로드 없음).
# 실패 출력을 숨기지 않아 패키지 충돌/의존성 문제를 바로 확인할 수 있게 한다.
pkg_install_bundle_dir() {
    local dir="$1"
    dpkg -i "$dir"/*.deb || {
        log "dpkg 1차 실패 -> 의존성 정리 시도"
        DEBIAN_FRONTEND=noninteractive \
        apt-get -o DPkg::Lock::Timeout=900 -f install -y --no-download \
            || die "deb 의존성 해결 실패. 번들이 빌드 호스트와 다른 OS 용일 수 있다."
        dpkg -i "$dir"/*.deb || die "deb 설치 실패. 위 dpkg 오류를 확인할 것."
    }
}

pkg_install_file() { DEBIAN_FRONTEND=noninteractive dpkg -i "$1" >/dev/null; }

pkg_hold() { apt-mark hold "$@" >/dev/null; }

# 목록을 변수에 담아 파이프를 없앤다. pipefail 아래에서 grep -q 가 먼저 끝나면
# 앞 명령이 SIGPIPE 로 141 이 되어 거짓 실패가 난다(common.sh ctr_missing_images 참고).
pkg_is_held() {
    local held; held="$(apt-mark showhold 2>/dev/null || true)"
    grep -qxF "$1" <<<"$held"
}

pkg_file_glob() { echo "${1}_*.deb"; }

pkg_extract() { dpkg-deb -x "$1" "$2"; }

# apt 를 오프라인(로컬 deb 만)으로 실행한다.
# dpkg lock 경쟁(unattended-upgrades)으로 exit 100 이 나는 것을 막기 위해
# Lock::Timeout 을 준다. 기존 운영 클러스터에서 실제로 겪은 문제다.
apt_offline_install() {
    local deb_dir="$1"
    require_root
    log "로컬 deb 설치: $deb_dir"
    DEBIAN_FRONTEND=noninteractive \
    apt-get -o Debug::NoLocking=0 \
            -o DPkg::Lock::Timeout=900 \
            -o Dir::Etc::sourcelist=/dev/null \
            -o Dir::Etc::sourceparts=/dev/null \
            -o APT::Get::List-Cleanup=0 \
            install -y --no-download --allow-downgrades "$deb_dir"/*.deb \
        || die "deb 설치 실패: $deb_dir"
}

#--- CA 신뢰 저장소 -----------------------------------------------------
# 확장자가 .crt 여야 update-ca-certificates 가 인식한다.
# .pem 으로 두면 조용히 무시된다.
ca_trust_anchor_file() { echo "/usr/local/share/ca-certificates/${1}.crt"; }

ca_trust_update() { update-ca-certificates >/dev/null 2>&1; }

ca_trust_bundle_file() { echo "/etc/ssl/certs/ca-certificates.crt"; }
