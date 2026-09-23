#!/usr/bin/env bash
# minio.myrobots.co.kr 테스트용 mc(mcli) 클라이언트 배포 (멱등)
#
#   - CA ConfigMap  : myubuntu:/opt/minio/certs/public.crt
#   - Secret        : myubuntu 의 minio 컨테이너 env(MINIO_ROOT_USER/PASSWORD)
#     자격증명은 로컬 디스크에 저장되지 않고 SSH -> kubectl 로 바로 전달된다.
set -euo pipefail

NS=minio-test
KEY="${KEY:-$HOME/.ssh/charles-vanilla.pem}"
MYUBUNTU="${MYUBUNTU:-<NFS_PUBLIC_IP>}"   # myubuntu 퍼블릭 IP (재시작 시 변동)
HERE="$(cd "$(dirname "$0")" && pwd)"

echo "==> namespace"
kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -

echo "==> CA 인증서 가져오기"
ssh -i "$KEY" -o StrictHostKeyChecking=accept-new "ubuntu@$MYUBUNTU" \
  'sudo cat /opt/minio/certs/public.crt' > "$HERE/minio-ca.crt"
openssl x509 -in "$HERE/minio-ca.crt" -noout -subject

echo "==> CA ConfigMap"
kubectl -n "$NS" create configmap minio-ca \
  --from-file="minio-ca.crt=$HERE/minio-ca.crt" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "==> 자격증명 Secret (값은 출력하지 않음)"
ssh -i "$KEY" "ubuntu@$MYUBUNTU" 'bash -s' <<'EOS' | kubectl apply -f -
set -euo pipefail
env_of() { sudo docker inspect minio --format "{{range .Config.Env}}{{println .}}{{end}}" \
             | grep "^$1=" | head -1 | cut -d= -f2-; }
U=$(env_of MINIO_ROOT_USER)
P=$(env_of MINIO_ROOT_PASSWORD)
[ -n "$U" ] && [ -n "$P" ] || { echo "credentials not found" >&2; exit 1; }
cat <<YAML
apiVersion: v1
kind: Secret
metadata:
  name: minio-creds
  namespace: minio-test
type: Opaque
stringData:
  username: "$U"
  password: "$P"
YAML
EOS

echo "==> Deployment"
kubectl apply -f "$HERE/mc-client.yaml"
kubectl -n "$NS" rollout status deploy/mc-client --timeout=120s

echo
echo "사용법:  kubectl -n $NS exec -it deploy/mc-client -- mcli ls minio"
