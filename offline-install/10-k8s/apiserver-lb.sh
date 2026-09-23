#!/usr/bin/env bash
#---------------------------------------------------------------------
# 10-k8s : apiserver 로드밸런서 (다중 control plane 용)
#
# 다중 CP 는 안정적인 단일 엔드포인트(controlPlaneEndpoint)를 전제로 한다.
# 사내에 이미 LB(F5, NSX-ALB, 클라우드 LB 등)가 있으면 그것을 쓰는 편이 낫다.
# 없을 때 haproxy 컨테이너로 같은 역할을 세우는 것이 이 스크립트다.
#
#   sudo ./apiserver-lb.sh --backends 10.0.0.11,10.0.0.12,10.0.0.13
#   sudo ./apiserver-lb.sh --backends ... --image-tar /path/haproxy.tar
#   sudo ./apiserver-lb.sh --check-only
#   sudo ./apiserver-lb.sh --uninstall
#
# 옵션:
#   --backends a,b,c   CP 노드 IP 목록 (필수). 포트를 생략하면 6443
#   --port N           LB 가 받을 포트 (기본 6443)
#   --image-tar PATH   haproxy 이미지 tar. 40-haproxy 번들의 것을 쓴다
#
# 이 호스트에 두면 안 되는 경우:
#   CP 노드 자신에 6443 으로 두는 것은 불가능하다(apiserver 가 점유). 다른
#   포트로는 가능하지만 그 CP 가 죽으면 LB 도 같이 죽어 HA 의미가 줄어든다.
#   전용 호스트 또는 최소한 CP 가 아닌 노드를 쓸 것.
#
# 이 LB 자체의 이중화:
#   이 스크립트는 LB 한 대를 세운다. LB 가 단일 장애점이 되는 것을 막으려면
#   keepalived 로 VIP 를 두 대에 띄우고 각 대에서 이 스크립트를 실행한다.
#   근거와 절차는 README 4.2절.
#---------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# 번들 안에서는 00-common 이 같은 트리에 있고, 저장소에서는 상위에 있다.
if [[ -f "${SCRIPT_DIR}/00-common/common.sh" ]]; then
    source "${SCRIPT_DIR}/00-common/common.sh"
else
    source "${SCRIPT_DIR}/../00-common/common.sh"
fi

MODE="install"
BACKENDS=""
LB_PORT="6443"
IMAGE_TAR=""
CONTAINER="k8s-apiserver-lb"
CFG_DIR="/etc/haproxy-apiserver"

while (($#)); do
    case "$1" in
        --backends)   BACKENDS="${2:?--backends 에 값이 없다}"; shift ;;
        --port)       LB_PORT="${2:?--port 에 값이 없다}"; shift ;;
        --image-tar)  IMAGE_TAR="${2:?--image-tar 에 값이 없다}"; shift ;;
        --check-only) MODE="check" ;;
        --uninstall)  MODE="uninstall" ;;
        -h|--help)    sed -n '3,30p' "${BASH_SOURCE[0]}" | sed 's/^#//'; exit 0 ;;
        *)            die "알 수 없는 인자: $1" ;;
    esac
    shift
done

require_root
HAPROXY_IMG="${HAPROXY_IMAGE:-haproxy:3.4.4}"

#=====================================================================
# 판정
#=====================================================================
run_checks() {
    step "apiserver LB 판정"

    check "컨테이너 실행 중" bash -c "
        [[ \$(docker inspect -f '{{.State.Running}}' '$CONTAINER' 2>/dev/null) == true ]]"
    check "재시작 정책 unless-stopped" bash -c "
        [[ \$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' '$CONTAINER' 2>/dev/null) == unless-stopped ]]"
    check "${LB_PORT} 리스닝" bash -c "ss -lnt | grep -q ':${LB_PORT} '"

    # 설정이 문법적으로 맞는지 haproxy 자신에게 물어본다.
    check "haproxy 설정 유효" bash -c "
        docker exec '$CONTAINER' haproxy -c -f /usr/local/etc/haproxy/haproxy.cfg >/dev/null 2>&1"

    # 백엔드가 실제로 응답하는지. LB 가 떠 있어도 뒤가 죽어 있으면 의미가 없다.
    local up=0 total=0 b host port
    if [[ -f "${CFG_DIR}/backends" ]]; then
        while read -r b; do
            [[ -n "$b" ]] || continue
            total=$((total+1))
            host="${b%:*}"; port="${b##*:}"
            if timeout 5 bash -c ">/dev/tcp/${host}/${port}" 2>/dev/null; then
                up=$((up+1)); ok "  백엔드 ${b} 응답"
            else
                warn "  백엔드 ${b} 무응답"
            fi
        done < "${CFG_DIR}/backends"
    fi
    check "백엔드 최소 1대 응답(${up}/${total})" bash -c "[[ ${up} -ge 1 ]]"

    # LB 를 통해 apiserver 의 /healthz 가 오는지. 이것이 최종 판정이다.
    # 아직 클러스터가 없으면 실패가 정상이므로 정보로만 낸다.
    local hz
    hz="$(timeout 10 curl -sk "https://127.0.0.1:${LB_PORT}/healthz" 2>/dev/null || true)"
    if [[ "$hz" == "ok" ]]; then
        ok "LB 경유 apiserver /healthz = ok"
    else
        warn "LB 경유 /healthz 응답이 ok 가 아니다: ${hz:-무응답}"
        log  "  아직 kubeadm init 을 하지 않았다면 정상이다."
    fi

    # 정족수 관점 안내. 판정이 아니라 정보다.
    if (( total > 0 && total % 2 == 0 )); then
        warn "백엔드(CP) 수가 짝수(${total})다. etcd 정족수는 과반이라 홀수를 권장한다."
    fi

    check_summary
}

#=====================================================================
# 제거
#=====================================================================
if [[ "$MODE" == "uninstall" ]]; then
    step "apiserver LB 제거"
    docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
    rm -rf "$CFG_DIR"
    ok "제거 완료"
    warn "이 LB 가 controlPlaneEndpoint 였다면 클러스터가 접속 불가가 된다."
    exit 0
fi

if [[ "$MODE" == "check" ]]; then
    run_checks
    exit $?
fi

#=====================================================================
# 설치
#=====================================================================
[[ -n "$BACKENDS" ]] || die "--backends 로 CP 노드 IP 를 지정할 것 (쉼표 구분)"
require_cmds docker

step "apiserver LB 구성"

#--- 이미지 준비 -------------------------------------------------------
# 에어갭이므로 pull 하지 않는다. 이미 적재돼 있거나 tar 를 받아야 한다.
if docker image inspect "$HAPROXY_IMG" >/dev/null 2>&1; then
    ok "haproxy 이미지 존재: ${HAPROXY_IMG}"
elif [[ -n "$IMAGE_TAR" && -f "$IMAGE_TAR" ]]; then
    docker load -i "$IMAGE_TAR" >/dev/null || die "이미지 적재 실패: ${IMAGE_TAR}"
    ok "haproxy 이미지 적재: ${IMAGE_TAR}"
else
    die "$(cat <<MSG
haproxy 이미지(${HAPROXY_IMG})가 없다. 에어갭이므로 pull 하지 않는다.

40-haproxy 번들의 이미지 tar 를 넘길 것:
  sudo ./apiserver-lb.sh --backends ... --image-tar <40-haproxy번들>/images/haproxy_*.tar
MSG
)"
fi

#--- 백엔드 목록 정규화 ------------------------------------------------
install -d -m 0755 "$CFG_DIR"
: > "${CFG_DIR}/backends"
IFS=',' read -ra _bl <<<"$BACKENDS"
for b in "${_bl[@]}"; do
    b="$(echo "$b" | tr -d '[:space:]')"
    [[ -n "$b" ]] || continue
    [[ "$b" == *:* ]] || b="${b}:6443"
    echo "$b" >> "${CFG_DIR}/backends"
done
BACKEND_N="$(grep -c . "${CFG_DIR}/backends")"
(( BACKEND_N > 0 )) || die "유효한 백엔드가 없다: ${BACKENDS}"
log "백엔드 ${BACKEND_N}대: $(tr '\n' ' ' < "${CFG_DIR}/backends")"

#--- haproxy.cfg ------------------------------------------------------
# apiserver 는 TLS 를 자기가 종료해야 한다(클라이언트 인증서로 사용자를
# 식별하기 때문). 그래서 L7 이 아니라 **mode tcp** 로 그대로 넘긴다.
# 여기서 TLS 를 끊으면 kubectl 의 클라이언트 인증서가 apiserver 에 도달하지
# 못해 모든 요청이 anonymous 가 된다.
{
    cat <<EOF
#---------------------------------------------------------------------
# apiserver LB — apiserver-lb.sh 가 생성했다. 직접 고치지 말 것.
#---------------------------------------------------------------------
global
    log stdout format raw local0
    # 기본 maxconn 은 여유가 있지만, watch 연결이 많은 클러스터에서는
    # 커넥션이 오래 살아 있으므로 넉넉히 둔다.
    maxconn 16384

defaults
    log     global
    mode    tcp
    option  tcplog
    # apiserver 의 watch 는 장시간 유지되는 연결이다. 기본 타임아웃으로는
    # 정상 연결이 끊겨 컨트롤러가 반복 재접속한다.
    timeout connect 10s
    timeout client  4h
    timeout server  4h
    retries 2

frontend k8s-apiserver
    bind *:${LB_PORT}
    default_backend k8s-controlplane

backend k8s-controlplane
    # TLS 를 종료하지 않는다(mode tcp). 클라이언트 인증서가 apiserver 까지
    # 그대로 가야 사용자 식별이 된다.
    balance roundrobin
    # /healthz 로 살아있음을 판단한다. TCP 연결만 보면 apiserver 가
    # 기동 중(아직 요청을 못 받는 상태)인 것을 정상으로 오판한다.
    option httpchk GET /healthz
    http-check expect status 200
    default-server check check-ssl verify none inter 3s fall 3 rise 2
EOF
    i=0
    while read -r b; do
        [[ -n "$b" ]] || continue
        i=$((i+1))
        echo "    server cp${i} ${b}"
    done < "${CFG_DIR}/backends"
} > "${CFG_DIR}/haproxy.cfg"
ok "${CFG_DIR}/haproxy.cfg"

#--- 기동 -------------------------------------------------------------
docker rm -f "$CONTAINER" >/dev/null 2>&1 || true

# --user root 가 필요하다. 공식 이미지는 Config.User=haproxy 이고 그 상태로는
# 1024 미만 포트를 바인드할 수 없다(40-haproxy 에서 실측한 것과 같은 문제).
# --cap-add NET_BIND_SERVICE 만으로는 안 된다 — ambient capability 가 아니다.
docker run -d --name "$CONTAINER" \
    --restart unless-stopped \
    --network host \
    --user root \
    -v "${CFG_DIR}/haproxy.cfg:/usr/local/etc/haproxy/haproxy.cfg:ro" \
    "$HAPROXY_IMG" \
    >/dev/null || die "haproxy 기동 실패"
ok "컨테이너 ${CONTAINER} 기동"

# 설정 오류로 즉시 죽는 경우를 잡는다. 기동 직후의 Running 만 보면
# 크래시 루프를 통과시킨다.
sleep 3
retry_until 30 bash -c "ss -lnt | grep -q ':${LB_PORT} '" \
    || die "${LB_PORT} 리스닝이 확인되지 않는다. docker logs ${CONTAINER} 확인."

echo
run_checks
rc=$?

step "다음 단계"
echo "  이 주소를 첫 CP 의 controlPlaneEndpoint 로 쓴다:"
echo "    sudo ./install.sh --control-plane-endpoint $(hostname -I | awk '{print $1}'):${LB_PORT}"
echo
echo "  백엔드를 바꾸려면 --backends 로 다시 실행하면 된다(컨테이너 재생성)."
echo "  LB 자체를 이중화하려면 keepalived VIP 를 쓴다 — README 4.2절."
exit $rc
