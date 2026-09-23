# offline-install — 에어갭 환경 오프라인 설치

인터넷에 접근할 수 없는(에어갭) Ubuntu 22.04 / 24.04 노드에 Kubernetes **v1.36.4** 와
UiPath Automation Suite 용 인프라를 구성한다.

**저장소 루트는 온라인 설치 기준이다.** 노드가 인터넷에 나갈 수 있다면 루트의
`README.md` 를 볼 것. 두 경로를 섞어 쓰면 안 된다.

| | 저장소 루트 (온라인) | **이 폴더 (오프라인)** |
|---|---|---|
| 전제 | 노드가 인터넷 접근 가능 | 노드가 인터넷 접근 **불가** |
| 패키지 | 노드에 apt 저장소 등록 후 직접 설치 | 번들의 deb 를 `dpkg -i` |
| 이미지 | 노드가 레지스트리에서 pull | 번들의 tar 를 `ctr -n k8s.io images import` |
| CNI | Flannel v0.28.9 | **Cilium 1.20.2** |
| 검증 | 수동 | 단계별 판정 + nftables 에어갭 강제 |

---

## 1. 동작 모델

두 종류의 호스트가 필요하다. **번들은 설치 대상과 같은 OS 에서 만들어야 한다**
(deb 의존성 해석이 "현재 설치되지 않은 것" 기준으로 이뤄지기 때문).

```
   [빌드 호스트: 인터넷 O]                      [타깃 노드: 에어갭]
   build-bundle.sh                              install.sh
   업스트림에서 수집 -> tar.gz  ──(복사)──>      tar 풀고 설치 + 판정
```

번들은 자기완결형이다(`00-common/` 포함). 타깃에서 추가로 받아올 것이 없다.
`install.sh` 는 시작 시 `SHA256SUMS` 를 검증하므로 전송 손상을 설치 전에 잡는다.

---

## 2. 적용 순서 — 번호순이 아니다

```
10-k8s  →  60-cilium  →  50-nfs-csi  →  40-haproxy  →  [30-harbor]  →  [20-minio]
```

CNI 가 없으면 노드가 `NotReady` 이고 아무 워크로드도 스케줄되지 않는다. 그래서
`10-k8s` 다음에 **`60-cilium` 을 먼저** 적용한다. 디렉터리 번호는 구성요소 분류이지
실행 순서가 아니다.

| 단계 | 내용 | 번들 크기 | 상태 |
|---|---|---|---|
| `10-k8s` | kubeadm, containerd, helm, docker, podman | 381M | 완료 (CP 23/23, worker 24/24) |
| `60-cilium` | CNI. 노드를 Ready 로 만든다 | 348M | 완료 (CP 9/9, worker 5/5) |
| `50-nfs-csi` | NFS 서버 + csi-driver-nfs + StorageClass | 226M | 완료 (서버 11/11, CP 16/16, worker 6/6) |
| `40-haproxy` | ingress L4 로드밸런서 | 45M | 완료 (11/11) |
| `30-harbor` | 컨테이너 레지스트리 | — | 미착수 |
| `20-minio` | S3 호환 오브젝트 스토리지 | — | 미착수 |

MSSQL(FTS 포함) · PostgreSQL 은 커스텀 이미지를 공개 레지스트리에 올려 뒀다.
자세한 내용은 `PROGRESS.md` 5절을 볼 것.

```
docker.io/javaos74/mssql-fts:2022          SQL Server 2022 + Full-Text Search
docker.io/javaos74/postgres-jammy:16.15    PostgreSQL 16 (Ubuntu 22.04 기반)
```

---

## 3. 빠른 시작

### 3.0 사이트별 설정 — 최초 1회

내부 IP·사내 호스트명은 `site.env` 로 분리돼 있다. **이 파일은 git 에 올라가지
않는다**(`.gitignore`). 저장소를 받은 뒤 한 번 만들어야 한다.

```bash
cd offline-install/00-common
cp site.env.example site.env
vi site.env            # NFS_SERVER_HOST, HARBOR_* 등을 자신의 환경 값으로
```

| 키 | 용도 |
|---|---|
| `SITE_PRIVATE_CIDR` | 에어갭 판정에서 "사내망"으로 허용할 대역. NFS export 기본 범위 |
| `NFS_SERVER_HOST` | NFS 서버 사설 IP |
| `HARBOR_HOSTNAME` / `HARBOR_PRIVATE_IP` | 사내 레지스트리. `/etc/hosts` 매핑에 쓰인다 |
| `SITE_REACHABILITY_HOST` / `_PORT` | `airgap-on.sh` 의 사내망 도달 확인 대상 |

만들지 않아도 동작은 하지만 `site.env.example` 의 **예시 값**이 쓰이고 경고가 나온다.
그 상태로는 NFS 마운트 등이 실패한다.

```
[versions.env] WARN site.env 가 없어 site.env.example 의 예시 값을 쓴다.
```

`site.env` 는 번들에 포함된다(`build-bundle.sh` 가 복사한다). 에어갭 타깃에서 값을
다시 입력할 필요가 없다는 뜻이다. 번들 자체가 사내 자산이므로 문제되지 않는다.

### 3.1 빌드와 설치

```bash
# --- 빌드 호스트(인터넷 O, 타깃과 같은 OS) ---
cd offline-install/00-common && ./verify-urls.sh      # 업스트림 생존 확인(선택)
cd ../10-k8s && ./build-bundle.sh                    # -> bundle/k8s-1.36.4-<코드네임>.tar.gz

# --- 타깃 노드(에어갭) ---
scp bundle/k8s-1.36.4-noble.tar.gz{,.sha256} <타깃>:~/
sha256sum -c k8s-1.36.4-noble.tar.gz.sha256
tar xzf k8s-1.36.4-noble.tar.gz && cd k8s-1.36.4-noble

sudo ./90-verify/airgap-on.sh                        # 인터넷 차단(검증 목적)
sudo ./install.sh                                    # control plane
sudo ./90-verify/airgap-off.sh                       # 해제 + 카운터 판정
```

각 단계 스크립트는 공통 옵션을 갖는다.

```bash
sudo ./install.sh --check-only     # 설치하지 않고 현재 상태만 판정
sudo ./install.sh --role worker    # worker 노드 (10-k8s / 60-cilium / 50-nfs-csi)
sudo ./install.sh --uninstall      # 제거 (10-k8s 는 --reset)
```

worker 추가는 `10-k8s/README.md` 4.0절을 볼 것. control plane 에서 발급한
`kubeadm token create --print-join-command` 출력을 `--join-command` 로 넘긴다.

---

## 4. 구성

```
00-common/
  versions.env        모든 버전 핀. 단일 출처. 여기만 고치면 전 단계에 반영된다
  site.env.example    사이트별 설정 예시. 복사해서 site.env 로 쓴다
  site.env            내부 IP·사내 호스트명. git 추적 제외. 번들에는 포함된다
  common.sh           공통 함수(로깅·판정·체크섬·이미지 적재)
  verify-urls.sh      업스트림 URL 생존 확인
  publish-images.sh   커스텀 이미지를 레지스트리에 게시
10-k8s/ 40-haproxy/ 50-nfs-csi/ 60-cilium/
  build-bundle.sh     빌드 호스트에서 실행
  install.sh          타깃에서 root 로 실행. 설치 + 판정
  README.md           설계 근거·트러블슈팅
90-verify/
  airgap-on.sh        nftables 로 인터넷만 차단(사내망 RFC1918 은 허용)
  airgap-off.sh       해제 + 유출 카운터 판정
```

버전을 바꿀 때는 `verify-urls.sh` 를 먼저 통과시킬 것. 업스트림이 배포를 내리는 일이
실제로 발생한다(MinIO 오픈소스가 아카이브되어 `dl.min.io` 가 410 Gone 을 반환한다).

---

## 5. 오프라인 설치였음을 증명하는 방법

"번들만으로 설치됐다"를 주장만으로 두지 않기 위해 `90-verify` 가 있다.
nftables 로 인터넷을 막고, 차단된 패킷을 **소음과 신호로 나눠 센다.**

```
airgap-fwd-other = 0    <- 판정 기준. 파드가 인터넷에서 무언가를 받으려 한 횟수
airgap-*-noise   != 0   <- 정상. DNS(53) / NTP(123) / 클라우드 플랫폼 엔드포인트
```

`airgap-fwd-other` 가 0 이 아니면 번들에 빠진 것이 있다는 뜻이다.
`airgap-off.sh` 가 해제 시 이 판정을 자동 출력한다.

규칙은 런타임 규칙이라 **재부팅하면 사라진다.** 재부팅 후 검증을 이어갈 때는
다시 실행해야 한다.

---

## 6. 대상 환경

| 항목 | 값 |
|---|---|
| OS | Ubuntu 22.04(jammy) / 24.04(noble), amd64 |
| 최소 사양 | 2 vCPU / 2GB (실검증 4 vCPU / 7.8GB) |
| 권한 | 빌드는 일반 사용자, 설치는 root(sudo) |

요구 버전: helm 3.8+ · podman 4.9+ · docker 28+ (실제 핀은 `versions.env` 참고).
podman 은 22.04 배포판(3.4.4)이 요구사항에 미달해 정적 빌드를 쓴다 — 근거는
`versions.env` 주석에 있다.
