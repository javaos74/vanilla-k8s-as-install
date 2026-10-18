#!/usr/bin/env bash
#---------------------------------------------------------------------
# OS 판별 + OS 계열별 구현 로더 (common.sh 가 source 한다)
#
# 왜 분리하는가:
#   단계 스크립트 대부분(20~80 의 install.sh)은 컨테이너만 다뤄 OS 와 무관하다.
#   OS 에 따라 달라지는 것은 패키지 관리자 · CA 신뢰 저장소 · 패키지 이름뿐이므로
#   그것만 이 디렉터리의 계열별 파일로 모으고, 단계 스크립트는 아래 인터페이스
#   함수만 호출한다. RHEL 계열을 추가할 때 단계 스크립트를 복제하지 않기 위함이다.
#
# 구성:
#   os/detect.sh   이 파일. OS_* 변수 설정, 인터페이스 기본 구현(미지원 시 중단), 로더
#   os/debian.sh   Ubuntu (apt / dpkg / update-ca-certificates)
#   os/<계열>.sh   OS_FAMILY 와 같은 이름의 파일이 있으면 자동으로 읽는다
#
# 이 파일은 source 전용이다. 직접 실행하지 않는다.
#---------------------------------------------------------------------

# shellcheck disable=SC2034

#--- 판별 ---------------------------------------------------------------
# /etc/os-release 를 서브셸에서 읽는다. 그대로 source 하면 NAME / VERSION /
# ID 같은 흔한 이름이 호출한 스크립트의 변수를 덮어쓴다.
#
# 결과 변수:
#   OS_ID          ubuntu / rocky / rhel ...      (os-release ID)
#   OS_VERSION_ID  26.04 / 9.6 ...                (os-release VERSION_ID)
#   OS_CODENAME    resolute / noble / jammy / ""  (os-release VERSION_CODENAME)
#   OS_FAMILY      debian | rhel | unknown
#
# /etc/os-release 가 없어도(macOS 관리 호스트) 실패하지 않는다. 05-certs 의
# make-certs.sh 처럼 OS 와 무관한 스크립트가 맥에서도 common.sh 를 읽기 때문이다.
# 그때는 OS_FAMILY=unknown 이 되고, OS 기능을 실제로 호출할 때 중단한다.
os_detect() {
    OS_ID="" OS_VERSION_ID="" OS_CODENAME="" OS_ID_LIKE=""
    if [[ -r /etc/os-release ]]; then
        local _l
        while IFS= read -r _l; do
            case "$_l" in
                OS_ID=*)         OS_ID="${_l#OS_ID=}" ;;
                OS_VERSION_ID=*) OS_VERSION_ID="${_l#OS_VERSION_ID=}" ;;
                OS_CODENAME=*)   OS_CODENAME="${_l#OS_CODENAME=}" ;;
                OS_ID_LIKE=*)    OS_ID_LIKE="${_l#OS_ID_LIKE=}" ;;
            esac
        done < <(
            # shellcheck disable=SC1091
            . /etc/os-release
            echo "OS_ID=${ID:-}"
            echo "OS_VERSION_ID=${VERSION_ID:-}"
            echo "OS_CODENAME=${VERSION_CODENAME:-}"
            echo "OS_ID_LIKE=${ID_LIKE:-}"
        )
    fi

    case " ${OS_ID} ${OS_ID_LIKE} " in
        *" ubuntu "*|*" debian "*)                    OS_FAMILY="debian" ;;
        *" rhel "*|*" fedora "*|*" centos "*|*" rocky "*) OS_FAMILY="rhel" ;;
        *)                                             OS_FAMILY="unknown" ;;
    esac
}

#--- 인터페이스 (기본 구현) ----------------------------------------------
# 계열별 파일이 아래 함수를 재정의한다. 재정의되지 않은 함수를 부르면
# 어떤 기능이 이 OS 에서 아직 없는지 알려주고 중단한다. 조용히 다른 OS 의
# 명령(apt 등)을 실행하는 것보다 낫다.
_os_unsupported() {
    die "이 OS 에서는 아직 지원하지 않는 기능: $1 (ID=${OS_ID:-?} VERSION_ID=${OS_VERSION_ID:-?} 계열=${OS_FAMILY})"
}

# 지원 대상 OS 인지 확인하고 번들 이름에 쓰는 OS 태그를 출력한다.
#   Ubuntu: 코드네임 (resolute / noble / jammy)
os_bundle_tag()        { _os_unsupported os_bundle_tag; }
# 사람이 읽는 OS 표기. BUNDLE-INFO 등에 쓴다.  예) "Ubuntu 26.04 (resolute)"
os_label()             { _os_unsupported os_label; }
# 이 호스트의 패키지 아키텍처 표기(amd64 등)를 출력한다.
os_native_arch()       { _os_unsupported os_native_arch; }

# 패키지가 "설치 완료" 상태인가(지우고 설정 파일만 남은 상태는 거짓).
pkg_installed()        { _os_unsupported pkg_installed; }
# 빌드 도구 설치(온라인 빌드 호스트, 일반 사용자 + sudo).  예) skopeo
pkg_install_build_tool() { _os_unsupported pkg_install_build_tool; }
# 저장소에서 설치(온라인 호스트, root).  예) NFS 서버 패키지
pkg_install_online()   { _os_unsupported pkg_install_online; }
# 번들 디렉터리의 패키지 파일 전부를 오프라인 설치(root).
pkg_install_bundle_dir() { _os_unsupported pkg_install_bundle_dir; }
# 패키지 파일 하나를 오프라인 설치(root).
pkg_install_file()     { _os_unsupported pkg_install_file; }
# 자동 업그레이드에서 제외(root).
pkg_hold()             { _os_unsupported pkg_hold; }
# 업그레이드 제외 상태인가.
pkg_is_held()          { _os_unsupported pkg_is_held; }
# 패키지 파일 이름 glob.  예) nfs-common -> nfs-common_*.deb
pkg_file_glob()        { _os_unsupported pkg_file_glob; }
# 패키지 파일을 설치하지 않고 디렉터리에 푼다.
pkg_extract()          { _os_unsupported pkg_extract; }

# OS 신뢰 저장소에 CA 를 넣을 경로(파일)를 출력한다. 인자: 신뢰 이름
ca_trust_anchor_file() { _os_unsupported ca_trust_anchor_file; }
# 신뢰 저장소를 갱신해 번들 파일에 반영한다(root).
ca_trust_update()      { _os_unsupported ca_trust_update; }
# 갱신 결과가 모이는 CA 번들 파일 경로를 출력한다.
ca_trust_bundle_file() { _os_unsupported ca_trust_bundle_file; }

# 새로 설치한 파일에 보안 정책 기본 레이블을 다시 붙인다(root). SELinux 가 없는 계열은 no-op.
os_restore_file_labels() { return 0; }

# 계열별 값. 계열 파일이 채운다.
#   PKG_EXT             패키지 파일 확장자            (deb)
#   PKG_BUNDLE_SUBDIR   10-k8s 번들 안 패키지 디렉터리 (debs)
#   PKG_NFS_CLIENT      NFS 클라이언트 패키지          (nfs-common)
#   PKG_NFS_SERVER      NFS 서버 패키지                (nfs-kernel-server)
PKG_EXT="" PKG_BUNDLE_SUBDIR="" PKG_NFS_CLIENT="" PKG_NFS_SERVER=""

#--- 로드 ---------------------------------------------------------------
os_detect
_OS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ "$OS_FAMILY" != "unknown" && -f "${_OS_DIR}/${OS_FAMILY}.sh" ]]; then
    # shellcheck disable=SC1090
    source "${_OS_DIR}/${OS_FAMILY}.sh"
fi
