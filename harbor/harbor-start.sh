#!/usr/bin/env bash
#---------------------------------------------------------------------
# Harbor 기동 스크립트 (systemd harbor.service 의 ExecStart)
#
# 왜 필요한가:
#   harbor-log 를 제외한 8개 컨테이너는 logging driver 가
#   syslog / tcp://localhost:1514 이고, 이 포트는 harbor-log 컨테이너가
#   제공한다. Docker 데몬의 restart:always 는 compose 의 depends_on 을
#   지키지 않고 부팅 시 9개를 동시에 기동하므로, harbor-log 가 1514 를
#   바인드하기 전에 나머지가 먼저 뜨면 컨테이너 생성 단계에서
#     failed to initialize logging driver:
#     dial tcp 127.0.0.1:1514: connect: connection refused
#   로 exit 128 하고, 재시도 백오프를 소진한 뒤 영구 정지한다.
#   (2026-09-22 실제 발생: 9개 중 8개 미기동 -> 443 리스너 없음
#    -> istio-ingressgateway ImagePullBackOff -> haproxy 백엔드 전멸)
#
#   compose 의 `depends_on: - log` 는 "컨테이너 시작"까지만 보장하고
#   포트 수신 준비를 기다리지 않으므로, 1514 대기를 여기서 명시한다.
#
# 설치 위치: /usr/local/bin/harbor-start.sh  (root:root 0755)
#---------------------------------------------------------------------
set -uo pipefail

COMPOSE_DIR=/opt/harbor
SYSLOG_HOST=127.0.0.1
SYSLOG_PORT=1514
WAIT_SYSLOG_SECS=60      # 1514 대기 상한
WAIT_READY_TRIES=90      # 전체 서비스 running 대기: 90 x 2s = 180s

log() { echo "[harbor-start] $*"; }

cd "$COMPOSE_DIR" || { log "FATAL: $COMPOSE_DIR 에 접근할 수 없음"; exit 1; }

#--- 1단계: syslog 수집기를 단독으로 먼저 기동 ------------------------
log "harbor-log 기동"
docker compose up -d log

#--- 2단계: 1514 가 실제로 연결을 받을 때까지 대기 --------------------
log "${SYSLOG_HOST}:${SYSLOG_PORT} 대기 (최대 ${WAIT_SYSLOG_SECS}s)"
syslog_ready=0
for ((i = 1; i <= WAIT_SYSLOG_SECS; i++)); do
    if timeout 1 bash -c ">/dev/tcp/${SYSLOG_HOST}/${SYSLOG_PORT}" 2>/dev/null; then
        log "${SYSLOG_PORT} 준비됨 (${i}s 경과)"
        syslog_ready=1
        break
    fi
    sleep 1
done
if ((syslog_ready == 0)); then
    log "FATAL: ${SYSLOG_PORT} 가 ${WAIT_SYSLOG_SECS}s 안에 열리지 않음. harbor-log 로그:"
    docker compose logs --tail 40 log 2>&1 || true
    exit 1
fi

#--- 3단계: 나머지 전체 기동 (compose depends_on 순서를 따른다) -------
log "나머지 서비스 기동"
docker compose up -d

#--- 4단계: 모든 서비스가 running 인지 확인 ---------------------------
mapfile -t services < <(docker compose config --services)
log "대상 서비스 ${#services[@]}개: ${services[*]}"

declare -a broken=()
for ((try = 1; try <= WAIT_READY_TRIES; try++)); do
    broken=()
    for svc in "${services[@]}"; do
        state=$(docker compose ps -a --format '{{.State}}' "$svc" 2>/dev/null | head -1)
        [[ "$state" == "running" ]] || broken+=("${svc}=${state:-missing}")
    done
    ((${#broken[@]} == 0)) && break
    sleep 2
done

if ((${#broken[@]} > 0)); then
    log "FATAL: running 상태가 아닌 서비스: ${broken[*]}"
    for entry in "${broken[@]}"; do
        svc=${entry%%=*}
        log "--- ${svc} 로그 ---"
        docker compose logs --tail 20 "$svc" 2>&1 || true
    done
    exit 1
fi

log "서비스 ${#services[@]}개 전부 running"

#--- 참고 정보: 외부 수신 포트 상태 (실패로 보지 않음) ----------------
if timeout 2 bash -c ">/dev/tcp/127.0.0.1/443" 2>/dev/null; then
    log "443 수신 정상"
else
    log "WARN: 443 이 아직 수신하지 않음 (proxy 헬스체크 진행 중일 수 있음)"
fi

log "완료"
