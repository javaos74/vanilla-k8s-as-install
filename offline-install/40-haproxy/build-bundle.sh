#!/usr/bin/env bash
#---------------------------------------------------------------------
# 40-haproxy : 오프라인 번들 빌드 (온라인 호스트에서 실행)
#
# 산출물: bundle/haproxy-<ver>/ + .tar.gz
#
# 용도: ingress L4 패스스루. 호스트의 80/443/15021 을 받아
#       ingress gateway 의 NodePort 로 넘긴다. TLS 는 종료하지 않는다.
#
# 단일 노드이므로 API 서버(6443) LB 는 만들지 않는다. 실익이 없다.
#
# OS 의존 없음(컨테이너 이미지 + 설정 파일뿐). 22.04 / 24.04 공용.
# docker 는 10-k8s 번들에서 이미 설치된다.
#---------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../00-common/common.sh"

require_online
require_cmds curl tar

HAPROXY_TAG="${HAPROXY_IMAGE##*:}"
BUNDLE_NAME="haproxy-${HAPROXY_TAG}"
BUNDLE_DIR="${SCRIPT_DIR}/bundle/${BUNDLE_NAME}"
IMG_DIR="${BUNDLE_DIR}/images"
CONF_DIR="${BUNDLE_DIR}/conf"

step "HAProxy ${HAPROXY_TAG} 번들 빌드 (OS 공용)"
mkdir -p "$IMG_DIR" "$CONF_DIR"

if ! command -v skopeo >/dev/null 2>&1; then
    log "skopeo 설치(빌드 도구)"
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq skopeo
fi
ok "skopeo $(skopeo --version | awk '{print $3}')"

#=====================================================================
# 1. 이미지
#=====================================================================
step "이미지 다운로드"
IMG_TAR="${IMG_DIR}/$(image_to_filename "$HAPROXY_IMAGE").tar"
if [[ -s "$IMG_TAR" ]]; then
    log "이미 존재: $(basename "$IMG_TAR")"
else
    skopeo copy --retry-times 5 "docker://${HAPROXY_IMAGE}" \
        "docker-archive:${IMG_TAR}.part:${HAPROXY_IMAGE}" >/dev/null \
        || die "이미지 받기 실패: ${HAPROXY_IMAGE}"
    mv "${IMG_TAR}.part" "$IMG_TAR"
fi
ok "$(basename "$IMG_TAR") ($(du -h "$IMG_TAR" | cut -f1))"
echo "$HAPROXY_IMAGE" > "${CONF_DIR}/images.list"

#=====================================================================
# 2. haproxy.cfg 템플릿
#=====================================================================
step "haproxy.cfg 템플릿 생성"

# __NP_HTTP__ / __NP_HTTPS__ / __NP_STATUS__ / __BACKEND_IP__ 는 install.sh 가
# 실제 값으로 치환한다. NodePort 는 ingress gateway 서비스에서 자동 탐지한다.
cat > "${CONF_DIR}/haproxy.cfg.tmpl" <<'EOF'
#---------------------------------------------------------------------
# L4 (mode tcp) 로드밸런서 — ingress 전용
#
# 프론트엔드 : 443(HTTPS), 80(HTTP), 15021(ingress 상태/ready)
# 백엔드     : ingress gateway 의 NodePort
#
# TLS 패스스루다. HAProxy 는 TLS 를 종료하지 않는다.
# 따라서 클라이언트 원본 IP 는 백엔드에서 보이지 않는다. 필요하면
# 게이트웨이가 PROXY protocol 을 받도록 설정하고 server 줄에 send-proxy-v2 를 붙인다.
#
# 이 파일은 40-haproxy/install.sh 가 템플릿에서 생성한다. 직접 수정하려면
# 수정 후 다음을 실행한다:
#   sudo docker kill -s HUP l4
#---------------------------------------------------------------------

global
    log stdout format raw local0 info
    maxconn 60000
    stats socket /var/lib/haproxy/admin.sock mode 660 level admin
    stats timeout 30s
    # 컨테이너 안에서 root 로 돌지 않는다
    user  haproxy
    group haproxy

defaults
    mode                    tcp
    log                     global
    option                  tcplog
    option                  dontlognull
    retries                 3
    timeout connect         5s
    timeout client          1h
    timeout server          1h
    timeout queue           30s
    timeout check           5s
    # inter 5s / fall 3 / rise 2 -> 장애 감지 15초, 복구 10초
    default-server          inter 5s fall 3 rise 2

#---------------------------------------------------------------------
# 헬스체크는 ingress gateway 의 상태 포트(__NP_STATUS__)로 한다.
#
# Envoy 의 상태 포트는 HTTP/1.0 요청을 426 Upgrade Required 로 거부한다.
# 그래서 ver HTTP/1.1 과 Host 헤더를 명시해야 한다. 이것을 빼면 모든 백엔드가
# 영구 DOWN 으로 보인다.
#---------------------------------------------------------------------

frontend fe_https
    bind *:443
    default_backend be_https

backend be_https
    balance leastconn
    # 소스 IP 기준 고정. 순수 라운드로빈이 필요하면 아래 두 줄을 지운다.
    stick-table type ip size 200k expire 30m
    stick on src
    option httpchk
    http-check send meth GET uri /healthz/ready ver HTTP/1.1 hdr Host localhost
    http-check expect status 200
    server node1 __BACKEND_IP__:__NP_HTTPS__ check port __NP_STATUS__

frontend fe_http
    bind *:80
    default_backend be_http

backend be_http
    balance leastconn
    option httpchk
    http-check send meth GET uri /healthz/ready ver HTTP/1.1 hdr Host localhost
    http-check expect status 200
    server node1 __BACKEND_IP__:__NP_HTTP__ check port __NP_STATUS__

frontend fe_status
    bind *:15021
    default_backend be_status

backend be_status
    balance roundrobin
    option httpchk
    http-check send meth GET uri /healthz/ready ver HTTP/1.1 hdr Host localhost
    http-check expect status 200
    server node1 __BACKEND_IP__:__NP_STATUS__ check

#---------------------------------------------------------------------
# 통계. 루프백에만 바인드하므로 외부에서 접근할 수 없다.
# 외부로 열려면 stats auth user:pass 를 반드시 추가할 것.
#---------------------------------------------------------------------
listen stats
    bind 127.0.0.1:8404
    mode http
    stats enable
    stats uri /
    stats refresh 10s
EOF
ok "haproxy.cfg.tmpl 생성"

#=====================================================================
# 3. 패키징
#=====================================================================
step "번들 패키징"
mkdir -p "${BUNDLE_DIR}/00-common"
cp "${SCRIPT_DIR}/../00-common/versions.env" "${BUNDLE_DIR}/00-common/"
# site.env(내부 IP·사내 호스트명)는 git 추적 대상이 아니지만 번들에는 넣는다.
# 에어갭 타깃에서 값을 다시 입력할 필요가 없어야 하고, 번들 자체는 사내 자산이다.
# 없으면 install.sh 가 예시 값으로 돌아 NFS 마운트 등이 실패하므로 경고한다.
if [[ -f "${SCRIPT_DIR}/../00-common/site.env" ]]; then
    cp "${SCRIPT_DIR}/../00-common/site.env" "${BUNDLE_DIR}/00-common/"
else
    cp "${SCRIPT_DIR}/../00-common/site.env.example" "${BUNDLE_DIR}/00-common/"
    warn "site.env 가 없어 예시 값으로 번들을 만든다. 타깃에서 값을 채워야 한다."
fi
cp "${SCRIPT_DIR}/../00-common/common.sh"    "${BUNDLE_DIR}/00-common/"
cp "${SCRIPT_DIR}/install.sh"                "${BUNDLE_DIR}/"
cp "${SCRIPT_DIR}/README.md"                 "${BUNDLE_DIR}/" 2>/dev/null || true
chmod +x "${BUNDLE_DIR}/install.sh"

cat > "${BUNDLE_DIR}/BUNDLE-INFO" <<EOF
bundle        : ${BUNDLE_NAME}
bundle_version: ${BUNDLE_VERSION}
built_at      : $(date -Is)
built_on      : $(hostname)
target_os     : Ubuntu 22.04 / 24.04 공용 (OS 의존 없음)
haproxy       : ${HAPROXY_IMAGE}
컨테이너명    : l4
네트워크      : host (80/443/15021 직접 바인드)
재시작 정책   : unless-stopped
용도          : ingress L4 패스스루 (TLS 종료 안 함)
EOF

write_manifest "$BUNDLE_DIR"

TARBALL="${SCRIPT_DIR}/bundle/${BUNDLE_NAME}.tar.gz"
tar -C "${SCRIPT_DIR}/bundle" -czf "$TARBALL" "$BUNDLE_NAME"
sha256sum "$TARBALL" | awk '{print $1}' > "${TARBALL}.sha256"

step "완료"
cat "${BUNDLE_DIR}/BUNDLE-INFO"
echo
ok "번들: ${TARBALL} ($(du -h "$TARBALL" | cut -f1))"
