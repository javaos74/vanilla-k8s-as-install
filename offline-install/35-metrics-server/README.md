# 35-metrics-server — 로컬 Harbor 를 거친 Metrics Server 배포

UiPath Automation Suite 사전 점검(`uipathctl prereq run`)이 요구하는 Metrics Server 를
에어갭 클러스터에 배포한다. 이미지를 **로컬 Harbor(30-harbor)에 올리고 그 주소로**
배포한다. 에어갭에서는 매니페스트 기본 주소 `registry.k8s.io` 에 닿지 않는다.

Rocky Linux 9.8 에어갭 노드에서 Harbor push → 배포 → `kubectl top` 까지 **판정 8/8** 을 확인했다. public / private `uipath` 프로젝트 모두 검증했다(4절).

---

## 1. 이미지

| | 값 |
|---|---|
| 원본 | `registry.uipath.com/rancher/hardened-k8s-metrics-server:v0.9.0-build20260722` |
| 다이제스트 | `sha256:6f27f99a50ae8880846a24528a632a9419e0220ba93ad0519fff88ae7c43df8a` (linux/amd64 단일) |
| Harbor 주소 | `<HARBOR_HOSTNAME>/uipath/rancher/hardened-k8s-metrics-server:v0.9.0-build20260722` |

Harbor 에서는 UiPath AS 이미지를 seed 하는 **`uipath` 프로젝트**에 `registry.uipath.com` 의 경로를
그대로 둔다. `input.json` 의 `registries.docker.url` 이 `<harbor>/uipath` 이고
`uipathctl registry seed` 도 같은 규칙으로 올리므로, 레지스트리 경로가 하나로 맞춰진다.
프로젝트는 `METRICS_SERVER_HARBOR_PROJECT` 로 바꿀 수 있다.

`registry.uipath.com` 에는 `metrics-server/metrics-server` 경로가 없고 Rancher 하드닝
빌드만 있다(2026-10-18, 익명 토큰으로 조회). egress 를 `registry.uipath.com` 하나로 줄인
환경에서도 빌드할 수 있게 이것을 기본으로 했다.

업스트림 `registry.k8s.io/metrics-server/metrics-server:v0.9.0` 과 실행 명령(`/metrics-server`)은
같다. 이미지 기본 사용자가 없지만 매니페스트가 `runAsUser: 1000` / `runAsNonRoot: true` /
`readOnlyRootFilesystem: true` 를 지정한다. 업스트림을 쓰려면 `versions.env` 의
`METRICS_SERVER_SOURCE_IMAGE` / `_DIGEST` 를 바꾼다.

매니페스트는 저장소 루트 `metrics-server/components.yaml`(v0.9.0, `--kubelet-insecure-tls`
등 적용본)에서 이미지 줄만 `__METRICS_SERVER_IMAGE__` 로 바꾼 `conf/components.yaml.tmpl` 이다.

---

## 2. 빌드 / 설치

```bash
# 빌드 호스트(인터넷 O)
./00-common/build-in-container.sh 26.04 35-metrics-server
# 또는 cd 35-metrics-server && ./build-bundle.sh

# control plane (에어갭). 30-harbor 와 05-certs deploy-certs 이후.
tar xzf metrics-server-v0.9.0.tar.gz && cd metrics-server-v0.9.0
sudo HARBOR_PASSWORD='<Harbor admin 비밀번호>' ./install.sh
sudo ./install.sh --check-only
```

설치 순서:

1. Harbor 응답(`/api/v2.0/ping`)과 인증서 검증. CA 검증을 끄지 않는다.
2. 프로젝트(`uipath`) 확인. 없으면 public 으로 만든다. **private 이면** kube-system 에
   pull secret `harbor-uipath-pull` 을 만들어 `metrics-server` ServiceAccount 에 붙인다.
   pull 계정은 `HARBOR_PULL_USER`/`HARBOR_PULL_PASSWORD`(Harbor robot 계정 권장)이고,
   없으면 push 계정을 쓰며 경고한다. ServiceAccount 를 Deployment 보다 먼저 만든다
   (파드 생성 시점에 SA 의 imagePullSecrets 가 복사되기 때문). 매니페스트 자체는 원본과 같다.
3. `docker load` → `tag` → `login` → `push`. 저장소 이름에 `/` 가 있어 Harbor API 조회 시
   `rancher%252Fhardened-k8s-metrics-server` 처럼 두 번 인코딩한다. 자격증명은 임시 `DOCKER_CONFIG` 에만 쓰고 지운다.
4. `crictl pull` 로 **containerd(kubelet 경로)** 가 Harbor 에서 받는지 먼저 본다.
   여기서 실패하면 배포 전에 멈추고 05-certs 를 안내한다.
5. 매니페스트 적용 → rollout 대기 → 판정.

자격증명은 `HARBOR_USER`/`HARBOR_PASSWORD` 환경변수 → `site.env` 의 `HARBOR_ADMIN_PASSWORD`
→ (Harbor 와 같은 호스트면) `/opt/harbor/.harbor-credentials` 순서로 찾는다.

### 모든 노드가 Harbor 를 신뢰해야 한다

파드는 어느 노드에도 뜰 수 있다. worker 를 포함한 **모든 노드**가 `HARBOR_HOSTNAME` 을
해석하고(`/etc/hosts` 또는 사내 DNS) containerd 가 CA 를 신뢰해야 한다.

```bash
cd 05-certs && ./deploy-certs.sh --nodes 'cp-node,worker-01,worker-02'
```

---

## 3. 판정

```
Harbor 응답 / Harbor 에 이미지 있음(API)
Deployment metrics-server Available
파드 이미지가 Harbor 주소
파드가 Harbor 에서 받은 이미지로 실행 중(imageID 가 <harbor>/uipath/rancher/hardened-k8s-metrics-server@sha256:...)
APIService v1beta1.metrics.k8s.io Available
kubectl top nodes / kubectl top pods -A 응답
```

`imageID` 를 따로 보는 이유: 노드에 다른 경로로 미리 적재된 이미지로 떠도 `image` 필드는
Harbor 주소로 보인다. 실제로 Harbor 에서 받았는지는 `imageID` 로만 알 수 있다.

---

## 4. 검증 상태

2026-10-18, Rocky Linux 9.8 Azure 단일 노드(SELinux enforcing, `airgap-on.sh` 엄격 모드),
30-harbor(사내 CA, 26/26) 위에서.

| 항목 | 결과 |
|---|---|
| 원본 이미지 존재·다이제스트·아키텍처·실행 명령 | **확인** (crane) |
| 매니페스트 = `metrics-server/components.yaml` | **일치** (`diff` 결과 이미지 줄 1개만 다름) |
| 번들 빌드 | **완료** (21M, 태그 = 핀 일치) |
| `uipath` 프로젝트 없음 → public 으로 생성 → push → 배포 | **8/8**, `kubectl top nodes` 정상 |
| `uipath` 를 private 으로 전환 → 재설치 | **8/8**. pull secret `harbor-uipath-pull` 이 SA 와 파드에 붙음 |
| private 에서 kubelet 이 secret 으로 받는지 | **확인**. 노드 캐시를 지우고 파드를 다시 띄워 `Pulling` → `Successfully pulled`. 자격증명 없는 `crictl pull` 은 실패 |
| push 계정 자격증명 잔존 | **없음** (임시 `DOCKER_CONFIG` 삭제, `/root/.docker` 의 auths 비어 있음) |
| 재부팅 후 | **8/8** |

Harbor 에 올라간 이미지의 다이제스트(`sha256:772eed79…`)는 원본(`sha256:6f27f99a…`)과 다르다.
`docker load` → `push` 가 매니페스트를 다시 만들기 때문이다(레이어는 같다). 판정은 태그와
Harbor 경로(`imageID`)로 본다.

---

## 5. 순서

```
10-k8s → 60-cilium → 05-certs → 50-nfs-csi → 30-harbor → [35-metrics-server] → ...
```
