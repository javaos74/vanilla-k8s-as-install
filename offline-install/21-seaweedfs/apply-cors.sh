#!/usr/bin/env bash
#---------------------------------------------------------------------
# 21-seaweedfs : 버킷 단위 S3 CORS 적용 (에어갭 노드에서 root 로 실행)
#
#   sudo ./apply-cors.sh <버킷> [<버킷> ...]   # 지정한 버킷에 적용
#   sudo ./apply-cors.sh --all                 # 현재 존재하는 모든 버킷
#   sudo ./apply-cors.sh --show <버킷>         # 적용된 설정만 확인
#
# 전제: install.sh 로 SeaweedFS 가 기동되어 있어야 한다.
#
# 규칙은 conf/s3-cors.json.tmpl, 허용 오리진은 site.env 의 WEED_CORS_ORIGINS 다.
# 서버 전역(-s3.allowedOrigins)은 install.sh 가 compose 에 넣는다. 이 스크립트는
# 버킷 쪽 규칙만 다룬다. 둘은 역할이 다르다.
#   전역  : preflight 를 통과시킬지 말지를 결정한다(문지기).
#   버킷  : 통과한 뒤 어떤 헤더를 돌려줄지 정한다(ExposeHeaders / MaxAge).
#---------------------------------------------------------------------
set -euo pipefail

BUNDLE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${BUNDLE_ROOT}/00-common/common.sh"

require_root

CONF_DIR="${BUNDLE_ROOT}/conf"
WEED_DIR="/opt/weed"
ENV_FILE="${WEED_DIR}/weed.env"
CERT_DIR="${WEED_DIR}/certs"
CORS_TMPL="${CONF_DIR}/s3-cors.json.tmpl"

_WEED_DOMAIN="$(hostname -d 2>/dev/null || true)"
WEED_HOSTNAME="${WEED_HOSTNAME:-weed${_WEED_DOMAIN:+.${_WEED_DOMAIN}}}"
WEED_CORS_ORIGINS="${WEED_CORS_ORIGINS:-${AS_FQDN:+https://${AS_FQDN}}}"

MODE="apply"
BUCKETS=()
case "${1:-}" in
    "")      die "버킷 이름이 필요하다. 사용법: $0 <버킷> [...] | --all | --show <버킷>" ;;
    --all)   MODE="all" ;;
    --show)  MODE="show"; shift; BUCKETS=("$@") ;;
    -*)      die "알 수 없는 인자: $1" ;;
    *)       BUCKETS=("$@") ;;
esac

#--- 선행 조건 -------------------------------------------------------
[[ -f "$ENV_FILE" ]]   || die "${ENV_FILE} 가 없다. install.sh 를 먼저 실행할 것."
[[ -f "$CORS_TMPL" ]]  || die "${CORS_TMPL} 가 없다."
[[ -r "${CERT_DIR}/ca.crt" ]] || die "${CERT_DIR}/ca.crt 를 읽을 수 없다."
[[ -n "$WEED_CORS_ORIGINS" ]] \
    || die "WEED_CORS_ORIGINS 가 비었다. site.env 에 설정할 것(예: https://as.example.internal)."
[[ "$WEED_CORS_ORIGINS" != *"*"* ]] \
    || die "WEED_CORS_ORIGINS 에 * 는 쓰지 않는다: ${WEED_CORS_ORIGINS}"
docker inspect -f '{{.State.Running}}' seaweedfs 2>/dev/null | grep -qx true \
    || die "seaweedfs 컨테이너가 실행 중이 아니다."

env_get() { grep -E "^$1=" "$ENV_FILE" 2>/dev/null | cut -d= -f2- || true; }

WORK_DIR="$(mktemp -d)"
cleanup() { rm -rf "$WORK_DIR"; }
trap cleanup EXIT

aws_run() {
    AWS_ACCESS_KEY_ID="$(env_get WEED_ROOT_USER)" \
    AWS_SECRET_ACCESS_KEY="$(env_get WEED_ROOT_PASSWORD)" \
    docker run --rm --network host \
        --add-host "${WEED_HOSTNAME}:127.0.0.1" \
        -e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY \
        -e AWS_DEFAULT_REGION="$SEAWEEDFS_REGION" \
        -e AWS_CA_BUNDLE=/certs/ca.crt \
        -e AWS_PAGER= \
        -v "${CERT_DIR}/ca.crt:/certs/ca.crt:ro" \
        -v "${WORK_DIR}:/work" \
        "$SEAWEEDFS_CLIENT_IMAGE" \
        --endpoint-url "https://${WEED_HOSTNAME}:${SEAWEEDFS_S3_PORT}" "$@"
}

#--- 규칙 파일 생성 --------------------------------------------------
# 쉼표 목록을 JSON 배열 원소로 바꾼다: a,b -> "a", "b"
origins_json() {
    local out="" o
    IFS=',' read -r -a _arr <<< "$WEED_CORS_ORIGINS"
    for o in "${_arr[@]}"; do
        o="${o#"${o%%[![:space:]]*}"}"; o="${o%"${o##*[![:space:]]}"}"
        [[ -n "$o" ]] || continue
        [[ -z "$out" ]] && out="\"${o}\"" || out="${out}, \"${o}\""
    done
    [[ -n "$out" ]] || die "WEED_CORS_ORIGINS 파싱 결과가 비었다: ${WEED_CORS_ORIGINS}"
    printf '%s' "$out"
}

sed -e "s|__WEED_CORS_ORIGINS_JSON__|$(origins_json)|g" "$CORS_TMPL" > "${WORK_DIR}/s3-cors.json"
if grep -q '__[A-Z0-9_]*__' "${WORK_DIR}/s3-cors.json"; then
    grep -n '__[A-Z0-9_]*__' "${WORK_DIR}/s3-cors.json" >&2 || true
    die "CORS 규칙에 치환되지 않은 자리표시자가 남았다"
fi
python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "${WORK_DIR}/s3-cors.json" \
    || die "생성된 CORS 규칙이 올바른 JSON 이 아니다"
chmod a+r "${WORK_DIR}/s3-cors.json"
ok "CORS 규칙 생성 (허용 오리진: ${WEED_CORS_ORIGINS})"

#--- 대상 버킷 ------------------------------------------------------
if [[ "$MODE" == "all" ]]; then
    mapfile -t BUCKETS < <(aws_run s3api list-buckets --query 'Buckets[].Name' --output text 2>/dev/null | tr '\t' '\n' | sed '/^$/d')
    ((${#BUCKETS[@]})) || die "버킷이 하나도 없다."
    log "대상 버킷: ${BUCKETS[*]}"
fi

#--- preflight 실측 --------------------------------------------------
# 브라우저가 보내는 것과 같은 OPTIONS 를 던져 Access-Control-Allow-Origin 을 본다.
preflight() {   # <버킷> <오리진> -> "<상태코드> <allow-origin>"
    local bucket="$1" origin="$2" out code aco
    out="$(curl -s --max-time 10 --path-as-is -o /dev/null -D - \
        --cacert "${CERT_DIR}/ca.crt" \
        --resolve "${WEED_HOSTNAME}:${SEAWEEDFS_S3_PORT}:127.0.0.1" \
        -X OPTIONS \
        -H "Origin: ${origin}" \
        -H 'Access-Control-Request-Method: PUT' \
        -H 'Access-Control-Request-Headers: content-type' \
        "https://${WEED_HOSTNAME}:${SEAWEEDFS_S3_PORT}/${bucket}/cors-probe" 2>/dev/null || true)"
    code="$(printf '%s' "$out" | head -1 | awk '{print $2}')"
    aco="$(printf '%s' "$out" | grep -i '^access-control-allow-origin:' | head -1 | cut -d' ' -f2- | tr -d '\r')"
    printf '%s %s' "${code:-응답없음}" "${aco:-없음}"
}

FIRST_ORIGIN="${WEED_CORS_ORIGINS%%,*}"

#--- 실행 ------------------------------------------------------------
rc=0
for b in "${BUCKETS[@]}"; do
    [[ -n "$b" ]] || continue
    if [[ "$MODE" != "show" ]]; then
        step "버킷 ${b} 에 CORS 적용"
        if ! aws_run s3api put-bucket-cors --bucket "$b" \
                --cors-configuration "file:///work/s3-cors.json" >/dev/null 2>&1; then
            warn "버킷 ${b}: put-bucket-cors 실패 (버킷이 없거나 권한이 없다)"
            rc=1
            continue
        fi
    else
        step "버킷 ${b} CORS 확인"
    fi

    if ! aws_run s3api get-bucket-cors --bucket "$b" > "${WORK_DIR}/readback.json" 2>/dev/null; then
        warn "버킷 ${b}: get-bucket-cors 실패"
        rc=1
        continue
    fi
    sed 's/^/    /' "${WORK_DIR}/readback.json"

    # 되읽은 값에 오리진이 실제로 들어갔는지 확인한다.
    if grep -qF "$FIRST_ORIGIN" "${WORK_DIR}/readback.json"; then
        ok "버킷 ${b}: 오리진 ${FIRST_ORIGIN} 반영 확인"
    else
        warn "버킷 ${b}: 되읽은 설정에 ${FIRST_ORIGIN} 가 없다"
        rc=1
    fi

    # 실제 preflight 응답. 허용 오리진은 통과, 외부 오리진은 막혀야 한다.
    log "preflight 허용 오리진 ${FIRST_ORIGIN} -> $(preflight "$b" "$FIRST_ORIGIN")"
    log "preflight 외부 오리진 https://cors-probe.invalid -> $(preflight "$b" "https://cors-probe.invalid")"
done

echo
if ((rc == 0)); then
    ok "완료. 허용 오리진: ${WEED_CORS_ORIGINS}"
else
    warn "일부 버킷에서 실패했다. 위 메시지를 확인할 것."
fi
exit $rc
