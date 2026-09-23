# 10-k8s — Kubernetes 1.36.4 오프라인 설치 (control plane / worker)

Ubuntu 22.04 / 24.04 에어갭 환경에 kubeadm control plane 과 worker 를 구성한다.
같은 번들로 두 역할을 모두 설치하며, `--role` 로 구분한다.
helm · docker · podman 도 이 번들에서 함께 설치된다.

실측 결과는 다음과 같다.

| 대상 | 결과 |
|---|---|
| control plane (22.04 / 24.04) | 에어갭 설치 **판정 23/23 통과** |
| worker (24.04, `k8s-worker-01`) | 에어갭 조인 **판정 24/24 통과** |

---

## 1. 전제

| 항목 | 값 |
|---|---|
| 대상 OS | Ubuntu 22.04(jammy) 또는 24.04(noble), amd64 |
| 최소 사양 | 2 vCPU / 2GB (실검증 환경 4 vCPU / 7.8GB) |
| 빌드 호스트 | **설치 대상과 같은 OS**, 인터넷 연결 필요 |
| 권한 | 설치는 root(sudo) |

**빌드 호스트의 OS 가 타깃과 같아야 한다.** deb 의존성 해석이 "현재 설치되지 않은 것"
기준으로 이뤄지므로, 22.04 타깃 번들은 22.04 에서, 24.04 타깃 번들은 24.04 에서 빌드한다.
번들 이름에 코드네임이 박히므로(`k8s-1.36.4-jammy`, `k8s-1.36.4-noble`) 혼동을 막을 수 있다.

---

## 2. 번들 내용

번들 크기는 디렉터리 683MB / 아카이브 381MB 이다.

```
k8s-1.36.4-<codename>/
├── BUNDLE-INFO           빌드 시점·버전 요약
├── SHA256SUMS            44개 파일 체크섬
├── install.sh            설치 스크립트
├── 00-common/            versions.env + common.sh (자기완결)
├── 90-verify/            airgap-on.sh / airgap-off.sh
├── debs/                 deb 23개 (187MB)
├── images/               이미지 7개 (docker-archive tar)
├── bin/                  helm, podman-static(+서명)
└── conf/                 kubeadm-init.yaml, kubeadm-join.yaml, images.list,
                          pause-image, k8s-modules.conf, k8s-sysctl.conf
```

### 버전

| 구성요소 | 버전 | 출처 |
|---|---|---|
| kubeadm / kubelet / kubectl | 1.36.4-1.1 | pkgs.k8s.io v1.36 |
| cri-tools | 1.36.0-1.1 | 동일 |
| kubernetes-cni | 1.9.1-1.1 | 동일 (`/opt/cni/bin` 제공) |
| containerd.io | 2.3.5 | Docker 저장소 (containerd + ctr + shim + **runc 1.5.1**) |
| docker-ce / cli | 29.8.1 | Docker 저장소 |
| docker buildx / compose | 0.37.1 / 5.5.1 | Docker 저장소 |
| helm | v3.22.0 | get.helm.sh |
| podman | v5.8.7 | podman-static (정적 빌드) |

이미지 7개는 `kubeadm config images list` 로 얻은 것이다.

```
registry.k8s.io/kube-apiserver:v1.36.4
registry.k8s.io/kube-controller-manager:v1.36.4
registry.k8s.io/kube-scheduler:v1.36.4
registry.k8s.io/kube-proxy:v1.36.4
registry.k8s.io/coredns/coredns:v1.14.2
registry.k8s.io/pause:3.10.2
registry.k8s.io/etcd:3.6.8-0
```

---

## 3. 번들 빌드 (온라인 호스트)

```bash
cd offline-install/00-common
./verify-urls.sh          # 핀 URL 실존 확인. 실패하면 번들을 만들지 말 것

cd ../10-k8s
./build-bundle.sh
```

산출물은 `bundle/k8s-1.36.4-<codename>.tar.gz` 와 `.sha256` 이다.

빌드 스크립트가 빌드 호스트에 남기는 변경은 두 가지다. 둘 다 멱등이고 타깃에는 영향이 없다.

- `/etc/apt/sources.list.d/{kubernetes,docker}.list` + `/etc/apt/keyrings/` 서명키
- `skopeo` 설치 — 데몬 없이 레지스트리 이미지를 tar 로 받기 위한 빌드 도구

`kubeadm` 은 설치하지 않는다. deb 에서 `dpkg-deb -x` 로 바이너리만 꺼내
이미지 목록을 얻으므로 빌드 호스트가 오염되지 않는다.

#### 빌드 호스트는 같은 OS 이면서 **깨끗해야** 한다

같은 OS 여야 하는 것만으로는 부족하다. **대상 패키지가 이미 설치돼 있으면
번들에 구멍이 생긴다.**

`apt-get install --download-only` 는 명시한 패키지는 다시 받지만 **이미 설치된
전이 의존성은 받지 않는다**(apt 가 이미 충족된 것으로 보기 때문). 그래서 설치가
끝난 노드에서 번들을 다시 만들면 그 노드에 있는 만큼 빠진다.

실측으로 확인한 사례다. CP 로 쓰던 노드에서 다시 빌드했더니 이렇게 됐다.

```
deb 23개 (깨끗한 호스트)  ->  19개 (CP 로 쓰던 호스트)
누락: docker-ce-rootless-extras / libnfsidmap1 / pigz / rpcbind
```

이 번들로 깨끗한 타깃에 설치하면 `dpkg` 의존성 오류가 난다. 번들 크기도
381M → 371M 로 줄어 눈치채기 어렵다.

`build-bundle.sh` 가 이 상태를 감지해 중단한다.

```
WARN 빌드 호스트에 이미 설치된 대상 패키지가 있다: kubelet kubeadm ... nfs-common
WARN 이 상태로 빌드하면 **전이 의존성이 누락된 불완전한 번들**이 된다.
FATAL 깨끗한 호스트에서 빌드할 것.
```

의존성 폐쇄집합을 계산해 채우는 방식은 쓰지 않았다. `libc6` 같은 기반 패키지까지
끌어와 타깃에서 `dpkg -i` 로 기반 라이브러리를 교체할 위험이 있기 때문이다.
감지해서 멈추는 편이 안전하다.

정말 그 호스트에서 만들어야 하면 `--allow-dirty-host` 로 넘길 수 있지만,
번들 완전성을 직접 확인해야 한다.

---

## 4. 설치 (에어갭 타깃)

같은 번들로 두 역할을 설치한다. 공통 단계(커널·swap·sysctl / deb / containerd /
이미지 / 도구)는 동일하고 마지막 단계만 `kubeadm init` 이냐 `kubeadm join` 이냐로 갈린다.

| 역할 | 명령 | 결과 |
|---|---|---|
| control plane (첫 대, 단일) | `sudo ./install.sh` (기본값) | `kubeadm init`. CP 추가 불가 |
| control plane (첫 대, HA) | `sudo ./install.sh --control-plane-endpoint <LB>:6443` | `kubeadm init --upload-certs`. CP 추가 가능 |
| control plane (추가) | `sudo ./install.sh --role control-plane --join-command "..." --certificate-key <KEY>` | `kubeadm join --control-plane` |
| worker | `sudo ./install.sh --role worker --join-command "..."` | `kubeadm join` |

CP 를 여러 대 둘 계획이면 **첫 CP 부터** `--control-plane-endpoint` 를 줘야 한다.
나중에 붙이는 것은 사실상 재구축이다 — 이유는 4.1절.

```bash
# 1) 전송
scp bundle/k8s-1.36.4-noble.tar.gz{,.sha256} <타깃>:~/

# 2) 타깃에서 무결성 확인 후 전개
sha256sum -c k8s-1.36.4-noble.tar.gz.sha256
tar xzf k8s-1.36.4-noble.tar.gz && cd k8s-1.36.4-noble

# 3) (검증 목적이면) 에어갭 전환
sudo ./90-verify/airgap-on.sh

# 4) 설치 — control plane
sudo ./install.sh
```

`install.sh` 는 `SHA256SUMS` 를 먼저 검증하므로 전송 손상을 설치 전에 잡는다.

### 4.0 다중 control plane (HA)

CP 가 한 대면 그 노드가 죽는 순간 클러스터를 조작할 수 없다. 이미 돌고 있는
파드는 계속 돌지만 스케줄링·스케일·복구가 전부 멈춘다. CP 를 늘리는 것은
이 단일 장애점을 없애기 위한 것이다.

이 단계는 **stacked etcd** 구성이다. 각 CP 가 자기 안에 etcd 멤버를 하나씩
갖는다. etcd 를 별도 호스트에 두는 external etcd 구성은 다루지 않는다 —
운영 대상이 하나 더 늘고, AS 규모에서는 stacked 로 충분하다.

```
                    ┌──────────────────┐
   kubectl ────────>│  LB :6443        │  controlPlaneEndpoint
   kubelet ────────>│  (haproxy/F5)    │
                    └────┬────┬────┬───┘
                 ┌───────┘    │    └───────┐
            ┌────▼────┐  ┌────▼────┐  ┌────▼────┐
            │  CP-1   │  │  CP-2   │  │  CP-3   │
            │ apiserv │  │ apiserv │  │ apiserv │
            │ etcd ◄──┼──┼──► etcd ◄┼──┼──► etcd │   2379/2380
            └─────────┘  └─────────┘  └─────────┘
```

#### CP 는 홀수로 둔다

etcd 는 **과반**이 살아 있어야 쓰기가 된다. 짝수는 장애 허용 수를 늘리지 못하면서
관리 대상만 늘린다.

| CP 수 | 정족수 | 장애 허용 | 평가 |
|---|---|---|---|
| 1 | 1 | 0 | 단일 장애점 |
| 2 | 2 | **0** | 1대만 죽어도 쓰기 불가. 1대보다 나쁘다 |
| 3 | 2 | 1 | **권장** |
| 4 | 3 | 1 | 3대와 같다. 이득 없음 |
| 5 | 3 | 2 | 큰 클러스터 |

2대 구성이 1대보다 나쁜 이유는 단순하다. 정족수가 2인데 멤버가 2이므로
**어느 한 대가 죽어도 과반을 잃는다.** 게다가 고장 지점이 두 배다.
`install.sh` 는 CP 수가 짝수면 경고한다.

#### 4.0.1 LB 를 먼저 세운다

`controlPlaneEndpoint` 는 모든 CP 앞에 놓인 안정적인 주소다. 이 주소는
kubelet·컨트롤러·kubectl 이 모두 쓰므로 **CP 를 늘리거나 줄여도 바뀌지 않아야**
한다. 그래서 특정 CP 의 IP 를 쓰면 안 된다.

선택지는 세 가지다.

| 방법 | 장점 | 단점 |
|---|---|---|
| 사내 LB (F5, NSX-ALB, 클라우드 LB) | 이미 이중화됨. 운영 주체 분명 | 방화벽·요청 절차 |
| haproxy + keepalived VIP | 추가 장비 불필요 | 직접 운영해야 함 |
| DNS 이름 여러 A 레코드 | 간단 | 죽은 CP 로도 보낸다. 권장하지 않음 |

사내 LB 가 있으면 그것을 쓴다. `mode tcp` (L4 패스스루)여야 하고 **TLS 를
종료해서는 안 된다.** apiserver 는 클라이언트 인증서로 사용자를 식별하므로,
LB 가 TLS 를 끊으면 인증서가 apiserver 에 도달하지 못해 모든 요청이
`anonymous` 가 된다. 헬스체크는 `GET /healthz` 로 한다(TCP 연결만 보면
기동 중인 apiserver 를 정상으로 오판한다).

LB 가 없으면 이 번들의 스크립트로 세운다. 전용 호스트 또는 최소한 CP 가 아닌
노드에서 실행할 것.

```bash
# haproxy 이미지는 40-haproxy 번들의 것을 쓴다(중복 보관하지 않는다)
sudo ./apiserver-lb.sh --backends 10.0.0.11,10.0.0.12,10.0.0.13 \
      --image-tar <40-haproxy번들>/images/haproxy_3.4.4.tar

sudo ./apiserver-lb.sh --check-only
sudo ./apiserver-lb.sh --uninstall
```

CP 노드 자신에 LB 를 6443 으로 둘 수는 없다(apiserver 가 점유). 다른 포트로는
가능하지만 그 CP 가 죽으면 LB 도 같이 죽어 HA 의미가 크게 줄어든다.

이 스크립트는 LB **한 대**를 세운다. LB 가 단일 장애점이 되는 것을 막으려면
4.2절의 keepalived VIP 를 쓴다.

#### 4.0.2 첫 CP

```bash
sudo ./install.sh --control-plane-endpoint 10.0.0.10:6443 \
      --cert-san 10.0.0.12 --cert-san 10.0.0.13 \
      --cert-san k8s-api.example.internal
```

`--cert-san` 으로 나중에 쓸 주소를 미리 넣는다. apiserver 인증서의 SAN 은
발급 후에 추가하기 번거롭다(인증서 재발급 + 컴포넌트 재시작). 지금 넉넉히
넣는 편이 싸다.

`--control-plane-endpoint` 를 주면 `install.sh` 가 `kubeadm init` 에
`--upload-certs` 를 붙인다. CA 개인키 등이 `kube-system/kubeadm-certs`
Secret 에 암호화되어 올라가고, 추가 CP 가 그것을 내려받아 쓴다.

#### 4.0.3 추가 CP

첫 CP 에서 조인 정보를 발급한다.

```bash
# 첫 CP
sudo ./install.sh --print-join-command
```

worker 용과 CP 용 명령을 함께 출력한다. CP 용을 추가 CP 노드에서 실행한다.

```bash
# 추가 CP 노드
sudo ./install.sh --role control-plane \
      --join-command "kubeadm join 10.0.0.10:6443 --token ... \
                      --discovery-token-ca-cert-hash sha256:..." \
      --certificate-key <64자 hex>
```

`--role control-plane` 에 조인 정보가 함께 오면 추가 CP 로 판단한다. 모드를
따로 지정하지 않아도 되고 worker 조인과 인자 형태가 같다.

CP 를 붙인 뒤 **LB 백엔드에 그 노드를 추가**해야 한다. 잊으면 트래픽이 가지
않아 HA 가 성립하지 않는다.

```bash
sudo ./apiserver-lb.sh --backends 10.0.0.11,10.0.0.12   # 다시 실행하면 갱신된다
```

#### certificate-key 는 2시간이면 사라진다

`kubeadm-certs` Secret 에는 만료 시각이 붙어 있고 2시간 뒤 자동 삭제된다.
CA 개인키가 클러스터 안에 오래 남아 있는 것이 위험하기 때문이다.

만료 후 CP 를 추가하려면 인증서를 다시 올려 새 키를 받아야 한다.
`--print-join-command` 가 매번 이 작업을 한 뒤 키를 출력하므로, 그냥 다시
실행하면 된다.

```bash
sudo ./install.sh --print-join-command    # upload-certs 재실행 + 새 키 발급
```

이 키는 **클러스터 CA 개인키를 복호화할 수 있다.** 채팅·티켓에 남기지 말 것.

#### control-plane taint 는 유지된다

단일 노드에서는 `install.sh` 가 taint 를 제거해야 워크로드가 스케줄된다.
다중 노드에서는 반대로 **유지해야** 한다. CP 에 일반 워크로드가 섞이면 그
부하가 etcd 지연으로 이어지고, etcd 지연은 클러스터 전체의 응답성 문제가 된다.

기본 동작은 자동이다.

| 상황 | taint |
|---|---|
| 단일 CP (`--control-plane-endpoint` 없음) | 제거 |
| HA 첫 CP (`--control-plane-endpoint` 있음) | 유지 |
| 추가 CP | 유지 |

`--untaint` / `--keep-taint` 로 명시할 수 있다.

#### 4.0.4 CP 제거

```bash
# 빼낼 CP 에서
sudo ./install.sh --reset
# 남은 CP 에서
kubectl delete node <빼낸-노드>
```

`kubeadm reset` 은 API 에 닿을 수 있으면 **etcd 멤버를 스스로 제거한다.**
닿지 않는 상태에서 reset 하면 유령 멤버가 남아 남은 CP 들의 정족수 계산을
망친다. 3대에서 1대를 이렇게 잃으면 멤버는 3인데 살아 있는 것은 2 —
아직 과반이므로 버티지만, 한 대만 더 잃으면 쓰기가 멈춘다.

`install.sh --reset` 은 이 상황을 감지해 수동 제거 명령을 안내한다.

```bash
kubectl -n kube-system exec etcd-<살아있는CP> -- etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key member list
# ... member remove <ID>
```

LB 백엔드에서도 빼야 한다.

#### 4.0.6 검증 상태

2026-09-23 에 Ubuntu 24.04.4 노드 3대 + LB 1대로 에어갭 검증했다.

| 항목 | 결과 |
|---|---|
| 첫 CP (`--control-plane-endpoint`) | **28/28** |
| 추가 CP 2대 (`--certificate-key`) | **각 28/28** |
| apiserver LB (백엔드 3대) | **5/5** |
| etcd | 3멤버 · healthy 3 · 동일 raft index · 리더 1 |
| 번들 무결성(`verify_manifest`) | 49개 파일 통과 |
| 에어갭 유출 | `airgap-fwd-other = 0` |

`admin.conf` 가 LB 주소를 가리키는 것과 인증서 SAN 에 LB IP·`--cert-san` 값이
들어간 것을 확인했다.

**장애 시험 2종을 실제로 수행했다.**

apiserver 만 정지(CP 1대) — LB 가 다른 CP 로 넘긴다.

```
CP1 자기 6443: 죽음 / admin.conf 대상: https://<LB>:6443
kubectl get nodes  -> 3대 모두 반환
kubectl auth whoami -> X509SHA256=89f2e0e2...
```

`auth whoami` 가 클라이언트 인증서 기반 credential-id 를 돌려준 것이 중요하다.
LB 가 TLS 를 종료했다면 `anonymous` 가 됐을 것이므로, `mode tcp` 패스스루가
제대로 동작한다는 증거다. 전환에는 헬스체크 주기만큼(`fall 3` x `inter 3s` ≈ 9초)
걸려 첫 요청 1회가 실패할 수 있다.

**etcd 리더 노드를 통째로 정지** — 정족수 2/3 로 쓰기까지 유지된다.

```
configmap/quorum-test-... created          <- 쓰기 성공 (정족수 필요)
etcd: 2 healthy / 1 unhealthy(정지한 노드)
```

이 상태에서 `--check-only` 는 **실패를 정확히 잡는다**(판정이 형식적이지 않다).

```
OK   etcd 멤버 수 == CP 노드 수(3)
FAIL etcd 전 멤버 healthy
     etcd 멤버 3개 / healthy 2개
=== 검증 결과: 통과 27 / 실패 1 ===
```

CP 제거(`--reset`)도 검증했다. 2대 중 1대를 reset 하니 kubeadm 이 etcd 멤버를
스스로 제거해 목록이 2 → 1 로 줄었고, 새 `certificate-key` 를 발급받아 다시
조인하는 것까지 확인했다.

### 4.1 controlPlaneEndpoint 를 나중에 추가할 수 없는 이유

`kubeadm init` 을 `--control-plane-endpoint` 없이 하면 kubeadm 은 **그 노드의
IP 를 클러스터 곳곳에 직접 박는다.**

| 대상 | 박히는 값 |
|---|---|
| `/etc/kubernetes/*.conf` (admin·kubelet·controller-manager·scheduler) | `server: https://<그 CP IP>:6443` |
| `kube-system/kubeadm-config` ConfigMap | `controlPlaneEndpoint` 가 비어 있음 |
| `kube-public/cluster-info` ConfigMap | 조인하는 노드가 참조하는 주소 |
| apiserver 인증서 SAN | LB 주소가 없다 |

이 상태에서 CP 를 추가하면 새 CP 는 자기 kubeconfig 가 **첫 CP 만** 가리키므로
첫 CP 가 죽으면 같이 멈춘다. HA 가 아니다.

바로잡으려면 위 네 곳을 모두 고치고 apiserver 인증서를 재발급한 뒤 컴포넌트를
재시작해야 한다. 절차가 길고 중간에 틀리면 클러스터에 접속할 수 없게 된다.
**클러스터를 새로 만드는 편이 빠르고 안전하다.**

그래서 다음을 권한다.

> CP 를 늘릴 **가능성**이 있으면 처음부터 `--control-plane-endpoint` 를 준다.
> 지금 CP 가 한 대뿐이어도 LB 뒤에 한 대만 두면 된다. 나중에 CP 만 붙이면
> 클러스터를 건드리지 않고 HA 로 올라간다.

`install.sh --check-only` 는 `controlPlaneEndpoint` 가 없으면 경고한다.

### 4.2 LB 이중화 — keepalived VIP

`apiserver-lb.sh` 는 LB 한 대를 세운다. 그 한 대가 죽으면 CP 가 셋이어도
클러스터에 접속할 수 없다. LB 가 새로운 단일 장애점이 된 것이다.

사내 LB(F5 등)를 쓰면 이미 이중화되어 있으므로 이 절은 필요 없다.
직접 운영한다면 **VIP 를 두 대에 띄우고** 각 대에서 `apiserver-lb.sh` 를 실행한다.

```
        VIP 10.0.0.10  (keepalived 가 한쪽에만 붙인다)
         ↓ (MASTER 장애 시 BACKUP 으로 이동)
   ┌─────────────┐        ┌─────────────┐
   │ LB-1 MASTER │        │ LB-2 BACKUP │
   │ haproxy:6443│        │ haproxy:6443│
   └──────┬──────┘        └──────┬──────┘
          └────────┬─────────────┘
              CP-1 / CP-2 / CP-3 의 6443
```

`controlPlaneEndpoint` 는 VIP 주소로 둔다. keepalived 는 배포판 패키지
(`apt-get install keepalived`)이므로 에어갭에서는 deb 를 따로 준비해야 한다.
이 번들에는 포함하지 않았다 — LB 구성 방식이 사이트마다 달라 강제할 수 없다.

설정의 핵심만 적는다(`/etc/keepalived/keepalived.conf`).

```
vrrp_script chk_haproxy {
    # haproxy 가 죽으면 우선순위를 낮춰 VIP 를 넘긴다.
    # 이것이 없으면 LB 호스트는 살아 있고 haproxy 만 죽은 상태에서
    # VIP 를 계속 붙들어 트래픽이 블랙홀로 간다.
    script "/usr/bin/killall -0 haproxy"
    interval 2
    weight -20
}

vrrp_instance k8s_api {
    state MASTER          # 다른 대는 BACKUP
    interface eth0
    virtual_router_id 51  # 같은 L2 의 다른 VRRP 그룹과 겹치면 안 된다
    priority 101          # BACKUP 은 100
    authentication { auth_type PASS; auth_pass <공유암호> }
    virtual_ipaddress { 10.0.0.10/24 }
    track_script { chk_haproxy }
}
```

주의할 점 둘이다.

- **VRRP 는 멀티캐스트(224.0.0.18)를 쓴다.** 클라우드·가상화 환경에서 막혀 있는
  경우가 많다. 그때는 유니캐스트(`unicast_src_ip`/`unicast_peer`)로 바꾼다.
  Azure·AWS 처럼 VIP 자체를 허용하지 않는 환경이면 플랫폼 LB 를 쓰는 편이 맞다.
- `virtual_router_id` 가 같은 L2 의 다른 VRRP 그룹과 겹치면 서로를 잡아먹는다.

### 4.3 worker 추가

control plane 에서 조인 명령을 발급한다. 토큰 기본 수명은 24시간이다.

```bash
# control plane
sudo kubeadm token create --print-join-command
# -> kubeadm join 10.0.0.11:6443 --token abcdef.0123456789abcdef \
#      --discovery-token-ca-cert-hash sha256:1234...
```

출력을 worker 에서 그대로 넘긴다. 사람이 세 값을 옮겨 적다 틀리는 것을 막기 위해
`--join-command` 가 문자열을 직접 파싱한다.

```bash
# worker
sudo ./install.sh --role worker --join-command "kubeadm join 10.0.0.11:6443 \
    --token abcdef.0123456789abcdef \
    --discovery-token-ca-cert-hash sha256:1234..."

# 항목별로 주고 싶다면
sudo ./install.sh --role worker --api-server 10.0.0.11:6443 \
    --token abcdef.0123456789abcdef --ca-cert-hash sha256:1234...
```

**worker 는 `--role worker` 를 반드시 명시해야 한다.** 역할을 생략하면
control plane 으로 간주한다(기존 동작 유지). 그래야 인자를 빼먹었을 때
새 클러스터를 init 해버리는 사고를 막을 수 있다. 다만 이미 설치된 노드에서
`--check-only` / `--reset` 을 쓸 때는 파일로 역할을 자동 판별한다.

| 파일 | 판별 |
|---|---|
| `/etc/kubernetes/admin.conf` 있음 | control plane |
| `/etc/kubernetes/kubelet.conf` 만 있음 | worker |

조인 전에 `apiServerEndpoint` 로 TCP 연결을 먼저 시도한다. 여기서 막히면 kubeadm 이
수십 초 기다린 뒤 불친절한 오류를 내므로, 방화벽/NSG 문제를 즉시 알려주는 편이 낫다.

worker 도 `kubeadm join` 만으로는 `NotReady` 다. CNI 파드와 CSI 파드가 그 노드에
배치되어야 하는데, 에어갭에서는 이미지를 받아올 수 없다. 그래서 **각 번들의
`--role worker` 모드로 이미지를 미리 적재**한다.

```bash
# worker 에서, 조인 후
cd ~/deploy-cilium/cilium-1.20.2 && sudo ./install.sh --role worker   # 이미지만 적재
cd ~/deploy-nfs/nfs-csi-v4.13.4  && sudo ./install.sh --role worker   # nfs-common + 이미지
```

helm 설치나 매니페스트 적용은 control plane 에서 한 번만 한다. Cilium 과
csi-nfs-node 는 DaemonSet 이므로 조인한 노드로 자동 확장된다. worker 에서 helm 을
다시 돌리면 같은 릴리스를 두 곳에서 관리하게 되어 위험하다.

worker 를 떼어낼 때는 양쪽을 모두 정리해야 한다.

```bash
# worker
sudo ./install.sh --reset
# control plane
kubectl delete node <worker-name>
```

`node-role.kubernetes.io/worker` 라벨은 kubeadm 이 붙이지 않는다. 표시용으로
원하면 control plane 에서 직접 붙인다(NodeRestriction 때문에 kubelet 은 자기
노드에 role 라벨을 붙일 수 없다).

```bash
kubectl label node <worker-name> node-role.kubernetes.io/worker=
```

### 옵션

```bash
sudo ./install.sh --check-only   # 설치하지 않고 현재 상태만 판정(역할 자동 판별)
sudo ./install.sh --reset        # kubeadm reset + 설정 정리 (패키지는 유지)
sudo ./install.sh --help         # 사용법
```

`install.sh` 는 멱등이다. 이미 초기화된 클러스터가 있으면 `kubeadm init` 을,
이미 조인된 노드면 `kubeadm join` 을 건너뛴다.

### 설치 단계

1. 번들 무결성 검증, 에어갭 여부 확인
2. 커널 모듈(`overlay`, `br_netfilter`), sysctl, swap 비활성(+fstab 주석)
3. deb 23개 설치 → `kubelet/kubeadm/kubectl/containerd.io` **apt-mark hold**
4. containerd 설정 (아래 4.1)
5. 이미지 7개를 **`k8s.io` 네임스페이스로** 적재 후 목록 대조
6. helm / podman 설치
7. **control plane**: `kubeadm init --config conf/kubeadm-init.yaml`
   **worker**: `kubeadm join --config conf/kubeadm-join.yaml`
8. control plane 만: kubeconfig 배치, control-plane taint 제거
9. 판정 — control plane 23항목 / worker 24항목

worker 에도 docker·helm·podman 이 함께 설치된다. deb 세트를 역할별로 나누지 않고
하나로 유지하기 때문이다. worker 에서 쓰지는 않지만 해롭지도 않으며, 두 노드의
런타임 조합을 동일하게 유지하는 이점이 있다.

### 4.4 containerd 설정에서 반드시 맞춰야 하는 3가지

`containerd config default` 로 생성한 뒤 아래 3개를 고친다. 하나라도 틀리면 증상이 제각각이다.

| 항목 | 값 | 틀리면 |
|---|---|---|
| `SystemdCgroup` | `true` | kubelet 은 뜨지만 파드가 무작위로 재시작된다. kubelet `cgroupDriver: systemd` 와 반드시 일치해야 한다 |
| `pinned_images.sandbox` | `registry.k8s.io/pause:3.10.2` | 파드가 sandbox 생성 단계에서 실패한다 |
| `BinaryName` | `/usr/bin/runc` | **아래 참고** |

`BinaryName` 기본값은 빈 문자열이고, 이때 containerd 는 PATH 에서 `runc` 를 찾는다.
그런데 podman-static 이 `/usr/local/bin/runc`(1.4.3)를 함께 설치하고
`/usr/local/bin` 이 `/usr/bin` 보다 PATH 앞에 온다. 고정하지 않으면 containerd 가
containerd.io 의 `/usr/bin/runc`(1.5.1) 대신 podman 쪽 1.4.3 을 쓰게 된다.
containerd 2.3.5 가 검증한 조합이 1.5.1 이므로 절대경로로 박아둔다.

이 문제는 조용히 발생한다. `runc --version` 은 1.4.3 을 보여주지만 클러스터는 정상 동작하므로,
알아채지 못한 채 검증되지 않은 조합으로 운영하게 된다.

---

## 5. 설치 직후 상태 — 노드가 NotReady 인 것이 정상

```
NAME    STATUS     ROLES           VERSION   CONTAINER-RUNTIME
<node>  NotReady   control-plane   v1.36.4   containerd://2.3.5

coredns-xxx   0/1   Pending
coredns-yyy   0/1   Pending
etcd-<node>                      1/1   Running
kube-apiserver-<node>            1/1   Running
kube-controller-manager-<node>   1/1   Running
kube-proxy-xxx                   1/1   Running
kube-scheduler-<node>            1/1   Running
```

CNI 가 없으므로 노드는 `NotReady`, CoreDNS 는 `Pending` 이다.
**`60-cilium` 을 적용하면 Ready 로 전환된다.** 이 단계에서 CoreDNS 가 Pending 인 것을
장애로 오인하지 말 것.

### 5.1 worker 조인 후 상태

worker 도 조인 직후에는 `NotReady` 다. 이유가 control plane 과 같다 — 그 노드에
CNI 파드가 올라오지 않았다. worker 판정은 이 사실을 실패로 처리하지 않고 정보로만
출력한다.

```
[OK] 조인 완료(kubelet.conf 존재)
[OK] 클러스터 CA 존재(pki/ca.crt)
[OK] control plane 산출물 없음(worker 로 올바르게 설치됨)
     apiserver 엔드포인트: https://10.0.0.11:6443
[OK] apiserver 응답(/healthz)
[OK] 자기 노드가 API 에 등록됨
     참고: 노드 k8s-worker-01 Ready=False
       이 노드에 CNI 파드가 올라오기 전에는 NotReady 가 정상이다.
```

worker 에는 `admin.conf` 가 없으므로 판정이 `kubelet.conf` 를 kubeconfig 로 쓴다.
kubelet 의 사용자(`system:node:<이름>`)는 **자기 노드 객체만** 읽을 수 있고,
`/healthz` 는 `system:public-info-viewer` 로 인증된 사용자 전체에 열려 있다.
그래서 이 두 가지는 worker 에서도 확인할 수 있다. 전체 클러스터 상태(다른 노드,
DaemonSet 등)는 권한 밖이므로 control plane 에서 본다.

`60-cilium --role worker` 까지 실행하면 다음과 같이 된다.

```
NAME                     STATUS   ROLES           VERSION   INTERNAL-IP
k8s-cp-noble   Ready    control-plane   v1.36.4   10.0.0.11
k8s-worker-01     Ready    worker          v1.36.4   10.0.0.13

cilium         desired=2  ready=2
csi-nfs-node   desired=2  ready=2
kube-proxy     desired=2  ready=2
```

노드 간 데이터 경로도 확인했다. Cilium 이 각 노드에 `/24` 를 나눠주고
(`10.244.0.0/24`, `10.244.1.0/24`) 상호 도달을 보고한다.

```
Cluster health:  2/2 reachable
```

---

## 6. 오프라인 설치가 진짜였는지 확인하는 방법

`airgap-on.sh` 가 만든 nftables 카운터가 증거다.

```bash
sudo nft list table inet airgap | grep counter
```

카운터는 **소음(noise)** 과 **신호(other)** 로 나뉘어 있다. 판정 기준이 서로 다르기 때문이다.

| 카운터 | 의미 | 기대값 |
|---|---|---|
| `airgap-fwd-other` | 파드·컨테이너가 인터넷으로 나가려 한 횟수 | **0** ← 판정 기준 |
| `airgap-out-other` | 호스트가 인터넷으로 나가려 한 횟수 | 소수(스크립트 자체 프로브 등) |
| `airgap-fwd-noise` | 파드의 DNS/NTP/Azure 플랫폼 접근 | 0 이 아님 (정상) |
| `airgap-out-noise` | 호스트의 DNS/NTP/Azure 플랫폼 접근 | 0 이 아님 (정상) |

**`airgap-fwd-other` 가 0 이어야 한다.** 0 이 아니면 파드가 번들에 없는 이미지를
인터넷에서 받으려 한 것이다. `airgap-off.sh` 가 해제 시 이 판정을 자동 출력한다.

소음 카운터가 계속 증가하는 것은 정상이다. Azure 플랫폼 주소 `168.63.129.16` 은 공인
대역이라 차단되는데, 이 주소가 DNS 와 WireServer(walinuxagent 상태 보고)를 겸한다.
따라서 `systemd-resolved` 와 `walinuxagent` 가 끝없이 재시도한다. 설치와 무관하다.
온프레미스에서는 `airgap-on.sh` 의 `PLATFORM_V4` 를 관리망 주소로 바꾸거나 지우면 된다.

측정으로 확인한 값이다.

| 모드 | 소음 증가 | 이름 해석 | 인터넷 연결 |
|---|---|---|---|
| 엄격 (`airgap-on.sh`) | 약 54건 / 10초 | 실패 | 차단 |
| `--allow-dns` | 약 1건 / 10초 | 성공 | 차단 |

DNS 차단으로 인한 소음이 거슬리면 `--allow-dns` 를 쓴다. 이름은 해석되지만
연결은 여전히 차단되므로(실측: `github.com` → `20.200.245.247` 해석 성공, HTTP 000)
에어갭 검증의 엄격성은 유지된다.

---

## 7. 트러블슈팅

| 증상 | 원인 | 조치 |
|---|---|---|
| `Version '29.8.1-1~ubuntu...' for 'docker-ce' was not found` | `docker-ce`/`docker-ce-cli` 의 apt 버전에는 **epoch `5:`** 가 붙는다. deb 파일명에는 없다 | `versions.env` 의 `DOCKER_DEB_EPOCH` 확인. `apt-cache madison docker-ce` 로 실제 문자열 대조 |
| deb 일부만 받아짐 | `apt-get download` 는 인자 중 하나만 실패해도 **전체를 중단**한다 | 빌드 스크립트가 패키지별로 호출하고 실패 목록을 보고한다. 보고된 패키지의 버전을 `apt-cache madison` 으로 확인 |
| `ctr images ls` 에는 보이는데 파드는 ImagePullBackOff | 이미지를 기본 네임스페이스에 적재했다 | `ctr -n k8s.io images import` 여야 한다. kubelet 은 `k8s.io` 네임스페이스만 본다 |
| `control plane 파드 4종 Running` 판정 실패 | init 직후 static 파드가 아직 API 에 등록되지 않았다 | 판정에 120초 대기가 들어 있다. 계속 실패하면 `journalctl -u kubelet` 확인 |
| `podman: command not found` | tarball 최상위가 `podman-linux-amd64/` 라 `-C /` 로 바로 풀면 `/podman-linux-amd64` 가 생긴다 | 임시 디렉터리에 푼 뒤 `usr/`·`etc/` 만 옮긴다(스크립트가 처리) |
| deb 의존성 해결 실패 | 번들이 다른 OS 용이다 | `BUNDLE-INFO` 의 `target_os` 와 `/etc/os-release` 대조 |
| `apt-get` exit 100 (dpkg lock) | `unattended-upgrades` 와 경쟁 | 스크립트가 `DPkg::Lock::Timeout=900` 을 준다 |
| `적재되지 않은 이미지: ...` 인데 `ctr -n k8s.io images ls` 에는 보인다 | `ctr images ls -q \| grep -q` 의 오탐. grep 이 첫 일치에서 끝나 ctr 이 SIGPIPE(141)로 죽고 `pipefail` 이 파이프라인을 실패로 판정한다 | 고쳤다. `common.sh` 의 `ctr_missing_images()` 사용. 목록 앞쪽 이미지에서만 간헐 발생한다 |
| worker 에서 `조인 정보가 부족하다` | `--role worker` 만 주고 토큰을 안 넘겼다 | control plane 에서 `kubeadm token create --print-join-command` 출력을 `--join-command` 로 넘긴다 |
| `couldn't validate the identity of the API Server` | 토큰이 만료됐다(기본 24시간) | control plane 에서 토큰을 새로 발급한다 |
| worker 가 계속 `NotReady` | 그 노드에 CNI 이미지가 없어 cilium 파드가 `ImagePullBackOff` | worker 에서 `60-cilium/install.sh --role worker` 실행 |
| worker 의 PVC 파드가 `ContainerCreating` 에서 멈춤 | 그 노드에 `nfs-common` 또는 CSI 이미지가 없다 | worker 에서 `50-nfs-csi/install.sh --role worker` 실행 |
| worker 재조인이 실패한다 | control plane 에 옛 노드 객체가 남아 있다 | `kubectl delete node <name>` 후 worker 에서 `--reset` → 재조인 |
| CP 조인이 `error execution phase control-plane-prepare/download-certs` 로 실패 | `kubeadm-certs` Secret 이 만료됐다(2시간) | 첫 CP 에서 `./install.sh --print-join-command` 재실행해 새 키를 받는다 |
| `--certificate-key 형태가 잘못됐다` | 키가 잘려서 붙여졌다 | 32바이트 AES 키의 hex 이므로 정확히 64자여야 한다 |
| CP 조인이 etcd 단계에서 멈춘다 | CP 간 2379/2380 이 막혀 있다 | stacked etcd 는 CP 끼리 이 포트로 통신한다. 방화벽/NSG 확인 |
| CP 를 추가했는데 첫 CP 가 죽으면 같이 멈춘다 | `controlPlaneEndpoint` 없이 init 했다 | 4.1절. 사실상 재구축이 필요하다 |
| `kubectl` 이 `x509: certificate is valid for ..., not <LB주소>` | LB 주소가 apiserver 인증서 SAN 에 없다 | `--control-plane-endpoint` 를 주면 자동으로 들어간다. 이미 init 했다면 `--cert-san` 을 넣어 인증서 재발급 필요 |
| LB 는 살아 있는데 모든 요청이 권한 오류 | LB 가 TLS 를 종료했다(L7 모드) | apiserver 는 클라이언트 인증서로 사용자를 식별한다. `mode tcp` 패스스루여야 한다 |
| CP 1대를 reset 했더니 남은 CP 들이 쓰기 불가 | 유령 etcd 멤버가 남아 정족수를 잃었다 | 4.0.4절의 `etcdctl member remove` |
| `etcd 멤버 수 == CP 노드 수` 판정 실패 | 조인이 중간에 실패했거나 제거된 CP 의 멤버가 남았다 | `etcdctl member list` 로 대조 후 불필요한 멤버 제거 |

### 로그 위치

- `kubeadm init` : `/var/log/kubeadm-init.log`
- `kubeadm join` : `/var/log/kubeadm-join.log`
- kubelet : `journalctl -u kubelet`
- containerd : `journalctl -u containerd`
- containerd 원본 설정 백업 : `/etc/containerd/config.toml.orig`

---

## 8. 다음 단계

```
10-k8s  →  60-cilium  →  50-nfs-csi  →  40-haproxy  →  30-harbor  →  20-minio
```

CNI 가 없으면 아무 워크로드도 스케줄되지 않으므로 **60-cilium 을 먼저** 적용한다.
번호 순서가 아니라 위 순서를 따를 것.
