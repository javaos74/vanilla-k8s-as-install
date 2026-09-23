# 20-minio — MinIO 오브젝트 스토리지 오프라인 설치

UiPath Automation Suite 용 S3 호환 오브젝트 스토리지. 단일 노드 · 단일 드라이브
(SNSD) 구성, TLS 활성. 컨테이너명은 `minio` 다.

Ubuntu 24.04 에어갭 노드에서 **판정 23/23 통과**를 확인한 구성이다(9절).

---

## 1. 먼저 알아야 할 것 — 업스트림이 아카이브됐다

**MinIO 오픈소스(server / mc / KES)는 아카이브되어 `dl.min.io` 가 410 Gone 을
반환한다.** 바이너리 배포 경로가 사라졌고 GitHub 릴리스에도 에셋이 없다.

```
$ curl -sI https://dl.min.io/server/minio/release/linux-amd64/minio
HTTP/1.1 410 Gone
```

현재 살아 있는 유일한 경로가 quay.io 컨테이너 이미지다. 그래서 이 번들은
deb/tarball 설치를 제공하지 않고 **컨테이너로만** 구성한다.

| | 값 |
|---|---|
| server | `quay.io/minio/minio:RELEASE.2025-09-07T16-13-09Z` |
| client | `quay.io/minio/mc:RELEASE.2025-08-13T08-35-41Z` |

**보안 업데이트는 더 이상 제공되지 않는다.** 폐쇄망 운용을 전제로 받아들이거나,
AGPL 라이선스와 운영 정책을 검토해 대안(예: 상용 AIStor, Ceph RGW, SeaweedFS)을
선택해야 한다. 이 번들은 "기존 환경과 같은 버전으로 재현한다"를 목표로 한다.

빌드 시점의 다이제스트를 `conf/images.digests` 에 기록한다. 태그가 사라져도
우리가 무엇을 받았는지 증명할 수 있어야 하기 때문이다.

---

## 2. 번들 내용

아카이브 86MB. OS 에 의존하지 않는다(이미지 + 설정뿐).

```
minio-RELEASE.<...>/
├── BUNDLE-INFO
├── SHA256SUMS            12개 파일
├── install.sh
├── 00-common/            versions.env + site.env + common.sh
├── images/               minio, mc (docker-archive tar)
└── conf/
    ├── images.list
    ├── images.digests            빌드 시점 다이제스트
    ├── docker-compose.yml.tmpl
    ├── minio.env.tmpl
    └── minio-openssl.cnf.tmpl
```

docker / docker compose 는 `10-k8s` 번들에서 설치된다. 이 번들은 설치하지 않는다.

---

## 3. 왜 docker compose 인가

`40-haproxy` 는 `docker run` 을 쓰는데 이쪽은 compose 를 쓴다. 이유가 있다.

| | `docker run` | **compose** |
|---|---|---|
| 자격증명 전달 | `-e` 로 넘기면 `ps` 에 노출된다 | `env_file` 로 파일에서 읽는다(0600) |
| healthcheck | 긴 인라인 문자열 | 파일에 구조적으로 기록 |
| 변경 추적 | 명령행 히스토리에 의존 | 파일 diff 로 확인 |

MinIO 는 루트 자격증명을 환경변수로 받아야 하므로 노출 경로를 줄이는 쪽을 택했다.
compose 플러그인(v5.5.1)은 `10-k8s` 번들에 포함돼 있다.

---

## 4. 설치

```bash
# 빌드 호스트(인터넷 O)
cd offline-install/20-minio && ./build-bundle.sh

# 타깃 노드(에어갭)
scp bundle/minio-*.tar.gz{,.sha256} <타깃>:~/
sha256sum -c minio-*.tar.gz.sha256
tar xzf minio-*.tar.gz && cd minio-*

sudo ../offline-install/90-verify/airgap-on.sh   # 검증 목적
sudo ./install.sh
```

옵션은 `--check-only`(판정만), `--test-restart`(자동 복구 검증),
`--uninstall`(컨테이너만 제거, 데이터 보존) 이다.

### 설정 값

`00-common/site.env` 에서 읽는다. 없으면 `site.env.example` 의 예시 값이 쓰인다.

| 키 | 기본 동작 |
|---|---|
| `MINIO_HOSTNAME` | 클라이언트가 접속할 이름. 인증서 SAN 에 들어간다 |
| `MINIO_ROOT_USER` | 비우면 `uipathadmin` |
| `MINIO_ROOT_PASSWORD` | **비우면 무작위 생성**하고 설치 끝에 출력한다 |
| `MINIO_REGION` | `versions.env` 에 있다. UiPath AS 가 리전을 요구한다 |

비밀번호를 기본값으로 박아두지 않는다. 공개 저장소의 기본 비밀번호가 그대로
운영에 들어가는 일이 실제로 생긴다. 생성된 값은 `/opt/minio/minio.env`(0600)에
저장되고 설치 마지막에 한 번 출력된다.

MinIO 는 **`MINIO_ROOT_USER` 3자 이상, `MINIO_ROOT_PASSWORD` 8자 이상**이 아니면
기동 직후 종료된다. 로그에만 이유가 남아 원인을 찾기 어렵다.
`install.sh` 가 기동 전에 길이를 검사해 먼저 알려준다.

---

## 5. TLS — 인증서를 타깃에서 만드는 이유

인증서를 빌드 시점에 만들지 않는다. SAN 에 **타깃 노드의 호스트명과 IP** 가
들어가야 하고, 그 값은 타깃에서만 알 수 있다. 빌드 호스트에서 만들면 SAN 이
맞지 않아 클라이언트가 거부한다.

SAN 에 이름과 IP 를 모두 넣는다. 하나만 넣으면 다른 쪽으로 접속할 때 실패한다.

```
DNS.1 = <MINIO_HOSTNAME>   DNS.2 = localhost
IP.1  = <노드 IP>          IP.2  = 127.0.0.1
```

사내 CA 가 있으면 `/opt/minio/certs/public.crt` 와 `private.key` 를 교체하면 된다.
`install.sh` 는 기존 인증서가 있으면 만들지 않는다(멱등).

컨테이너는 uid 1000 으로 돌기 때문에 `certs/` 와 데이터 디렉터리를 `1000:1000`
소유로 맞춘다. 이것을 빼면 기동은 되는데 쓰기가 실패한다.

### 클라이언트 쪽 준비

자가서명이므로 클라이언트가 CA 를 신뢰해야 한다.

```bash
# 이름 해석 (에어갭에서는 /etc/hosts 가 사내 DNS 역할)
echo "<노드IP> <MINIO_HOSTNAME>" | sudo tee -a /etc/hosts

# mc 를 쓰는 경우
mkdir -p ~/.mc/certs/CAs && cp public.crt ~/.mc/certs/CAs/

# k8s 파드가 쓰는 경우 — CA 를 Secret 으로 넣고 워크로드에 마운트한다
kubectl create secret generic minio-ca --from-file=ca.crt=public.crt
```

---

## 6. 판정 23항목

설정 확인에 더해 **실제 버킷 왕복**을 수행한다.

```
docker / compose 사용 가능
이미지 2개 적재됨
compose 파일 · env 파일(0600) · 인증서 · 데이터 디렉터리 존재
compose 설정 문법 유효
컨테이너 실행 중(크래시 루프 아님)      <- PID 10초 유지 확인
재시작 정책 unless-stopped
호스트 9000 / 9001 수신
9000 이 TLS 로 응답 · health/live 200 · 콘솔 9001 응답
인증서 SAN 에 접속 이름 포함
  -- 버킷 왕복 --
mc 로 서버 접속 가능
버킷 생성 -> 객체 업로드 -> 목록에 보임 -> 내용 일치
호스트 볼륨에 데이터 기록됨            <- 컨테이너 안에만 있으면 재시작 시 소실
```

`컨테이너 실행 중` 을 `.State.Running` 으로만 보면 안 된다. 크래시 루프에 빠진
컨테이너도 재시작하는 순간에는 `true` 로 보인다(`40-haproxy` 에서 실제로 겪었다).
그래서 PID 유지까지 확인한다.

`호스트 볼륨에 데이터 기록됨` 이 중요하다. 설정만 보는 검사로는 볼륨 마운트가
빠졌거나 권한이 없는 경우를 잡지 못하고, 재시작 후에야 데이터 소실을 알게 된다.

### mc 를 컨테이너로 돌린다

호스트에 mc 를 설치하지 않는다. 바이너리 배포 경로가 없고(1절), 호스트를
더럽히지 않는 편이 낫다. 자격증명은 명령행이 아니라 `MC_HOST_<alias>` 환경변수로
넘긴다 — 명령행에 넣으면 `ps` 와 셸 히스토리에 비밀번호가 남는다.

---

## 7. 자동 복구

```bash
sudo ./install.sh --test-restart
```

| 단계 | 방법 | 확인 |
|---|---|---|
| 프로세스 사고사 | 호스트에서 컨테이너 PID 에 `kill -9` | `RestartCount` 증가 + health 복구 |
| 재부팅 대리 | `systemctl restart docker` | running 복귀 + health 응답 |

**`docker kill` 로 시험하면 안 된다.** `docker kill`/`docker stop` 은 "사용자가
의도적으로 멈춤"으로 기록되고(`HasBeenManuallyStopped`), `unless-stopped` 는 그
경우 재시작하지 않는다. `40-haproxy` 에서 이 함정에 빠져 60초간 복구를 기다린
적이 있다. 정책 문제가 아니라 시험 방법이 틀린 것이다.

---

## 8. 트러블슈팅

| 증상 | 원인 | 조치 |
|---|---|---|
| 기동 직후 컨테이너 종료, 로그에 credential 관련 메시지 | `MINIO_ROOT_PASSWORD` 8자 미만 또는 `USER` 3자 미만 | `install.sh` 가 사전에 잡는다. 수동 설정 시 길이 확인 |
| `mc` 가 `Server not initialized` / 연결 실패 | 서버가 TLS 전용인데 `http://` 로 붙었다 | `https://` + `--insecure`(자가서명) |
| 클라이언트에서 x509 오류 | CA 미신뢰 또는 SAN 불일치 | 5절. SAN 에 접속 이름이 있는지 `openssl x509 -text` 로 확인 |
| 콘솔 접속 시 localhost 로 리다이렉트되어 끊김 | `MINIO_BROWSER_REDIRECT_URL` 미설정 | `minio.env` 에 있다. 이름을 바꾸면 컨테이너 재생성 필요 |
| 버킷은 만들어지는데 업로드가 실패 | 데이터 디렉터리가 uid 1000 소유가 아니다 | `chown -R 1000:1000 /data/minio` |
| 재시작 후 데이터가 사라짐 | 볼륨 마운트 누락 | 판정의 `호스트 볼륨에 데이터 기록됨` 항목 확인 |
| 포트 9000 바인드 실패 | 다른 프로세스 점유 | `install.sh` 가 사전에 잡는다. `ss -lntp` 확인 |

로그는 `docker logs minio` 또는 `docker compose -f /opt/minio/docker-compose.yml logs` 다.

---

## 9. 검증 상태

2026-09-23 에 Ubuntu 24.04 에어갭 노드에서 수행했다.

| 항목 | 결과 |
|---|---|
| 번들 빌드 | **완료** (86MB, 이미지 2개) |
| 에어갭 설치 + 판정 | **통과 23/23** |
| 버킷 왕복(생성·업로드·목록·내용·호스트 볼륨) | **통과** |
| 프로세스 사고사 후 자동 복구 | **통과** (`RestartCount 0 -> 1`) |
| docker 데몬 재시작 후 복구 | **통과** |
| `airgap-fwd-other` 카운터 | **0** |

```
=== 검증 결과: 통과 23 / 실패 0 ===
```

---

## 10. UiPath Automation Suite 연계

AS 는 S3 호환 스토리지에 다음을 요구한다.

- **엔드포인트**: `https://<MINIO_HOSTNAME>:9000`
- **리전**: `versions.env` 의 `MINIO_REGION` (기본 `ap-northeast-2`).
  리전을 비우면 일부 S3 클라이언트가 서명 계산에 실패한다.
- **자격증명**: `/opt/minio/minio.env` 의 루트 계정.
  운영에서는 루트를 직접 쓰지 말고 AS 전용 사용자·정책을 만들 것.
- **CA 신뢰**: 자가서명이면 AS 설치 시 CA 번들에 포함시켜야 한다.

버킷은 AS 설치 절차가 만들거나, 미리 만들어 둘 수 있다.

```bash
# 예: AS 용 버킷을 미리 생성
docker run --rm --network host \
  -e MC_HOST_m="https://<user>:<pass>@127.0.0.1:9000" \
  quay.io/minio/mc:RELEASE.2025-08-13T08-35-41Z --insecure \
  mb m/uipath-bucket
```

---

## 11. 다음 단계

```
10-k8s  →  60-cilium  →  50-nfs-csi  →  40-haproxy  →  30-harbor  →  [20-minio]
```
