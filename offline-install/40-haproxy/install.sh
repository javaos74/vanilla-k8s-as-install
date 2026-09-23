#!/usr/bin/env bash
#---------------------------------------------------------------------
# 40-haproxy : 오프라인 설치 (노드에서 root 로 실행)
#
#   sudo ./install.sh                 # 설치
#   sudo ./install.sh --check-only    # 판정만
#   sudo ./install.sh --test-restart  # 강제 종료 후 자동 복구 실동작 검증
#   sudo ./install.sh --uninstall     # 제거
#
# 전제: 10-k8s 설치 완료(docker 포함).
#
# ingress gateway 가 아직 없어도 설치된다. 그 경우 백엔드는 DOWN 으로 보이며
# 이것이 정상이다(게이트웨이는 UiPath AS 설치 시 들어온다).
#---------------------------------------------------------------------
BUNDLE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${BUNDLE_ROOT}/00-common/common.sh"

MODE="install"
case "${1:-}" in
    --check-only)   MODE="check" ;;
    --test-restart) MODE="restart-test" ;;
    --uninstall)    MODE="uninstall" ;;
    "")             MODE="install" ;;
    *)              die "알 수 없는 인자: $1" ;;
esac

require_root

CONF_DIR="${BUNDLE_ROOT}/conf"
IMG_DIR="${BUNDLE_ROOT}/images"
CONTAINER="l4"
HOST_CFG_DIR="/etc/haproxy-l4"
HOST_CFG="${HOST_CFG_DIR}/haproxy.cfg"

# ingress gateway NodePort 기본값. 서비스가 있으면 자동 탐지가 이 값을 덮어쓴다.
DEFAULT_NP_HTTP=31223
DEFAULT_NP_HTTPS=31164
DEFAULT_NP_STATUS=31956

#=====================================================================
# 판정
#=====================================================================
run_checks() {
    step "설치 상태 판정"

    check "docker 사용 가능"            docker info
    check "haproxy 이미지 적재됨"        bash -c "docker image inspect '${HAPROXY_IMAGE}' >/dev/null 2>&1"
    check "설정 파일 존재"               test -f "$HOST_CFG"

    # 설정 문법 검사. 컨테이너를 띄우기 전에 잡는 편이 빠르다.
    check "haproxy 설정 문법 유효(-c)" bash -c "
        docker run --rm -v '${HOST_CFG}':/usr/local/etc/haproxy/haproxy.cfg:ro \
            '${HAPROXY_IMAGE}' haproxy -c -f /usr/local/etc/haproxy/haproxy.cfg >/dev/null 2>&1"

    # 단순히 .State.Running 만 보면 안 된다. 바인드 실패로 크래시 루프에 빠진
    # 컨테이너도 재시작하는 순간에는 true 로 보인다(실측: 80/443 Permission denied
    # 상태에서 "실행 중" 판정이 통과했다). PID 가 10초간 유지되는지까지 본다.
    check "컨테이너 ${CONTAINER} 실행 중(크래시 루프 아님)" bash -c "
        [[ \$(docker inspect -f '{{.State.Status}}' '${CONTAINER}' 2>/dev/null) == running ]] || exit 1
        p1=\$(docker inspect -f '{{.State.Pid}}' '${CONTAINER}' 2>/dev/null)
        sleep 10
        p2=\$(docker inspect -f '{{.State.Pid}}' '${CONTAINER}' 2>/dev/null)
        [[ -n \"\$p1\" && \"\$p1\" != 0 && \"\$p1\" == \"\$p2\" ]]"

    # 오늘 Harbor 에서 얻은 교훈: 재시작 정책이 없으면 재부팅 후 올라오지 않는다.
    check "재시작 정책 unless-stopped" bash -c "
        [[ \$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' '${CONTAINER}' 2>/dev/null) == unless-stopped ]]"
    check "네트워크 모드 host" bash -c "
        [[ \$(docker inspect -f '{{.HostConfig.NetworkMode}}' '${CONTAINER}' 2>/dev/null) == host ]]"

    for p in 80 443 15021; do
        check "호스트 ${p} 수신" bash -c "ss -lnt | grep -qE ':${p}\b'"
    done

    # host 네트워크이므로 stats 가 호스트 루프백에서 바로 보인다.
    check "stats 응답(127.0.0.1:8404)" retry_until 30 bash -c "
        curl -sf -o /dev/null --max-time 5 http://127.0.0.1:8404/"

    #--- 백엔드 상태는 판정이 아니라 정보로 취급한다 ---
    echo
    if curl -sf --max-time 5 "http://127.0.0.1:8404/;csv" >/dev/null 2>&1; then
        log "백엔드 상태:"
        curl -s --max-time 5 "http://127.0.0.1:8404/;csv" \
          | awk -F, 'NR>1 && $2!="" && $1!="stats" {printf "    %-12s %-8s %s\n", $1, $2, $18}'
    fi

    if kubectl --kubeconfig /etc/kubernetes/admin.conf get svc -n istio-system \
            istio-ingressgateway >/dev/null 2>&1; then
        log "ingress gateway 서비스가 존재한다. 백엔드가 UP 이어야 정상이다."
    else
        log "ingress gateway 서비스가 없다. 백엔드 DOWN 은 정상이다."
        log "  (게이트웨이는 UiPath AS 설치 단계에서 들어온다)"
    fi

    check_summary
}

#=====================================================================
# 재시작 정책 실동작 검증
#=====================================================================
do_restart_test() {
    step "자동 복구 실동작 검증"

    local before after pid
    before="$(docker inspect -f '{{.RestartCount}}' "$CONTAINER" 2>/dev/null)" \
        || die "컨테이너 ${CONTAINER} 가 없다"
    [[ "$(docker inspect -f '{{.State.Status}}' "$CONTAINER")" == running ]] \
        || die "컨테이너가 running 이 아니다. 먼저 install.sh 를 실행할 것."
    log "현재 RestartCount=${before}"

    #--- 1단계: 프로세스 사고사 ---------------------------------------
    # docker kill / docker stop 을 쓰면 안 된다.
    #   두 명령은 "사용자가 의도적으로 멈춤"으로 기록되고(HasBeenManuallyStopped),
    #   unless-stopped 정책은 그 경우 재시작하지 않는다. 실측으로 확인했다:
    #   docker kill 후 60초간 RestartCount 가 0 에서 변하지 않았고, docker 데몬을
    #   재시작해도 exited 로 남았다. 정책이 잘못된 것이 아니라 시험 방법이 틀린 것이다.
    # 프로세스가 죽는 상황을 재현하려면 호스트에서 컨테이너 PID 를 직접 죽인다.
    pid="$(docker inspect -f '{{.State.Pid}}' "$CONTAINER")"
    [[ -n "$pid" && "$pid" != "0" ]] || die "컨테이너 PID 를 확인할 수 없다"
    log "호스트에서 컨테이너 PID ${pid} 에 SIGKILL"
    kill -9 "$pid" || die "kill 실패"

    if retry_until 60 bash -c "[[ \$(docker inspect -f '{{.State.Status}}' '${CONTAINER}' 2>/dev/null) == running ]]"; then
        after="$(docker inspect -f '{{.RestartCount}}' "$CONTAINER")"
        [[ "$after" != "$before" ]] \
            || die "상태는 running 이지만 RestartCount 가 늘지 않았다(${before}). 재확인 필요."
        ok "프로세스 사고사 후 자동 복구 (RestartCount ${before} -> ${after})"
    else
        die "자동 복구되지 않았다. 재시작 정책을 확인할 것."
    fi

    retry_until 45 bash -c "curl -sf -o /dev/null --max-time 5 http://127.0.0.1:8404/" \
        && ok "복구 후 stats 응답 정상" \
        || die "복구됐지만 stats 가 응답하지 않는다"

    #--- 2단계: docker 데몬 재시작 (노드 재부팅 대리 검증) -------------
    # 재부팅 검증을 실제 reboot 없이 하는 방법이다. unless-stopped 는 데몬이
    # 다시 떴을 때 컨테이너를 복구해야 한다. 이 단계가 통과하면 재부팅 후에도
    # l4 가 올라온다고 볼 수 있다.
    step "docker 데몬 재시작 후 복구 (재부팅 대리 검증)"
    systemctl restart docker || die "docker 데몬 재시작 실패"
    if retry_until 90 bash -c "[[ \$(docker inspect -f '{{.State.Status}}' '${CONTAINER}' 2>/dev/null) == running ]]"; then
        ok "데몬 재시작 후 ${CONTAINER} 복구됨"
    else
        die "데몬 재시작 후 ${CONTAINER} 가 올라오지 않았다. 재부팅 후에도 올라오지 않는다."
    fi
    retry_until 60 bash -c "curl -sf -o /dev/null --max-time 5 http://127.0.0.1:8404/" \
        && ok "데몬 재시작 후 stats 응답 정상" \
        || die "복구됐지만 stats 가 응답하지 않는다"

    for p in 80 443 15021; do
        retry_until 30 bash -c "ss -lnt | grep -qE ':${p}\b'" \
            && ok "호스트 ${p} 재수신" || die "포트 ${p} 가 다시 열리지 않았다"
    done
    exit 0
}

do_uninstall() {
    step "제거"
    docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
    ok "컨테이너 제거. 설정(${HOST_CFG_DIR})은 남겨둔다."
    exit 0
}

[[ "$MODE" == "uninstall" ]]    && do_uninstall
[[ "$MODE" == "restart-test" ]] && do_restart_test
if [[ "$MODE" == "check" ]]; then run_checks; exit $?; fi

#=====================================================================
# 0. 사전 확인
#=====================================================================
step "사전 확인"
verify_manifest "$BUNDLE_ROOT"

is_online && warn "인터넷 연결 상태다. 오프라인 검증이라면 airgap-on.sh 를 먼저 실행할 것." \
          || ok "인터넷 차단 상태 (에어갭 검증 조건 충족)"

require_cmds docker
docker info >/dev/null 2>&1 || die "docker 가 동작하지 않는다. 10-k8s 설치를 확인할 것."

# 호스트 80/443 을 다른 프로세스가 이미 쓰고 있으면 바인드에 실패한다.
for p in 80 443 15021; do
    if ss -lntp | grep -qE ":${p}\b"; then
        holder="$(ss -lntp | grep -E ":${p}\b" | head -1)"
        if ! docker inspect -f '{{.State.Running}}' "$CONTAINER" >/dev/null 2>&1; then
            die "포트 ${p} 를 이미 다른 프로세스가 쓰고 있다: ${holder}"
        fi
    fi
done
ok "포트 80/443/15021 사용 가능"

#=====================================================================
# 1. 이미지 적재
#=====================================================================
step "이미지 적재 (docker)"
# k8s 워크로드가 아니라 docker 로 돌리므로 ctr 이 아니라 docker load 를 쓴다.
IMG_TAR="$(ls "${IMG_DIR}"/*.tar 2>/dev/null | head -1)"
[[ -n "$IMG_TAR" ]] || die "이미지 tar 를 찾지 못했다"
if docker image inspect "$HAPROXY_IMAGE" >/dev/null 2>&1; then
    ok "이미지 이미 존재: ${HAPROXY_IMAGE}"
else
    docker load -i "$IMG_TAR" >/dev/null || die "docker load 실패"
    docker image inspect "$HAPROXY_IMAGE" >/dev/null 2>&1 \
        || die "적재 후에도 ${HAPROXY_IMAGE} 를 찾을 수 없다"
    ok "이미지 적재: ${HAPROXY_IMAGE}"
fi

#=====================================================================
# 2. NodePort 자동 탐지 + 설정 생성
#=====================================================================
step "설정 생성"

NP_HTTP="$DEFAULT_NP_HTTP"; NP_HTTPS="$DEFAULT_NP_HTTPS"; NP_STATUS="$DEFAULT_NP_STATUS"

KC=/etc/kubernetes/admin.conf
if [[ -f "$KC" ]] && kubectl --kubeconfig "$KC" get svc -n istio-system istio-ingressgateway >/dev/null 2>&1; then
    # 실제 서비스가 있으면 그 값을 쓴다. 고정값을 쓰다 어긋나는 것을 막는다.
    get_np() {
        kubectl --kubeconfig "$KC" -n istio-system get svc istio-ingressgateway \
            -o jsonpath="{.spec.ports[?(@.name=='$1')].nodePort}" 2>/dev/null
    }
    v="$(get_np http2)";  [[ -n "$v" ]] && NP_HTTP="$v"
    v="$(get_np https)";  [[ -n "$v" ]] && NP_HTTPS="$v"
    v="$(get_np status-port)"; [[ -n "$v" ]] && NP_STATUS="$v"
    ok "ingress gateway NodePort 자동 탐지: http=${NP_HTTP} https=${NP_HTTPS} status=${NP_STATUS}"
else
    warn "ingress gateway 서비스가 없다. 기본값을 사용한다: http=${NP_HTTP} https=${NP_HTTPS} status=${NP_STATUS}"
    warn "게이트웨이 설치 후 이 스크립트를 다시 실행하면 실제 값으로 갱신된다."
fi

# host 네트워크이므로 백엔드는 루프백으로 충분하다. NAT 를 한 번 덜 지난다.
BACKEND_IP="127.0.0.1"

mkdir -p "$HOST_CFG_DIR"
sed -e "s/__NP_HTTP__/${NP_HTTP}/g" \
    -e "s/__NP_HTTPS__/${NP_HTTPS}/g" \
    -e "s/__NP_STATUS__/${NP_STATUS}/g" \
    -e "s/__BACKEND_IP__/${BACKEND_IP}/g" \
    "${CONF_DIR}/haproxy.cfg.tmpl" > "${HOST_CFG}.new"

# 적용 전에 문법을 검사한다. 잘못된 설정으로 컨테이너를 재생성하면
# 서비스가 내려간 채로 올라오지 않는다.
docker run --rm -v "${HOST_CFG}.new":/tmp/haproxy.cfg:ro "$HAPROXY_IMAGE" \
    haproxy -c -f /tmp/haproxy.cfg >/dev/null 2>&1 \
    || { docker run --rm -v "${HOST_CFG}.new":/tmp/haproxy.cfg:ro "$HAPROXY_IMAGE" \
             haproxy -c -f /tmp/haproxy.cfg; die "생성된 설정이 문법 오류다"; }
ok "설정 문법 검사 통과"

install_file "${HOST_CFG}.new" "$HOST_CFG" 0644
rm -f "${HOST_CFG}.new"

#=====================================================================
# 3. 컨테이너 기동
#=====================================================================
step "컨테이너 기동"

# --network host 를 쓰는 이유:
#   1) 백엔드가 같은 노드의 NodePort 다. bridge 면 docker0 게이트웨이를 거쳐
#      NAT 를 한 번 더 지나고, 루프백 백엔드를 쓸 수 없다.
#   2) stats(127.0.0.1:8404)가 호스트에서 바로 보인다. bridge 면 컨테이너
#      네임스페이스 안에만 열려 docker exec 없이는 확인할 수 없다.
# 대가로 80/443/15021 을 호스트에서 직접 점유한다. 이것이 의도한 동작이다.
#
# --user root 가 반드시 필요하다:
#   haproxy 공식 이미지는 Config.User=haproxy 로 비특권 사용자로 기동한다.
#   그 상태에서는 80/443 바인드가 Permission denied 로 실패하고 컨테이너가
#   Restarting 루프에 빠진다(실측: haproxy 3.4.4).
#   --cap-add NET_BIND_SERVICE 로는 해결되지 않는다. docker 는 ambient capability
#   를 설정하지 않으므로, 파일 capability 가 없는 바이너리를 비root 로 실행하면
#   permitted 집합에 있어도 effective 가 되지 않는다.
#   root 로 기동하면 마스터가 특권 포트를 바인드한 뒤 설정의 `user haproxy` /
#   `group haproxy` 지시자에 따라 워커가 권한을 내려놓는다. 이것이 haproxy 의
#   표준 동작이다.
#
# --restart unless-stopped 를 반드시 준다. 없으면 노드 재부팅 후 올라오지 않는다.
if docker inspect "$CONTAINER" >/dev/null 2>&1; then
    log "기존 컨테이너 제거 후 재생성(설정·정책 반영)"
    docker rm -f "$CONTAINER" >/dev/null
fi

docker run -d --name "$CONTAINER" \
    --restart unless-stopped \
    --network host \
    --user root \
    -v "${HOST_CFG}":/usr/local/etc/haproxy/haproxy.cfg:ro \
    "$HAPROXY_IMAGE" >/dev/null \
    || die "컨테이너 기동 실패"

# 기동 확인은 상태 플래그가 아니라 실제 응답으로 한다. 바인드 실패는
# Running=true 로 잠깐 보였다가 종료되는 형태로 나타나므로 플래그로는 놓친다.
if ! retry_until 45 bash -c "curl -sf -o /dev/null --max-time 3 http://127.0.0.1:8404/"; then
    docker logs --tail 20 "$CONTAINER" >&2 || true
    die "컨테이너가 정상 기동하지 않았다(stats 8404 무응답). 위 로그를 확인할 것."
fi
ok "컨테이너 ${CONTAINER} 기동 및 stats 응답 확인"

#=====================================================================
# 4. 판정
#=====================================================================
run_checks
rc=$?

step "다음 단계"
echo "  설정 변경 후 무중단 반영:  sudo docker kill -s HUP ${CONTAINER}"
echo "  자동 복구 검증:            sudo ./install.sh --test-restart"
echo "  백엔드 상태:               curl -s 'http://127.0.0.1:8404/;csv'"
echo
echo "  다음: 30-harbor -> 20-minio"
exit $rc
