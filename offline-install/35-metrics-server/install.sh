#!/usr/bin/env bash
#---------------------------------------------------------------------
# 35-metrics-server : 로컬 Harbor 를 거쳐 metrics-server 배포 (control plane 에서 root)
#
#   sudo ./install.sh                 # Harbor 에 이미지 push -> 배포 -> 판정
#   sudo ./install.sh --check-only    # 판정만
#   sudo ./install.sh --uninstall     # 클러스터에서 제거(Harbor 이미지는 남긴다)
#
# 전제:
#   10-k8s + 60-cilium 설치 완료(노드 Ready)
#   30-harbor 설치 완료, 이 노드에서 https://<HARBOR_HOSTNAME> 에 닿는다
#   이 노드의 containerd 가 Harbor 인증서를 신뢰한다(05-certs deploy-certs --local)
#
# Harbor 자격증명(push 용). 아래 순서로 찾는다.
#   1) 환경변수 HARBOR_USER / HARBOR_PASSWORD
#   2) site.env 의 HARBOR_ADMIN_PASSWORD (사용자 admin)
#   3) 이 노드가 Harbor 호스트이면 /opt/harbor/.harbor-credentials
# 자격증명은 임시 DOCKER_CONFIG 에만 쓰고 끝나면 지운다(/root/.docker 에 남기지 않는다).
#
# 이미지 위치: <HARBOR_HOSTNAME>/uipath/rancher/hardened-k8s-metrics-server:<태그>
#   UiPath AS 이미지를 seed 하는 uipath 프로젝트에 registry.uipath.com 경로를 그대로 둔다.
#   uipath 프로젝트가 private 이면 kube-system 에 pull secret(harbor-uipath-pull)을 만들고
#   metrics-server ServiceAccount 에 붙인다. pull 계정은 HARBOR_PULL_USER/HARBOR_PULL_PASSWORD
#   (Harbor robot 계정 권장). 없으면 push 계정을 쓰고 경고한다.
#
# 왜 Harbor 를 거치는가:
#   ctr import 로 노드마다 넣으면 노드를 추가할 때마다 다시 넣어야 하고, 파드가
#   다른 노드로 옮겨가면 ImagePullBackOff 가 된다. 레지스트리에서 받게 하면
#   어느 노드에서도 같은 이미지를 받는다. 대신 **모든 노드**가 Harbor 이름을
#   해석하고 CA 를 신뢰해야 한다(05-certs deploy-certs --nodes ...).
#---------------------------------------------------------------------
BUNDLE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${BUNDLE_ROOT}/00-common/common.sh"

MODE="install"
case "${1:-}" in
    --check-only) MODE="check" ;;
    --uninstall)  MODE="uninstall" ;;
    "")           MODE="install" ;;
    *)            die "알 수 없는 인자: $1 (--check-only | --uninstall)" ;;
esac

require_root
require_cmds kubectl curl
export KUBECONFIG=/etc/kubernetes/admin.conf

IMG_DIR="${BUNDLE_ROOT}/images"
CONF_DIR="${BUNDLE_ROOT}/conf"
TMPL="${CONF_DIR}/components.yaml.tmpl"

HARBOR_HOST="${HARBOR_HOSTNAME:?site.env 에 HARBOR_HOSTNAME 이 없다}"
PROJECT="${METRICS_SERVER_HARBOR_PROJECT}"
SRC_IMAGE="$METRICS_SERVER_SOURCE_IMAGE"
TAG="${SRC_IMAGE##*:}"
REPO="${METRICS_SERVER_HARBOR_REPO}"
TARGET_IMAGE="${HARBOR_HOST}/${PROJECT}/${REPO}:${TAG}"
# Harbor API 는 저장소 이름의 '/' 를 두 번 인코딩해야 한다(rancher%252Fhardened-...).
REPO_API="${REPO//\//%252F}"
PULL_SECRET="harbor-${PROJECT}-pull"

# Harbor 접속에 쓸 CA. 30-harbor(같은 호스트) 또는 05-certs 가 배치한다.
HARBOR_CA=""
for c in "/etc/docker/certs.d/${HARBOR_HOST}/ca.crt" \
         "/etc/containerd/certs.d/${HARBOR_HOST}/ca.crt" \
         /opt/pki/ca/ca.crt; do
    [[ -f "$c" ]] && { HARBOR_CA="$c"; break; }
done

hcurl() {   # Harbor API 호출. CA 검증을 끄지 않는다.
    curl -fsS --max-time 15 ${HARBOR_CA:+--cacert "$HARBOR_CA"} "$@"
}

harbor_creds() {
    HB_USER="${HARBOR_USER:-admin}"
    HB_PASS="${HARBOR_PASSWORD:-${HARBOR_ADMIN_PASSWORD:-}}"
    if [[ -z "$HB_PASS" && -f /opt/harbor/.harbor-credentials ]]; then
        HB_PASS="$(grep -E '^HARBOR_ADMIN_PASSWORD=' /opt/harbor/.harbor-credentials | cut -d= -f2-)"
    fi
    [[ -n "$HB_PASS" ]] || { HB_USER=""; return 1; }
}

#=====================================================================
# 판정
#=====================================================================
run_checks() {
    step "Metrics Server 판정"
    check "Harbor 응답 (https://${HARBOR_HOST}/api/v2.0/ping)" \
        bash -c "$(declare -f hcurl); HARBOR_CA='${HARBOR_CA}'; [[ \$(hcurl https://${HARBOR_HOST}/api/v2.0/ping) == Pong ]]"
    # private 프로젝트일 수 있어 자격증명이 있으면 붙인다(--check-only 는 없을 수 있다).
    local auth=""
    [[ -n "${HB_USER:-}" && -n "${HB_PASS:-}" ]] && auth="-u '${HB_USER}:${HB_PASS}'"
    check "Harbor 에 이미지 있음 (${PROJECT}/${REPO}:${TAG})" \
        bash -c "$(declare -f hcurl); HARBOR_CA='${HARBOR_CA}'; hcurl ${auth} 'https://${HARBOR_HOST}/api/v2.0/projects/${PROJECT}/repositories/${REPO_API}/artifacts/${TAG}' >/dev/null"
    check "Deployment metrics-server Available" retry_until 180 bash -c '
        kubectl -n kube-system get deploy metrics-server \
            -o jsonpath="{.status.availableReplicas}" 2>/dev/null | grep -qE "^[1-9]"'
    check "파드 이미지가 Harbor 주소" bash -c "
        kubectl -n kube-system get pods -l k8s-app=metrics-server \
            -o jsonpath='{.items[*].spec.containers[0].image}' | grep -qF '${TARGET_IMAGE}'"
    # imageID 가 Harbor 주소로 기록됐는지. 노드에 미리 적재된 다른 이름의 이미지가
    # 아니라 실제로 Harbor 에서 받은 것인지 확인한다.
    check "파드가 Harbor 에서 받은 이미지로 실행 중(imageID)" bash -c "
        kubectl -n kube-system get pods -l k8s-app=metrics-server \
            -o jsonpath='{.items[*].status.containerStatuses[0].imageID}' | grep -qF '${HARBOR_HOST}/${PROJECT}/${REPO}@sha256:'"
    check "APIService v1beta1.metrics.k8s.io Available" retry_until 180 bash -c '
        [[ $(kubectl get apiservice v1beta1.metrics.k8s.io \
            -o jsonpath="{.status.conditions[?(@.type==\"Available\")].status}" 2>/dev/null) == True ]]'
    check "kubectl top nodes 응답" retry_until 180 bash -c 'kubectl top nodes --no-headers 2>/dev/null | grep -q .'
    check "kubectl top pods -A 응답" retry_until 120 bash -c 'kubectl top pods -A --no-headers 2>/dev/null | grep -q .'
    echo
    kubectl top nodes 2>/dev/null | sed 's/^/    /' || true
    check_summary
}

if [[ "$MODE" == "check" ]]; then
    # 자격증명이 있으면 쓰고, 없으면 익명으로 본다(private 이면 이미지 항목만 실패한다).
    harbor_creds || true
    run_checks; exit $?
fi

if [[ "$MODE" == "uninstall" ]]; then
    step "metrics-server 제거"
    sed "s@__METRICS_SERVER_IMAGE__@${TARGET_IMAGE}@g" "$TMPL" | kubectl delete --ignore-not-found -f - || true
    kubectl -n kube-system delete secret "$PULL_SECRET" --ignore-not-found >/dev/null 2>&1 || true
    ok "제거 완료 (Harbor 의 ${TARGET_IMAGE} 는 남겼다)"
    exit 0
fi

#=====================================================================
# 0. 사전 확인
#=====================================================================
step "사전 확인"
verify_manifest "$BUNDLE_ROOT"
is_online && warn "인터넷 연결 상태다. 오프라인 검증이라면 90-verify/airgap-on.sh 를 먼저 실행할 것." \
          || ok "인터넷 차단 상태 (에어갭 검증 조건 충족)"
require_cmds docker crictl
[[ -f "$KUBECONFIG" ]] || die "control plane 이 아니다(admin.conf 없음)"
kubectl get nodes -o jsonpath='{.items[*].status.conditions[?(@.type=="Ready")].status}' \
    | grep -q True || die "Ready 노드가 없다. 60-cilium 을 먼저 설치할 것."
ok "클러스터 Ready"

getent hosts "$HARBOR_HOST" >/dev/null \
    || die "${HARBOR_HOST} 를 해석하지 못한다. /etc/hosts 또는 사내 DNS 에 등록할 것(모든 노드)."
[[ -n "$HARBOR_CA" ]] \
    || die "Harbor CA 를 찾지 못했다. 05-certs 의 deploy-certs.sh --local 을 먼저 실행할 것."
[[ "$(hcurl "https://${HARBOR_HOST}/api/v2.0/ping" 2>/dev/null)" == "Pong" ]] \
    || die "https://${HARBOR_HOST} 에 닿지 않거나 인증서 검증에 실패했다(CA: ${HARBOR_CA})."
ok "Harbor 응답 + 인증서 검증 (CA: ${HARBOR_CA})"

harbor_creds || die "Harbor 비밀번호를 찾지 못했다. HARBOR_PASSWORD 환경변수 또는 site.env 의 HARBOR_ADMIN_PASSWORD 를 줄 것."
hcurl -u "${HB_USER}:${HB_PASS}" "https://${HARBOR_HOST}/api/v2.0/users/current" >/dev/null \
    || die "Harbor 인증 실패 (사용자 ${HB_USER})"
ok "Harbor 인증 (사용자 ${HB_USER})"

#=====================================================================
# 1. Harbor 프로젝트 확인
#=====================================================================
step "Harbor 프로젝트 ${PROJECT}"
PUB="$(hcurl -u "${HB_USER}:${HB_PASS}" "https://${HARBOR_HOST}/api/v2.0/projects/${PROJECT}" 2>/dev/null \
       | python3 -c 'import sys,json; print(json.load(sys.stdin).get("metadata",{}).get("public",""))' 2>/dev/null || true)"
if [[ -z "$PUB" ]]; then
    hcurl -u "${HB_USER}:${HB_PASS}" -H 'Content-Type: application/json' -X POST \
        -d "{\"project_name\":\"${PROJECT}\",\"metadata\":{\"public\":\"true\"}}" \
        "https://${HARBOR_HOST}/api/v2.0/projects" >/dev/null \
        || die "프로젝트 ${PROJECT} 생성 실패"
    ok "프로젝트 ${PROJECT} 생성 (public)"
    PUB="true"
elif [[ "$PUB" == "true" ]]; then
    ok "프로젝트 ${PROJECT} 존재 (public)"
else
    ok "프로젝트 ${PROJECT} 존재 (private) — kube-system 에 pull secret 을 만든다"
fi

#=====================================================================
# 2. 이미지 push
#=====================================================================
step "이미지 push -> ${TARGET_IMAGE}"
TAR="$(ls "${IMG_DIR}"/*.tar 2>/dev/null | head -1)"
[[ -n "$TAR" ]] || die "번들에 이미지 tar 가 없다"
docker load -i "$TAR" >/dev/null || die "docker load 실패: $TAR"
docker tag "$SRC_IMAGE" "$TARGET_IMAGE"

DOCKER_CONFIG="$(mktemp -d)"; export DOCKER_CONFIG
trap 'rm -rf "$DOCKER_CONFIG"' EXIT
echo "$HB_PASS" | docker login "$HARBOR_HOST" -u "$HB_USER" --password-stdin >/dev/null \
    || die "docker login ${HARBOR_HOST} 실패. /etc/docker/certs.d/${HARBOR_HOST}/ca.crt 를 확인할 것."
docker push -q "$TARGET_IMAGE" >/dev/null || die "docker push 실패: ${TARGET_IMAGE}"
docker logout "$HARBOR_HOST" >/dev/null 2>&1 || true
rm -rf "$DOCKER_CONFIG"; unset DOCKER_CONFIG; trap - EXIT
ok "push 완료"

# 노드 쪽(containerd = kubelet 경로)에서 실제로 받아지는지 먼저 본다. 여기서 실패하면
# 파드가 ImagePullBackOff 가 되므로 배포 전에 원인을 알려준다.
PULL_USER="${HARBOR_PULL_USER:-$HB_USER}"
PULL_PASS="${HARBOR_PULL_PASSWORD:-$HB_PASS}"
CRI_CREDS=()
[[ "$PUB" == "true" ]] || CRI_CREDS=(--creds "${PULL_USER}:${PULL_PASS}")
crictl --runtime-endpoint unix:///run/containerd/containerd.sock pull "${CRI_CREDS[@]}" "$TARGET_IMAGE" >/dev/null 2>&1 \
    || die "containerd 가 ${TARGET_IMAGE} 를 받지 못했다. 05-certs deploy-certs.sh --local 로 containerd 신뢰(certs.d + config_path)를 설정할 것."
ok "containerd 에서 Harbor pull 확인"

#=====================================================================
# 3. 배포
#=====================================================================
step "metrics-server 배포"
if [[ "$PUB" != "true" ]]; then
    [[ -n "${HARBOR_PULL_USER:-}" ]] \
        || warn "HARBOR_PULL_USER 가 없어 push 계정(${PULL_USER})으로 pull secret 을 만든다. 운영에서는 Harbor robot 계정을 쓸 것."
    kubectl -n kube-system create secret docker-registry "$PULL_SECRET" \
        --docker-server="$HARBOR_HOST" --docker-username="$PULL_USER" --docker-password="$PULL_PASS" \
        --dry-run=client -o yaml | kubectl apply -f - >/dev/null || die "pull secret 생성 실패"
    # ServiceAccount 를 먼저 만들고 imagePullSecrets 를 붙인다. 파드 생성 시점에 SA 의
    # imagePullSecrets 가 복사되므로 Deployment 보다 먼저여야 한다. 매니페스트는 원본
    # (metrics-server/components.yaml)과 같게 두고, apply 는 이 필드를 지우지 않는다
    # (매니페스트에 없는 필드이고 imperative 로 만든 값이라 last-applied 에 없다).
    kubectl -n kube-system get sa metrics-server >/dev/null 2>&1 \
        || kubectl -n kube-system create sa metrics-server >/dev/null
    kubectl -n kube-system patch sa metrics-server --type merge \
        -p "{\"imagePullSecrets\":[{\"name\":\"${PULL_SECRET}\"}]}" >/dev/null \
        || die "ServiceAccount 에 pull secret 연결 실패"
    ok "pull secret ${PULL_SECRET} -> sa/metrics-server"
fi
sed "s@__METRICS_SERVER_IMAGE__@${TARGET_IMAGE}@g" "$TMPL" | kubectl apply -f - >/dev/null \
    || die "kubectl apply 실패"
kubectl -n kube-system rollout status deployment/metrics-server --timeout=180s \
    || die "rollout 실패: kubectl -n kube-system describe pod -l k8s-app=metrics-server"
ok "rollout 완료"

#=====================================================================
# 4. 판정
#=====================================================================
run_checks
rc=$?

step "다음 단계"
echo "  worker 노드에도 파드가 옮겨갈 수 있다. 모든 노드가 ${HARBOR_HOST} 를 해석하고"
echo "  CA 를 신뢰해야 한다:  05-certs/deploy-certs.sh --nodes '<노드들>'"
echo "  UiPath AS 사전 점검:  uipathctl prereq run input.json --versions versions.json"
exit $rc
