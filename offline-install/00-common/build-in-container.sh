#!/usr/bin/env bash
#---------------------------------------------------------------------
# 컨테이너에서 오프라인 번들을 만든다 (rootless podman, sudo 불필요)
# 70-mssql 과 85-ollama-embedding 은 예외로 호스트 Docker 로 빌드한다(아래).
#
#   ./build-in-container.sh 24.04 10-k8s
#   ./build-in-container.sh 22.04 10-k8s
#   ./build-in-container.sh 24.04 20-minio 30-harbor 40-haproxy
#   ./build-in-container.sh 26.04 21-seaweedfs
#   ./build-in-container.sh 24.04 45-redis
#   ./build-in-container.sh 24.04 70-mssql
#   ./build-in-container.sh 24.04 85-ollama-embedding
#   ./build-in-container.sh 24.04 all
#
# 70-mssql 은 왜 호스트 Docker 인가:
#   이미지는 빌드하지 않는다. 게시된 mssql-fts 이미지를 skopeo 로 다이제스트
#   고정해 받는다. 받은 이미지에 FTS 가 들어 있는지 docker load + docker run 으로
#   확인하는데(70-mssql/README.md 3절), 빌드 컨테이너에는 docker 가 없다.
#   그래서 호스트 Docker 를 쓸 수 있으면 컨테이너 단계가 끝난 뒤(85 보다 먼저)
#   호스트에서 70-mssql/build-bundle.sh 를 실행한다. 호스트 Docker 나 호스트
#   skopeo 를 못 쓰면 경고하고 예전처럼 컨테이너에서 빌드한다. 이때는 FTS 포함
#   확인만 건너뛰고 번들은 만들어지므로 종료 코드에 영향이 없다.
#
# 85-ollama-embedding 은 왜 호스트 Docker 인가:
#   이미지 빌드 중에 ollama serve / ollama pull 로 모델을 이미지에 넣는다
#   (85-ollama-embedding/README.md D2). docker 데몬이 필요한데 빌드 컨테이너에는
#   docker 가 없다. 그래서 컨테이너 단계가 끝난 뒤 호스트에서
#   85-ollama-embedding/build-bundle.sh all (cpu + gpu) 을 실행한다.
#   실행 계정이 docker 를 못 쓰면 빌드 시작 때 docker 그룹 권한을 구성한다
#   (prepare_host_docker). 그래도 못 쓰면 경고하고 85 만 건너뛴다.
#   건너뛰었을 때 종료 코드: all 이면 영향 없음, 단계로 직접 지정했으면 1.
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
# 70-mssql·85-ollama-embedding 은 컨테이너가 아니라 호스트 Docker 로 빌드한다(머리말).
ALL_STAGES=(10-k8s 20-minio 21-seaweedfs 30-harbor 35-metrics-server 40-haproxy 45-redis 50-nfs-csi 60-cilium 70-mssql 80-postgresql 85-ollama-embedding)
if [[ "$1" == "all" ]]; then
    STAGES=("${ALL_STAGES[@]}")
else
    STAGES=("$@")
fi

# 85-ollama-embedding 을 컨테이너 단계에서 뺀다. 70-mssql 은 일단 남겨 두고 표시만 한다.
#   OLLAMA_MODE : "" = 요청 없음 / all = all 에 포함 / named = 단계로 직접 지정
#   MSSQL_REQ   : "" = 요청 없음 / 1 = 요청됨(호스트에서 빌드할 수 없으면 컨테이너 단계에 남는다)
# 셸 자동 완성이 붙이는 끝의 / 도 같은 단계로 본다.
OLLAMA_MODE=""
MSSQL_REQ=""
CTR_STAGES=()
for st in "${STAGES[@]}"; do
    case "${st%/}" in
        85-ollama-embedding)
            if [[ "$1" == "all" ]]; then OLLAMA_MODE=all; else OLLAMA_MODE=named; fi
            ;;
        70-mssql)
            MSSQL_REQ=1
            CTR_STAGES+=("$st")
            ;;
        *)
            CTR_STAGES+=("$st")
            ;;
    esac
done

#---------------------------------------------------------------------
# 70-mssql·85-ollama-embedding 용 호스트 Docker 준비
#
# 두 단계가 함께 쓴다. 같은 계정·같은 데몬이라 판정이 같고, 따로 확인하면
# usermod 안내와 sudo 암호 입력이 두 번 나올 수 있다.
#
# 실행 계정이 docker 데몬에 접근할 수 있게 한다. sudo docker 로 우회하지 않는다.
#   1) 지금 프로세스로 docker info 가 되면 그대로 쓴다.
#   2) 소켓 권한 거부이고 계정이 이미 docker 그룹 회원이면(/etc/group) 이 세션에만
#      그룹이 없는 것이다(그룹 추가 전에 연 로그인 셸, tmux 서버). 다시 로그인하지
#      않도록 sg docker 로 실행한다.
#   3) 회원이 아니면 sudo usermod -aG docker <계정> 으로 추가하고 sg docker 로 실행한다.
#      확인을 묻지 않는다. 바꾸는 내용과 docker 그룹이 root 와 같은 권한이라는 점은
#      실행 전에 출력한다. stdin 이 터미널이 아니면 sudo -n 으로 암호를 묻지 않는다.
# 컨테이너 단계보다 먼저 부른다. sudo 암호 입력과 경고가 긴 빌드의 끝이 아니라
# 시작에 나오게 하려는 것이다.
#
# 입력: HOST_DOCKER_FOR(안내 문구에 넣을 단계 이름).
# 결과: HOST_DOCKER_RUN=direct|sg. 쓸 수 없으면 HOST_DOCKER_SKIP(원인)·
# HOST_DOCKER_FIX(조치)를 남기고 1 을 돌려준다. 단계별 WARN 은 부른 쪽이
# 출력한다(mssql_skip, ollama_skip).
#---------------------------------------------------------------------
HOST_DOCKER_RUN="" HOST_DOCKER_SKIP="" HOST_DOCKER_FIX="" HOST_DOCKER_FOR=""
MSSQL_RUN="" MSSQL_SKIP="" MSSQL_FIX=""
OLLAMA_RUN="" OLLAMA_SKIP="" OLLAMA_FIX=""

host_docker_unusable() {
    HOST_DOCKER_SKIP="$1" HOST_DOCKER_FIX="$2"
    return 1
}

# 70-mssql 은 건너뛰지 않고 컨테이너에서 빌드한다. 빠지는 것은 FTS 포함 확인뿐이다.
mssql_skip() {
    MSSQL_SKIP="$1" MSSQL_FIX="$2"
    echo "WARN 호스트에서 70-mssql 을 빌드할 수 없어 빌드 컨테이너에서 빌드한다. 이미지의 FTS 포함 확인만 건너뛴다." >&2
    echo "     원인: ${MSSQL_SKIP}" >&2
    echo "     조치: ${MSSQL_FIX}" >&2
}

ollama_skip() {
    OLLAMA_SKIP="$1" OLLAMA_FIX="$2"
    echo "WARN 호스트 Docker 를 쓸 수 없어 85-ollama-embedding 을 건너뛴다. 나머지 단계는 계속한다." >&2
    echo "     원인: ${OLLAMA_SKIP}" >&2
    echo "     조치: ${OLLAMA_FIX}" >&2
}

prepare_host_docker() {
    local user err sudo_cmd=(sudo)
    # 플랫폼·docker 미설치 조치는 85 가 요청되면 85 요건(buildx 포함)을 안내한다.
    local fix_platform="Linux x86_64 + Docker 호스트에서 실행한다(70-mssql/README.md 4절)"
    local fix_docker="Docker Engine 을 설치한다(70-mssql/README.md 4절)"
    if [[ -n "$OLLAMA_MODE" ]]; then
        fix_platform="Linux x86_64 + Docker 호스트에서 실행한다(85-ollama-embedding/README.md D2)"
        fix_docker="Docker Engine + buildx 를 설치한다(85-ollama-embedding/README.md 3절)"
    fi
    user="$(id -un)"

    [[ "$(uname -s)/$(uname -m)" == Linux/x86_64 ]] \
        || { host_docker_unusable "Linux x86_64 빌드 호스트가 아니다(현재 $(uname -s)/$(uname -m))" \
                 "$fix_platform"; return 1; }
    command -v docker >/dev/null 2>&1 \
        || { host_docker_unusable "이 호스트에 docker 명령이 없다(빌드 컨테이너가 아니라 호스트의 docker 를 쓴다)" \
                 "$fix_docker"; return 1; }

    if err="$(docker info 2>&1 >/dev/null)"; then
        HOST_DOCKER_RUN=direct
        echo "    docker 사용 가능 (계정 ${user})"
        return 0
    fi
    [[ "$err" == *"permission denied"* ]] \
        || { host_docker_unusable "docker 데몬에 접근할 수 없다: $(head -n 1 <<<"$err")" \
                 "sudo systemctl status docker 로 데몬 상태를 확인하고 시작한다"; return 1; }
    getent group docker >/dev/null 2>&1 \
        || { host_docker_unusable "docker 소켓 권한이 없고 이 호스트에 docker 그룹이 없다" \
                 "ls -l /var/run/docker.sock 으로 소켓 소유 그룹을 확인한다"; return 1; }
    [[ " $(id -nG) " != *" docker "* ]] \
        || { host_docker_unusable "docker 그룹으로 실행 중인데도 소켓 권한이 거부됐다: $(head -n 1 <<<"$err")" \
                 "ls -l /var/run/docker.sock 으로 소켓 소유 그룹이 docker 인지 확인한다"; return 1; }

    if [[ " $(id -nG "$user") " == *" docker "* ]]; then
        echo "    ${user} 는 docker 그룹 회원이지만 이 세션에는 그룹이 없다(그룹 추가 전에 연 셸이나 tmux)."
        echo "    다시 로그인하지 않아도 되도록 이번 빌드는 sg docker 로 실행한다. 바꾸는 것은 없다."
    else
        echo "    ${user} 는 docker 그룹이 아니다. ${HOST_DOCKER_FOR} 빌드를 위해 다음을 실행한다:"
        echo "      sudo usermod -aG docker ${user}"
        echo "    주의: docker 그룹은 root 와 같은 권한이다(컨테이너로 호스트 파일시스템을 마운트할 수 있다)."
        echo "    되돌리기: sudo gpasswd -d ${user} docker"
        [[ -t 0 ]] || sudo_cmd=(sudo -n)
        "${sudo_cmd[@]}" usermod -aG docker "$user" \
            || { host_docker_unusable "${user} 를 docker 그룹에 추가하지 못했다(sudo 불가: 비밀번호 필요 또는 권한 없음)" \
                     "관리자가 sudo usermod -aG docker ${user} 를 실행한 뒤 다시 실행한다"; return 1; }
        echo "    추가했다. 이미 열린 셸과 tmux 에는 다시 로그인해야 반영된다. 이번 빌드는 sg docker 로 실행한다."
    fi

    command -v sg >/dev/null 2>&1 \
        || { host_docker_unusable "sg 명령이 없어 docker 그룹으로 실행할 수 없다" \
                 "다시 로그인한 뒤(tmux 는 tmux kill-server 후) 다시 실행한다"; return 1; }
    err="$(sg docker -c 'docker info' 2>&1 >/dev/null)" \
        || { host_docker_unusable "sg docker 로도 docker 에 접근하지 못했다: $(head -n 1 <<<"$err")" \
                 "id -nG ${user} 에 docker 가 있는지, 다시 로그인한 셸에서 docker info 가 되는지 확인한다"; return 1; }
    HOST_DOCKER_RUN=sg
    echo "    sg docker 로 docker 사용 가능"
}

# 컨테이너 단계의 결과(rc)를 받아, 요청됐으면 70-mssql, 85-ollama-embedding 순서로
# 호스트 Docker 로 빌드하고 종료한다. 컨테이너 단계가 실패해도 둘은 빌드한다
# (RUNNER 와 같은 방식).
# 종료 코드: 컨테이너 단계 rc 가 0 이 아니면 그 값. 아니면 70 이나 85 실패 시 1,
# 85 를 건너뛰었으면 직접 지정한 경우만 1(산출물이 없으므로), all 이면 0.
# 70 을 컨테이너에서 빌드했으면(호스트 Docker 사용 불가) 컨테이너 rc 에 이미 들어 있다.
finish() {
    local rc="$1" mrc=0 orc=0
    [[ -n "$MSSQL_REQ" || -n "$OLLAMA_MODE" ]] || exit "$rc"
    if [[ -n "$MSSQL_REQ" ]]; then
        echo
        echo "================ 70-mssql (호스트 Docker) ================"
        case "$MSSQL_RUN" in
            direct)
                echo "    호스트에서 실행: build-bundle.sh"
                (cd "${REPO}/70-mssql" && ./build-bundle.sh) || mrc=$?
                ;;
            sg)
                echo "    호스트에서 실행: sg docker -c 'build-bundle.sh'"
                sg docker -c "$(printf 'cd %q && ./build-bundle.sh' "${REPO}/70-mssql")" || mrc=$?
                ;;
            *)
                echo "  [SKIP] 70-mssql FTS 포함 확인: ${MSSQL_SKIP}"
                echo "         조치: ${MSSQL_FIX}"
                echo "         70-mssql 번들은 빌드 컨테이너에서 빌드했다(결과는 위 컨테이너 출력)."
                ;;
        esac
        if [[ -n "$MSSQL_RUN" ]]; then
            if ((mrc == 0)); then echo "  [OK] 70-mssql"; else echo "  [FAIL] 70-mssql"; fi
        fi
    fi
    if [[ -n "$OLLAMA_MODE" ]]; then
        echo
        echo "================ 85-ollama-embedding (호스트 Docker) ================"
        case "$OLLAMA_RUN" in
            direct)
                echo "    호스트에서 실행: build-bundle.sh all (cpu + gpu)"
                (cd "${REPO}/85-ollama-embedding" && ./build-bundle.sh all) || orc=$?
                ;;
            sg)
                echo "    호스트에서 실행: sg docker -c 'build-bundle.sh all' (cpu + gpu)"
                sg docker -c "$(printf 'cd %q && ./build-bundle.sh all' "${REPO}/85-ollama-embedding")" || orc=$?
                ;;
            *)
                echo "  [SKIP] 85-ollama-embedding: ${OLLAMA_SKIP}"
                echo "         조치: ${OLLAMA_FIX}"
                [[ "$OLLAMA_MODE" == all ]] || orc=1
                ;;
        esac
        if [[ -n "$OLLAMA_RUN" ]]; then
            if ((orc == 0)); then echo "  [OK] 85-ollama-embedding"; else echo "  [FAIL] 85-ollama-embedding"; fi
        fi
    fi
    ((rc != 0 || (mrc == 0 && orc == 0))) || rc=1
    exit "$rc"
}

# 호스트 Docker 확인. 컨테이너 단계보다 먼저 한 번만 한다.
# 70-mssql 은 호스트에서 빌드할 수 있을 때만 컨테이너 단계에서 뺀다.
if [[ -n "$MSSQL_REQ" || -n "$OLLAMA_MODE" ]]; then
    label=""
    [[ -z "$MSSQL_REQ" ]] || label="70-mssql"
    [[ -z "$OLLAMA_MODE" ]] || label="${label:+${label}, }85-ollama-embedding"
    echo "=== ${label}: 호스트 Docker 확인 ==="

    # 호스트에서 70-mssql/build-bundle.sh 를 실행하면 skopeo 가 없을 때 sudo apt-get 으로
    # 설치하려 한다. 컨테이너 경로에서는 필요 없던 일이므로, 없으면 호스트로 보내지 않는다.
    # 플랫폼이 원인인 경우(macOS 등)는 prepare_host_docker 의 판정에 맡긴다.
    mssql_host=""
    if [[ -n "$MSSQL_REQ" ]]; then
        if [[ "$(uname -s)/$(uname -m)" == Linux/x86_64 ]] && ! command -v skopeo >/dev/null 2>&1; then
            mssql_skip "이 호스트에 skopeo 가 없다(호스트에서 빌드하면 70-mssql 이미지를 skopeo 로 받는다)" \
                "skopeo 를 설치한 뒤 다시 실행한다(예: sudo apt-get install skopeo, 70-mssql/README.md 4절)"
        else
            mssql_host=1
        fi
    fi

    HOST_DOCKER_FOR="${mssql_host:+70-mssql}"
    [[ -z "$OLLAMA_MODE" ]] || HOST_DOCKER_FOR="${HOST_DOCKER_FOR:+${HOST_DOCKER_FOR}, }85-ollama-embedding"
    if [[ -n "$HOST_DOCKER_FOR" ]]; then
        if prepare_host_docker; then
            if [[ -n "$mssql_host" ]]; then
                MSSQL_RUN="$HOST_DOCKER_RUN"
                rest=()
                for st in "${CTR_STAGES[@]}"; do
                    [[ "${st%/}" == 70-mssql ]] || rest+=("$st")
                done
                CTR_STAGES=(${rest[@]+"${rest[@]}"})
            fi
            [[ -z "$OLLAMA_MODE" ]] || OLLAMA_RUN="$HOST_DOCKER_RUN"
        else
            [[ -z "$mssql_host" ]] || mssql_skip "$HOST_DOCKER_SKIP" "$HOST_DOCKER_FIX"
            [[ -z "$OLLAMA_MODE" ]] || ollama_skip "$HOST_DOCKER_SKIP" "$HOST_DOCKER_FIX"
        fi
    fi
    echo
fi

# 45-redis 는 OS 패키지 번들이 아니라 amd64 Redis 이미지 하나만 받는다.
# Ubuntu 컨테이너가 필요 없으므로 호스트에서 직접 빌드해 rootless Podman 의
# user-namespace 재실행 제한을 우회한다.
if ((${#CTR_STAGES[@]} == 1)) && [[ "${CTR_STAGES[0]}" == "45-redis" ]]; then
    echo "Redis 빌드는 OS 독립적이므로 Podman 컨테이너 없이 호스트에서 실행합니다."
    rc=0
    (cd "${REPO}/45-redis" && ./build-bundle.sh) || rc=$?
    finish "$rc"
fi
((${#CTR_STAGES[@]} > 0)) || finish 0

echo "=== 빌드 환경 ==="
echo "  이미지 : ${IMAGE}"
echo "  저장소 : ${REPO}"
echo "  단계   : ${CTR_STAGES[*]}"
if [[ -n "$MSSQL_REQ" ]]; then
    if [[ -n "$MSSQL_RUN" ]]; then
        echo "  호스트 : 70-mssql (호스트 Docker, 컨테이너 단계 뒤에 실행)"
    else
        echo "  호스트 : 70-mssql 은 컨테이너에서 빌드 (FTS 포함 확인 건너뜀, 위 WARN 참고)"
    fi
fi
if [[ -n "$OLLAMA_MODE" ]]; then
    if [[ -n "$OLLAMA_RUN" ]]; then
        echo "  호스트 : 85-ollama-embedding (호스트 Docker, 컨테이너 단계 뒤에 실행)"
    else
        echo "  호스트 : 85-ollama-embedding (건너뜀, 위 WARN 참고)"
    fi
fi
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
    -e STAGES="${CTR_STAGES[*]}" \
    "$IMAGE" \
    bash -c "$RUNNER" || finish $?

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
    podman run --rm -v "${REPO}:/work:ro,z" "$IMAGE" bash -c "$VERIFY" || finish $?
fi

finish 0
