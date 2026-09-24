#!/usr/bin/env bash
#---------------------------------------------------------------------
# 50-nfs-csi : NFS 서버 구성 (infra-01 10.0.0.10 에서 root 로 실행)
#
# 이 스크립트만 NFS "서버" 를 만든다. 각 k8s 노드에는 클라이언트(nfs-common)와
# CSI 드라이버만 들어간다(install.sh).
#
# 이 호스트에는 Harbor 가 이미 운영 중이다. 이 스크립트는 Harbor 를 건드리지 않는다.
# 건드리는 것은 nfs-kernel-server 패키지, /data/nfs 디렉터리, /etc/exports 뿐이다.
#
#   sudo ./setup-nfs-server.sh              # 구성
#   sudo ./setup-nfs-server.sh --check-only # 판정만
#---------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# 번들 안에서 실행될 때와 저장소에서 실행될 때 모두 동작하도록 경로를 둘 다 본다.
if [[ -f "${SCRIPT_DIR}/00-common/common.sh" ]]; then
    source "${SCRIPT_DIR}/00-common/common.sh"
else
    source "${SCRIPT_DIR}/../00-common/common.sh"
fi

MODE="setup"
[[ "${1:-}" == "--check-only" ]] && MODE="check"

require_root

# 내보낼 대역. k8s 노드가 있는 VNet 전체를 허용한다.
NFS_ALLOWED_CIDR="${NFS_ALLOWED_CIDR:-${SITE_PRIVATE_CIDR}}"

#---------------------------------------------------------------------
# export 옵션에 대한 판단
#
#   rw                : 읽기/쓰기
#   sync              : 쓰기를 즉시 반영. async 는 빠르지만 서버 장애 시 데이터 손실
#   no_subtree_check  : 서브트리 검사 비활성(성능, NFS 권장)
#   no_root_squash    : 컨테이너가 root 로 쓰기 때문에 필요.
#                       이게 없으면 root 쓰기가 nobody 로 매핑돼 권한 오류가 난다
#   insecure          : 비특권 포트(>1024)에서 오는 마운트를 허용.
#
# insecure 를 넣는 이유가 중요하다. 이것이 없으면 클라이언트가 noresvport 로
# 마운트할 때 서버가 거부해 "mount.nfs: Operation not permitted" (exit 32) 가 되고
# PVC 가 Pending 에서 멈춘다. 기존 운영 클러스터에서 실제로 겪은 문제다.
# 대안은 StorageClass 에서 noresvport 를 빼는 것인데(그쪽을 기본으로 한다),
# 서버에도 insecure 를 둬서 양쪽 모두 안전하게 만든다.
#---------------------------------------------------------------------
EXPORT_OPTS="rw,sync,no_subtree_check,no_root_squash,insecure"

run_checks() {
    step "NFS 서버 판정"

    check "nfs-kernel-server 설치됨"  dpkg -s nfs-kernel-server
    check "nfs-server 서비스 active"  systemctl is-active --quiet nfs-server
    check "nfs-server 부팅 자동기동"   systemctl is-enabled --quiet nfs-server
    check "${NFS_EXPORT_PATH} 존재"    test -d "$NFS_EXPORT_PATH"
    check "/etc/exports 에 항목 있음"  grep -q "^${NFS_EXPORT_PATH}[[:space:]]" /etc/exports
    check "exportfs 에 노출됨"         bash -c "exportfs -v | grep -q '${NFS_EXPORT_PATH}'"
    check "insecure 옵션 적용됨"       bash -c "exportfs -v | grep -A1 '${NFS_EXPORT_PATH}' | grep -q insecure"
    check "no_root_squash 적용됨"      bash -c "exportfs -v | grep -A1 '${NFS_EXPORT_PATH}' | grep -q no_root_squash"
    check "2049 수신(TCP)"             bash -c "ss -lntp | grep -q ':2049'"
    check "111 수신(rpcbind)"          bash -c "ss -lnt | grep -q ':111'"

    # 자기 자신을 마운트해 실제 읽기/쓰기가 되는지 본다. 설정만 보는 것보다 확실하다.
    #
    # 주의: 127.0.0.1 로 마운트하면 안 된다. export 가 ${NFS_ALLOWED_CIDR} 로
    # 제한돼 있고 루프백 주소는 그 대역에 없어서 서버가 접근을 거부한다
    # (mount.nfs4: access denied by server). 반드시 자기 사설 IP 를 쓴다.
    check "로컬 마운트 + 쓰기 테스트 (${NFS_SERVER_HOST})" bash -c '
        m=$(mktemp -d)
        mount -t nfs4 -o nfsvers=4.1 '"${NFS_SERVER_HOST}:${NFS_EXPORT_PATH}"' "$m" 2>/dev/null || { rmdir "$m"; exit 1; }
        echo ok > "$m/.write-test" 2>/dev/null
        rc=$?
        rm -f "$m/.write-test" 2>/dev/null
        umount "$m" 2>/dev/null; rmdir "$m"
        exit $rc'

    echo
    log "현재 export 목록:"
    exportfs -v | sed 's/^/    /'

    check_summary
}

if [[ "$MODE" == "check" ]]; then run_checks; exit $?; fi

#=====================================================================
step "NFS 서버 구성 (${NFS_EXPORT_PATH} -> ${NFS_ALLOWED_CIDR})"

# Harbor 를 건드리지 않음을 명시적으로 확인한다.
if docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^harbor-core$'; then
    log "Harbor 가 가동 중이다. 이 스크립트는 Harbor 를 변경하지 않는다."
fi

#--- 1. 패키지 --------------------------------------------------------
if ! dpkg -s nfs-kernel-server >/dev/null 2>&1; then
    step "nfs-kernel-server 설치"
    # 이 호스트는 온라인이다. 오프라인 노드용 deb 는 10-k8s 번들에 포함돼 있다.
    is_online || die "이 호스트에 인터넷이 필요하다(nfs-kernel-server 설치)."
    DEBIAN_FRONTEND=noninteractive apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -o DPkg::Lock::Timeout=900 nfs-kernel-server
    ok "nfs-kernel-server 설치 완료"
else
    ok "nfs-kernel-server 이미 설치됨"
fi

#--- 2. export 디렉터리 -----------------------------------------------
step "export 디렉터리 준비"
mkdir -p "$NFS_EXPORT_PATH"
# 0777 은 넓다. 워크로드의 fsGroup 이 정해지면 좁힐 것을 권한다.
# CSI 프로비저너가 하위 디렉터리를 만들고 파드가 임의 UID 로 쓰기 때문에
# 초기 구성에서는 0777 로 둔다.
chmod 0777 "$NFS_EXPORT_PATH"
ok "$(ls -ld "$NFS_EXPORT_PATH")"

#--- 3. /etc/exports --------------------------------------------------
step "/etc/exports 설정"
EXPORT_LINE="${NFS_EXPORT_PATH} ${NFS_ALLOWED_CIDR}(${EXPORT_OPTS})"

if [[ -f /etc/exports ]] && grep -q "^${NFS_EXPORT_PATH}[[:space:]]" /etc/exports; then
    CURRENT="$(grep "^${NFS_EXPORT_PATH}[[:space:]]" /etc/exports)"
    if [[ "$CURRENT" == "$EXPORT_LINE" ]]; then
        ok "이미 동일하게 설정됨"
    else
        cp -a /etc/exports "/etc/exports.bak.$(date +%Y%m%d-%H%M%S)"
        log "기존 항목 교체 (백업: /etc/exports.bak.*)"
        log "  이전: ${CURRENT}"
        sed -i "s@^${NFS_EXPORT_PATH}[[:space:]].*@${EXPORT_LINE}@" /etc/exports
        ok "  이후: ${EXPORT_LINE}"
    fi
else
    [[ -f /etc/exports ]] && cp -a /etc/exports "/etc/exports.bak.$(date +%Y%m%d-%H%M%S)"
    echo "$EXPORT_LINE" >> /etc/exports
    ok "항목 추가: ${EXPORT_LINE}"
fi

#--- 4. 서비스 --------------------------------------------------------
step "서비스 기동"
systemctl enable --now rpcbind >/dev/null 2>&1 || true
systemctl enable --now nfs-server >/dev/null
exportfs -ra
systemctl restart nfs-server
retry_until 30 systemctl is-active --quiet nfs-server \
    || die "nfs-server 가 기동되지 않았다: journalctl -u nfs-server"
ok "nfs-server 기동"

#=====================================================================
run_checks
rc=$?

step "다음 단계"
echo "  각 k8s 노드에서 50-nfs-csi 번들의 install.sh 를 실행한다."
echo "  노드에서 도달 확인:  showmount -e ${NFS_SERVER_HOST}"
exit $rc
