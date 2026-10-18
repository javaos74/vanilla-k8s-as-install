#!/usr/bin/env bash
#---------------------------------------------------------------------
# 컨테이너에서 오프라인 번들을 만든다 (rootless podman, sudo 불필요)
#
#   ./build-in-container.sh 24.04 10-k8s
#   ./build-in-container.sh 22.04 10-k8s
#   ./build-in-container.sh 24.04 20-minio 30-harbor 40-haproxy
#   ./build-in-container.sh 26.04 21-seaweedfs
#   ./build-in-container.sh 24.04 45-redis
#   ./build-in-container.sh 24.04 all
#
# 왜 VM 이 아니라 컨테이너인가:
#   번들 빌드는 deb 와 컨테이너 이미지를 **내려받는** 일뿐이다. 커널이 필요한
#   작업이 없으므로 컨테이너로 충분하고, VM 보다 빠르고 가볍다.
#   빌드 호스트가 "깨끗해야" 하는 요구도 컨테이너가 더 잘 만족한다 —
#   매번 새 컨테이너를 띄우므로 이전 빌드의 흔적이 남지 않는다.
#
# 왜 대상 OS 와 같은 이미지를 쓰는가:
#   10-k8s 는 deb 를 받는다. deb 버전 문자열에 코드네임이 들어가고(docker),
#   OS 기본 패키지(conntrack/socat 등)도 릴리스마다 다르다. 그래서 22.04 용
#   번들은 jammy 컨테이너에서, 24.04 용은 noble 컨테이너에서 만들어야 한다.
#   나머지 단계는 이미지·차트·바이너리만 다루므로 OS 와 무관하다.
#
# 컨테이너에 추가로 설치하는 것: curl / gnupg / ca-certificates / sudo
#   build-bundle.sh 가 요구하는 도구다. 10-k8s 의 전이 의존성은 빈 dpkg 상태 +
#   기준선(ubuntu-server-minimal) 대비로 계산하므로(10-k8s/pkgs-debian.sh)
#   빌드 컨테이너에 무엇이 깔려 있든 번들 내용은 같다.
#
# 10-k8s 를 빌드하면 끝난 뒤 새 컨테이너에서 번들 설치 검증을 한다
# (ubuntu-server-minimal + dpkg -i). SKIP_INSTALL_TEST=1 로 건너뛴다.
#---------------------------------------------------------------------
set -euo pipefail

OSVER="${1:?사용법: $0 <22.04|24.04|26.04> <단계...|all>}"; shift
[[ "$OSVER" == "22.04" || "$OSVER" == "24.04" || "$OSVER" == "26.04" ]] || { echo "OS 는 22.04, 24.04 또는 26.04" >&2; exit 1; }
(($#)) || { echo "빌드할 단계를 지정할 것 (또는 all)" >&2; exit 1; }

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="docker.io/library/ubuntu:${OSVER}"

# OS 에 의존하는 단계는 10-k8s 뿐이다. 나머지는 어느 이미지에서 만들어도 같다.
ALL_STAGES=(10-k8s 20-minio 21-seaweedfs 30-harbor 35-metrics-server 40-haproxy 45-redis 50-nfs-csi 60-cilium 70-mssql 80-postgresql)
if [[ "$1" == "all" ]]; then
    STAGES=("${ALL_STAGES[@]}")
else
    STAGES=("$@")
fi

# 45-redis 는 OS 패키지 번들이 아니라 amd64 Redis 이미지 하나만 받는다.
# Ubuntu 컨테이너가 필요 없으므로 호스트에서 직접 빌드해 rootless Podman 의
# user-namespace 재실행 제한을 우회한다.
if ((${#STAGES[@]} == 1)) && [[ "${STAGES[0]}" == "45-redis" ]]; then
    echo "Redis 빌드는 OS 독립적이므로 Podman 컨테이너 없이 호스트에서 실행합니다."
    (cd "${REPO}/45-redis" && ./build-bundle.sh)
    exit $?
fi

echo "=== 빌드 환경 ==="
echo "  이미지 : ${IMAGE}"
echo "  저장소 : ${REPO}"
echo "  단계   : ${STAGES[*]}"
echo

# 컨테이너 안에서 실행할 것. 단계를 순서대로 돌린다.
# set -e 로 중단하지 않고 각 단계의 결과를 모아 마지막에 보고한다.
read -r -d '' RUNNER <<'INNER' || true
set -uo pipefail
export DEBIAN_FRONTEND=noninteractive

echo "--- 전제 도구 설치"
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
    ca-certificates curl gnupg sudo tar >/dev/null
echo "    curl $(curl --version | head -1 | awk '{print $2}') / gnupg 설치됨"

# 기반 패키지 집합을 실제 Ubuntu Server 와 맞춘다.
#
# 이것이 없으면 번들이 **위험해진다.** ubuntu:24.04 컨테이너는 최소 이미지라
# 실제 서버에 기본 포함된 것들이 빠져 있다. 그 상태로 의존성을 받으면
# systemd / systemd-sysv / perl / python3 / dbus / openssh-client / libc6 까지
# 번들에 들어가고, 타깃에서 dpkg -i 로 그것들을 덮어써 시스템을 망칠 수 있다.
# 실측: 최소 이미지에서 deb 101개(기반 패키지 125개), 아래 설치 후 기반 370개.
#
# ubuntu-server-minimal 은 nftables/socat/conntrack/ebtables/iptables 는 넣지
# 않는다. 이들은 번들에 들어가야 하는 것들이라 정확히 원하는 경계다.
echo "--- 기반 패키지를 실제 서버와 맞춘다 (ubuntu-server-minimal)"
apt-get install -y -qq ubuntu-server-minimal >/dev/null 2>&1 \
    || { echo "    !! ubuntu-server-minimal 설치 실패"; exit 1; }
echo "    설치된 패키지 $(dpkg -l | grep -c '^ii')개"

# 오염 가드가 보는 패키지가 없음을 먼저 확인한다(컨테이너는 깨끗해야 한다).
DIRTY=""
for p in kubelet kubeadm kubectl containerd.io docker-ce nfs-common; do
    dpkg -s "$p" >/dev/null 2>&1 && DIRTY="${DIRTY} ${p}"
done
if [[ -n "$DIRTY" ]]; then
    echo "    !! 컨테이너가 깨끗하지 않다:${DIRTY}"
    exit 1
fi
echo "    오염 없음 (대상 패키지 미설치)"

FAILED=""
for st in ${STAGES}; do
    echo
    echo "================ ${st} ================"
    if ( cd "/work/${st}" && ./build-bundle.sh ); then
        echo "  [OK] ${st}"
    else
        echo "  [FAIL] ${st}"
        FAILED="${FAILED} ${st}"
    fi
done

echo
echo "================ 요약 ================"
for st in ${STAGES}; do
    f=$(ls -1 "/work/${st}/bundle/"*.tar.gz 2>/dev/null | head -1)
    if [[ -n "$f" ]]; then
        printf "  %-16s %s\n" "$st" "$(du -h "$f" | cut -f1)  $(basename "$f")"
    else
        printf "  %-16s %s\n" "$st" "산출물 없음"
    fi
done
[[ -z "$FAILED" ]] || { echo "  실패:${FAILED}"; exit 1; }
INNER

# --userns=keep-id 를 쓰지 않는다. 컨테이너 안에서 root 여야 apt 가 동작한다.
# rootless podman 은 컨테이너의 root 를 호스트의 내 uid 로 매핑하므로
# /work 에 쓴 파일은 호스트에서 내 소유로 보인다.
podman run --rm \
    -v "${REPO}:/work:z" \
    -e STAGES="${STAGES[*]}" \
    "$IMAGE" \
    bash -c "$RUNNER" || exit $?

#---------------------------------------------------------------------
# 10-k8s 번들 설치 검증 (새 컨테이너)
#
# 번들의 deb 만으로 깨끗한 노드에 설치가 끝나는지 실제로 확인한다.
# 빌드 컨테이너는 빌드 도구(skopeo 등)가 깔려 있어 설치 검증에 쓸 수 없으므로
# 같은 이미지로 새 컨테이너를 띄워 ubuntu-server-minimal 만 깐 뒤 dpkg -i 한다.
#
# 이 검증이 생긴 이유(실측): skopeo 가 끌어온 iptables/nftables 라이브러리 6개가
# 26.04 번들에서 빠졌는데 빌드는 성공했고, 설치 노드에서야 "dependency problems"
# 로 드러났다. 번들의 결함은 빌드 단계에서 잡아야 한다.
#
# 컨테이너에는 systemd 가 없어 서비스 기동은 확인하지 않는다. 패키지가 전부
# "installed" 로 구성되는지와 dpkg --audit 이 깨끗한지만 본다.
# 건너뛰려면 SKIP_INSTALL_TEST=1.
#---------------------------------------------------------------------
if [[ " ${STAGES[*]} " == *" 10-k8s "* && "${SKIP_INSTALL_TEST:-0}" != "1" ]]; then
    echo
    echo "=== 10-k8s 번들 설치 검증 (${IMAGE} + ubuntu-server-minimal) ==="
    read -r -d '' VERIFY <<'INNER' || true
set -uo pipefail
export DEBIAN_FRONTEND=noninteractive
. /etc/os-release
B="$(ls -dt /work/10-k8s/bundle/k8s-*-"${VERSION_CODENAME}" 2>/dev/null | head -1)"
[[ -n "$B" && -d "$B/debs" ]] || { echo "  !! 번들을 찾지 못했다: k8s-*-${VERSION_CODENAME}"; exit 1; }
echo "  번들: $(basename "$B") / deb $(ls "$B"/debs/*.deb | wc -l)개"

apt-get update -qq
apt-get install -y -qq ubuntu-server-minimal >/dev/null 2>&1 \
    || { echo "  !! ubuntu-server-minimal 설치 실패"; exit 1; }
echo "  기준선 패키지 $(dpkg -l | grep -c '^ii')개"

# 저장소에서 아무것도 받지 않는다. dpkg -i 는 번들 파일만 쓴다.
dpkg -i "$B"/debs/*.deb > /tmp/dpkg.log 2>&1
DPKG_RC=$?

BAD=()
for d in "$B"/debs/*.deb; do
    n="$(dpkg-deb -f "$d" Package)"
    st="$(dpkg-query -W -f='${db:Status-Status}' "$n" 2>/dev/null || echo missing)"
    [[ "$st" == "installed" ]] || BAD+=("${n}:${st}")
done
AUDIT="$(dpkg --audit 2>&1)"

if (( DPKG_RC == 0 )) && ((${#BAD[@]} == 0)) && [[ -z "$AUDIT" ]]; then
    echo "  [OK] deb 전부 installed, dpkg --audit 깨끗함"
    exit 0
fi
echo "  [FAIL] dpkg rc=${DPKG_RC}, 미구성 ${#BAD[@]}개: ${BAD[*]}"
grep -E "depends on|is not installed|error processing" /tmp/dpkg.log | sort -u | head -20 | sed 's/^/    /'
[[ -n "$AUDIT" ]] && echo "$AUDIT" | head -10 | sed 's/^/    audit: /'
echo "  이 번들을 쓰지 말 것. 빠진 의존성을 확인해 10-k8s/pkgs-debian.sh 를 고쳐야 한다."
exit 1
INNER
    podman run --rm -v "${REPO}:/work:ro,z" "$IMAGE" bash -c "$VERIFY" || exit $?
fi
