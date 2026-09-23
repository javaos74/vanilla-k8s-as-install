# 50-nfs-csi — NFS 서버 + csi-driver-nfs 오프라인 설치

k8s 노드에 NFS 동적 프로비저닝을 붙인다. 두 부분으로 나뉜다.

| 대상 | 스크립트 | 내용 |
|---|---|---|
| NFS 서버 (`infra-01` 10.0.0.10) | `setup-nfs-server.sh` | `nfs-kernel-server`, `/data/nfs`, `/etc/exports` |
| k8s 노드 (에어갭) | `install.sh` | `nfs-common` 확인, CSI 드라이버, snapshot-controller, StorageClass |

NFS 서버는 **구성 완료·판정 11/11 통과**했고, 노드 쪽 CSI 설치도 두 OS 에서
**에어갭 판정 16/16 통과**했다(9절).

---

## 1. 서버와 클라이언트를 나눈 이유

NFS 서버를 k8s 노드 위에 두면 단일 노드 환경에서 스토리지와 워크로드가 같은 장애 도메인에
묶인다. `hard` 마운트를 쓰기 때문에 서버가 멈추면 마운트를 가진 모든 파드의 I/O 가
무한 대기한다. 그래서 서버는 클러스터 밖(`infra-01`)에 둔다.

`infra-01` 에는 Harbor 가 운영 중이다. `setup-nfs-server.sh` 는 Harbor 를 건드리지
않는다. 변경 범위는 `nfs-kernel-server` 패키지, `/data/nfs`, `/etc/exports` 뿐이다.
스크립트가 실행 시 Harbor 가동을 감지하면 그 사실을 로그에 남긴다.

---

## 2. NFS 서버 구성

```bash
# infra-01 에서
sudo ./setup-nfs-server.sh
sudo ./setup-nfs-server.sh --check-only     # 판정만
```

적용되는 export 는 다음과 같다.

```
/data/nfs 10.0.0.0/16(rw,sync,no_subtree_check,no_root_squash,insecure)
```

### 옵션 선택 근거

| 옵션 | 이유 |
|---|---|
| `sync` | 쓰기를 즉시 반영. `async` 는 빠르지만 서버 장애 시 데이터 손실 |
| `no_subtree_check` | NFS 권장. 서브트리 검사 비용 제거 |
| `no_root_squash` | 컨테이너가 root 로 쓰기 때문에 필요. 없으면 root 쓰기가 `nobody` 로 매핑돼 권한 오류 |
| `insecure` | **아래 3절** |

### 3. `insecure` 와 `noresvport` — 같은 문제의 양쪽 끝

기존 운영 클러스터에서 겪은 문제다. PVC 가 `Pending` 에서 멈추고 이벤트에 이렇게 남는다.

```
mount.nfs: Operation not permitted    (exit 32)
```

컨테이너 문제로 보이지만 호스트에서 수동 마운트해도 똑같이 실패한다. 원인은
클라이언트가 **비특권 포트(>1024)로 마운트**하는데(`noresvport`) 서버 export 에
`insecure` 가 없어 서버가 거부하는 것이다.

이 번들은 양쪽에서 막는다.

- 서버: export 에 `insecure` 를 넣는다
- 클라이언트: StorageClass `mountOptions` 에 `noresvport` 를 **넣지 않는다**.
  `install.sh` 판정에 "mountOptions 에 noresvport 없음" 항목이 있다

`mountOptions` 는 불변 필드다. 잘못 넣었으면 StorageClass 를 **삭제하고 재생성**해야 한다.

### 서버 판정 11항목

패키지·서비스·export 설정 외에 **실제 마운트 쓰기 테스트**를 한다.

```
로컬 마운트 + 쓰기 테스트 (10.0.0.10)
```

여기서 `127.0.0.1` 로 마운트하면 안 된다. export 가 `10.0.0.0/16` 으로 제한돼 있고
루프백 주소는 그 대역에 없어 서버가 거부한다(`access denied by server`).
자기 사설 IP 를 써야 한다. 이 함정 때문에 첫 실행에서 10/11 로 실패했다.

---

## 4. 번들 구성 — 출처를 왜 나눴는가

아카이브 226MB, 이미지 7개, 매니페스트 14개.

```
nfs-csi-v4.13.4/
├── setup-nfs-server.sh
├── install.sh
├── manifests/            적용 순서를 파일명 번호로 고정
│   ├── 10-crd-*.yaml                    (6) external-snapshotter CRD
│   ├── 20-rbac-snapshot-controller.yaml
│   ├── 21-setup-snapshot-controller.yaml     replicas=1 로 수정됨
│   ├── 30-csi-nfs-{controller,driverinfo,node}.yaml
│   ├── 30-rbac-csi-nfs.yaml
│   ├── 40-storageclass.yaml             nfs-csi / nfs-csi-retain
│   └── 41-snapshotclass.yaml            csi-nfs-snapclass
├── images/               7개
└── conf/images.list
```

`csi-driver-nfs` 의 `deploy/` 에도 스냅샷 관련 파일이 들어 있지만 **제외했다.**
버전이 어긋나기 때문이다.

| 출처 | snapshot-controller 이미지 |
|---|---|
| csi-driver-nfs v4.13.4 의 `csi-snapshot-controller.yaml` | v8.4.0 |
| external-snapshotter v8.6.0 의 `setup-snapshot-controller.yaml` | **v8.5.0** ← 사용 |

둘을 모두 적용하면 컨트롤러가 중복 배치되고 이미지도 두 버전을 받아야 한다.

더 중요한 것은 `csi-driver-nfs` 의 `crd-csi-snapshot.yaml` 이다. 이 파일이
`volumesnapshots` / `volumesnapshotclasses` / `volumesnapshotcontents` **3종 CRD 를
다시 정의한다.** 파일명 순서상 `10-crd-*` 뒤에 적용되므로, 제외하지 않으면
external-snapshotter v8.6.0 CRD 를 csi-driver-nfs 쪽 사본으로 덮어쓴다.
스냅샷 CRD 의 authority 는 external-snapshotter 로 통일했다.

빌드 스크립트가 이 중복을 자동 검사한다.

```
[OK] 스냅샷 CRD 중복 없음
```

`volumesnapshots` CRD 를 정의하는 파일이 2개 이상이면 빌드를 중단한다.

### 이미지 7개

```
registry.k8s.io/sig-storage/nfsplugin:v4.13.4
registry.k8s.io/sig-storage/csi-provisioner:v6.3.0
registry.k8s.io/sig-storage/csi-resizer:v2.2.0
registry.k8s.io/sig-storage/csi-snapshotter:v8.6.0
registry.k8s.io/sig-storage/csi-node-driver-registrar:v2.17.0
registry.k8s.io/sig-storage/livenessprobe:v2.19.0
registry.k8s.io/sig-storage/snapshot-controller:v8.5.0
```

Cilium 과 마찬가지로 **목록을 손으로 관리하지 않는다.** 실제 적용할 `manifests/` 에서
`image:` 참조를 뽑아낸다. 그래서 제외한 파일의 이미지(snapshot-controller v8.4.0)는
번들에 들어가지 않는다.

`nfs-common` deb 는 이 번들에 없다. OS 별 패키지이므로 `10-k8s` 번들의 `debs/` 에
포함되어 있다. 덕분에 이 번들은 22.04 / 24.04 공용이다.

---

## 5. StorageClass

| 이름 | reclaimPolicy | 비고 |
|---|---|---|
| `nfs-csi` | Delete | **기본 클래스** |
| `nfs-csi-retain` | Retain | PVC 삭제 후에도 데이터 보존 |

공통 파라미터는 `server: 10.0.0.10`, `share: /data/nfs`, `mountPermissions: "0777"` 이고
`mountOptions` 는 `nfsvers=4.1, hard, timeo=600, retrans=2` 다.

`allowVolumeExpansion: true` 로 두었지만 **NFS 는 실제 용량 쿼터를 적용하지 않는다.**
PVC 의 용량 값은 사실상 라벨이다. 1Gi 를 요청해도 서버 디스크 전체를 쓸 수 있다.

`mountPermissions: "0777"` 은 권한이 넓다. 워크로드의 `fsGroup` 이 정해지면 `0770` 등으로
좁히는 것을 권한다.

---

## 6. 빌드와 설치

```bash
# 온라인 호스트
cd offline-install/50-nfs-csi
./build-bundle.sh

# NFS 서버 (infra-01)
sudo ./setup-nfs-server.sh

# 에어갭 k8s 노드
tar xzf nfs-csi-v4.13.4.tar.gz && cd nfs-csi-v4.13.4
sudo ./install.sh
```

`install.sh` 는 CRD 를 먼저 적용하고 **등록을 기다린 뒤** 나머지를 적용한다.
한꺼번에 적용하면 `VolumeSnapshotClass` 가 `no matches for kind` 로 실패할 수 있다.

설치 전에 두 가지를 먼저 막는다.

- 노드가 `Ready` 가 아니면 중단한다. CNI 가 없으면 CSI 파드가 스케줄되지 않는다
- `showmount -e 10.0.0.10` 가 실패하면 중단한다. 서버에 도달하지 못하면 뒤 단계가 모두 무의미하다

---

### worker 노드

```bash
# worker 에서 (조인 + CNI 적재가 끝난 뒤)
sudo ./install.sh --role worker          # nfs-common + 이미지만 준비
sudo ./install.sh --role worker --check-only
```

worker 에서는 매니페스트를 적용하지 않는다. `csi-nfs-node` 는 DaemonSet 이고
StorageClass 는 클러스터 자원이므로 control plane 에서 한 번 적용하면 조인한 노드로
자동 확장된다. worker 에 필요한 것은 두 가지다.

| 항목 | 없으면 |
|---|---|
| `nfs-common` | PVC 는 Bound 인데 파드가 `ContainerCreating` 에서 멈춘다 |
| CSI 이미지 | `csi-nfs-node` 파드가 `ImagePullBackOff`. 그 노드에서 NFS 볼륨을 쓸 수 없다 |

`nfs-common` deb 는 10-k8s 번들에서 찾는다(`/root`, `~/deploy*` 등 흔한 경로를 훑는다).

판정 6항목이다. 마지막 항목은 커널 마운트만으로 하므로 파드나 이미지가 필요하지 않다.

```
조인 완료(kubelet.conf 존재)
nfs-common 설치됨
mount.nfs4 존재
NFS 서버 export 조회
CSI 이미지 적재(k8s.io 네임스페이스)
NFS export 에 쓰기/읽기 가능
```

---

## 7. 판정 항목

설정 확인 12항목에 더해 **실제 프로비저닝과 쓰기를 수행한다.** 모두 16항목이다.

```
nfs-csi-smoke 네임스페이스 생성
  -> PVC(1Gi, ReadWriteMany) 생성        -> PVC Bound
  -> 파드가 해당 PVC 마운트              -> 파드 Running
  -> PV 의 subdir 확인
  -> 노드에서 export 를 직접 마운트      -> 쓰기/읽기 가능
                                         -> 프로비저너가 만든 subdir 이 서버에 존재
  -> 네임스페이스 삭제
```

`PVC Bound` 와 `파드가 NFS 볼륨 마운트 후 Running` 이 통과하면 프로비저너·마운트·권한이
모두 정상이라는 뜻이다. 설정만 보는 검사로는 3절의 `noresvport` 문제를 잡을 수 없다.

스모크 파드는 `pause` 이미지다. **아무것도 쓰지 않으므로 파드 Running 만으로는 쓰기
권한을 증명하지 못한다.** 그래서 노드에서 export 를 직접 마운트해 파일을 쓰고 읽은 뒤,
프로비저너가 만든 하위 디렉터리가 서버에 실제로 있는지까지 확인한다. `nfs-common` 의
`mount.nfs4` 를 쓰므로 추가 이미지가 필요하지 않다.

`subdir` 키는 소문자다. `subDir` 로 조회하면 항상 빈 값이 나온다(csi-driver-nfs
v4.13.4 실측). PV 의 실제 `volumeAttributes` 는 다음과 같다.

```json
{"server":"10.0.0.10","share":"/data/nfs","mountPermissions":"0777",
 "subdir":"pvc-2a80ddbb-3262-4af4-b8de-c1aad626b5ff", ...}
```

---

## 8. 트러블슈팅

| 증상 | 원인 | 조치 |
|---|---|---|
| PVC `Pending`, `mount.nfs: Operation not permitted` (exit 32) | export 에 `insecure` 없음 + 클라이언트 `noresvport` | 3절 참고. `mountOptions` 는 불변이라 SC 삭제·재생성 필요 |
| `access denied by server` (서버 자체 테스트) | `127.0.0.1` 로 마운트했다. export 대역 밖이다 | 자기 사설 IP 사용 |
| `no matches for kind VolumeSnapshotClass` | CRD 등록 전에 적용했다 | `install.sh` 가 CRD 등록을 대기한다. 수동 적용 시 순서 준수 |
| `snapshot-controller` 하나가 `Pending` | 기본 replicas 가 2다 | 빌드 시 1로 낮춘다(`21-setup-*.yaml`) |
| PVC 는 Bound 인데 파드가 `ContainerCreating` 에서 멈춤 | 노드에 `nfs-common` 없음 | `install.sh` 가 10-k8s 번들의 deb 로 설치한다 |
| `Released` 상태 PV 누적 | `nfs-csi-retain` 사용분 | PVC 삭제 후에도 PV 와 `/data/nfs` 하위 디렉터리가 남는다. 주기적 정리 필요 |
| 파드 I/O 무한 대기 | NFS 서버 정지 + `hard` 마운트 | 서버를 먼저 살린다. 중지/시작 순서는 서버가 나중에 죽고 먼저 살아야 한다 |
| `적재되지 않은 이미지: ...` 인데 `ctr images ls` 에는 보인다 | `ctr images ls -q \| grep -q` 형태의 오탐. grep 이 첫 일치에서 끝나면서 ctr 이 SIGPIPE(141)로 죽고 `pipefail` 이 실패로 판정한다 | 고쳤다. `common.sh` 의 `ctr_missing_images()` 를 쓴다. 목록 앞쪽 이미지에서만 간헐 발생해 놓치기 쉽다 |
| `서버 하위 디렉터리=확인불가` | `subDir`(카멜케이스)로 조회했다 | 키는 소문자 `subdir` 이다. 7절 참고 |

---

## 9. 검증 상태

2026-09-22 에 Ubuntu 24.04 / 22.04 두 노드에서 에어갭 설치를 수행했다.

| 항목 | 상태 |
|---|---|
| NFS 서버 구성 (infra-01) | **완료. 판정 11/11 통과** |
| 번들 빌드 | **완료.** 226MB / 14 매니페스트 / 7 이미지, CRD 중복 검사 통과 |
| 노드 CSI 설치 + 프로비저닝 + 쓰기 | **양쪽 OS 통과 16/16** |
| `airgap-fwd-other` 카운터 | **0** (파드가 인터넷 접근을 시도하지 않았다) |
| 재부팅 후 CSI 파드 자동 복구 | **통과** (22.04 노드: `csi-nfs-controller` 5/5, `csi-nfs-node` 3/3, `snapshot-controller` 1/1) |
| worker(24.04) `--role worker` | **판정 6/6 통과.** `csi-nfs-node` DaemonSet 2/2 |
| worker 에 고정한 파드의 PVC 마운트 | **통과.** `nodeName` 으로 worker 에 고정한 파드가 Running 이고, worker 호스트에서 `findmnt` 로 `10.0.0.10:/data/nfs/pvc-...` 마운트를 확인했다 |

검증 로그의 핵심 부분은 다음과 같다.

```
OK   PVC Bound
OK   파드가 NFS 볼륨 마운트 후 Running
     PV=pvc-2a80ddbb-...  서버 하위 디렉터리=pvc-2a80ddbb-...
OK   NFS export 에 쓰기/읽기 가능
OK   프로비저너가 만든 pvc-2a80ddbb-... 가 서버에 존재
=== 검증 결과: 통과 16 / 실패 0 ===
```

검증 중 발견해 고친 것은 두 가지다. 둘 다 8절 표에 증상으로 적어 뒀다.

1. **이미지 적재 오탐** — `ctr images ls -q | grep -q` 가 SIGPIPE + `pipefail` 조합으로
   실패해, 적재된 이미지를 "없음"으로 보고하고 설치가 중단됐다. `common.sh` 에
   `ctr_missing_images()` 를 추가하고 `10-k8s` / `50-nfs-csi` / `60-cilium` 의
   4곳을 모두 교체했다.
2. **`subdir` 키 대소문자** — PV 의 하위 디렉터리 조회가 항상 빈 값이었다.

에어갭 검증 절차는 다음과 같다.

```bash
sudo ./90-verify/airgap-off.sh          # 빌드는 온라인에서
./build-bundle.sh
tar xzf bundle/nfs-csi-v4.13.4.tar.gz -C ~/deploy-nfs
sudo ./90-verify/airgap-on.sh           # 에어갭 전환
cd ~/deploy-nfs/nfs-csi-v4.13.4 && sudo ./install.sh
sudo ./90-verify/airgap-off.sh          # 카운터 판정이 함께 출력된다
```

`airgap-on.sh` 규칙은 nftables 런타임 규칙이라 **재부팅하면 사라진다.** 재부팅 후
검증을 이어갈 때는 다시 실행해야 한다.

---

## 10. 다음 단계

```
10-k8s  →  60-cilium  →  [50-nfs-csi]  →  40-haproxy  →  30-harbor  →  20-minio
```
