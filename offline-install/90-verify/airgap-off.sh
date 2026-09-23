#!/usr/bin/env bash
#---------------------------------------------------------------------
# airgap-on.sh 로 적용한 차단을 해제한다.
#
# 전용 테이블(inet airgap)만 삭제하므로 docker / kube-proxy / cilium 이
# 만든 규칙에는 영향을 주지 않는다.
#
# 해제 전에 차단 카운터를 출력한다. 이 수치가 "설치 중 인터넷 접근을
# 시도했는가"에 대한 증거가 된다. 0 이면 완전한 오프라인 설치였다는 뜻이다.
#---------------------------------------------------------------------
set -euo pipefail

[[ "${EUID}" -eq 0 ]] || { echo "root 권한 필요 (sudo)" >&2; exit 1; }

TABLE="airgap"

if nft list table inet "$TABLE" >/dev/null 2>&1; then
    echo "[airgap] 차단 카운터 (해제 전 기록):"
    nft list table inet "$TABLE" | grep -E "counter packets" | sed 's/^/    /' || true
    echo

    # 판정: DNS/NTP/플랫폼이 아닌 forward 차단이 있었는지가 핵심이다.
    #
    # 주의: 이 스크립트는 set -euo pipefail 이다. grep 이 매칭에 실패하면
    # exit 1 이고 pipefail 때문에 파이프 전체가 실패해 스크립트가 여기서
    # 중단된다. 그러면 아래 nft delete 가 실행되지 않아 "해제 스크립트가
    # 해제를 안 하는" 상태가 된다(구버전 규칙 이름이 남은 호스트에서 실제로 발생).
    # 그래서 반드시 || true 로 막고 기본값을 준다.
    FWD_OTHER="$(nft list table inet "$TABLE" 2>/dev/null \
                 | grep 'airgap-fwd-other' \
                 | grep -oE 'packets [0-9]+' \
                 | awk '{print $2}' || true)"

    if [[ -z "$FWD_OTHER" ]]; then
        echo "  판정: airgap-fwd-other 카운터를 찾지 못했다."
        echo "        구버전 airgap-on.sh 로 적용된 테이블일 수 있다(판정 생략)."
    elif [[ "$FWD_OTHER" == "0" ]]; then
        echo "  판정: airgap-fwd-other = 0  ->  파드가 인터넷 접근을 시도하지 않았다."
        echo "        완전한 오프라인 설치였다."
    else
        echo "  판정: airgap-fwd-other = ${FWD_OTHER}  ->  파드가 인터넷 접근을 시도했다."
        echo "        번들에 누락된 이미지/파일이 있을 수 있다. 확인:"
        echo "        kubectl get events -A --field-selector type=Warning"
    fi
    echo

    nft delete table inet "$TABLE"
    echo "[airgap] inet ${TABLE} 테이블 삭제 완료"
else
    echo "[airgap] inet ${TABLE} 테이블이 없다 (이미 해제됨)"
fi

echo
printf "  인터넷 (140.82.112.3:443) : "
if timeout 8 bash -c ">/dev/tcp/140.82.112.3/443" 2>/dev/null; then
    echo "도달 가능 (해제 확인)"
else
    echo "여전히 차단  <-- 다른 원인(NSG 등)을 확인할 것"
fi
