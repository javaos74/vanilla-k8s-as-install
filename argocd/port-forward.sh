#!/usr/bin/env bash
# ArgoCD UI 포트포워딩 (k8s 클러스터)
#
#   start : ./port-forward.sh          -> http://localhost:8080
#   stop  : ./port-forward.sh stop
#   status: ./port-forward.sh status
#
# argocd-server 는 server.insecure=true 로 떠 있어 8080 에서 평문 HTTP 를 제공한다.
# svc 의 80/443 둘 다 targetPort 8080 이므로 80 으로 포워딩하고 http 로 접속한다.
# 포워딩은 localhost 에만 바인딩되므로 외부에 노출되지 않는다.
set -uo pipefail

CTX=k8s
NS=argocd
LOCAL_PORT=8080
PIDFILE="$HOME/.argocd-portforward.pid"
LOGFILE="$HOME/.argocd-portforward.log"

running() { [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; }

case "${1:-start}" in
  stop)
    if running; then kill "$(cat "$PIDFILE")" && echo "중지됨"; else echo "실행 중이 아님"; fi
    rm -f "$PIDFILE"
    ;;
  status)
    if running; then
      echo "실행 중 (pid $(cat "$PIDFILE"))  ->  http://localhost:$LOCAL_PORT"
      curl -s -o /dev/null -w "  HTTP %{http_code}\n" --max-time 5 "http://localhost:$LOCAL_PORT/"
    else
      echo "실행 중이 아님"
    fi
    ;;
  start)
    running && { echo "이미 실행 중 (pid $(cat "$PIDFILE"))"; exit 0; }
    # 파드 재시작/네트워크 끊김에 대비해 죽으면 다시 붙는다
    nohup bash -c "
      while true; do
        kubectl --context $CTX -n $NS port-forward svc/argocd-server $LOCAL_PORT:80 >> '$LOGFILE' 2>&1
        echo \"[\$(date '+%F %T')] port-forward 종료 — 3초 후 재연결\" >> '$LOGFILE'
        sleep 3
      done
    " > /dev/null 2>&1 &
    echo $! > "$PIDFILE"
    sleep 4
    echo "시작됨 (pid $(cat "$PIDFILE"))  ->  http://localhost:$LOCAL_PORT"
    echo "로그: $LOGFILE"
    ;;
  *)
    echo "usage: $0 [start|stop|status]" >&2; exit 1
    ;;
esac
