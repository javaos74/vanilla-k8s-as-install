# Vanilla Kubernetes 클러스터

kubeadm 으로 구성한 바닐라 Kubernetes **v1.36.4** 와, 그 위에 UiPath Automation Suite
를 올리기 위한 인프라(MinIO · Harbor · HAProxy · NFS CSI · MSSQL · PostgreSQL) 구축 자료.

---

## 설치 경로가 두 가지다 — 먼저 고를 것

이 저장소에는 **서로 다른 두 개의 설치 경로**가 들어 있다. 섞어 쓰면 안 된다.

| | **온라인 설치 (이 폴더)** | **오프라인 설치 (`offline-install/`)** |
|---|---|---|
| 전제 | 노드가 인터넷에 접근 가능 | 노드가 인터넷에 접근 **불가**(에어갭) |
| 패키지 출처 | `download.docker.com`, `pkgs.k8s.io` apt 저장소를 노드에 등록해 직접 설치 | 온라인 빌드 호스트에서 만든 **번들(tar.gz)** 을 옮겨서 설치 |
| 컨테이너 이미지 | 노드가 레지스트리에서 pull | 번들의 tar 를 `ctr -n k8s.io images import` 로 적재 |
| 노드 구성 | control plane 1 + worker 3 | 단일 노드 / **다중 CP(HA)** / worker 추가 모두 지원 |
| CNI | Cilium 1.20.2 (매니페스트는 `offline-install/60-cilium/`) | Cilium 1.20.2 |
| 진입점 | `prep-node.sh` → `kubeadm init --config kubeadm-init.yaml` | `offline-install/10-k8s/build-bundle.sh` → `install.sh` |
| 검증 | 수동 | 단계별 판정 스크립트 + nftables 에어갭 강제 |

**이 폴더(저장소 루트)는 온라인 설치 기준이다.** 근거는 `prep-node.sh` 가 노드에
apt 저장소를 등록하고 인터넷에서 패키지를 받는다는 점이다.

```bash
# prep-node.sh — 노드가 인터넷에 나가야 동작한다
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o ...
echo "deb ... https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list
echo "deb ... https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/deb/ /"           > /etc/apt/sources.list.d/kubernetes.list
```

에어갭 환경이라면 이 폴더의 절차는 **첫 단계에서 실패한다.** `offline-install/` 를 볼 것.

아래 문서는 전부 온라인 설치로 구축한 실제 환경의 기록이다.

---

AWS `ap-northeast-2`, 프로파일 `uipath`, 계정 `<AWS_ACCOUNT_ID>`, VPC `<VPC_ID>` (172.31.0.0/16)
구축일 2026-09-16 / 클러스터명 `k8s` / Kubernetes **v1.36.4**

> 공개 저장소이므로 계정 번호, 리소스 ID, IP 주소는 `<PLACEHOLDER>` 형태로 치환되어 있다.
> 매니페스트를 그대로 적용하기 전에 `PLACEHOLDERS.md`의 목록을 자신의 환경 값으로 바꿀 것.
> 서버 호스트명도 고객 환경명을 제거하고 `k8s-cp` / `k8s-01~03` 으로 일반화했다.
> 설치 당시의 실행 로그(`init-cp.log`, `log-k8s-*.txt`, `join-k8s-*.txt`)는
> 재현에 쓸모가 없고 내부 호스트명만 남기므로 저장소에서 제외했다.

---

## 1. 서버 구성

| 서버 | Instance ID | 사설 IP | 퍼블릭 IP | 역할 |
|---|---|---|---|---|
| K8S-CP | `<CP_INSTANCE_ID>` | <CP_PRIVATE_IP> | **<CP_PUBLIC_IP>** (EIP) | control plane, SQL Server 2022 |
| K8S-01 | `<WORKER01_INSTANCE_ID>` | <WORKER01_PRIVATE_IP> | 동적 | worker |
| K8S-02 | `<WORKER02_INSTANCE_ID>` | <WORKER02_PRIVATE_IP> | 동적 | worker |
| K8S-03 | `<WORKER03_INSTANCE_ID>` | <WORKER03_PRIVATE_IP> | 동적 | worker |
| infra-01 | `<NFS_INSTANCE_ID>` | <NFS_PRIVATE_IP> | 동적 | NFS 서버 (`/data/nfs`) |

- 노드 4대: Ubuntu 22.04.5 LTS, m6i.2xlarge (8 vCPU / 31.5GB), 루트 EBS 128GB
- infra-01: Ubuntu 24.04.4 LTS, t3.2xlarge, 루트 150GB + 데이터 500GB (`<NFS_DATA_VOLUME_ID>`, `DeleteOnTermination: false`)
- SSH: `ssh -i ~/.ssh/charles-vanilla.pem ubuntu@<IP>`
- **사설 IP는 stop/start 후에도 유지됨.** 클러스터 설정 전체가 사설 IP 기준이라 재시작에 안전.

### Security Group `<SECURITY_GROUP_ID>` (charles-vanilla-security)

| 포트 | 소스 | 용도 |
|---|---|---|
| 전체 | 자기 참조 (`<SECURITY_GROUP_ID>`) | 클러스터 내부 통신 전체 (etcd, kubelet, VXLAN, NFS) |
| 22 | <ADMIN_IP_1>/32, <ADMIN_IP_2>/32 | SSH |
| 6443 | <ADMIN_IP_1>/32 | kubectl (`<SG_RULE_ID_6443>`) |
| 443, 2433, 5432 | 0.0.0.0/0 | 기존 규칙 (클러스터와 무관) |

자기 참조 규칙이 모든 프로토콜을 허용하므로 클러스터용 포트를 따로 열 필요가 없었다. **1433(SQL Server)은 외부에 열려 있지 않음** — VPC 내부에서만 접근 가능.

---

## 2. 설치 구성 요소

| 구성 요소 | 버전 | 비고 |
|---|---|---|
| kubeadm / kubelet / kubectl | 1.36.4-1.1 | `apt-mark hold` 적용 |
| containerd | 2.3.5 | Docker 저장소, `SystemdCgroup = true` |
| CNI: Cilium | 1.20.2 | vxlan(UDP 8472), Pod CIDR `10.244.0.0/16` |
| CSI: csi-driver-nfs | v4.13.4 | provisioner `nfs.csi.k8s.io` |
| external-snapshotter | v8.6.0 | CRD + snapshot-controller |
| metrics-server | v0.9.0 | `--kubelet-insecure-tls` 필요 |
| CoreDNS | 1.14.2 | hosts + template 커스터마이즈 |
| SQL Server | 2022 (16.0.4255.1) | CP에만, AMI 기본 포함 |

CNI 는 **Cilium 하나로 통일**했다. 초기 구축은 Flannel 로 했으나 오프라인 경로와
CNI 를 이원화할 이유가 없어 Flannel 매니페스트는 저장소에서 제거했다.
`kubeadm-init.yaml` 의 `podSubnet` 이 `offline-install` 의 `POD_CIDR` 과 같은
`10.244.0.0/16` 이므로 온라인 설치에서도 `offline-install/60-cilium/` 의
Helm values 를 그대로 쓸 수 있다(차이는 이미지를 pull 하는지 번들에서 적재하는지뿐).

### 네트워크 대역
- Pod CIDR `10.244.0.0/16` — VPC(172.31.0.0/16)와 충돌 회피 목적으로 선택
- Service CIDR `10.96.0.0/12`
- 노드별 podCIDR: cp `10.244.0.0/24`, 03 `10.244.1.0/24`, 02 `10.244.2.0/24`, 01 `10.244.3.0/24`

### StorageClass

| 이름 | reclaimPolicy | 비고 |
|---|---|---|
| `nfs-csi` | Delete | **기본 클래스** |
| `nfs-csi-retain` | Retain | PVC 삭제 후에도 데이터 보존 |

공통 파라미터: `server: <NFS_PRIVATE_IP>`, `share: /data/nfs`, `mountPermissions: "0777"`
mountOptions: `nfsvers=4.1, hard, timeo=600, retrans=2`
`allowVolumeExpansion: true` (단, NFS는 실제 용량 쿼터를 적용하지 않음 — PVC 용량 값은 사실상 라벨)

VolumeSnapshotClass: `csi-nfs-snapclass` (deletionPolicy Delete)

NFS export: `/data/nfs 172.31.0.0/16(rw,sync,no_subtree_check,no_root_squash)`

### CoreDNS 커스터마이즈

```
template IN A k8s.myrobots.co.kr {      # 와일드카드 *.k8s.myrobots.co.kr
   match "^.*\.k8s\.myrobots\.co\.kr\.$"
   answer "{{ .Name }} 60 IN A <NFS_PRIVATE_IP>"
   fallthrough
}
template IN AAAA k8s.myrobots.co.kr { ... }   # 권한 있는 NODATA
hosts {                                   # 개별 이름
   <NFS_PRIVATE_IP> k8s.myrobots.co.kr
   <NFS_PRIVATE_IP> minio.myrobots.co.kr
   ttl 60
   fallthrough
}
```

- `hosts`는 와일드카드 미지원 → `template` 플러그인 사용
- `fallthrough` 필수. 없으면 목록 외 모든 이름이 NXDOMAIN이 되어 클러스터 DNS 전체가 마비된다
- 정규식이 `k8s` 앞에 최소 1개 라벨을 요구 → apex는 `hosts`가 처리 (중복 없음)
- AAAA를 권한 있는 NODATA로 응답: 미처리 시 매 조회마다 외부 리졸버로 나가 지연 발생 + 내부 호스트명 유출
- **클러스터 내부 DNS 전용.** 노드 호스트 셸에서는 해석되지 않음

---

## 3. 접속 방법

| 위치 | 엔드포인트 | 컨텍스트 |
|---|---|---|
| iMac Studio | `https://<CP_PUBLIC_IP>:6443` | `k8s` |
| K8S-CP | `https://<CP_PRIVATE_IP>:6443` | `k8s` |
| infra-01 | `https://<CP_PRIVATE_IP>:6443` | `k8s` |

- 맥의 기존 컨텍스트(`charles-aks-admin`, `docker-desktop`, `kind-local`)는 보존. `kubectl config use-context`로 전환
- 전부 `cluster-admin` 권한. TLS 완전 검증(`insecure-skip-tls-verify` 미사용)
- 인증서 SAN: `k8s-cp`, `<CP_PRIVATE_IP>`, `<CP_PUBLIC_IP>`, `<CP_PUBLIC_DNS>`, `127.0.0.1`, `localhost`
- SAN에 `127.0.0.1`이 있으므로 SSH 터널도 가능: `ssh -L 6443:<CP_PRIVATE_IP>:6443 ubuntu@<CP_PUBLIC_IP>`
- 인증서 만료 2027-09-16 (발급 시점 기준 364일)

---

## 4. 중지 / 재시작 절차

**순서가 중요하다.** NFS 서버가 클라이언트보다 나중에 죽고 먼저 살아야 한다. StorageClass에 `hard` 옵션이 있어 서버가 먼저 사라지면 마운트를 가진 노드의 I/O가 무한 대기한다.

```
중지: 워커 01~03 (동시)  →  CP  →  infra-01
시작: infra-01  →  CP  →  워커 01~03
```

`drain` / `cordon`은 불필요 — 전체를 내리는 상황에서 파드를 다른 노드로 밀어내는 것은 무의미하다.

### 중지 전 권장 작업

```bash
# etcd 스냅샷 (단일 멤버라 보험 가치가 큼)
kubectl -n kube-system exec etcd-k8s-cp -- etcdctl \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  snapshot save /var/lib/etcd/etcd-snapshot-$(date +%Y%m%d-%H%M%S).db

# 무결성 검증
kubectl -n kube-system exec etcd-k8s-cp -- etcdutl \
  snapshot status <파일> --write-out=table
```

CP는 EC2 stop 전에 서비스를 정상 종료: `sudo systemctl stop mssql-server` → `sudo systemctl stop kubelet` → `sudo sync`
infra-01는: `sudo exportfs -ua` → `sudo systemctl stop nfs-server` → `sudo sync`

### 재시작 시 확인

`kubelet`, `containerd`(4대), `nfs-server`/`rpcbind`(infra-01), `mssql-server`(CP) 모두 `enabled`이므로 자동 복구된다.
infra-01의 `/data`는 fstab에 **UUID + `nofail`**로 등록되어 자동 마운트된다 (수동 마운트였다면 `/data/nfs`가 빈 디렉터리로 올라와 모든 PV가 깨졌을 것).
CP는 EIP 덕분에 주소가 그대로이므로 맥의 kubeconfig를 손댈 필요가 없다. 워커 3대와 infra-01는 퍼블릭 IP가 바뀌지만 클러스터 동작에는 영향이 없다(SSH 접속용으로만 쓰임).

---

## 5. 해결한 문제 (재발 시 참고)

| 증상 | 원인 | 조치 |
|---|---|---|
| `apt-get` exit 100, dpkg lock 점유 | `unattended-upgrades`와 경쟁 | `/etc/apt/apt.conf.d/99-lock-timeout`에 `DPkg::Lock::Timeout "900";` |
| PVC `Pending`, `mount.nfs: Operation not permitted` (exit 32) | **`noresvport` 옵션.** export에 `insecure`가 없어 서버가 비특권 포트를 거부. 컨테이너 문제로 보였으나 호스트에서도 동일하게 실패 | StorageClass에서 `noresvport` 제거. `mountOptions`는 불변 필드이므로 SC 삭제 후 재생성 필요 |
| prereq: `metrics not yet available for node ...` | metrics-server 미설치. kubeadm 바닐라는 기본 포함 안 함 | metrics-server 설치 + `--kubelet-insecure-tls` (kubeadm은 kubelet **serving** 인증서를 자체 서명하고 해당 CSR 자동 승인 컨트롤러도 없음) + `--kubelet-preferred-address-types=InternalIP` (노드 호스트명이 DNS에 없음) |
| EIP 연결 후 kubectl TLS 실패 | 인증서 SAN에 구 IP가 박혀 있음. kubeconfig 주소만 고쳐도 실패 | `apiserver.crt/key` 삭제 → `kubeadm init phase certs apiserver --config` → static pod 재시작. **`kubeadm-config` ConfigMap의 certSANs도 갱신 필수** (누락하면 이후 `certs renew` 시 SAN 소실) |

---

## 6. 미해결 / 주의사항

- **SQL Server `sa` 비밀번호 불명.** 계정 자체는 정상(오류 코드 `18456 State 8` = 비밀번호 불일치, 즉 존재+활성). AMI가 EULA만 수락한 상태로 빌드되어 비밀번호가 디스크에 없음 — `/var/opt/mssql/secrets/`에는 `machine-key`뿐, cloud-init user-data / bash history / systemd 환경변수 모두 비어 있음. 재설정: `sudo systemctl stop mssql-server && sudo /opt/mssql/bin/mssql-conf set-sa-password`
- **단일 컨트롤 플레인.** HA 아님. etcd도 단일 멤버 → 스냅샷 백업이 유일한 복구 수단
- **NFS 서버 단일 장애점.** infra-01가 죽으면 모든 PV가 멈춤. `Scheduled-for-Deletion: 2026-09-06` 태그가 여전히 붙어 있음 — 계속 사용하려면 정리 필요
- `mountPermissions: "0777"`은 권한이 넓다. 워크로드의 `fsGroup`이 정해지면 `0770` 등으로 축소 권장
- `Released` 상태 PV가 누적된다 (prereq의 `nfs-csi-retain` 사용분). PVC 삭제 후에도 PV와 `/data/nfs` 하위 디렉터리가 남음
- `*.k8s.myrobots.co.kr` 하위 이름을 나중에 클러스터 내부 Service로 옮기면, `template`이 `kubernetes` 플러그인보다 먼저 실행되어 계속 <NFS_PRIVATE_IP>으로 간다. 예외 처리 필요
- **비용**: 중지 중에도 EBS 총 1,162GB 과금. EIP는 인스턴스 중지 중에만 시간당 과금(실행 중엔 무료)
- 계정의 다른 EIP 3개(`<OTHER_EIP_1>`, `<OTHER_EIP_2>`, `<OTHER_EIP_3>`)는 **사용 중**이다 — 다른 VPC의 ENI에 연결됨. 재사용 금지

---

## 7. 파일 위치

로컬 `~/k8s-vanilla/`

```
prep-node.sh                    노드 준비 스크립트 (멱등, 노드 추가 시 재사용)
kubeadm-init.yaml               kubeadm ClusterConfiguration (certSANs 포함)
csi-nfs/                        csi-driver-nfs 매니페스트 + storageclass-nfs.yaml
                                + snapshotclass-nfs.yaml + snapshot/ (external-snapshotter)
metrics-server/components.yaml  metrics-server (kubeadm용으로 패치됨)
coredns/coredns-configmap.yaml  현재 Corefile
backups/etcd-snapshot-*.db      etcd 스냅샷
```

CP의 `~/csi-nfs/`에도 CSI 매니페스트가 복제되어 있다.
맥 kubeconfig 백업: `~/.kube/config.bak.*`

### 최신 etcd 스냅샷

`etcd-snapshot-20260917-015352.db` — 2,984 keys / revision 26594 / hash `2cc8d41a` / 20MB
보관 3중: 맥 `~/k8s-vanilla/backups/`, CP `/var/lib/etcd/`, infra-01 `/data/backups/`
(infra-01의 500GB 볼륨은 `DeleteOnTermination: false`이므로 인스턴스 종료 후에도 잔존)

---

## 8. 현재 상태

2026-09-17 01:55 KST 기준 **5대 전부 `stopped`**. CP의 EIP `<CP_PUBLIC_IP>`는 유지되어 재시작 후 즉시 접속 가능.
