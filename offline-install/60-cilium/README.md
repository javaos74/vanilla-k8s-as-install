# 60-cilium — Cilium 1.20.2 CNI 오프라인 설치

`10-k8s` 로 만든 단일 노드 클러스터에 CNI 를 넣어 노드를 `Ready` 로 만든다.

양쪽 OS 에서 에어갭 설치를 수행해 **판정 9/9 통과**를 확인했다.
다중 CP(3-CP HA) 에서도 검증했다 — CP 3대 전부 Ready, CoreDNS Running,
추가 CP 에서 `--role worker` 이미지 적재 5/5, 에어갭 상태에서 파드 재기동 확인.
worker(24.04) 에서는 `--role worker` 로 이미지만 적재해 **판정 5/5 통과**,
노드 2대 모두 Ready(`cilium` DaemonSet 2/2, `Cluster health 2/2 reachable`)를 확인했다.

---

## 1. 전제와 구성 결정

`10-k8s` 가 먼저 설치되어 `kubeadm init` 이 끝난 상태여야 한다.
`/etc/kubernetes/admin.conf` 와 노드의 `spec.podCIDR` 이 있어야 한다.

| 항목 | 값 | 이유 |
|---|---|---|
| Cilium | 1.20.2 | 문서상 k8s 1.33~1.36 e2e 지원. 1.36 포함 |
| kube-proxy | **유지** | 대체하려면 `kubeadm init --skip-phases=addon/kube-proxy` 와 `k8sServiceHost/Port` 지정이 필요해 검증이 복잡해진다 |
| routingMode | `tunnel` / `vxlan` | 기존 운영 클러스터(Flannel VXLAN)와 네트워크 요구사항이 같다 (UDP 8472) |
| ipam.mode | `kubernetes` | kubeadm 이 노드에 할당한 `spec.podCIDR` 을 그대로 사용 |
| operator.replicas | **1** | 기본값 2 로 두면 단일 노드에서 operator 파드 하나가 영구 `Pending` |
| hubble | 비활성 | 관측성 기능. 인프라 검증에 불필요하고 이미지·메모리가 늘어난다 |
| envoy | 비활성 | L7 정책/Ingress 미사용. CLI 는 `disabled (using embedded mode)` 로 표시한다 |

이 번들은 **OS 에 의존하지 않는다.** 컨테이너 이미지 + helm 차트 + 정적 바이너리뿐이라
22.04 / 24.04 공용이다. `10-k8s` 처럼 OS 별로 번들을 나눌 필요가 없다.

---

## 2. 번들 내용

아카이브 348MB. 이미지 2개가 대부분을 차지한다.

```
cilium-1.20.2/
├── BUNDLE-INFO
├── SHA256SUMS            10개 파일
├── install.sh
├── 00-common/
├── chart/cilium-1.20.2.tgz
├── bin/cilium-linux-amd64.tar.gz     cilium-cli v0.20.0
├── images/
│   ├── quay.io_cilium_cilium_v1.20.2.tar            (699MB)
│   └── quay.io_cilium_operator-generic_v1.20.2.tar  (123MB)
└── conf/
    ├── values.yaml       설치 값 (위 표의 결정이 모두 여기 있다)
    └── images.list       렌더링으로 추출한 이미지 목록
```

### 이미지 목록을 손으로 관리하지 않는다

`build-bundle.sh` 는 `helm template` 으로 차트를 실제 렌더링한 뒤 `image:` 참조를 뽑아낸다.

```bash
helm template cilium chart/cilium-1.20.2.tgz -n kube-system -f conf/values.yaml \
  | grep -oE '^\s*image:\s*"?[^"]+"?$' | ...
```

값에 따라 필요한 이미지가 달라지기 때문이다. hubble 을 켜면 relay·UI 가, envoy 를 켜면
cilium-envoy 가 추가된다. 목록을 사람이 관리하면 반드시 누락이 생긴다.
현재 값에서는 **2개**로 확정된다.

---

## 3. 다이제스트 고정을 반드시 끌 것 (`useDigest: false`)

Cilium 차트의 기본값은 `useDigest: true` 이고, 이때 파드는 이렇게 이미지를 참조한다.

```
quay.io/cilium/cilium:v1.20.2@sha256:2939231d0d3e...
```

번들은 이미지를 `docker-archive` tar 로 옮기는데, **이 변환 과정에서 매니페스트가
재작성되어 원본 다이제스트가 보존되지 않는다.** 그 결과 다이제스트 참조가 로컬에 없는
것으로 판정되어 파드가 `ImagePullBackOff` 로 떨어진다. 에어갭이므로 받아올 곳도 없다.

`conf/values.yaml` 에서 `image.useDigest` 와 `operator.image.useDigest` 를 모두
`false` 로 둔다. 빌드 스크립트는 렌더링 결과에 `@sha256:` 이 남아 있으면 **빌드를 중단**한다.
값 파일을 고치다 이 설정을 놓치는 것을 막기 위한 장치다.

```
[FATAL] 다이제스트 참조가 남아 있다. values.yaml 의 useDigest 설정을 보완할 것.
```

---

## 4. 빌드와 설치

```bash
# 온라인 호스트
cd offline-install/60-cilium
./build-bundle.sh

# 에어갭 타깃
scp bundle/cilium-1.20.2.tar.gz{,.sha256} <타깃>:~/
tar xzf cilium-1.20.2.tar.gz && cd cilium-1.20.2
sudo ./install.sh
```

옵션은 `--check-only`(판정만), `--uninstall`(제거), `--role`(역할) 이다.
`install.sh` 는 멱등이며, 릴리스가 이미 있으면 `helm upgrade` 로 전환한다.

### worker 노드

```bash
# worker 에서 (10-k8s --role worker 로 조인이 끝난 뒤)
sudo ./install.sh --role worker          # 이미지만 적재
sudo ./install.sh --role worker --check-only
```

#### 추가 control plane 도 같은 방식으로 이미지를 적재해야 한다

`--role worker` 는 이름이 worker 지만 **하는 일은 "이미지만 적재"** 다. 다중 CP
클러스터의 2번째·3번째 CP 에도 그대로 써야 한다. DaemonSet 은 모든 노드에
파드를 띄우므로, 이미지가 없는 노드에서는 `ImagePullBackOff` 가 된다.

```bash
# 추가 CP 에서 (10-k8s 로 control plane 조인이 끝난 뒤)
sudo ./install.sh --role worker          # 이미지만 적재. helm 은 건드리지 않는다
```

빠뜨리면 그 노드가 인터넷에 나갈 수 있는 환경에서는 조용히 성공한다 —
레지스트리에서 직접 받아버리기 때문이다. 실제 에어갭에서만 드러나므로
검증 중에 놓치기 쉽다. 실측으로 확인한 함정이다.

```
# 적재하지 않은 노드에서 ctr 로 본 이미지 (다이제스트 형태 = 레지스트리 pull)
quay.io/cilium/cilium@sha256:2939231d...
# 번들로 적재한 노드 (태그 형태 = ctr images import)
quay.io/cilium/cilium:v1.20.2
```

worker 에서는 **helm 을 돌리지 않는다.** Cilium 은 DaemonSet 이라 control plane 에서
한 번 설치하면 조인한 노드에 자동으로 파드가 배치된다. worker 에서 helm 을 다시 돌리면
같은 릴리스를 두 곳에서 관리하게 되어 위험하다.

worker 에 필요한 것은 에어갭이라 받아올 수 없는 컨테이너 이미지를 containerd 에 미리
넣어두는 것뿐이다. 이미지가 없으면 cilium 파드가 `ImagePullBackOff` 로 떨어지고 그
노드는 영구 `NotReady` 가 된다.

판정 5항목이다. 앞 두 개는 이 스크립트가 한 일이고, 뒤 세 개는 control plane 의
DaemonSet 이 이 노드에 파드를 배치한 결과다.

```
조인 완료(kubelet.conf 존재)
cilium 이미지 적재(k8s.io 네임스페이스)
cilium CNI 설정 파일 생성됨(/etc/cni/net.d)
cilium-cni 플러그인 배치됨
이 노드가 Ready
```

역할을 생략하면 `admin.conf` 유무로 자동 판별한다. cilium-cli 는 worker 에 설치하지
않는다(kubeconfig 가 없어 쓸 수 없다).

`helm install` 에 `--wait` 를 주지 않는다. `--wait` 는 타임아웃 시 원인을 남기지 않고
롤백해버려서, 파드가 왜 뜨지 않는지 알 수 없게 된다. 대신 판정 단계에서 최대 180초
대기하며 상태를 확인한다.

---

## 5. 판정 9항목

```
helm 릴리스 cilium 존재
cilium DaemonSet 전부 Ready
cilium-operator Available
노드 Ready                        <- 이 단계의 목표
CoreDNS Running
CNI 설정 파일 생성됨(/etc/cni/net.d)
kube-proxy 유지됨(대체 안 함)
cilium status (cli 진단)
파드 기동 + 클러스터 DNS 해석      <- 실제 통신 검증
```

마지막 항목은 `pause` 파드를 띄워 `Ready` 가 되는지 본다. CNI 가 동작하지 않으면
여기서 반드시 실패한다. 파드 IP 가 Pod CIDR(`10.244.0.0/16`) 범위인지도 함께 출력한다.

실측값은 24.04 에서 `10.244.0.68`, 22.04 에서 `10.244.0.120` 이었다.

### 설치 후 정상 상태

```
NAME                       STATUS   ROLES           VERSION
k8s-cp-jammy   Ready    control-plane   v1.36.4

cilium-4xd2q                       1/1  Running
cilium-operator-ddbf85895-k2vnb    1/1  Running
coredns-589f44dc88-22678           1/1  Running
coredns-589f44dc88-vq2t6           1/1  Running
etcd-...                           1/1  Running
kube-apiserver-...                 1/1  Running
kube-controller-manager-...        1/1  Running
kube-proxy-d6swc                   1/1  Running
kube-scheduler-...                 1/1  Running
```

---

## 6. 오프라인이었음을 확인하는 방법

```bash
sudo nft list table inet airgap | grep counter
```

**`airgap-fwd-other` 가 0 이어야 한다.** 이 카운터는 파드가 DNS·NTP·플랫폼 주소가 아닌
곳으로 나가려 한 횟수다. 0 이 아니면 번들에 없는 이미지를 인터넷에서 받으려 한 것이다.

실측 결과(22.04, Cilium 설치 완료 직후):

```
airgap-out-noise = 1277      DNS/NTP/Azure 플랫폼 (정상)
airgap-out-other = 45        호스트 배경 트래픽 + 스크립트 자체 프로브
airgap-fwd-noise = 54        CoreDNS 상류 질의 (정상)
airgap-fwd-other = 0         <- 판정 통과
```

`airgap-fwd-noise` 가 0 이 아닌 것은 정상이다. CoreDNS 기본 Corefile 이
`forward . /etc/resolv.conf` 이므로 파드가 상류 공인 리졸버로 질의를 보내고 차단된다.

`airgap-off.sh` 가 해제 시 이 판정을 자동으로 출력한다.

---

## 7. 트러블슈팅

| 증상 | 원인 | 조치 |
|---|---|---|
| 파드 `ImagePullBackOff`, 참조에 `@sha256:` | `useDigest` 가 켜져 있다 | `conf/values.yaml` 확인. 다이제스트는 docker-archive 변환에서 보존되지 않는다 |
| `cilium-operator` 하나가 계속 `Pending` | `operator.replicas` 가 2다 | 단일 노드에서는 1로 |
| 노드에 `spec.podCIDR` 이 없다 | `kubeadm init` 에 `podSubnet` 이 빠졌다 | `install.sh` 가 사전에 잡아 중단한다. 10-k8s 의 `kubeadm-init.yaml` 확인 |
| `cilium status` 가 `dial tcp 127.0.0.1:8080: connection refused` | `KUBECONFIG` 없이 실행했다. CLI 가 기본 엔드포인트로 폴백한다 | `sudo KUBECONFIG=/etc/kubernetes/admin.conf cilium status` |
| `cilium status` 에 `Envoy DaemonSet: 1 errors` | `KUBECONFIG` 미지정 상태의 오탐 | 위와 같다. 정상 출력은 `disabled (using embedded mode)` |
| 제거 후 재설치가 엉킨다 | cilium 인터페이스·BPF 맵 잔여 | `--uninstall` 이 `cilium_host`/`cilium_net`/`cilium_vxlan` 과 BPF 맵을 정리한다 |
| `적재되지 않은 이미지: ...` 인데 `ctr -n k8s.io images ls` 에는 보인다 | `ctr images ls -q \| grep -q` 의 오탐. grep 이 첫 일치에서 끝나 ctr 이 SIGPIPE(141)로 죽고 `pipefail` 이 파이프라인을 실패로 판정한다 | 고쳤다. `common.sh` 의 `ctr_missing_images()` 사용. 목록 앞쪽 이미지에서만 간헐 발생한다 |

---

## 8. 다음 단계

```
10-k8s  →  [60-cilium]  →  50-nfs-csi  →  40-haproxy  →  30-harbor  →  20-minio
```

노드가 `Ready` 가 됐으므로 이제 워크로드를 스케줄할 수 있다.
다음은 `50-nfs-csi` 이며, NFS 서버는 `infra-01`(10.0.0.10)의 `/data/nfs` 를 쓴다.
