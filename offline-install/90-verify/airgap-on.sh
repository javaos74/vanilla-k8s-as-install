#!/usr/bin/env bash
#---------------------------------------------------------------------
# 호스트를 "에어갭" 상태로 전환한다.
#
# 모델: 인터넷은 차단하되 사내망(RFC1918)은 허용한다.
#       실제 온프레미스 에어갭과 같은 모양이며, 사내 레지스트리(Harbor)와
#       NFS 서버가 사설망에 있는 이 구성에 맞다.
#
# 왜 nftables 인가:
#   - Azure NSG 변경은 권한이 필요하고 되돌리기가 번거롭다.
#   - 호스트 로컬 규칙이라 SSH 세션을 유지하면서 즉시 적용/해제할 수 있다.
#
# 왜 output 만으로는 부족한가:
#   컨테이너/파드 트래픽은 output 훅이 아니라 forward 훅을 지난다.
#   output 만 막으면 파드가 인터넷에서 이미지를 받아올 수 있어
#   "오프라인 설치 검증"이 무의미해진다. 그래서 forward 도 같이 막는다.
#
# 왜 drop 이 아니라 reject 인가:
#   drop 은 타임아웃(수십 초)으로 나타나 검증이 느려지고 원인 파악이 어렵다.
#   reject(admin-prohibited)는 즉시 실패해 로그가 명확하다.
#
# 사용:
#   sudo ./airgap-on.sh              # 엄격 모드(공용 DNS 까지 차단)
#   sudo ./airgap-on.sh --allow-dns  # DNS 는 허용(이름 해석 실패를 피하고 싶을 때)
#   sudo ./airgap-off.sh             # 해제
#---------------------------------------------------------------------
set -euo pipefail

ALLOW_DNS=0
[[ "${1:-}" == "--allow-dns" ]] && ALLOW_DNS=1

[[ "${EUID}" -eq 0 ]] || { echo "root 권한 필요 (sudo)" >&2; exit 1; }
command -v nft >/dev/null 2>&1 || {
    echo "nft 가 없다. 온라인 상태에서 먼저 설치할 것: sudo apt-get install -y nftables" >&2
    exit 1
}

TABLE="airgap"

# 사내망 도달 확인 대상은 환경마다 다르다. site.env 에서 가져온다.
# 이 스크립트는 단독 실행도 가능해야 하므로, 없으면 확인 단계만 생략한다.
# 번들에는 00-common/ 과 90-verify/ 가 함께 들어가므로 상대 경로가 성립한다.
_AG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for _c in "${_AG_DIR}/../00-common/site.env" "${_AG_DIR}/../00-common/site.env.example"; do
    [[ -f "$_c" ]] && { source "$_c"; break; }
done
SITE_REACHABILITY_HOST="${SITE_REACHABILITY_HOST:-}"
SITE_REACHABILITY_PORT="${SITE_REACHABILITY_PORT:-443}"

# 사내망으로 간주해 허용할 대역.
#   10.0.0.0/8     : 사내 VNet/VPC(Harbor·NFS 가 있는 대역) 포함.
#                    Pod CIDR 10.244/16 과 Service CIDR 10.96/12 도 여기 포함된다.
#   172.16.0.0/12  : docker0(172.17), Harbor 브리지(172.18) 등
#   192.168.0.0/16 : 예비
#   169.254.0.0/16 : link-local
#   224.0.0.0/4    : 멀티캐스트(일부 CNI 가 사용)
#
# 주의: Azure 플랫폼 DNS 168.63.129.16 은 이 목록에 없다(공인 대역).
#       엄격 모드에서는 이름 해석이 실패하므로, 사내 이름은 /etc/hosts 로 준다.
#       실제 에어갭에서도 사내 DNS 또는 hosts 를 쓰므로 같은 모양이다.
PRIVATE_V4='{ 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16, 224.0.0.0/4 }'

# Azure 플랫폼 엔드포인트. DNS 와 WireServer(walinuxagent 상태 보고, :80/:32526)를
# 겸하는 주소다. 공인 IP 지만 "인터넷"이 아니라 하이퍼바이저 관리 채널이므로
# 차단은 유지하되 소음으로 분류한다. 이렇게 하지 않으면 waagent 트래픽이
# 신호 카운터에 섞여 판정을 흐린다(실측: 90초에 약 29건).
# 온프레미스라면 이 항목을 관리망 주소로 바꾸거나 지우면 된다.
PLATFORM_V4='168.63.129.16'

DNS_RULES=""
if ((ALLOW_DNS)); then
    DNS_RULES='        udp dport 53 accept
        tcp dport 53 accept'
fi

echo "[airgap] 기존 ${TABLE} 테이블 제거(있으면)"
nft delete table inet "$TABLE" 2>/dev/null || true

echo "[airgap] 규칙 적용 (ALLOW_DNS=${ALLOW_DNS})"
nft -f - <<EOF
table inet ${TABLE} {
    chain output {
        # priority -10: docker / kube-proxy / cilium 테이블보다 먼저 판단한다.
        # policy 는 accept 로 두고 마지막 reject 규칙으로 막는다(정책 drop 은 조용히
        # 버려 타임아웃이 되므로 검증에 불리하다).
        type filter hook output priority -10; policy accept;

        # 이미 성립된 연결은 통과. 이것이 없으면 실행 중인 SSH 세션이 끊긴다.
        ct state established,related accept

        oifname "lo" accept
        ip daddr ${PRIVATE_V4} accept
${DNS_RULES}

        # IPv6: 루프백 / link-local / ULA 만 허용
        ip6 daddr ::1 accept
        ip6 daddr fe80::/10 accept
        ip6 daddr fd00::/8 accept

        # 나머지(=인터넷)는 즉시 거부.
        # "소음"과 "신호"를 분리해 센다. 판정 기준이 서로 다르기 때문이다.
        #   소음(noise): DNS(53) + NTP(123) + Azure 플랫폼 엔드포인트.
        #     Azure 플랫폼 DNS 168.63.129.16 이 공인 대역이라 systemd-resolved 가
        #     끝없이 재시도하고, systemd-timesyncd 도 공용 NTP 로 나가며,
        #     walinuxagent 도 같은 주소의 WireServer 로 상태를 보고한다.
        #     설치 성공/실패와 무관하다.
        #   신호(other): 그 외 전부. 번들에 없는 것을 인터넷에서 받으려 한 흔적이다.
        # nftables 는 comment 를 규칙 맨 끝에만 허용한다(verdict 뒤).
        ip daddr ${PLATFORM_V4} counter reject with icmpx type admin-prohibited comment "airgap-out-noise"
        meta l4proto { tcp, udp } th dport { 53, 123 } counter reject with icmpx type admin-prohibited comment "airgap-out-noise"
        counter reject with icmpx type admin-prohibited comment "airgap-out-other"
    }

    chain forward {
        # 컨테이너/파드 egress 경로. 여기를 막지 않으면 에어갭이 성립하지 않는다.
        type filter hook forward priority -10; policy accept;

        ct state established,related accept
        iifname "lo" accept
        ip daddr ${PRIVATE_V4} accept
${DNS_RULES}

        ip6 daddr ::1 accept
        ip6 daddr fe80::/10 accept
        ip6 daddr fd00::/8 accept

        # forward 쪽 DNS 차단은 CoreDNS 때문에 반드시 발생한다.
        # CoreDNS 기본 Corefile 이 'forward . /etc/resolv.conf' 이므로
        # 파드가 상류 공인 리졸버로 질의를 보내고 여기서 막힌다. 정상이다.
        ip daddr ${PLATFORM_V4} counter reject with icmpx type admin-prohibited comment "airgap-fwd-noise"
        meta l4proto { tcp, udp } th dport { 53, 123 } counter reject with icmpx type admin-prohibited comment "airgap-fwd-noise"
        # 이 카운터가 0 이 아니면 파드가 이미지나 파일을 인터넷에서 받으려 한 것이다.
        # = 번들에 빠진 것이 있다는 신호. 오프라인 설치 판정의 핵심 지표다.
        counter reject with icmpx type admin-prohibited comment "airgap-fwd-other"
    }
}
EOF

echo "[airgap] 적용 완료"
echo
echo "--- 즉시 확인 ---"
printf "  인터넷 (140.82.112.3:443 github)  : "
if timeout 6 bash -c ">/dev/tcp/140.82.112.3/443" 2>/dev/null; then
    echo "도달 가능  <-- 비정상. 규칙을 확인할 것"
else
    echo "차단됨 (정상)"
fi
if [[ -n "$SITE_REACHABILITY_HOST" ]]; then
    printf "  사내망 (%s:%s)%*s: " "$SITE_REACHABILITY_HOST" "$SITE_REACHABILITY_PORT" 8 ""
    if timeout 6 bash -c ">/dev/tcp/${SITE_REACHABILITY_HOST}/${SITE_REACHABILITY_PORT}" 2>/dev/null; then
        echo "도달 가능 (정상 - 사내 레지스트리/NFS 사용 가능)"
    else
        echo "차단됨  <-- 비정상. 사설망이 막히면 설치가 불가능하다"
    fi
else
    echo "  사내망 확인 생략 (site.env 의 SITE_REACHABILITY_HOST 미설정)"
fi
echo
echo "차단 카운터:  sudo nft list table inet ${TABLE} | grep counter"
echo
echo "  판정 기준 — 설치 후 아래 카운터를 볼 것:"
echo "    airgap-fwd-other  = 0 이어야 한다. 0 이 아니면 파드가 인터넷에서"
echo "                        무언가를 받으려 한 것이므로 번들에 누락이 있다."
echo "    airgap-out-noise / airgap-fwd-noise  는 0 이 아닌 것이 정상이다."
echo "                        (DNS 53 + NTP 123. Azure DNS 168.63.129.16 이 공인"
echo "                         대역이고 CoreDNS 도 상류 리졸버로 질의를 보낸다)"
echo
echo "해제:         sudo ./airgap-off.sh"
