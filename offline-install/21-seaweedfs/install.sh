#!/usr/bin/env bash
#---------------------------------------------------------------------
# 21-seaweedfs : 오프라인 설치 (에어갭 노드에서 root 로 실행)
#
#   sudo ./install.sh                  # 설치 + S3 왕복 검증
#   sudo ./install.sh --check-only     # 판정만
#   sudo ./install.sh --test-restart   # 자동 복구 실동작 검증
#   sudo ./install.sh --uninstall      # 컨테이너 제거(데이터는 남긴다)
#
# 전제: 10-k8s 설치 완료(docker + docker compose).
#       05-certs 로 weed 인증서를 배치했으면(/opt/pki/weed) 그것을 쓴다.
#
# 결과: /opt/weed 에 SeaweedFS(weed server: master+volume+filer+S3). S3 는 TLS 전용.
#       데이터는 호스트 WEED_DATA_DIR(기본 /data/weed) -> 컨테이너 /data.
# 포트: S3 API 는 호스트 SEAWEEDFS_S3_PORT(기본 8333) -> 컨테이너 8333.
#       master(9333) / volume(8080) / filer(8888) 는 컨테이너 루프백 전용이다(README 4절).
#
# 자격증명은 site.env 의 WEED_ROOT_USER / WEED_ROOT_PASSWORD 를 쓴다.
# 비밀번호가 비어 있으면 무작위 생성해 /opt/weed/weed.env(0600)에 저장하고 출력한다.
#
# 이 스크립트는 실제 서버에서 아직 실행하지 않았다. 정적 검사만 했다(README 7절).
#---------------------------------------------------------------------
BUNDLE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${BUNDLE_ROOT}/00-common/common.sh"

MODE="install"
case "${1:-}" in
    --check-only)   MODE="check" ;;
    --test-restart) MODE="restart-test" ;;
    --uninstall)    MODE="uninstall" ;;
    "")             MODE="install" ;;
    *)              die "알 수 없는 인자: $1 (--check-only | --test-restart | --uninstall)" ;;
esac

require_root

CONF_DIR="${BUNDLE_ROOT}/conf"
IMG_DIR="${BUNDLE_ROOT}/images"

WEED_DIR="/opt/weed"
WEED_DATA_DIR="${WEED_DATA_DIR:-/data/weed}"
COMPOSE_FILE="${WEED_DIR}/docker-compose.yml"
ENV_FILE="${WEED_DIR}/weed.env"
S3_JSON="${WEED_DIR}/s3.json"
CERT_DIR="${WEED_DIR}/certs"
CONTAINER="seaweedfs"

# 접속 이름·주소. site.env 로 덮어쓸 수 있다.
# hostname -d 는 도메인이 없을 때 오류가 아니라 **빈 문자열**을 반환한다.
# 처리하지 않으면 "weed." 처럼 끝에 점만 남는 이름이 만들어진다(20-minio 와 같은 이유).
# ip route 가 실패해도(기본 경로 없음) set -e 로 조용히 죽지 않게 || true 를 붙인다.
_WEED_DOMAIN="$(hostname -d 2>/dev/null || true)"
WEED_HOSTNAME="${WEED_HOSTNAME:-weed${_WEED_DOMAIN:+.${_WEED_DOMAIN}}}"
WEED_HOST_IP="${WEED_HOST_IP:-$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}' || true)}"
[[ -n "$WEED_HOST_IP" ]] || WEED_HOST_IP="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"

# 브라우저 CORS 허용 오리진. site.env 의 WEED_CORS_ORIGINS 를 쓴다.
# 없으면 AS_FQDN 으로 만든다. 둘 다 없으면 아래 검증에서 멈춘다.
# 와일드카드로 조용히 넘어가지 않게 기본값을 '*' 로 두지 않는다.
WEED_CORS_ORIGINS="${WEED_CORS_ORIGINS:-${AS_FQDN:+https://${AS_FQDN}}}"

# 판정에 쓸 버킷 이름. 남더라도 해가 없도록 전용 이름을 쓴다.
SMOKE_BUCKET="weed-smoke-test"
SMOKE_DIR=""

dc() { docker compose -f "$COMPOSE_FILE" "$@"; }

# env 파일의 값 하나. 키가 없으면 빈 문자열(set -e 로 죽지 않는다).
env_get() { grep -E "^$1=" "$ENV_FILE" 2>/dev/null | cut -d= -f2- || true; }

# S3 헬스 엔드포인트. 인증 없이 응답한다. -k: 판정 전 단계라 CA 검증은 따로 본다.
weed_healthz() {
    curl -fsk -o /dev/null --max-time 5 "https://127.0.0.1:${SEAWEEDFS_S3_PORT}/healthz"
}

#=====================================================================
# aws CLI 실행 도우미
#
# 호스트에 aws CLI 를 설치하지 않고 번들의 aws-cli 이미지로 돌린다.
# mc 는 AGPL 이라 쓰지 않는다(README 1절).
# --network host: 서버가 호스트 포트 SEAWEEDFS_S3_PORT 에 있다(20-minio 의 mc 와 같은 방식).
# --add-host: 접속 이름과 가상 호스트 스타일 이름(<버킷>.<이름>)을 127.0.0.1 로 풀어
#   실제 이름으로 SNI·인증서를 검증한다. CA 는 AWS_CA_BUNDLE 로 준다(검증을 끄지 않는다).
# 자격증명은 값 없는 -e 로 넘긴다. docker 가 호출한 셸의 환경에서 값을 읽으므로
# docker run 명령행(ps)에 비밀번호가 남지 않는다.
#
#   aws_run [--virtual] [--secret <값>] <aws 인자...>
#     --virtual : 가상 호스트 스타일 주소(기본은 경로 스타일)
#     --secret  : 비밀번호를 바꿔 보낸다(거부 확인용)
#=====================================================================
smoke_prepare() {
    SMOKE_DIR="$(mktemp -d /tmp/weed-smoke.XXXXXX)"
    printf '[default]\ns3 =\n    addressing_style = path\n'    > "${SMOKE_DIR}/aws-path.cfg"
    printf '[default]\ns3 =\n    addressing_style = virtual\n' > "${SMOKE_DIR}/aws-virtual.cfg"
}

smoke_cleanup() {
    [[ -n "$SMOKE_DIR" ]] || return 0
    aws_run s3 rb --force "s3://${SMOKE_BUCKET}" >/dev/null 2>&1 || true
    rm -rf "$SMOKE_DIR"
    SMOKE_DIR=""
}

aws_run() {
    local style="path" secret
    secret="$(env_get WEED_ROOT_PASSWORD)"
    while (($#)); do
        case "$1" in
            --virtual) style="virtual"; shift ;;
            --secret)  secret="$2"; shift 2 ;;
            *)         break ;;
        esac
    done
    AWS_ACCESS_KEY_ID="$(env_get WEED_ROOT_USER)" AWS_SECRET_ACCESS_KEY="$secret" \
    docker run --rm --network host \
        --add-host "${WEED_HOSTNAME}:127.0.0.1" \
        --add-host "${SMOKE_BUCKET}.${WEED_HOSTNAME}:127.0.0.1" \
        -e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY \
        -e AWS_DEFAULT_REGION="$SEAWEEDFS_REGION" \
        -e AWS_CONFIG_FILE="/work/aws-${style}.cfg" \
        -e AWS_CA_BUNDLE=/certs/ca.crt \
        -e AWS_PAGER= \
        -v "${CERT_DIR}/ca.crt:/certs/ca.crt:ro" \
        -v "${SMOKE_DIR}:/work" \
        "$SEAWEEDFS_CLIENT_IMAGE" \
        --endpoint-url "https://${WEED_HOSTNAME}:${SEAWEEDFS_S3_PORT}" "$@"
}

# 아래는 check 에 직접 넘기기 위한 래퍼다. 출력을 변수에 담은 뒤 grep 한다.
# `aws_run ... | grep -q` 로 쓰면 grep 이 먼저 끝날 때 SIGPIPE 와 pipefail 때문에
# 거짓 실패가 날 수 있다(common.sh 의 ctr_missing_images 설명과 같은 이유).
s3_listed() {   # [--virtual] <객체 이름>
    local out
    if [[ "$1" == "--virtual" ]]; then
        out="$(aws_run --virtual s3 ls "s3://${SMOKE_BUCKET}/" 2>/dev/null)" || return 1
        shift
    else
        out="$(aws_run s3 ls "s3://${SMOKE_BUCKET}/" 2>/dev/null)" || return 1
    fi
    grep -q "$1" <<<"$out"
}

# 내려받은 내용이 올린 원본(SMOKE_DIR/<이름>)과 같은지.
s3_download_matches() {   # <객체 이름>
    rm -f "${SMOKE_DIR}/$1.down"
    aws_run s3 cp "s3://${SMOKE_BUCKET}/$1" "/work/$1.down" >/dev/null 2>&1 || return 1
    [[ "$(sha256sum < "${SMOKE_DIR}/$1")" == "$(sha256sum < "${SMOKE_DIR}/$1.down")" ]]
}

# 거부되어야 하는 요청. 아무 오류가 아니라 인증 오류로 거부됐는지까지 본다.
s3_denied() {   # <aws_run 인자...>
    local out
    if out="$(aws_run "$@" 2>&1)"; then
        return 1
    fi
    grep -qE 'SignatureDoesNotMatch|AccessDenied|InvalidAccessKeyId|Forbidden|403' <<<"$out"
}

# 컨테이너가 S3 포트만 publish 하는지. 내부 포트(9333/8080/8888)는 인증이 없다.
only_s3_published() {
    local out
    out="$(docker port "$CONTAINER" 2>/dev/null)" || return 1
    [[ -n "$out" ]] && ! grep -qv '^8333/tcp ' <<<"$out"
}

# 내부 포트가 컨테이너 밖(컨테이너 IP)에서 닿지 않는지. -ip.bind=127.0.0.1 의 효과다.
internal_ports_closed() {
    local ip p
    ip="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$CONTAINER" 2>/dev/null || true)"
    [[ -n "$ip" ]] || return 1
    for p in 9333 8080 8888; do
        curl -s -o /dev/null --max-time 3 "http://${ip}:${p}/" && return 1
    done
    return 0
}

# 호스트 볼륨에 볼륨 파일(.dat)이 실제로 생겼는지.
data_written() {
    [[ -n "$(find "$WEED_DATA_DIR" -type f -name '*.dat' -size +0 -print -quit 2>/dev/null)" ]]
}

#=====================================================================
# 판정
#=====================================================================
run_checks() {
    step "설치 상태 판정"

    check "docker 사용 가능"         docker info
    check "docker compose 사용 가능"  bash -c "docker compose version >/dev/null 2>&1"

    local img
    while read -r img; do
        [[ -n "$img" ]] || continue
        check "이미지 적재됨: ${img##*/}" \
            bash -c "docker image inspect '$img' >/dev/null 2>&1"
    done < "${CONF_DIR}/images.list"

    check "compose 파일 존재"         test -f "$COMPOSE_FILE"
    check "compose 설정 문법 유효"     bash -c "docker compose -f '$COMPOSE_FILE' config >/dev/null 2>&1"
    check "env 파일 권한 0600"        bash -c "[[ \$(stat -c %a '$ENV_FILE' 2>/dev/null) == 600 ]]"
    check "s3.json 이 uid ${SEAWEEDFS_UID} 소유 · 0600" bash -c "
        [[ \$(stat -c '%u %a' '$S3_JSON' 2>/dev/null) == '${SEAWEEDFS_UID} 600' ]]"
    check "s3.json JSON 유효"          bash -c "python3 -m json.tool '$S3_JSON' >/dev/null 2>&1"
    check "TLS 인증서·키·CA 존재"      bash -c "
        test -s '${CERT_DIR}/weed.crt' -a -s '${CERT_DIR}/weed.key' -a -s '${CERT_DIR}/ca.crt'"
    # 컨테이너는 uid 1000(seaweed)으로 돈다. 키가 root 소유면 읽지 못하고 즉시 종료한다(README 4절).
    check "인증서·키가 uid ${SEAWEEDFS_UID} 소유 · 키 0600" bash -c "
        [[ \$(stat -c %u '${CERT_DIR}/weed.crt' 2>/dev/null) == '${SEAWEEDFS_UID}' ]] &&
        [[ \$(stat -c '%u %a' '${CERT_DIR}/weed.key' 2>/dev/null) == '${SEAWEEDFS_UID} 600' ]]"
    check "인증서가 CA 로 검증됨(체인)" bash -c "
        openssl verify -CAfile '${CERT_DIR}/ca.crt' '${CERT_DIR}/weed.crt' >/dev/null 2>&1"
    check "인증서 SAN 에 ${WEED_HOSTNAME} 포함" bash -c "
        openssl x509 -in '${CERT_DIR}/weed.crt' -noout -text \
          | grep -A1 'Subject Alternative Name' | grep -qF 'DNS:${WEED_HOSTNAME}'"
    # 가상 호스트 스타일(<버킷>.<이름>)에 필요하다(-s3.domainName).
    check "인증서 SAN 에 *.${WEED_HOSTNAME} 포함" bash -c "
        openssl x509 -in '${CERT_DIR}/weed.crt' -noout -text \
          | grep -A1 'Subject Alternative Name' | grep -qF 'DNS:*.${WEED_HOSTNAME}'"
    check "데이터 디렉터리 존재"       test -d "$WEED_DATA_DIR"

    # 크래시 루프를 실행 중으로 오판하지 않도록 PID 유지까지 본다(20-minio 와 같다).
    check "컨테이너 실행 중(크래시 루프 아님)" bash -c "
        [[ \$(docker inspect -f '{{.State.Status}}' '$CONTAINER' 2>/dev/null) == running ]] || exit 1
        p1=\$(docker inspect -f '{{.State.Pid}}' '$CONTAINER' 2>/dev/null)
        sleep 10
        p2=\$(docker inspect -f '{{.State.Pid}}' '$CONTAINER' 2>/dev/null)
        [[ -n \"\$p1\" && \"\$p1\" != 0 && \"\$p1\" == \"\$p2\" ]]"
    check "재시작 정책 unless-stopped" bash -c "
        [[ \$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' '$CONTAINER' 2>/dev/null) == unless-stopped ]]"
    # 정상 종료에 26~27초가 걸린다. 10초(기본)면 SIGKILL 로 끊긴다(README 4절).
    check "stop_grace_period 1m (StopTimeout=60)" bash -c "
        [[ \$(docker inspect -f '{{.Config.StopTimeout}}' '$CONTAINER' 2>/dev/null) == 60 ]]"
    check "healthcheck healthy" retry_until 120 bash -c "
        [[ \$(docker inspect -f '{{.State.Health.Status}}' '$CONTAINER' 2>/dev/null) == healthy ]]"

    #--- 포트 ------------------------------------------------------------
    check "호스트 ${SEAWEEDFS_S3_PORT} 수신" retry_until 60 bash -c "ss -lnt | grep -qE ':${SEAWEEDFS_S3_PORT}\b'"
    check "S3 포트(8333)만 publish"                 only_s3_published
    check "내부 포트(9333/8080/8888)가 컨테이너 밖에서 닿지 않음" internal_ports_closed

    #--- TLS -------------------------------------------------------------
    # -s3.cert.file 을 주면 S3 포트는 HTTPS 전용이다. 평문 요청이 200 이면 TLS 가 꺼진 것이다.
    check "평문 HTTP 거부" bash -c "
        [[ \$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1:${SEAWEEDFS_S3_PORT}/healthz) != 200 ]]"
    check "이름으로 TLS 검증(CA, SNI)" retry_until 30 \
        curl -fsS -o /dev/null --max-time 5 --cacert "${CERT_DIR}/ca.crt" \
            --resolve "${WEED_HOSTNAME}:${SEAWEEDFS_S3_PORT}:127.0.0.1" \
            "https://${WEED_HOSTNAME}:${SEAWEEDFS_S3_PORT}/healthz"
    # SAN 에 노드 IP 가 있을 때만 IP 로도 검증한다. 05-certs 는 WEED_HOST_IP 를 비우면
    # IP 를 넣지 않는다(README 5절). 그때는 이름으로만 검증된다.
    # 파이프로 바로 grep 하지 않는다. awk 가 먼저 끝나면 openssl 이 SIGPIPE 로 죽고
    # pipefail 때문에 일치해도 거짓이 될 수 있다.
    local san
    san="$(cert_san "${CERT_DIR}/weed.crt" || true)"
    # 공백을 지우고 끝에 쉼표를 붙여 "IPAddress:<IP>," 로 비교한다.
    # 10.0.0.2 가 10.0.0.20 에 걸리지 않게 하기 위함이다.
    if [[ -n "$WEED_HOST_IP" ]] \
       && grep -qF "IPAddress:${WEED_HOST_IP}," <<<"${san// /},"; then
        check "IP(${WEED_HOST_IP})로 TLS 검증(SAN IP)" \
            curl -fsS -o /dev/null --max-time 5 --cacert "${CERT_DIR}/ca.crt" \
                "https://${WEED_HOST_IP}:${SEAWEEDFS_S3_PORT}/healthz"
    else
        log "인증서 SAN 에 노드 IP(${WEED_HOST_IP:-미확인})가 없어 IP 검증은 건너뛴다. 이름으로만 검증된다."
    fi

    # -master.telemetry=false 가 먹었는지. 켜져 있으면 telemetry.seaweedfs.com 으로 보낸다(README 4절).
    check "telemetry 전송 로그 없음" bash -c "
        ! docker logs '$CONTAINER' 2>&1 | grep -qi 'telemetry.seaweedfs.com'"

    #--- 실제 동작 검증: S3 왕복 -------------------------------------------
    # 설정만 보는 검사로는 자격증명·인증서·디스크 권한 문제를 잡을 수 없다.
    step "S3 왕복 검증 (aws-cli, CA 검증 켬)"

    smoke_prepare
    head -c $((5 * 1024 * 1024))  /dev/urandom > "${SMOKE_DIR}/o5.bin"
    # 20MB 는 aws CLI 의 멀티파트 기준(8MB)을 넘으므로 멀티파트 업로드가 된다.
    head -c $((20 * 1024 * 1024)) /dev/urandom > "${SMOKE_DIR}/o20.bin"
    aws_run s3 rb --force "s3://${SMOKE_BUCKET}" >/dev/null 2>&1 || true

    check "aws-cli 로 서버 접속(버킷 목록)" retry_until 60 aws_run s3 ls
    check "버킷 생성"                aws_run s3 mb "s3://${SMOKE_BUCKET}"
    check "업로드 5MB"               aws_run s3 cp /work/o5.bin  "s3://${SMOKE_BUCKET}/o5.bin"
    check "업로드 20MB(멀티파트)"     aws_run s3 cp /work/o20.bin "s3://${SMOKE_BUCKET}/o20.bin"
    check "목록에 보임"               s3_listed o20.bin
    check "다운로드 sha256 일치(20MB)" s3_download_matches o20.bin
    check "가상 호스트 스타일 목록"    s3_listed --virtual o5.bin
    check "잘못된 secret 거부"        s3_denied --secret "wrong-secret-${RANDOM}${RANDOM}" s3 ls "s3://${SMOKE_BUCKET}/"
    check "익명 요청 거부"            s3_denied --no-sign-request s3 ls "s3://${SMOKE_BUCKET}/"
    # 데이터가 호스트 볼륨에 실제로 떨어졌는지. 컨테이너 안에만 있으면 재생성 시 사라진다.
    check "호스트 볼륨에 데이터 기록됨" data_written

    # 정리. 실패해도 판정에 영향을 주지 않는다.
    smoke_cleanup

    log "S3 엔드포인트: https://${WEED_HOSTNAME}:${SEAWEEDFS_S3_PORT} (리전 ${SEAWEEDFS_REGION}, HTTPS 전용)"
    check_summary
}

#=====================================================================
# 자동 복구 실동작 검증
#=====================================================================
do_restart_test() {
    step "자동 복구 실동작 검증"

    local before after pid
    before="$(docker inspect -f '{{.RestartCount}}' "$CONTAINER" 2>/dev/null)" \
        || die "컨테이너 ${CONTAINER} 가 없다"
    log "현재 RestartCount=${before}"

    # 재시작 뒤에도 객체가 남는지 보려고 먼저 하나 쓴다.
    smoke_prepare
    echo "offline-install restart-test $(date -Is)" > "${SMOKE_DIR}/r.txt"
    aws_run s3 rb --force "s3://${SMOKE_BUCKET}" >/dev/null 2>&1 || true
    aws_run s3 mb "s3://${SMOKE_BUCKET}" >/dev/null 2>&1 || die "검증용 버킷을 만들지 못했다"
    aws_run s3 cp /work/r.txt "s3://${SMOKE_BUCKET}/r.txt" >/dev/null 2>&1 \
        || die "검증용 객체를 쓰지 못했다"
    ok "검증용 객체 기록: s3://${SMOKE_BUCKET}/r.txt"

    # docker kill 을 쓰면 안 된다. "사용자가 의도적으로 멈춤"으로 기록되어
    # unless-stopped 가 재시작하지 않는다(40-haproxy 에서 실측).
    pid="$(docker inspect -f '{{.State.Pid}}' "$CONTAINER")"
    [[ -n "$pid" && "$pid" != "0" ]] || die "컨테이너 PID 를 확인할 수 없다"
    log "호스트에서 컨테이너 PID ${pid} 에 SIGKILL"
    kill -9 "$pid" || die "kill 실패"

    # RestartCount 가 늘어나는 것을 기다린다. status == running 을 기다리면 kill 직후
    # 아직 running 으로 보여 즉시 통과하는 거짓 결과가 된다(20-minio 와 같은 이유).
    if retry_until 180 bash -c "
        rc=\$(docker inspect -f '{{.RestartCount}}' '${CONTAINER}' 2>/dev/null || echo 0)
        st=\$(docker inspect -f '{{.State.Status}}' '${CONTAINER}' 2>/dev/null || echo none)
        [[ \"\$rc\" -gt ${before} && \"\$st\" == running ]]"; then
        after="$(docker inspect -f '{{.RestartCount}}' "$CONTAINER")"
        ok "프로세스 사고사 후 자동 복구 (RestartCount ${before} -> ${after})"
    else
        die "자동 복구되지 않았다. 재시작 정책을 확인할 것."
    fi
    retry_until 120 weed_healthz \
        && ok "복구 후 health 응답 정상" || die "복구됐지만 health 가 응답하지 않는다"

    # docker 데몬 재시작 = 노드 재부팅 대리 검증
    step "docker 데몬 재시작 후 복구 (재부팅 대리 검증)"
    systemctl restart docker || die "docker 데몬 재시작 실패"
    retry_until 150 bash -c "[[ \$(docker inspect -f '{{.State.Status}}' '$CONTAINER' 2>/dev/null) == running ]]" \
        && ok "데몬 재시작 후 복구됨" || die "데몬 재시작 후 올라오지 않았다"
    retry_until 150 weed_healthz \
        && ok "health 응답 정상" || die "복구됐지만 health 가 응답하지 않는다"

    step "재시작 후 객체 유지"
    retry_until 60 s3_download_matches r.txt \
        && ok "재시작 전에 쓴 객체를 같은 내용으로 읽었다" \
        || die "재시작 뒤 객체를 읽지 못했거나 내용이 다르다"
    smoke_cleanup
    exit 0
}

do_uninstall() {
    step "SeaweedFS 제거"
    if [[ -f "$COMPOSE_FILE" ]]; then
        dc down >/dev/null 2>&1 || true
    fi
    docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
    ok "컨테이너 제거. 설정(${WEED_DIR})과 데이터(${WEED_DATA_DIR})는 남겨둔다."
    log "데이터까지 지우려면: rm -rf ${WEED_DATA_DIR}"
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

require_cmds docker openssl curl python3
docker info >/dev/null 2>&1 || die "docker 가 동작하지 않는다. 10-k8s 설치를 확인할 것."
docker compose version >/dev/null 2>&1 \
    || die "docker compose 플러그인이 없다. 10-k8s 번들의 docker-compose-plugin deb 를 확인할 것."
ok "docker $(docker --version | awk '{print $3}' | tr -d ,) / compose $(docker compose version --short 2>/dev/null)"

# 입력값 검증. 값은 sed 치환과 compose 파일에 그대로 들어간다.
if [[ ! "$SEAWEEDFS_S3_PORT" =~ ^[0-9]{1,5}$ ]] || ((SEAWEEDFS_S3_PORT < 1 || SEAWEEDFS_S3_PORT > 65535)); then
    die "SEAWEEDFS_S3_PORT 값이 유효하지 않다: ${SEAWEEDFS_S3_PORT}"
fi
[[ "$WEED_HOSTNAME" =~ ^[A-Za-z0-9.-]+$ ]] || die "WEED_HOSTNAME 값이 유효하지 않다: ${WEED_HOSTNAME}"
[[ -n "$WEED_CORS_ORIGINS" ]] \
    || die "WEED_CORS_ORIGINS 가 비었다. site.env 에 설정할 것(예: https://as.example.internal)."
[[ "$WEED_CORS_ORIGINS" != *"*"* ]] \
    || die "WEED_CORS_ORIGINS 에 * 는 쓰지 않는다. 오리진을 명시할 것: ${WEED_CORS_ORIGINS}"
[[ "$WEED_CORS_ORIGINS" =~ ^https?://[A-Za-z0-9.:-]+(,https?://[A-Za-z0-9.:-]+)*$ ]] \
    || die "WEED_CORS_ORIGINS 는 쉼표로 구분한 스킴+호스트 목록이어야 한다: ${WEED_CORS_ORIGINS}"
[[ "$WEED_DATA_DIR" =~ ^/[A-Za-z0-9_./-]+$ && "$WEED_DATA_DIR" != *".."* ]] \
    || die "WEED_DATA_DIR 는 공백 없는 단순 절대 경로여야 한다: ${WEED_DATA_DIR}"
[[ -z "$WEED_HOST_IP" || "$WEED_HOST_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] \
    || die "WEED_HOST_IP 를 IPv4 주소로 설정할 것: ${WEED_HOST_IP}"

# 포트 선점 확인. 기동 실패는 로그만 남기고 조용히 끝나므로 먼저 잡는다.
if ss -lnt | grep -qE ":${SEAWEEDFS_S3_PORT}\b"; then
    docker inspect -f '{{.State.Running}}' "$CONTAINER" >/dev/null 2>&1 \
        || die "포트 ${SEAWEEDFS_S3_PORT} 를 다른 프로세스가 쓰고 있다: $(ss -lntp | grep -E ":${SEAWEEDFS_S3_PORT}\b" | head -1)"
fi
ok "포트 ${SEAWEEDFS_S3_PORT} 사용 가능"

log "접속 이름=${WEED_HOSTNAME} / 주소=${WEED_HOST_IP:-미확인} / 데이터=${WEED_DATA_DIR}"

#=====================================================================
# 1. 이미지 적재
#=====================================================================
step "이미지 적재 (docker)"
# k8s 워크로드가 아니라 docker 로 돌리므로 ctr 이 아니라 docker load 를 쓴다.
shopt -s nullglob
for tar in "${IMG_DIR}"/*.tar; do
    log "docker load: $(basename "$tar")"
    docker load -i "$tar" >/dev/null || die "docker load 실패: $tar"
done
shopt -u nullglob

MISSING=()
while read -r img; do
    [[ -n "$img" ]] || continue
    docker image inspect "$img" >/dev/null 2>&1 || MISSING+=("$img")
done < "${CONF_DIR}/images.list"
((${#MISSING[@]} == 0)) || die "적재되지 않은 이미지: ${MISSING[*]}"
ok "이미지 $(wc -l < "${CONF_DIR}/images.list")개 적재 확인"

#=====================================================================
# 2. 디렉터리 / 자격증명 / s3.json
#
# SeaweedFS 는 S3 자격증명을 환경변수가 아니라 JSON(-s3.config)으로 받는다.
# 자격증명의 원본은 weed.env(0600, root)이고, s3.json 은 매번 그것으로 다시 만든다.
# s3.json 은 컨테이너 uid 가 읽어야 하므로 1000:1000 · 0600 으로 둔다.
# root 0600 이면 "permission denied" 로 즉시 종료한다(README 4절).
#=====================================================================
step "디렉터리 및 자격증명"

install -d -m 0755 "$WEED_DIR"
install -d -m 0700 "$CERT_DIR"
# 데이터 디렉터리 소유권은 이미지 entrypoint 가 /data 를 chown 해서 맞춘다(README 4절).
install -d -m 0755 "$WEED_DATA_DIR"
ok "디렉터리: ${WEED_DIR}, ${WEED_DATA_DIR}"

if [[ -f "$ENV_FILE" ]]; then
    ok "기존 env 파일 사용: ${ENV_FILE}"
    WEED_ROOT_USER="$(env_get WEED_ROOT_USER)"
    WEED_ROOT_PASSWORD="$(env_get WEED_ROOT_PASSWORD)"
else
    # site.env 값이 있으면 쓰고, 없으면 무작위 생성한다.
    # 공개 저장소에 기본 비밀번호를 적어두면 그대로 운영에 들어가는 일이 실제로 생긴다.
    WEED_ROOT_USER="${WEED_ROOT_USER:-uipathadmin}"
    if [[ -z "${WEED_ROOT_PASSWORD:-}" ]]; then
        WEED_ROOT_PASSWORD="$(openssl rand -base64 36 | tr -dc 'A-Za-z0-9' | head -c 32)"
        GENERATED_PW=1
    fi
fi
# s3.json 의 JSON 문자열과 sed 치환에 그대로 들어가므로 안전한 문자만 받는다.
[[ "$WEED_ROOT_USER" =~ ^[A-Za-z0-9._-]{3,128}$ ]] \
    || die "WEED_ROOT_USER 는 영문자·숫자·. _ - 로 3~128자여야 한다"
[[ "$WEED_ROOT_PASSWORD" =~ ^[A-Za-z0-9._~+/=-]{8,128}$ ]] \
    || die "WEED_ROOT_PASSWORD 는 영문자·숫자·. _ ~ + / = - 로 8~128자여야 한다"

if [[ ! -f "$ENV_FILE" ]]; then
    ( umask 077
      {
          echo "# SeaweedFS S3 자격증명. 21-seaweedfs/install.sh 가 만들었다. root 만 읽는다(0600)."
          echo "# 바꾸려면 이 파일을 고친 뒤 install.sh 를 다시 실행한다(s3.json 을 다시 만든다)."
          echo "WEED_ROOT_USER=${WEED_ROOT_USER}"
          echo "WEED_ROOT_PASSWORD=${WEED_ROOT_PASSWORD}"
      } > "$ENV_FILE" )
    chmod 0600 "$ENV_FILE"
    ok "env 파일 생성: ${ENV_FILE} (0600)"
fi

# 비밀번호가 든 임시 파일이다. 이전 실행이 남긴 파일의 권한을 물려받지 않게 지우고 만든다.
rm -f "${S3_JSON}.new"
( umask 077
  sed -e "s|__WEED_ROOT_USER__|${WEED_ROOT_USER}|g" \
      -e "s|__WEED_ROOT_PASSWORD__|${WEED_ROOT_PASSWORD}|g" \
      "${CONF_DIR}/s3.json.tmpl" > "${S3_JSON}.new" )
python3 -m json.tool "${S3_JSON}.new" >/dev/null 2>&1 \
    || { rm -f "${S3_JSON}.new"; die "생성한 s3.json 이 JSON 으로 유효하지 않다"; }
# s3.json 은 파일 하나를 바인드 마운트한다. 파일을 교체하면 실행 중인 컨테이너는
# 옛 파일을 계속 본다. 내용이 바뀌면 아래 기동 단계에서 컨테이너를 다시 만든다.
RECREATE=0
cmp -s "${S3_JSON}.new" "$S3_JSON" 2>/dev/null || RECREATE=1
install_file "${S3_JSON}.new" "$S3_JSON" 0600
rm -f "${S3_JSON}.new"
chown "${SEAWEEDFS_UID}:${SEAWEEDFS_UID}" "$S3_JSON"
chmod 0600 "$S3_JSON"
ok "s3.json: ${S3_JSON} (${SEAWEEDFS_UID}:${SEAWEEDFS_UID}, 0600)"

#=====================================================================
# 3. TLS 인증서
#
# 우선순위: 05-certs 배치본(/opt/pki/weed) > 기존 /opt/weed/certs > 로컬 CA 로 새로 발급.
# 로컬 발급은 45-redis 와 같은 방식이다(CA 를 만들어 서버 인증서에 서명하고 CA 키는 버린다).
# 가상 호스트 스타일 때문에 SAN 에 *.<WEED_HOSTNAME> 을 넣는다(05-certs 와 같다).
# 컨테이너는 /certs/weed.crt · weed.key 를 읽는다. ca.crt 는 클라이언트 검증용이다.
#=====================================================================
step "TLS 인증서"

cert_sum() {
    { cat "${CERT_DIR}/weed.crt" "${CERT_DIR}/weed.key" 2>/dev/null || true; } | sha256sum | cut -d' ' -f1
}
CERT_SUM_BEFORE="$(cert_sum)"

PKI_WEED="${PKI_DIR:-/opt/pki}/weed"
if [[ -s "${PKI_WEED}/weed.crt" && -s "${PKI_WEED}/weed.key" ]]; then
    install -m 0644 "${PKI_WEED}/weed.crt" "${CERT_DIR}/weed.crt"
    install -m 0600 "${PKI_WEED}/weed.key" "${CERT_DIR}/weed.key"
    if [[ -s "${PKI_WEED}/ca.crt" ]]; then
        install -m 0644 "${PKI_WEED}/ca.crt" "${CERT_DIR}/ca.crt"
    elif [[ -s "${PKI_DIR:-/opt/pki}/ca/ca.crt" ]]; then
        install -m 0644 "${PKI_DIR:-/opt/pki}/ca/ca.crt" "${CERT_DIR}/ca.crt"
    else
        die "weed 인증서용 CA 를 찾지 못했다. 05-certs 를 먼저 배포할 것."
    fi
    ok "사내 CA 발급 인증서 사용 (${PKI_WEED})"
elif [[ -s "${CERT_DIR}/weed.crt" && -s "${CERT_DIR}/weed.key" && -s "${CERT_DIR}/ca.crt" ]]; then
    ok "기존 인증서 사용 (만료: $(openssl x509 -in "${CERT_DIR}/weed.crt" -noout -enddate | cut -d= -f2))"
else
    WEED_SAN="DNS:${WEED_HOSTNAME},DNS:*.${WEED_HOSTNAME},DNS:localhost${WEED_HOST_IP:+,IP:${WEED_HOST_IP}},IP:127.0.0.1"
    log "05-certs 인증서(${PKI_WEED})가 없어 로컬 CA 와 서버 인증서를 만든다."
    cert_tmp="$(mktemp -d)"
    openssl req -x509 -newkey rsa:3072 -nodes -days 3650 \
        -subj "/CN=SeaweedFS local CA" -addext "basicConstraints=critical,CA:TRUE" \
        -keyout "${cert_tmp}/ca.key" -out "${CERT_DIR}/ca.crt" >/dev/null 2>&1 \
        || die "로컬 CA 생성 실패"
    openssl req -newkey rsa:2048 -nodes -subj "/CN=${WEED_HOSTNAME}" \
        -keyout "${CERT_DIR}/weed.key" -out "${cert_tmp}/weed.csr" >/dev/null 2>&1 \
        || die "SeaweedFS 서버 키 생성 실패"
    printf 'basicConstraints=critical,CA:FALSE\nkeyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\nsubjectAltName=%s\n' \
        "$WEED_SAN" > "${cert_tmp}/weed.ext"
    openssl x509 -req -in "${cert_tmp}/weed.csr" -CA "${CERT_DIR}/ca.crt" \
        -CAkey "${cert_tmp}/ca.key" -CAcreateserial -CAserial "${cert_tmp}/ca.srl" -days 825 -sha256 \
        -extfile "${cert_tmp}/weed.ext" -out "${CERT_DIR}/weed.crt" >/dev/null 2>&1 \
        || die "SeaweedFS 서버 인증서 발급 실패"
    rm -rf "$cert_tmp"
    ok "로컬 CA 로 서버 인증서 발급 (SAN: ${WEED_SAN})"
fi

chmod 0644 "${CERT_DIR}/weed.crt" "${CERT_DIR}/ca.crt"
chmod 0600 "${CERT_DIR}/weed.key"
chown -R "${SEAWEEDFS_UID}:${SEAWEEDFS_UID}" "$CERT_DIR"
ok "인증서 소유권 ${SEAWEEDFS_UID}:${SEAWEEDFS_UID}, weed.key 0600"
# SeaweedFS 는 인증서를 기동할 때 읽는다. 바뀌었으면 컨테이너를 다시 만든다.
[[ "$(cert_sum)" == "$CERT_SUM_BEFORE" ]] || RECREATE=1

#=====================================================================
# 4. compose 파일 생성 및 기동
#=====================================================================
step "compose 파일 생성"

sed -e "s|__SEAWEEDFS_IMAGE__|${SEAWEEDFS_IMAGE}|g" \
    -e "s|__SEAWEEDFS_S3_PORT__|${SEAWEEDFS_S3_PORT}|g" \
    -e "s|__WEED_HOSTNAME__|${WEED_HOSTNAME}|g" \
    -e "s|__WEED_CORS_ORIGINS__|${WEED_CORS_ORIGINS}|g" \
    -e "s|__WEED_DATA_DIR__|${WEED_DATA_DIR}|g" \
    -e "s|__WEED_DIR__|${WEED_DIR}|g" \
    "${CONF_DIR}/docker-compose.yml.tmpl" > "${COMPOSE_FILE}.new"

if grep -q '__[A-Z0-9_]*__' "${COMPOSE_FILE}.new"; then
    grep -n '__[A-Z0-9_]*__' "${COMPOSE_FILE}.new" >&2 || true
    die "compose 파일에 치환되지 않은 자리표시자가 남았다"
fi
docker compose -f "${COMPOSE_FILE}.new" config >/dev/null 2>&1 \
    || { docker compose -f "${COMPOSE_FILE}.new" config; die "생성된 compose 파일이 유효하지 않다"; }
ok "compose 문법 검사 통과 (미치환 자리표시자 없음)"

install_file "${COMPOSE_FILE}.new" "$COMPOSE_FILE" 0644
rm -f "${COMPOSE_FILE}.new"

step "컨테이너 기동"
if ((RECREATE)); then
    log "s3.json 또는 인증서가 바뀌어 컨테이너를 다시 만든다."
    dc up -d --force-recreate >/dev/null 2>&1 || { dc logs --tail 30; die "기동 실패"; }
else
    dc up -d >/dev/null 2>&1 || { dc logs --tail 30; die "기동 실패"; }
fi

# 상태 플래그가 아니라 실제 응답으로 확인한다. 키 권한 문제는 기동 직후 종료로 나타난다.
if ! retry_until 120 weed_healthz; then
    dc logs --tail 40 >&2 || true
    die "$(cat <<'MSG'
SeaweedFS 가 정상 기동하지 않았다(healthz 무응답). 위 로그를 확인할 것.

흔한 원인:
  - s3.json 이나 인증서 키를 읽지 못한다
      fail to load config file /etc/seaweedfs/s3.json: permission denied
    -> s3.json · weed.key 는 uid 1000 소유 + 0600 이어야 한다(README 4절)
  - 데이터 디렉터리를 쓸 수 없다
MSG
)"
fi
ok "컨테이너 기동 및 healthz 응답 확인"

#=====================================================================
# 5. 판정
#=====================================================================
run_checks
rc=$?

step "다음 단계"
if [[ "${GENERATED_PW:-0}" == 1 ]]; then
    echo
    warn "S3 비밀번호를 무작위 생성했다. 아래 값을 안전한 곳에 보관할 것."
    echo "    WEED_ROOT_USER     = ${WEED_ROOT_USER}"
    echo "    WEED_ROOT_PASSWORD = ${WEED_ROOT_PASSWORD}"
    echo "    (${ENV_FILE} 에 0600 으로 저장돼 있다)"
    echo
fi
echo "  S3 엔드포인트: https://${WEED_HOSTNAME}:${SEAWEEDFS_S3_PORT}   (리전 ${SEAWEEDFS_REGION}, HTTPS 전용)"
echo "  데이터:        ${WEED_DATA_DIR}"
echo "  CORS 오리진:   ${WEED_CORS_ORIGINS}   (서버 전역 -s3.allowedOrigins)"
echo "  버킷 CORS:     sudo ./apply-cors.sh <버킷이름> [...]  (ExposeHeaders / MaxAge)"
echo
echo "  이름으로 접속하려면 클라이언트의 /etc/hosts 에 매핑이 필요하다:"
echo "    ${WEED_HOST_IP:-<노드IP>} ${WEED_HOSTNAME}"
echo "  가상 호스트 스타일(<버킷>.${WEED_HOSTNAME})을 쓰면 그 이름도 같은 IP 로 풀려야 한다."
echo "  클라이언트는 ${CERT_DIR}/ca.crt 를 신뢰해야 한다."
echo
echo "  자동 복구 검증: sudo ./install.sh --test-restart"
echo "  재판정:         sudo ./install.sh --check-only"
exit $rc
