#!/usr/bin/env bash
#---------------------------------------------------------------------
# 오프라인 번들 공통 함수
#
# 사용법: 각 스크립트 상단에서
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "${SCRIPT_DIR}/../00-common/common.sh"
#
# 이 파일은 source 전용이다. 직접 실행하지 않는다.
#---------------------------------------------------------------------

# shellcheck disable=SC2034

set -euo pipefail

COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${COMMON_DIR}/versions.env"

#--- 로깅 --------------------------------------------------------------
# 색은 tty 일 때만. 로그 파일로 리다이렉트하면 이스케이프가 섞이지 않는다.
if [[ -t 1 ]]; then
    _C_RED=$'\033[31m'; _C_YEL=$'\033[33m'; _C_GRN=$'\033[32m'
    _C_BLU=$'\033[34m'; _C_RST=$'\033[0m'
else
    _C_RED=""; _C_YEL=""; _C_GRN=""; _C_BLU=""; _C_RST=""
fi

_ts() { date '+%Y-%m-%d %H:%M:%S'; }

log()  { echo "${_C_BLU}[$(_ts)]${_C_RST} $*"; }
ok()   { echo "${_C_GRN}[$(_ts)] OK${_C_RST}   $*"; }
warn() { echo "${_C_YEL}[$(_ts)] WARN${_C_RST} $*" >&2; }
die()  { echo "${_C_RED}[$(_ts)] FATAL${_C_RST} $*" >&2; exit 1; }

# 단계 구분선. 긴 설치 로그에서 어디까지 진행됐는지 찾기 쉽게 한다.
step() { echo; echo "${_C_BLU}=== $* ===${_C_RST}"; }

#--- 환경 판별 ---------------------------------------------------------
# Ubuntu 코드네임(jammy/noble)을 반환. 지원 목록 밖이면 즉시 중단한다.
detect_codename() {
    local cn
    [[ -r /etc/os-release ]] || die "/etc/os-release 를 읽을 수 없음 (Ubuntu 가 아닌가?)"
    cn="$(. /etc/os-release && echo "${VERSION_CODENAME:-}")"
    [[ -n "$cn" ]] || die "VERSION_CODENAME 을 확인할 수 없음"
    grep -qw "$cn" <<<"$SUPPORTED_CODENAMES" \
        || die "지원하지 않는 OS: $cn (지원: $SUPPORTED_CODENAMES)"
    echo "$cn"
}

detect_arch() {
    local a; a="$(dpkg --print-architecture)"
    [[ "$a" == "$BUNDLE_ARCH" ]] || die "지원하지 않는 아키텍처: $a (번들은 $BUNDLE_ARCH 전용)"
    echo "$a"
}

# Ubuntu 코드네임 -> 버전 번호. docker-ce deb 파일명이
# docker-ce_<ver>-1~ubuntu.22.04~jammy_amd64.deb 형태라 둘 다 필요하다.
codename_to_osversion() {
    case "$1" in
        jammy) echo "22.04" ;;
        noble) echo "24.04" ;;
        *)     die "알 수 없는 코드네임: $1" ;;
    esac
}

require_root() {
    [[ "${EUID}" -eq 0 ]] || die "root 권한이 필요하다. sudo 로 실행할 것."
}

require_nonroot_build() {
    [[ "${EUID}" -ne 0 ]] || warn "빌드는 일반 사용자로 실행하는 것을 권장한다(산출물 소유권 문제 회피)."
}

# 필수 명령 존재 확인. 없으면 무엇을 설치해야 하는지 알려준다.
require_cmds() {
    local missing=()
    for c in "$@"; do command -v "$c" >/dev/null 2>&1 || missing+=("$c"); done
    ((${#missing[@]} == 0)) || die "필요한 명령이 없다: ${missing[*]}"
}

#--- 네트워크 상태 -----------------------------------------------------
# 온라인 빌드 호스트에서만 참이어야 한다.
is_online() {
    curl -fsS -o /dev/null --max-time 8 https://github.com 2>/dev/null
}

require_online() {
    is_online || die "인터넷 연결이 필요하다(빌드 단계). 에어갭 타깃에서 실행한 것이 아닌지 확인할 것."
}

# 에어갭 타깃에서 실행 중임을 확인. 설치 스크립트가 몰래 인터넷을 쓰지 않았음을
# 증명하는 근거가 되므로, 검증 시 반드시 통과시킨다.
require_airgap() {
    if is_online; then
        warn "이 호스트는 아직 인터넷에 연결돼 있다. 오프라인 검증이라면 90-verify/airgap-on.sh 를 먼저 실행할 것."
        return 1
    fi
    ok "인터넷 차단 상태 확인됨(에어갭)"
}

#--- 다운로드 + 체크섬 -------------------------------------------------
# curl 재시도를 붙인 다운로드. 이미 있으면 건너뛴다(빌드 재실행 시 시간 절약).
fetch() {
    local url="$1" out="$2"
    if [[ -s "$out" ]]; then
        log "이미 존재, 건너뜀: $(basename "$out")"
        return 0
    fi
    mkdir -p "$(dirname "$out")"
    log "다운로드: $url"
    curl -fL --retry 5 --retry-delay 3 --retry-connrefused \
         --connect-timeout 15 --max-time 1800 \
         -o "${out}.part" "$url" \
        || die "다운로드 실패: $url"
    mv "${out}.part" "$out"
    ok "$(basename "$out") ($(du -h "$out" | cut -f1))"
}

# 번들 디렉터리 전체의 sha256 매니페스트를 만든다.
# 경로를 번들 루트 기준 상대경로로 기록해야 타깃에서 검증이 성립한다.
write_manifest() {
    local bundle_dir="$1" manifest="${1}/SHA256SUMS"
    log "체크섬 매니페스트 생성"
    ( cd "$bundle_dir" \
      && find . -type f ! -name SHA256SUMS ! -name '*.part' -print0 \
         | sort -z \
         | xargs -0 sha256sum > SHA256SUMS )
    ok "SHA256SUMS ($(wc -l < "$manifest") 개 파일)"
}

# 타깃에서 번들 무결성 검증. 전송 중 손상/누락을 설치 전에 잡는다.
verify_manifest() {
    local bundle_dir="$1"
    [[ -f "${bundle_dir}/SHA256SUMS" ]] || die "SHA256SUMS 가 없다: ${bundle_dir}"
    log "번들 무결성 검증 중 ($(wc -l < "${bundle_dir}/SHA256SUMS") 개 파일)"
    ( cd "$bundle_dir" && sha256sum -c --quiet SHA256SUMS ) \
        || die "번들 무결성 검증 실패. 전송이 손상됐다. 다시 복사할 것."
    ok "번들 무결성 검증 통과"
}

#--- 이미지 처리 -------------------------------------------------------
# 이미지 참조에서 파일명으로 쓸 수 있는 문자열을 만든다.
#   quay.io/minio/minio:RELEASE.x -> quay.io_minio_minio_RELEASE.x
image_to_filename() {
    echo "$1" | tr '/:' '__'
}

# containerd(k8s.io 네임스페이스)로 이미지 tar 를 적재한다.
# kubelet 이 보는 네임스페이스가 k8s.io 이므로 -n k8s.io 가 반드시 필요하다.
# 이것을 빼면 ctr images ls 에는 보이지만 파드는 ImagePullBackOff 가 된다.
ctr_import() {
    local tar="$1"
    require_cmds ctr
    log "containerd 적재(k8s.io): $(basename "$tar")"
    ctr -n k8s.io images import --no-unpack=false "$tar" >/dev/null \
        || die "ctr import 실패: $tar"
}

# images.list 의 태그 중 containerd(k8s.io)에 적재되지 않은 것만 출력한다.
#
# 왜 함수로 빼는가:
#   `ctr -n k8s.io images ls -q | grep -qx "$img"` 형태를 직접 쓰면 안 된다.
#   grep -q 는 첫 일치에서 즉시 종료하고, 그 순간 아직 출력을 쓰고 있던 ctr 이
#   SIGPIPE 로 죽어 종료코드 141 이 된다. 이 파일의 pipefail 때문에 파이프라인
#   전체가 실패로 판정되어, 실제로는 적재된 이미지가 "없음"으로 보고된다.
#   목록 앞쪽 태그에서만 발생하므로 놓치기 쉽다(실측: 50-nfs-csi 7개 중 첫 번째만
#   오탐). 목록을 한 번 변수에 담아 파이프를 없앤다.
ctr_missing_images() {
    local list_file="$1" loaded img
    require_cmds ctr
    loaded="$(ctr -n k8s.io images ls -q 2>/dev/null || true)"
    while read -r img; do
        [[ -n "$img" ]] || continue
        grep -qxF "$img" <<<"$loaded" || echo "$img"
    done < "$list_file"
}

#--- 멱등성 도우미 -----------------------------------------------------
# 파일을 백업하고 교체한다. 내용이 같으면 아무것도 하지 않는다.
install_file() {
    local src="$1" dst="$2" mode="${3:-0644}"
    if [[ -f "$dst" ]] && cmp -s "$src" "$dst"; then
        log "변경 없음: $dst"
        return 0
    fi
    if [[ -f "$dst" ]]; then
        cp -a "$dst" "${dst}.bak.$(date +%Y%m%d-%H%M%S)"
        log "기존 파일 백업: ${dst}.bak.*"
    fi
    install -D -m "$mode" "$src" "$dst"
    ok "설치: $dst"
}

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

#--- 판정 --------------------------------------------------------------
# 검증 결과를 누적해 마지막에 한 번에 보고한다.
# 중간에 죽지 않고 전체 결과를 보여주는 편이 디버깅에 유리하다.
declare -a _CHECKS_PASS=() _CHECKS_FAIL=()

check() {
    local desc="$1"; shift
    if "$@" >/dev/null 2>&1; then
        _CHECKS_PASS+=("$desc"); ok "$desc"
    else
        _CHECKS_FAIL+=("$desc"); echo "${_C_RED}[$(_ts)] FAIL${_C_RST} $desc" >&2
    fi
}

# 조건이 만족될 때까지 기다린다. 기동 직후 판정이 실패하는 것을 막는다.
# kubeadm init 직후에는 static 파드가 아직 API 에 등록되지 않아
# 즉시 판정하면 실패한다(실측). 이럴 때 check 대신 이걸 쓴다.
#   check "설명" retry_until 120 bash -c '...'
retry_until() {
    local timeout="$1"; shift
    local deadline=$((SECONDS + timeout))
    while ((SECONDS < deadline)); do
        "$@" >/dev/null 2>&1 && return 0
        sleep 2
    done
    return 1
}

check_summary() {
    echo
    step "검증 결과: 통과 ${#_CHECKS_PASS[@]} / 실패 ${#_CHECKS_FAIL[@]}"
    if ((${#_CHECKS_FAIL[@]} > 0)); then
        for f in "${_CHECKS_FAIL[@]}"; do echo "  ${_C_RED}FAIL${_C_RST} $f"; done
        return 1
    fi
    ok "전체 통과"
}
