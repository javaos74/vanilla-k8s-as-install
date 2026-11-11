# 85-ollama-embedding — Ollama qwen3-embedding 8b + nginx Bearer 키 게이트웨이 (오프라인)

Ollama 로 `qwen3-embedding` 8b 임베딩 모델을 서빙하고, 앞단 nginx 가
`Authorization: Bearer <키>` 헤더를 검사한다. 단독 VM 에서 Docker Compose 로 실행하며
k8s 는 쓰지 않는다. UiPath AS 설치와 무관한 **선택 컴포넌트**다.

모델은 이미지 안에 들어 있다. 에어갭 VM 에서는 번들의 이미지 tar 만으로 설치되고,
설치·실행 중에 이미지나 모델을 인터넷에서 받지 않는다.

| flavor | 이미지(로컬) | 모델 | 양자화 | 대상 |
|---|---|---|---|---|
| `cpu` | `ollama-qwen3-embedding:0.40.13-cpu` | `qwen3-embedding:8b` | Q4_K_M (4.7GB) | GPU 없는 VM |
| `gpu` | `ollama-qwen3-embedding:0.40.13-gpu` | `qwen3-embedding:8b-q8_0` | Q8_0 (8.0GB) | NVIDIA GPU VM |

검증 상태는 10절에 있다. GPU 호스트의 드라이버·toolkit·Docker 는 GPU 사전 준비 번들(4.2절)로 오프라인 설치한다.

---

## 1. 구성

```
클라이언트 ──HTTP :80──▶ nginx (ollama-embedding-nginx)
                          │  Authorization: Bearer <키> 검사
                          │  틀리거나 없으면 401 + OpenAI 형식 JSON
                          ▼  frontend + backend 네트워크
                        ollama (ollama-embedding) :11434
                          backend 네트워크만 (internal: true, 외부 경로 없음)
                          호스트 포트 공개 안 함 · 모델은 이미지에 내장
```

| 파일 | 역할 |
|---|---|
| `image/Dockerfile` | `FROM ollama/ollama` + 빌드 중 `ollama pull` 로 모델을 넣는다. flavor 마다 같은 Dockerfile 을 `EMBED_MODEL` 만 바꿔 빌드한다 |
| `conf/nginx/default.conf` | 사용자 샘플 설정. 바꾼 곳은 키 2개 → `include` 1줄, `proxy_pass` 고정 IP → 서비스 이름 `ollama` 뿐이다 |
| `conf/docker-compose.yml.tmpl` | `install.sh` 가 `__PLACEHOLDER__` 를 치환해 `/opt/ollama-embedding/docker-compose.yml` 로 설치한다 |
| `build-bundle.sh` | 온라인 빌드 호스트: 이미지 빌드·검증, `docker save`, 번들 |
| `install.sh` | 에어갭 VM: 적재·키·설정·기동·판정, 자동 복구 검증, 제거 |
| `build-gpu-prep.sh` | 온라인 빌드 호스트: 대상 커널용 드라이버·toolkit·Docker deb 수집, flat apt 저장소, GPU 사전 준비 번들 |
| `install-gpu-prep.sh` | GPU VM: 사전 확인, 번들 저장소만 쓰는 apt 설치, nvidia 런타임 등록, 판정 |

설치 결과:

```
/opt/ollama-embedding/docker-compose.yml          0644
/opt/ollama-embedding/ollama-embedding.env        0600  OLLAMA_EMBED_API_KEY=<키> (원본)
/opt/ollama-embedding/nginx/conf.d/default.conf   0644  -> 컨테이너 /etc/nginx/conf.d (ro)
/opt/ollama-embedding/nginx/secrets/api-key.map   0600  -> 컨테이너 /etc/nginx/secrets (ro, 디렉터리 0700)
compose 프로젝트 ollama-embedding / 네트워크 ollama-embedding_frontend, ollama-embedding_backend(internal)
```

---

## 2. 결정과 근거 (2026-11-03)

| # | 항목 | 결정 | 근거 |
|---|---|---|---|
| D1 | `ollama/ollama` 버전 | **0.40.13**, linux/amd64 자식 매니페스트 `sha256:93c1376d…` 로 `FROM` 고정 | 2026-11-03 기준 `latest` 가 가리키는 정식 릴리스. 0.40.14 는 rc 뿐이다. 저장소 관례대로 플랫폼 매니페스트를 핀해 태그가 움직여도 같은 베이스를 쓴다 |
| D1' | nginx 버전 | **`nginx:1.30.6-alpine`**, amd64 자식 `sha256:84ed8c0d…` | stable 브랜치(운영 권장) 최신. mainline 은 1.31.8. alpine 은 26MB 로 debian 변형보다 작고 필요한 기능(`map`·`include`·`proxy_pass`)은 같다 |
| D1'' | 모델 고정 | 태그로 `ollama pull` 한 뒤 `ollama list` ID 가 핀한 매니페스트 다이제스트 앞 12자리와 다르면 빌드 실패. `verify-urls.sh` 가 레지스트리 매니페스트 sha256 을 핀과 대조한다 | `ollama pull` 은 다이제스트 지정을 지원하지 않는다. 태그가 다른 가중치로 바뀌면 조용히 다른 모델이 들어가므로 빌드 시점에 끊는다 |
| D2 | 빌드 머신 | **인터넷이 되는 Linux x86_64 + Docker Engine(buildx) 호스트.** macOS 는 지원하지 않는다 | 사용자 로컬은 Apple Silicon(arm64)이다. amd64 이미지를 에뮬레이션으로 빌드하면 `RUN` 안의 `ollama serve`/`pull` 이 느리고 동작을 보장할 수 없다. 8~11GB tar 를 다시 VM 으로 옮겨야 하고, 기존 빌드 스크립트도 GNU 도구를 가정한다. podman 빌드 컨테이너 안에는 docker 데몬이 없어 `docker build` 를 못 한다. 그래서 `build-in-container.sh` 는 이 단계를 컨테이너가 아니라 호스트 Docker 로 `build-bundle.sh` 를 실행한다(3절, 2026-11-06 변경. 70-mssql 도 FTS 포함 확인 때문에 같은 방식이다) |
| D3 | 컨테이너 런타임 | **Docker Engine + Compose 플러그인 v2.30 이상** | 저장소의 compose 컴포넌트(redis·pg·mssql·minio)가 모두 `docker compose` 이고 10-k8s 번들이 Docker 를 설치한다. NVIDIA 의 표준 경로가 Docker `--gpus` / compose `gpus:`(v2.30+)다. Podman 은 GPU 에 CDI 생성과 별도 compose 도구가 필요하다 |
| D3' | 엔진·NVIDIA 드라이버·toolkit 번들 포함 | **엔진은 GPU 사전 준비 번들에 포함하고, 없을 때만 설치한다.** NVIDIA 드라이버·toolkit 도 같은 번들에 넣는다(대상 커널별, 4.2절). CPU 번들은 Docker 를 전제로 둔다(10-k8s 번들 또는 사내 저장소) | 85 는 k8s 와 무관한 단독 VM 이고, 10-k8s 설치기에는 Docker 만 설치하는 모드가 없다(swap·sysctl·containerd `config.toml` 까지 바꾼다). 버전 핀은 `versions.env` 하나라 10-k8s 와 갈리지 않는다. Docker 엔진이나 containerd 패키지가 이미 있으면 그대로 둬서 10-k8s 노드와 기존 Docker 호스트를 건드리지 않는다. 2026-11-11 사용자 결정(이전 결정은 "포함하지 않는다") |
| D4 | CPU/GPU 선택 | **빌드 시 flavor 별 번들을 따로 만든다.** 설치는 하드웨어에 맞는 번들 하나를 반입해 `sudo ./install.sh` 만 실행한다. GPU 번들은 GPU 사전 조건이 없으면 아무것도 바꾸기 전에 중단한다. 자동 감지로 이미지를 바꾸지 않는다 | 두 이미지 tar 합계가 약 20GB 라 한 현장에 둘 다 싣는 것은 낭비다. 번들이 곧 선택이므로 결과가 결정적이다. 사전 확인이 없으면 docker 가 `could not select device driver "nvidia"` 로 늦게 실패한다 |
| D5 | nginx TLS | **적용하지 않는다.** 샘플대로 HTTP `listen 80` | 사용자가 동의한 nginx 변경은 세 가지(키 1개, 서비스 이름, 키 외부 주입)뿐이다. TLS 는 인증서 배포·클라이언트 CA 신뢰까지 바꾸는 별도 작업이다(7절) |
| D6 | API 키 주입·보관 | 기존 env 파일 > `OLLAMA_EMBED_API_KEY` > 자동 생성. 원본은 env 파일(0600), nginx 는 파생 map 파일을 디렉터리 마운트로 읽는다(5절) | 키가 git·이미지·컨테이너 Env(`docker inspect`)에 남지 않는다. envsubst 템플릿 방식은 키가 컨테이너 Env 에 보인다 |
| D7 | 안내할 엔드포인트 | **OpenAI 호환 `POST /v1/embeddings` 를 기본**으로, Ollama 네이티브 `POST /api/embed` 도 함께 | 샘플의 401 본문이 OpenAI 오류 형식이고, OpenAI SDK 가 `api_key` 를 `Authorization: Bearer` 로 보내므로 클라이언트는 `base_url` 과 `api_key` 만 바꾸면 된다 |
| D8 | 호스트 포트 | 컨테이너 80, 호스트 `OLLAMA_EMBED_PORT`(기본 80). **11434 는 호스트에 공개하지 않는다** | 11434 를 열면 키 검사를 우회할 수 있다 |
| D9 | 오프라인 증명 | compose `pull_policy: never` + ollama 를 `internal: true` 네트워크에만 연결 + 설치 전 빌드 이미지·빌드 캐시를 지우고 번들 tar 로만 적재 + 설치 이후 `docker events` 와 dockerd·containerd 로그에 이 작업의 pull 없음 + 컨테이너 외부 TCP 연결 실패 판정 | `90-verify/airgap-on.sh` 는 호스트 전체 방화벽을 바꾼다. 공유 VM 을 바꾸지 않고 "이미지·모델을 인터넷에서 받지 않았다"를 직접 보인다 |
| D10 | 이미지 이름 | 레지스트리에 올리지 않는 로컬 이미지 `ollama-qwen3-embedding:<버전>-<flavor>`. Dockerfile 은 하나(ARG `EMBED_MODEL`, `EMBED_MODEL_ID`) | 두 이미지의 차이는 모델 태그뿐이라 Dockerfile 을 나누면 내용이 갈라질 위험만 생긴다 |
| D11 | GPU 사전 준비 번들 형태 (2026-11-11) | GPU Ollama 번들과 **따로 만든다.** `build-gpu-prep.sh` 가 `bundle/ollama-embedding-gpu-prep-<코드네임>-<커널>.tar.gz` 를 만들고, 번들의 `install-gpu-prep.sh` 가 사전 확인·설치·nvidia 런타임 등록·판정을 맡는다. 재부팅은 안내만 한다. Ollama `install.sh` 에는 호스트 수준 변경을 넣지 않는다 | 수명주기가 다르다. 사전 준비 번들은 커널에 묶여 커널마다 다시 만들고(약 0.5GB), Ollama GPU 번들(10.4GiB)은 커널과 무관하다. 사전 준비는 재부팅이 따르는 호스트 수준 변경이고, 드라이버가 이미 있는 호스트(asw)에는 필요 없다. 빌드에 Docker 가 필요 없다 |
| D12 | 커널 고정 (2026-11-11) | 대상 커널은 빌드 옵션 `--kernel`(기본: 빌드 호스트의 `uname -r`)로 정하고 번들 이름과 `conf/target-kernel` 에 기록한다. 대상 노드의 커널이 다르면 `install-gpu-prep.sh` 가 아무것도 바꾸기 전에 멈춘다. DKMS 대체 경로는 두지 않는다. 드라이버는 Ubuntu prebuilt 모듈 `linux-modules-nvidia-595-open-<커널>` 과 **같은 버전**의 flavour 메타(`linux-modules-nvidia-595-open-aws` 등)로 설치한다 | prebuilt 모듈은 커널 ABI 마다 다른 패키지다. 메타를 빼면 `nvidia-dkms` 로 풀려 gcc·헤더·dkms 가 들어오고, 메타 버전을 지정하지 않으면 최신 커널(7.0.0-1017)이 함께 들어온다(2026-11-11 실측). DKMS 모듈은 Canonical 키로 서명되지 않는다(Secure Boot). 커널은 노드마다 달라 `site.env` 값으로 두지 않는다. 아카이브는 포켓마다 최신 버전만 남기므로 그 커널용 메타가 빠지면 그 커널용 번들은 더 만들 수 없다(2026-11-11 기준 7.0.0-1014-aws 용 메타는 noble-security 에만 있다) |
| D13 | deb 수집·설치 방식 (2026-11-11) | 빌드는 임시 디렉터리에 따로 둔 apt 설정(상태·목록·캐시·원본)으로 빈 dpkg 상태의 폐쇄집합을 계산하고, 기준선(Essential/required + `ubuntu-server-minimal` + `linux-image-<커널>`)을 뺀 것만 받는다. `debs/` 는 `apt-ftparchive` 로 flat apt 저장소로 만든다. 설치는 apt 원본을 이 `file:` 저장소 하나로만 두고 최상위 패키지(고정 버전)만 지정한다 | 호스트 apt 를 쓰면 호스트 캐시에 있는 deb 이 `--print-uris` 에서 빠지고(같은 계산이 5개와 150개로 갈렸다), 기존 `docker.sources` 와 Signed-By 가 충돌한다. `dpkg -i *.deb` 는 대상에 이미 있는 패키지를 번들 버전으로 바꾼다(예: git). apt 는 설치된 버전이 의존성을 만족하면 그대로 둔다 |
| D14 | 사전 준비 오프라인 증명 (2026-11-11) | 호스트 방화벽은 바꾸지 않는다. apt 원본이 번들 `file:` 저장소 하나뿐임, 설치 프로세스 트리의 `connect()` 기록(`strace -f`)에 AF_INET/AF_INET6·이름 해석 0건, `/var/cache/apt/archives` 의 deb 수 전후 비교, `/var/log/apt/history.log` 를 함께 보인다. `install-gpu-prep.sh` 는 인터넷 연결 확인을 하지 않는다 | 검증 인스턴스는 SSH 가 공인 IP 로 들어와 방화벽으로 외부를 막으면 접속을 잃는다. 판단에 쓰지 않는 외부 연결은 strace 증거를 흐린다 |

버전 핀은 모두 `00-common/versions.env` 에 있다(`OLLAMA_*`, GPU 사전 준비는 `NVIDIA_*` 와 Docker 절).

---

## 3. 빌드 (온라인 빌드 호스트)

빌드 호스트 요건:

| 항목 | 요건 |
|---|---|
| OS / 아키텍처 | Linux x86_64 (macOS·arm64 불가) |
| 도구 | Docker Engine + buildx, curl, skopeo(없으면 자동 설치), pigz(선택) |
| 네트워크 | Docker Hub, `registry.ollama.ai` |
| RAM | 16GB 이상 (빌드 검증에서 모델을 CPU 로 한 번 띄운다) |
| 디스크 | docker 저장소 + `bundle/` 합쳐 all 약 80GB, 단일 flavor 약 40GB |

```bash
cd offline-install
./00-common/verify-urls.sh            # "Ollama 임베딩" 4항목이 OK 여야 한다
cd 85-ollama-embedding
./build-bundle.sh                     # all = cpu + gpu (cpu | gpu 로 하나만)
```

`00-common/build-in-container.sh` 로도 빌드할 수 있다. `all` 에 이 단계가 들어 있고, 단계 이름으로 직접 지정해도 된다.

```bash
./00-common/build-in-container.sh 24.04 85-ollama-embedding   # 또는 24.04 all
```

- 이 단계는 podman 컨테이너가 아니라 **호스트 Docker** 로 `./build-bundle.sh all`(cpu + gpu)을 실행한다(D2). 다른 단계가 있으면 컨테이너 단계가 끝난 뒤에 실행한다. OS 인자(`24.04`)는 이 단계에 영향이 없다. flavor 하나만 빌드하려면 위처럼 `build-bundle.sh cpu|gpu` 를 직접 실행한다.
- 실행 계정이 docker 데몬에 접근하지 못하면 빌드 시작 때 docker 그룹 권한을 구성한다. `sudo docker` 로 우회하지 않는다.
  - 이미 docker 그룹 회원(`/etc/group`)인데 지금 세션에만 그룹이 없으면(그룹 추가 전에 연 셸, tmux 서버) 아무것도 바꾸지 않고 `sg docker` 로 실행한다. 이때 번들 파일의 그룹은 `docker` 가 된다.
  - 회원이 아니면 바꾸는 내용과 경고(**docker 그룹은 root 와 같은 권한**)를 출력하고 `sudo usermod -aG docker <계정>` 을 실행한 뒤 `sg docker` 로 실행한다. 확인은 묻지 않는다. stdin 이 터미널이 아니면 `sudo -n` 이라 암호가 필요하면 실패한다. 되돌리기는 `sudo gpasswd -d <계정> docker`.
- 그래도 쓸 수 없으면 `WARN` 으로 원인과 조치를 출력하고 이 단계만 건너뛴다. 원인은 Docker 미설치, 데몬 접근 불가, sudo 불가, docker 그룹 없음, Linux x86_64 아님으로 나눠 출력한다. 종료 코드는 `all` 이면 영향이 없고, 단계로 직접 지정했으면 1 이다.
- `build-bundle.sh` 를 직접 실행할 때는 예전처럼 docker 그룹이 아니면 `sudo docker` 로 실행한다.
- 빌드 컨테이너 안에서 `build-bundle.sh` 를 실행하면 `FATAL 필요한 명령이 없다: docker` 로 멈춘다. 호스트의 `which docker` 가 정상이어도 컨테이너 안에는 docker 가 없다. 이 변경 전의 `build-in-container.sh` 에서 `ALL_STAGES` 에 이 단계를 직접 넣어 돌리면 이렇게 된다.

`build-bundle.sh` 가 확인하는 것:

1. nginx 설정 문법: 번들에 넣을 nginx 이미지로 `nginx -t`
2. 이미지 빌드: Dockerfile 이 `ollama list` ID 를 핀과 대조(다르면 빌드 실패)
3. 빌드 이미지 실행 검증: 모델 ID, `ollama show` 의 양자화·`embedding length 4096`·capability `embedding`, `/api/embed` 응답 벡터 4096차원. **GPU 이미지도 `--gpus` 없이 CPU 로 띄워 같은 검사를 한다**

산출물 (2026-11-04 실측, 테스트 VM = 빌드 호스트):

| 번들 | tar.gz | 안의 이미지 tar | 빌드 시간 |
|---|---|---|---|
| `bundle/ollama-embedding-cpu-0.40.13.tar.gz` | 7.5GiB (8,003,904,770 B) | ollama 7.4GiB + nginx 61MiB | 약 10분 |
| `bundle/ollama-embedding-gpu-0.40.13.tar.gz` | 10.4GiB (11,135,654,881 B) | ollama 10.4GiB + nginx 61MiB | 약 13분 |

`./build-bundle.sh all` 전체는 1359초였다(i9-10885H 16스레드, 인터넷 직결). 대부분은 베이스 레이어 받기(114초),
`ollama pull`(CPU 145초 / GPU 245초), 이미지 내보내기(173초 / 297초), `docker save`(91초 / 128초)다.
모델 가중치는 거의 압축되지 않아 tar.gz 와 tar 크기가 같다. 각 번들에는 `.sha256` 이 함께 만들어진다.

빌드 호스트 디스크 사용량은 all 기준 **79GiB 늘었다**(docker 저장소의 두 이미지 + 빌드 캐시 + `bundle/` 의 tar 와
압축 해제 디렉터리). 빌드 뒤 `docker image rm` 과 `docker builder prune` 으로 docker 쪽을 되돌릴 수 있다.

번들 내용:

```
BUNDLE-INFO  SHA256SUMS  install.sh  README.md
00-common/{versions.env, site.env|site.env.example, common.sh, os/}
images/ollama-qwen3-embedding_0.40.13-<flavor>.tar   (docker save)
images/docker.io_library_nginx_1.30.6-alpine.tar     (skopeo, amd64 다이제스트)
conf/{flavor, images.list, images.digests, docker-compose.yml.tmpl, nginx/default.conf}
```

### GPU 사전 준비 번들

NVIDIA GPU VM 에 드라이버·toolkit·Docker 를 오프라인으로 설치하는 번들이다(D11~D13). **대상 커널마다** 따로 빌드한다.

| 항목 | 요건 |
|---|---|
| OS / 아키텍처 | 대상과 같은 Ubuntu 코드네임(예: 24.04 noble), amd64. 대상 커널로 부팅돼 있을 필요는 없다(같은 릴리스 아카이브에 그 커널용 모듈이 있으면 된다) |
| 네트워크 | Ubuntu 아카이브(restricted 포함), `download.docker.com`, `nvidia.github.io` |
| 권한·도구 | 일반 사용자. sudo 불필요(`apt-ftparchive` 가 없을 때만 `apt-utils` 를 sudo 로 설치). Docker 불필요 |
| 디스크 | 약 1GB (`bundle/` 의 압축 해제 디렉터리 + tar.gz) |

```bash
cd offline-install
./00-common/verify-urls.sh                        # "NVIDIA GPU 사전 준비" 5항목이 OK 여야 한다
cd 85-ollama-embedding
./build-gpu-prep.sh                               # 대상 커널 = 이 호스트의 uname -r
./build-gpu-prep.sh --kernel 6.8.0-147-generic    # 다른 커널용 (대상 노드의 uname -r)
```

`build-gpu-prep.sh` 가 확인하는 것:

1. 버전 결정: `nvidia-driver-595-open` 의 `595.99.02-*`, 대상 커널용 prebuilt 모듈 `linux-modules-nvidia-595-open-<커널>`, 그 모듈과 같은 버전의 flavour 메타 `linux-modules-nvidia-595-open-<flavour>`(`<커널>` 의 ABI 뒤 부분, 예: `aws`, `generic`). 메타에 같은 버전이 없으면 같은 버전을 가진 메타 후보를 출력하고 멈춘다
2. 의존성 폐쇄집합: 빈 dpkg 상태에서 기준선(Essential/required + `ubuntu-server-minimal` + `linux-image-<커널>`)과 기준선 + 대상을 계산해 차이만 받는다. 최상위 패키지(드라이버 3개, toolkit 4개, Docker 6개)가 모두 차이에 있어야 한다
3. 거부: 핵심 시스템 패키지(systemd·libc6·perl·python3 등, 10-k8s 와 같은 목록), 커널 패키지(`linux-image-`·`linux-headers-`·`linux-modules-<숫자>`·`linux-modules-extra-`), `dkms`·`nvidia-dkms-*` 가 섞이면 멈춘다
4. 받은 deb 수 = 차이 수, `debs/Packages` 항목 수 = deb 수

빌드 호스트에 남기는 변경은 없다. apt 상태·목록·캐시·원본을 임시 디렉터리로 돌리고(D13), 호스트의 Ubuntu 원본 목록은 복사해 읽기만 한다.

산출물은 `bundle/ollama-embedding-gpu-prep-<코드네임>-<커널>.tar.gz` 와 `.sha256` 이다(예: `ollama-embedding-gpu-prep-noble-7.0.0-1014-aws.tar.gz`).
크기는 2026-11-11 실측(빌드 호스트 g4dn.2xlarge, Ubuntu 24.04.5, 커널 7.0.0-1014-aws)으로 deb 170개 498.5MiB, tar.gz 약 498MiB 이고, 빌드는 85초 걸렸다.
같은 호스트에서 `--kernel 6.8.0-147-generic` 으로도 만들어졌다(deb 170개 498.3MiB, 75초. 모듈과 메타 `6.8.0-147.147+1`).

번들 내용:

```
BUNDLE-INFO  SHA256SUMS  install-gpu-prep.sh  README.md
00-common/{versions.env, site.env.example, common.sh, os/}   (site.env 는 넣지 않는다)
conf/{target-kernel, codename, gpu.specs, docker.specs, packages.list}
debs/{*.deb, Packages, Packages.gz, Release}                  (flat apt 저장소)
```

- `conf/packages.list` 는 줄마다 `패키지 버전 바이트` 다. `gpu.specs`·`docker.specs` 는 설치할 최상위 패키지(`이름=버전`)다.
- 이 번들은 사이트 값을 쓰지 않는다. 그래서 설치 때 나오는 `site.env 가 없어 site.env.example 의 예시 값을 쓴다` 경고는 무시해도 된다.
- `00-common/build-in-container.sh` 의 `all` 에는 들어가지 않는다. 대상 커널마다 따로 빌드해야 하므로 위 명령으로 직접 실행한다.

---

## 4. 설치 (에어갭 VM)

### 4.1 전제

- Docker Engine + Compose 플러그인 v2.30 이상 (CPU 번들: 10-k8s 번들 또는 사내 저장소. GPU 번들: 4.2절 GPU 사전 준비 번들이 설치한다)
- `curl`, `openssl`, `ss`
- 디스크: 아래 표. containerd 이미지 저장소(`docker info` 의 `driver-type: io.containerd.snapshotter.v1`)는 이미지를 압축본과 해제본으로 이중 저장한다

| 항목 | CPU 번들 | GPU 번들 |
|---|---|---|
| tar.gz | 7.5GiB | 10.4GiB |
| 압축 해제 디렉터리 | 7.5GiB | 10.4GiB |
| docker 저장소 적재분 | **16.8GiB** (실측, 이미지 tar 합계의 2.24배) | 약 23GiB (추정: tar × 2.24, 미실측) |
| 합계 (설치 중 최대) | 약 32GiB | 약 44GiB |

설치가 끝나면 tar.gz 와 압축 해제 디렉터리는 지워도 된다(재설치·`--check-only` 에는 압축 해제 디렉터리가 필요하다).

`install.sh` 는 이미지가 아직 없을 때 docker 저장소 여유가 **이미지 tar 합계 × 2.5** 보다 작으면 중단한다.
2.5 는 실측 비율(2.22, 2.24)에 10% 여유를 더한 값이다.

### 4.2 GPU 번들의 추가 전제 — GPU 사전 준비 번들

GPU 번들을 설치하려면 호스트에 다음이 있어야 한다. 없으면 `install.sh` 가 이미지 적재 전에 중단한다.

1. NVIDIA 드라이버: `nvidia-smi -L` 이 GPU 를 보여야 한다
2. nvidia-container-toolkit 과 docker 의 nvidia 런타임 등록
3. Docker Engine + Compose 플러그인

드라이버가 없는 GPU VM 에서는 GPU 사전 준비 번들(3절 "GPU 사전 준비 번들")로 셋을 오프라인 설치한다.
번들은 대상 노드의 커널(`uname -r`)과 Ubuntu 코드네임에 맞춰 빌드한 것이어야 한다.

```bash
sha256sum -c ollama-embedding-gpu-prep-noble-7.0.0-1014-aws.tar.gz.sha256
tar xzf ollama-embedding-gpu-prep-noble-7.0.0-1014-aws.tar.gz && cd ollama-embedding-gpu-prep-noble-7.0.0-1014-aws
sudo ./install-gpu-prep.sh --dry-run      # 사전 확인 + apt 시뮬레이션만. 아무것도 바꾸지 않는다
sudo ./install-gpu-prep.sh                # 설치 + 판정. 재부팅 안내가 나온다
sudo reboot
sudo ./install-gpu-prep.sh --check-only   # 재부팅 뒤 판정 (8절)
# 이어서 GPU 번들
cd ../ollama-embedding-gpu-0.40.13 && sudo ./install.sh
```

`install-gpu-prep.sh` 의 동작:

| 상황 | 동작 |
|---|---|
| 커널이 번들과 다르다 | 아무것도 바꾸기 전에 멈춘다(`커널이 번들과 다르다: 지금 … / 번들 …`). 그 커널용 번들을 `./build-gpu-prep.sh --kernel <uname -r>` 로 만든다. 커널을 바꾸거나 DKMS 로 빌드하지 않는다 |
| Ubuntu 코드네임이 다르다, 지금 커널이 Ubuntu 커널 패키지(`linux-image-<커널>`)가 아니다 | 멈춘다. 아무것도 바꾸지 않는다 |
| 번들과 이름·버전이 다른 NVIDIA 드라이버가 있다(DKMS 드라이버 등) | 멈춘다. 이 번들은 드라이버가 없는 호스트용이다. 번들과 이름·버전이 같은 것만 있으면 재실행으로 보고 진행한다 |
| Docker 엔진·containerd 가 이미 있다(`docker-ce`, `docker-ce-cli`, `docker.io`, `docker-engine`, `moby-engine`, `containerd.io`, `containerd`, `podman-docker` 중 하나 또는 `dockerd`) | Docker 는 설치하지 않고 그대로 둔다 |
| Docker 가 없다 | 번들의 Docker(`versions.env` 핀)를 설치하고 enable 한다 |
| apt 시뮬레이션 | 원본을 번들 `debs/` 하나로 두고 `apt-get -s install` 을 먼저 한다. 의존성이 풀리지 않거나, 패키지 제거·커널 패키지·dkms 설치가 하나라도 있으면 멈춘다. 업그레이드는 허용하고 목록을 출력한다 |
| 번들 deb 중 설치하지 않는 것 | 대상에 이미 있는 패키지는 설치된 버전이 의존성을 만족하면 그대로 둔다(예: `git`). 번들만으로 풀리지 않는 Recommends 는 apt 가 건너뛴다. 빌드 기준선의 폐쇄집합에 들어 있어 번들에 넣지 않은 `python3-xkit` 이 대상에 없으면 `nvidia-settings`(GUI 설정 도구, 드라이버의 Recommends)와 그 GTK·글꼴 의존성은 설치되지 않는다. 드라이버·CUDA·컨테이너 동작에는 영향이 없다(10절 실측: 170개 중 79개 설치) |
| nvidia 런타임 | docker 런타임에 `nvidia` 가 없을 때만 `nvidia-ctk runtime configure --runtime=docker` 와 docker 재시작을 한다. 기존 `daemon.json` 은 `.bak.<시각>` 으로 복사한다. 실행 중인 컨테이너가 있으면 경고한다 |
| nouveau | 차단 파일을 직접 만들지 않는다. `nvidia-kernel-common-595` 가 `/lib/modprobe.d/nvidia-graphics-drivers.conf` 를 설치하고 initramfs 를 다시 만든다. 스크립트는 그 결과를 판정한다 |
| 재부팅 | 하지 않는다. nvidia 모듈이 적재되지 않았으면 재부팅 안내를 출력한다 |
| 재실행 | 같은 번들로 다시 실행하면 apt 는 설치할 것이 없고, 런타임은 "변경 없음"이라 docker 를 재시작하지 않는다 |

바꾸는 것과 되돌리는 방법(apt 원본 목록 `/etc/apt/sources.list*` 와 커널은 바꾸지 않는다):

| 바뀐 것 | 되돌리는 방법 |
|---|---|
| NVIDIA 드라이버 패키지(`nvidia-driver-595-open`, prebuilt 모듈과 메타, X 의존성 포함. `nvidia-settings` 와 GTK 의존성은 그 Recommends 가 풀린 호스트에만 있다), nouveau 차단 파일, initramfs 재생성 | `sudo apt-get purge 'nvidia-*595*' 'libnvidia-*595*' linux-modules-nvidia-595-open-<flavour> linux-modules-nvidia-595-open-<커널> nvidia-prime nvidia-settings && sudo apt-get autoremove`. `/etc/modprobe.d/nvidia-graphics-drivers-kms.conf` 가 남으면 지우고 `sudo update-initramfs -u` 뒤 재부팅하면 nouveau 로 돌아간다 |
| toolkit 4개 패키지, `nvidia-cdi-refresh` 유닛 enable, `/var/run/cdi/nvidia.yaml` | `sudo apt-get purge nvidia-container-toolkit nvidia-container-toolkit-base libnvidia-container-tools libnvidia-container1` |
| `/etc/docker/daemon.json` (nvidia 런타임) | 백업(`daemon.json.bak.<시각>`)이 있으면 되돌리고, 없으면(새로 만든 파일) 지운다. 이어서 `sudo systemctl restart docker` |
| Docker 패키지 6개와 의존 패키지(번들이 설치한 경우) | GPU 번들을 먼저 제거(`sudo ./install.sh --uninstall`)한 뒤 `sudo apt-get purge docker-ce docker-ce-cli docker-ce-rootless-extras containerd.io docker-buildx-plugin docker-compose-plugin && sudo apt-get autoremove`. 데이터까지 지우려면 `/var/lib/docker`, `/var/lib/containerd` 를 지운다(복구 불가) |

VRAM: Q8_0 가중치가 8.0GB 다. VRAM 이 이보다 작으면 일부 레이어가 CPU 로 내려가고 `ollama ps` 의 PROCESSOR 가 CPU/GPU 혼합으로 나온다. VRAM 12GB 이상을 권장한다.

### 4.3 설치

```bash
# 하드웨어에 맞는 번들 하나만 옮긴다
sha256sum -c ollama-embedding-cpu-0.40.13.tar.gz.sha256
tar xzf ollama-embedding-cpu-0.40.13.tar.gz && cd ollama-embedding-cpu-0.40.13
sudo ./install.sh
```

옵션은 `--check-only`, `--test-restart`, `--uninstall` 이다.

### 4.4 설정 값 (`site.env`)

| 키 | 기본 동작 |
|---|---|
| `OLLAMA_EMBED_PORT` | `80`. nginx 를 노출할 호스트 포트 |
| `OLLAMA_EMBED_API_KEY` | **비우면 자동 생성**(권장). 5절 |

---

## 5. API 키

| 항목 | 내용 |
|---|---|
| 주입 우선순위 | ① 대상 호스트의 기존 `/opt/ollama-embedding/ollama-embedding.env` → ② 환경변수 또는 `site.env` 의 `OLLAMA_EMBED_API_KEY` → ③ `sk-` + `openssl rand -hex 16`(35자, 128비트) 생성. ②가 ①과 다르면 경고하고 ①을 유지한다 |
| 형식 | `^[A-Za-z0-9._-]{20,39}$`. 아니면 중단한다. 문자 제한은 nginx 문자열에 `"`·`\`·`$`·`;`·공백이 들어가지 않게 하려는 것이고, 길이 상한은 아래 "키 길이 상한" 때문이다 |
| 원본 | `/opt/ollama-embedding/ollama-embedding.env` (root 0600, `OLLAMA_EMBED_API_KEY=<키>` 한 줄, 따옴표 없이) |
| nginx 용 | `/opt/ollama-embedding/nginx/secrets/api-key.map` (디렉터리 0700, 파일 0600, `"Bearer <키>" 1;` 한 줄). `install.sh` 가 매번 env 에서 다시 만들고 백업을 남기지 않는다 |
| git 의 설정 | `conf/nginx/default.conf` 의 `map` 은 `include /etc/nginx/secrets/api-key.map;` 만 한다 |
| 출력 | 생성했을 때만 설치 끝에 한 번 출력한다. `--check-only` 는 키를 출력하지 않는다 |
| 확인 | `sudo grep '^OLLAMA_EMBED_API_KEY=' /opt/ollama-embedding/ollama-embedding.env` |

키를 직접 정하려면 `site.env` 보다 **설치 전에 env 파일을 만드는 방법**을 권장한다. `site.env` 에
적은 키는 번들에 그대로 실리고, `sudo OLLAMA_EMBED_API_KEY=... ./install.sh` 는 셸 기록에 남는다.

```bash
sudo install -d -m 0755 /opt/ollama-embedding
sudo sh -c 'umask 077; echo "OLLAMA_EMBED_API_KEY=<키>" > /opt/ollama-embedding/ollama-embedding.env'
```

키 교체:

```bash
sudo vi /opt/ollama-embedding/ollama-embedding.env     # 값만 바꾼다
sudo ./install.sh                                      # map 재생성 + nginx -t + nginx -s reload
```

nginx 는 키 파일을 **디렉터리 단위로** 마운트한다. 단일 파일 bind mount 는 파일을 새로
쓰면(mv) 옛 inode 를 계속 보여 주어 교체가 반영되지 않는다.

### 키 길이 상한 (39자)

샘플 nginx 설정은 `map_hash_bucket_size` 를 지정하지 않는다. 기본값은 CPU 캐시 라인
크기(x86_64 에서 64바이트)이고, map 의 문자열 키 `"Bearer <키>"` 가 이 버킷에 들어가지
않으면 nginx 가 아래 오류로 **기동하지 않는다**(재시작 반복).

```
[emerg] could not build map_hash, you should increase map_hash_bucket_size: 64
```

테스트 VM 에서 nginx 1.30.6 으로 잰 경계는 **키 39자 통과, 40자 실패**다. 처음 구현은
`sk-` + hex 48자(51자) 키를 생성해 이 오류로 nginx 가 뜨지 않았다(10절). 샘플 설정을
바꾸지 않고 생성 키를 35자로 줄이고 상한을 39자로 두었다. 더 긴 키가 필요하면
`conf/nginx/default.conf` 의 `map` 블록 앞에 `map_hash_bucket_size 128;` 을 넣어야 한다
(샘플 설정 변경이다).

헤더의 `Bearer` 는 대소문자를 가리지 않는다(`bearer`·`BEARER` 도 통과). nginx 의 `map`
문자열 비교가 대소문자를 구분하지 않기 때문이다. 같은 이유로 **키 값의 대소문자도
구분하지 않는다**(실측: 키를 대문자로 바꿔 보내도 200). 생성 키는 소문자 hex 라 엔트로피는
그대로 128비트다. 직접 정한 키에 대소문자를 섞으면 그만큼 엔트로피가 줄어든다.

---

## 6. 사용법

모델 이름은 flavor 마다 다르다: CPU `qwen3-embedding:8b`, GPU `qwen3-embedding:8b-q8_0`.

OpenAI 호환 (권장):

```bash
curl -sS http://<VM>:80/v1/embeddings \
  -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
  -d '{"model":"qwen3-embedding:8b","input":"hello"}'
# {"object":"list","data":[{"object":"embedding","embedding":[...4096개...],"index":0}],...}
```

```python
from openai import OpenAI
client = OpenAI(base_url="http://<VM>/v1", api_key="<키>")
vec = client.embeddings.create(model="qwen3-embedding:8b", input="hello").data[0].embedding
```

Ollama 네이티브 (같은 키):

```bash
curl -sS http://<VM>:80/api/embed \
  -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
  -d '{"model":"qwen3-embedding:8b","input":["hello","world"]}'
# {"model":"qwen3-embedding:8b","embeddings":[[...],[...]],...}
```

키가 없거나 틀리면:

```
HTTP/1.1 401 Unauthorized
Content-Type: application/json

{"error": {"message": "Invalid or missing API key.", "type": "invalid_request_error", "code": "invalid_api_key"}}
```

첫 요청은 모델을 메모리에 올리므로 느리다. Ollama 는 기본 5분 동안 요청이 없으면 모델을 내린다.

---

## 7. 주의

- **`/root/.ollama` 에 bind mount·볼륨을 걸지 말 것.** 모델은 이미지의 `/root/.ollama/models` 에 있다. 그 경로에 마운트하면 이미지에 넣은 모델이 가려져 `model "qwen3-embedding:8b" not found` 가 된다. 이 compose 는 ollama 에 볼륨을 두지 않는다
- **11434 를 호스트에 공개하지 말 것.** 공개하면 nginx 의 키 검사를 우회한다
- **TLS 미적용.** 키가 평문으로 전송된다. 신뢰된 내부망에서만 쓰고 방화벽으로 접근 대역을 제한한다. TLS 가 필요하면 05-certs 로 인증서를 발급해 443 server 블록을 추가하는 후속 작업이 필요하다
- **키 검사는 경로를 가리지 않는다.** 유효한 키를 가진 클라이언트는 `/api/delete`·`/api/create`·`/api/pull` 같은 관리 API 도 부를 수 있다(`/api/pull` 은 internal 네트워크라 실패한다). 경로 제한은 nginx 설정 변경이 필요한 후속 작업이다
- **모델 추가·변경은 이미지 재빌드다.** `versions.env` 의 모델 태그·다이제스트를 바꾸고 `build-bundle.sh` 를 다시 돌린다

---

## 8. 판정 항목

```
docker / compose 사용 가능 · 두 이미지 적재됨
compose 파일 존재 · compose 설정 유효 · env 0600 · 키 map 0600 / 디렉터리 0700 / Bearer 1줄
ollama / nginx 실행 중(크래시 루프 아님)      <- PID 10초 유지
재시작 정책 unless-stopped · ollama health=healthy · ollama 컨테이너 이미지 = flavor 이미지
  -- 오프라인 구성 --
ollama 호스트 포트 비공개 · ollama 네트워크 = backend(internal) 하나
ollama 컨테이너에서 외부 TCP 연결 불가(1.1.1.1:443, registry.ollama.ai:443)
이미지 안 모델 = 핀한 ID
  -- nginx 키 검사 / 임베딩 --
호스트 포트 수신 · 키 없음 401 + JSON · 틀린 키 401 + JSON
올바른 키 /v1/embeddings 200 + 4096차원 · /api/embed 200 + 4096차원
  -- GPU 번들만 --
컨테이너 nvidia-smi -L · 모델이 GPU 에 적재됨(ollama ps)
```

401 판정은 상태 코드, `Content-Type: application/json`, 본문이 샘플 문자열과 정확히 같은지를 모두 본다.
키는 curl 인자가 아니라 stdin(`-H @-`)으로 넘겨 `ps` 에 보이지 않는다.

GPU 사전 준비 판정(`install-gpu-prep.sh --check-only`, 4.2절):

```
  -- 설치 상태 --
커널 = 번들 커널 · 다음 부팅 커널(/boot/vmlinuz-* 최신) = 번들 커널
패키지 버전 = 번들 (드라이버 · prebuilt 모듈 · flavour 메타 · toolkit 4개)
nouveau 차단 설정(modprobe -c 에 blacklist nouveau) · initramfs 에 nvidia-graphics-drivers.conf
nvidia-ctk 1.20.1 · docker / compose 사용 가능 · docker 런타임에 nvidia
  -- 드라이버 동작 (--check-only 는 항상, 설치 직후에는 nvidia 모듈이 적재돼 있을 때만) --
nouveau 미적재 · nvidia 모듈 적재 · nvidia-smi -L 에 GPU · 드라이버 버전 = 595.99.02
```

---

## 9. 자동 복구

```bash
sudo ./install.sh --test-restart
```

| 단계 | 방법 | 확인 |
|---|---|---|
| 프로세스 사고사 | 두 컨테이너 각각 호스트에서 PID 에 `kill -9` | `RestartCount` 증가 + 올바른 키 `/v1/embeddings` 200 |
| 재부팅 대리 | `systemctl restart docker` | 두 컨테이너 running + 200 |

`docker kill` 로 시험하면 안 된다. 수동 정지로 기록되어 `unless-stopped` 가 재시작하지
않는다(40-haproxy 3절). `systemctl restart docker` 는 **같은 호스트의 다른 컨테이너도
재시작한다.**

---

## 10. 검증 상태

2026-11-04 에 Ubuntu 24.04.5 테스트 VM(x86_64, Docker 29.8.1 containerd 이미지 저장소, Compose 5.5.1)에서 수행했다.
같은 VM 을 빌드 호스트로도 썼다. VM 에는 NVIDIA GPU(Turing, VRAM 8GB)가 있지만 드라이버가 없다(nouveau).

| 항목 | 결과 |
|---|---|
| `verify-urls.sh` "Ollama 임베딩" 4항목 | **통과** (베이스·nginx 다이제스트, 두 모델 매니페스트 = 핀) |
| 번들 빌드 `./build-bundle.sh all` | **완료** (1359초, cpu 7.5GiB / gpu 10.4GiB) |
| 빌드 이미지 검증 (cpu) | 모델 ID `64b933495768`, Q4_K_M, embedding length 4096, `/api/embed` 4096차원 |
| 빌드 이미지 검증 (gpu, CPU 로 실행) | 모델 ID `9704fd987c12`, Q8_0, embedding length 4096, `/api/embed` 4096차원 |
| CPU 번들 설치 + 판정 | **통과 22/22** (번들 tar 만으로 적재) |
| 키 없음 / 틀린 키 / `Basic` 헤더 | **401** + `application/json` + 샘플 JSON 본문 그대로 |
| 올바른 키 `/v1/embeddings` · `/api/embed` | **200**, 4096차원 (입력 2개 배열도 정상) |
| 11434 직접 접속(VM·외부 클라이언트) | 연결 거부 |
| 재실행 멱등성 | 키 유지(env 파일 해시 동일), 설정 "변경 없음", 컨테이너 재생성 없음, 22/22 |
| 키 교체 (env 수정 → `install.sh`) | 옛 키 401, 새 키 200, map 에 옛 키 없음 |
| 자동 복구 `--test-restart` | **통과** (두 컨테이너 PID kill -9 → `RestartCount 0 -> 1`, docker 데몬 재시작 후 200) |
| GPU 번들 설치 (드라이버 없는 VM) | 사전 확인에서 **중단**(rc=1), 이미지·`/opt/ollama-embedding`·컨테이너 변화 없음, 기존 CPU 배포 200 유지 |
| GPU compose 렌더링 | Compose 5.5.1 이 `gpus: all` → `count: -1` 로 수용 |
| GPU(CUDA) 실행 경로 (이 VM) | 이 VM 에서는 미검증 — 드라이버·nvidia-container-toolkit 이 없다. 아래 2026-11-11 행에서 다른 호스트로 검증했다 |
| **GPU 번들 설치 (Tesla T4 16GB, 2026-11-11)** | **통과 24/24.** g4dn.2xlarge, Ubuntu 24.04.5, 커널 7.0.0-1014-aws, 드라이버 595.99.02(open, Ubuntu prebuilt 모듈), toolkit 1.20.1-1, Docker 29.8.1. 같은 커밋으로 그 호스트에서 다시 빌드한 번들을 썼다(모델 digest `9704fd98…` = 핀). `ollama ps` = `100% GPU`(9.1 GB, 37/37 레이어), VRAM 8805/15360 MiB. `--check-only`·재설치 멱등, `--test-restart` 통과, 재부팅 뒤 자동 기동과 GPU 재적재 확인 |
| GPU 응답 시간 (T4, 같은 Q8_0 을 CPU 8 vCPU 로 돌린 것과 비교) | 4토큰 0.045초 (CPU 0.31초), 633토큰 0.49초 (CPU 39.9초). 컨테이너를 만든 뒤 처음 들어오는 긴 입력은 CUDA JIT 로 25.6초 걸렸고, 그 뒤로는 다시 생기지 않았다 |
| GPU 번들 설치 (Quadro RTX 4000 Max-Q 8GB, 2026-11-11) | 통과 24/0. 다만 모델이 `28%/72% CPU/GPU` 혼합으로 적재됐다. 판정(`ollama_on_gpu`)은 혼합 적재도 통과시키므로 `100% GPU` 와 구분하지 못한다. VRAM 12GB 이상 권고(4.2절)와 맞는 결과다 |
| **GPU 사전 준비의 오프라인 설치 (Tesla T4, 2026-11-11)** | **통과.** 드라이버·toolkit·Docker 가 없는 새 g4dn.2xlarge(Ubuntu 24.04.5, 커널 7.0.0-1014-aws, nouveau 적재, Secure Boot 꺼짐)에서 했다. 번들 `ollama-embedding-gpu-prep-noble-7.0.0-1014-aws.tar.gz` 은 522,316,270 B, sha256 `49a42cde…`, deb 170개 498.5MiB 다. 번들은 요약 로그 문구를 고치기 전과 뒤에 두 번 빌드했고 deb 170개와 `Packages` 의 해시는 같다. 첫 설치는 고치기 전 번들로, 재실행과 판정은 고친 뒤 번들로 했다. `--dry-run` 과 설치 모두 새로 설치 79 / 업그레이드 0 / 제거 0 / 커널·dkms 0 이고, 설치 직후 판정은 15/15 다. 재부팅 뒤 `nvidia-smi` 에 Tesla T4 와 595.99.02 가 보이고 docker 런타임에 `nvidia` 가 있으며 `--check-only` 는 19/19 다. 재실행은 apt 설치 0, 런타임 "변경 없음", docker 재시작 없음이다. 이어서 GPU 번들 `install.sh` 24/24, `ollama ps` = `100% GPU`(9.1 GB), VRAM 8805/15360 MiB, `--check-only` 2회 결과 같음, `--test-restart` 통과, 재부팅 뒤 자동 기동과 GPU 재적재를 확인했다. 커널은 바뀌지 않았다(`uname -r` 과 `/boot/vmlinuz-*` 가 같고, 커널 패키지는 `linux-modules-nvidia-595-open-*` 2개만 늘었다). 가짜 `uname`(-r = 6.8.0-147-generic)으로는 `--dry-run` 과 설치 모두 `커널이 번들과 다르다` 로 rc=1 이고 dpkg 목록이 그대로다. 증거는 이 절 끝 |

```
=== 검증 결과: 통과 22 / 실패 0 ===
flavor=cpu / ollama version is 0.40.13 / 모델=qwen3-embedding:8b(Q4_K_M) / 포트=80
ollama: "inference compute" id=cpu library=cpu ... total="125.4 GiB"
```

오프라인 증거(호스트 방화벽을 바꾸지 않고 확인, D9):

1. 설치 전에 빌드 산출 이미지·nginx 이미지를 지우고 빌드 캐시를 0B 로 비웠다(`docker images` 가 작업 전 기준선과 같음)
2. compose 는 두 서비스 모두 `pull_policy: never`
3. 설치 시작 이후 `docker events --filter type=image --filter event=pull` 출력 없음. 다만 이 VM(containerd 이미지 저장소)의 dockerd 는 `docker load` 도 image 이벤트로 남기지 않았다. 그래서 dockerd·containerd 로그도 함께 봤고, 이 작업의 pull 기록은 없었다(같은 시간대에 k8s kubelet 이 다른 이미지를 받은 기록 1건만 있다)
4. `ollama-embedding_backend` 의 `Internal=true`, ollama 는 이 네트워크에만 붙어 있다. 컨테이너에서 `1.1.1.1:443` 은 `Network is unreachable`, `registry.ollama.ai` 는 이름 해석 실패
5. 실행 중 컨테이너의 `ollama list` = `qwen3-embedding:8b 64b933495768`, 볼륨 없음. 이미지 ID 가 번들 `BUNDLE-INFO` 의 `image_id` 와 같다

검증 중 고친 것:

1. **생성 키가 길어 nginx 가 기동하지 않았다.** 처음 구현은 `sk-` + hex 48자(51자) 키를 만들었고, nginx 가
   `could not build map_hash, you should increase map_hash_bucket_size: 64` 로 재시작을 반복했다. 빌드 시 `nginx -t`
   는 30자 시험 키를 써서 이를 잡지 못했다. 경계를 재서(39자 통과, 40자 실패) 생성 키를 35자로, 허용 상한을 39자로 줄였고,
   빌드 시 `nginx -t` 를 39자 키로 하도록 바꿨다. 샘플 nginx 설정은 바꾸지 않았다(5절).
2. **nginx 기동 실패 원인이 보이지 않았다.** `docker exec` 가 "is restarting" 으로만 실패했다. 기동 단계에서 nginx 가
   안정적으로 떠 있는지 먼저 보고, 아니면 nginx 로그를 출력하고 중단하도록 했다.

GPU 사전 준비 오프라인 증거(2026-11-11 T4, 호스트 방화벽을 바꾸지 않고 확인, D14):

1. apt 원본은 번들 `file:` 저장소 하나다(`Dir::Etc::sourceparts=/dev/null`, 임시 목록 디렉터리). `/var/log/apt/history.log` 의 Commandline 에 이 옵션이 남았다
2. 설치를 `strace -f --seccomp-bpf -e trace=connect` 로 감싸 프로세스 트리의 `connect()` 를 기록했다. `AF_INET`·`AF_INET6` 0건, 이름 해석 소켓 `io.systemd.Resolve` 0건이다. 나머지는 `AF_UNIX` 495건(nscd, systemd, dbus, `/var/run/docker.sock` 등)이다
3. `/var/cache/apt/archives/*.deb` 는 설치 전후 모두 0개다
4. 새로 생긴 패키지 79개의 버전이 모두 번들 `conf/packages.list` 와 같다. 지워진 패키지 0, 버전이 바뀐 패키지 0
5. 증거의 범위는 설치 프로세스 트리다. 번들 저장소로 `apt-get update` 를 할 때 호스트의 apt 훅(`/etc/apt/apt.conf.d/20apt-esm-hook.conf`)이 systemd 로 `apt-news.service`·`esm-cache.service` 를 띄운다. 이 둘은 트리 밖이고, 인터넷이 되는 검증 인스턴스에서 esm-cache 가 Canonical 서버에 접속해 503 을 받았다. 설치는 이 서비스에 의존하지 않는다
6. 번들 deb 170개 가운데 79개(477.9MiB)가 설치됐다. 16개는 같은 버전이 이미 있었고, `git`·`git-man` 은 설치된 7.3 을 그대로 뒀다. 73개는 `nvidia-settings`(GUI) Recommends 묶음이라 설치되지 않았다. 이 이미지에는 `python3-xkit` 이 없기 때문이다(4.2절)

GPU 사전 준비 검증 중 고친 것:

1. **`verify-urls.sh` 가 있는 패키지를 FAIL 로 보고했다.** `libnvidia-container-tools 1.20.1-1` 이 5번 중 5번 FAIL 이었다.
   Packages 색인을 `grep -q` 로 파이프에서 바로 찾으면, 첫 일치에서 grep 이 끝날 때 아직 쓰던 `paste` 가 SIGPIPE(141)로 죽는다.
   그러면 pipefail 때문에 결과가 "없음"이 된다. 색인을 변수에 담은 뒤 찾도록 고쳤다(`common.sh` `ctr_missing_images` 와 같은 방식).
2. **재부팅 전 요약 줄에 오류 문구가 드라이버 버전으로 찍혔다.** `nvidia-smi` 는 드라이버와 통신하지 못하면 오류를 stdout 에 쓴다.
   성공했을 때만 값을 쓰도록 고쳤다(재부팅 전에는 `?`). 판정과 종료코드는 그대로다.

---

## 11. 트러블슈팅

| 증상 | 원인 | 조치 |
|---|---|---|
| `GPU 번들 사전 조건이 없다` | 드라이버 또는 toolkit 없음 | 4.2절 GPU 사전 준비 번들. 또는 CPU 번들을 쓴다 |
| `커널이 번들과 다르다` (`install-gpu-prep.sh`) | GPU 사전 준비 번들이 다른 커널용이다 | 대상 노드의 `uname -r` 로 `./build-gpu-prep.sh --kernel <커널>` 을 실행해 그 커널용 번들을 만든다(3절). 커널은 바꾸지 않는다 |
| `다른 NVIDIA 드라이버가 이미 있다` | DKMS 드라이버 등 번들과 이름·버전이 다른 드라이버가 설치돼 있다 | 그 드라이버가 동작하면(`nvidia-smi -L`) 사전 준비 번들을 쓰지 않는다. 바꾸려면 기존 드라이버를 지우고 재부팅한 뒤 다시 실행한다 |
| `번들 저장소만으로 의존성이 풀리지 않는다` | 같은 코드네임이지만 대상의 OS 패키지(기준선)가 빌드 시점 아카이브보다 오래됐다. 번들의 deb 이 더 새 버전을 요구한다. 또는 빌드 기준선에 있어 번들에 넣지 않은 패키지가 대상에 없고, 그것이 Depends 다(Recommends 면 건너뛴다, 4.2절) | `--dry-run` 출력 끝의 apt 메시지에서 빠진 패키지와 요구 버전을 확인한다. 그 패키지를 사내 저장소 등으로 먼저 갱신하거나, 대상과 패치 수준이 같은 아카이브로 다시 빌드한다 |
| `재부팅이 필요하다` | 설치 직후 nouveau 가 적재돼 있거나 nvidia 모듈이 아직 없다 | 정상이다. `sudo reboot` 뒤 `sudo ./install-gpu-prep.sh --check-only` |
| `다음 부팅 커널 = 번들 커널` FAIL | 설치 뒤 unattended-upgrades 등으로 새 커널이 설치됐다. 재부팅하면 번들 모듈이 없는 커널로 뜬다 | 재부팅하기 전에 `ls /boot/vmlinuz-*` 로 확인한다. 새 커널로 부팅하려면 그 커널용 번들을 만든다. 번들 커널로 부팅하려면 GRUB 기본 항목을 번들 커널로 지정한다 |
| `could not select device driver "nvidia"` | toolkit 이 docker 에 등록되지 않음 | `nvidia-ctk runtime configure --runtime=docker` 후 docker 재시작 |
| `docker 저장소 여유가 부족하다` | containerd 저장소 이중 저장 | 4.1절. 저장소 볼륨을 늘린다 |
| `포트 80 를 다른 프로세스가 쓰고 있다` | 포트 충돌 | `site.env` 의 `OLLAMA_EMBED_PORT` 를 바꾼다 |
| nginx 로그 `host not found in upstream "ollama"` | nginx 가 ollama 보다 먼저 떴다(데몬 재시작 직후) | 재시작 정책이 다시 띄운다. 계속되면 `docker ps` 로 ollama 상태 확인 |
| nginx 가 `Restarting`, 로그 `could not build map_hash, you should increase map_hash_bucket_size: 64` | 키가 40자 이상 | 5절 "키 길이 상한". env 파일의 키를 39자 이하로 바꾸고 `sudo ./install.sh` |
| 올바른 키인데 401 | 헤더 형식(`Bearer` 뒤 공백 1칸, 앞뒤 공백·줄바꿈), env 파일과 다른 키 | `sudo grep '^OLLAMA_EMBED_API_KEY=' ...` 로 확인. 값 앞뒤에 공백이 없어야 한다 |
| `model "..." not found` | `/root/.ollama` 에 볼륨이 걸려 모델이 가려짐, 또는 flavor 와 다른 모델 이름 | 7절. 6절의 flavor 별 모델 이름 확인 |
| 첫 요청이 수십 초 걸림 | 모델 적재 | 정상. 5분 유휴 후 내려간다 |

로그: `docker logs ollama-embedding` · `docker logs ollama-embedding-nginx` ·
`docker compose -f /opt/ollama-embedding/docker-compose.yml logs`

---

## 12. 제거

```bash
sudo ./install.sh --uninstall          # 컨테이너·네트워크 제거. 설정·키·이미지는 남긴다
# 완전히 지우려면
docker image rm ollama-qwen3-embedding:0.40.13-cpu ollama-qwen3-embedding:0.40.13-gpu \
                docker.io/library/nginx:1.30.6-alpine
sudo rm -rf /opt/ollama-embedding
```

GPU 사전 준비(드라이버·toolkit·Docker·`daemon.json`)를 되돌리는 방법은 4.2절 표에 있다.
