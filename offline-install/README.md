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
| CNI | Cilium 1.20.2 (이 폴더의 매니페스트 재사용) | **Cilium 1.20.2** |
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

빌드 호스트는 같은 OS 이면서 **깨끗해야** 한다. 대상 패키지가 이미 설치돼 있으면
apt 가 전이 의존성을 다시 내려받지 않아 번들에 구멍이 생긴다(실측: deb 23 → 19개).
`10-k8s/build-bundle.sh` 가 이 상태를 감지해 중단한다 — 근거는 `10-k8s/README.md` 3절.

### 컨테이너로 빌드하기 — VM 없이

깨끗한 빌드 호스트를 매번 준비하는 것이 번거롭다면 컨테이너를 쓴다.
번들 빌드는 deb 와 이미지를 **내려받는 일**뿐이라 커널이 필요 없다.

```bash
cd offline-install
./00-common/build-in-container.sh 24.04 all       # 8단계 전부
./00-common/build-in-container.sh 22.04 10-k8s    # 22.04 용 (10-k8s 만 OS 의존)
./00-common/build-in-container.sh 24.04 30-harbor 70-mssql
```

**rootless podman 을 쓰므로 sudo 가 필요 없다.** 매번 새 컨테이너를 띄우므로
"깨끗한 호스트" 조건도 자동으로 만족한다.

단계 중 **OS 에 의존하는 것은 `10-k8s` 뿐**이다. deb 버전 문자열에 코드네임이
들어가고(docker) OS 기본 패키지도 릴리스마다 다르기 때문이다. 나머지는 이미지·
차트·바이너리만 다루므로 어느 이미지에서 만들어도 같다.

#### 최소 컨테이너 이미지를 그대로 쓰면 안 된다

`ubuntu:24.04` 컨테이너는 최소 이미지라 실제 서버에 기본 포함된 것들이 빠져 있다.
그 상태로 의존성을 받으면 **기반 패키지까지 번들에 들어간다.**

```
최소 이미지 그대로   : deb 101개 — systemd / systemd-sysv / perl / python3 /
                      dbus / openssh-client / libc6 포함  ← 위험
ubuntu-server-minimal: deb 33개 — 기반 패키지 없음        ← 정상
```

타깃에서 `dpkg -i` 로 `systemd` 나 `libc6` 를 덮어쓰면 노드가 손상될 수 있다.
`build-in-container.sh` 는 `ubuntu-server-minimal` 을 먼저 설치해 기반 패키지
집합을 실제 서버와 맞춘다. 그리고 `build-bundle.sh` 에 **핵심 시스템 패키지가
섞이면 중단하는 가드**가 있어, 어떤 방법으로 빌드해도 이 사고는 걸러진다.

deb 개수가 서버 빌드(23개)보다 많은 것은 정상이다. Ubuntu Server 이미지에 이미
있던 것들(`git` `keyutils` `libtirpc*` `less` `patch` 등)이 포함되기 때문이며,
더 최소인 타깃에도 설치되는 **안전한 상위집합**이다.

번들은 자기완결형이다(`00-common/` 포함). 타깃에서 추가로 받아올 것이 없다.
`install.sh` 는 시작 시 `SHA256SUMS` 를 검증하므로 전송 손상을 설치 전에 잡는다.

---

## 2. 적용 순서 — 번호순이 아니다

```
10-k8s  →  05-certs  →  60-cilium  →  50-nfs-csi  →  40-haproxy  →  30-harbor  →  20-minio
                                                      70-mssql · 80-postgresql (독립)
```

`05-certs` 는 사내 CA 하나로 모든 서비스 인증서를 발급하고 각 노드(master·worker)에
CA 를 신뢰시킨다. **10-k8s 다음에 두는 이유**는 containerd 신뢰 설정이
`/etc/containerd/config.toml` 을 요구하기 때문이다(발급 자체는 언제든 가능하다).
건너뛰어도 각 서비스가 자가서명 인증서를 만들어 동작하지만, 그 경우 클라이언트가
인증서를 서비스마다 따로 신뢰해야 한다.

CNI 가 없으면 노드가 `NotReady` 이고 아무 워크로드도 스케줄되지 않는다. 그래서
`10-k8s` 다음에 **`60-cilium` 을 먼저** 적용한다. 디렉터리 번호는 구성요소 분류이지
실행 순서가 아니다.

| 단계 | 내용 | 번들 크기 | 상태 |
|---|---|---|---|
| `10-k8s` | kubeadm, containerd, helm, docker, podman. 단일/다중 CP(HA) | 381M | 완료 (단일 CP 23/23, worker 24/24, **3-CP HA 각 28/28**) |
| `05-certs` | 사내 CA + 서비스 인증서 5종, 노드 CA 신뢰 | 번들 없음 | 완료 (발급 36/36, 배포 11/11) |
| `60-cilium` | CNI. 노드를 Ready 로 만든다 | 348M | 완료 (CP 9/9, worker 5/5) |
| `50-nfs-csi` | NFS 서버 + csi-driver-nfs + StorageClass | 226M | 완료 (서버 11/11, CP 16/16, worker 6/6) |
| `40-haproxy` | ingress L4 로드밸런서 | 45M | 완료 (11/11) |
| `30-harbor` | 컨테이너 레지스트리 | 697M | 완료 (26/26, 재부팅 후 9/9) |
| `20-minio` | S3 호환 오브젝트 스토리지 | 86M | 완료 (23/23) |
| `70-mssql` | SQL Server 2022 + Full-Text Search | 1.3G | 완료 (19/19) |
| `80-postgresql` | PostgreSQL 16 (TLS) | 145M | 완료 (25/25) |

`30-harbor` 는 443 을 직접 점유하므로 `40-haproxy` 와 같은 노드에 둘 수 없다.
레지스트리는 클러스터 밖 별도 호스트에 두는 것을 권장한다.

`70-mssql` 과 `80-postgresql` 은 k8s 에 올리지 않는다. UiPath AS 는 외부 DB 를
전제로 하며, 클러스터 장애가 DB 까지 끌고 가지 않도록 분리하는 것이 안전하다.
두 단계는 다른 단계와 순서 의존이 없다.

공식 mssql 이미지에는 **Full-Text Search 가 없어** 직접 빌드한 이미지를 쓴다.
AS 는 FTS 를 요구하므로 공식 이미지로는 설치가 진행되지 않는다.

```
docker.io/javaos74/mssql-fts:2022          SQL Server 2022 + Full-Text Search (CU26)
docker.io/javaos74/mssql-fts:2022-cu25     같은 것의 CU25 고정본
docker.io/javaos74/postgres-jammy:16.15    PostgreSQL 16 (jammy 기반, 대안)
```

빌드 레시피와 이미지 단위 FTS 판정 스크립트는 `70-mssql/fts-image/` 에 있다.
게시된 mssql 태그는 전부 FTS 포함이며 매니페스트 단위로 검증했다
(`70-mssql/README.md` 8절).

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

control plane 을 여러 대 두려면(HA) **첫 CP 부터** 안정적인 엔드포인트를 줘야 한다.
나중에 붙이는 것은 사실상 재구축이다 — 근거는 `10-k8s/README.md` 4.1절.

```bash
sudo ./apiserver-lb.sh --backends cp1,cp2,cp3 --image-tar <40-haproxy번들>/images/haproxy_*.tar
sudo ./install.sh --control-plane-endpoint <LB>:6443    # 첫 CP
sudo ./install.sh --print-join-command                  # 조인 명령 발급(worker/CP)
```

worker 추가는 `10-k8s/README.md` 4.0절을 볼 것. control plane 에서 발급한
`kubeadm token create --print-join-command` 출력을 `--join-command` 로 넘긴다.

---

## 4. 구성

```
00-common/
  build-in-container.sh  컨테이너에서 번들 빌드(rootless podman, sudo 불필요)
  versions.env        모든 버전 핀. 단일 출처. 여기만 고치면 전 단계에 반영된다
  site.env.example    사이트별 설정 예시. 복사해서 site.env 로 쓴다
  site.env            내부 IP·사내 호스트명. git 추적 제외. 번들에는 포함된다
  common.sh           공통 함수(로깅·판정·체크섬·이미지 적재)
  verify-urls.sh      업스트림 URL 생존 확인
  publish-images.sh   커스텀 이미지를 레지스트리에 게시
05-certs/
  make-certs.sh       사내 CA + 서비스 인증서 발급 (openssl 만 필요)
  deploy-certs.sh     노드에 CA 신뢰 설정 + 인증서 배치 (/opt/pki)
10-k8s/ 20-minio/ 30-harbor/ 40-haproxy/ 50-nfs-csi/ 60-cilium/
70-mssql/ 80-postgresql/
  build-bundle.sh     빌드 호스트에서 실행
  install.sh          타깃에서 root 로 실행. 설치 + 판정
  README.md           설계 근거·트러블슈팅
70-mssql/fts-image/
  Dockerfile          SQL Server 2022 + FTS 이미지 레시피
  build-image.sh      빌드 후 컨테이너를 띄워 FTS 까지 검증한다
  verify-fts-image.sh 이미지 하나만 따로 FTS 판정 (--smoke 로 CONTAINS 질의)
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
