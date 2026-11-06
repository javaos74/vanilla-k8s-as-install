# 21-seaweedfs — SeaweedFS S3 오브젝트 스토리지 (MinIO 대안)

`20-minio` 의 라이선스 대안으로 쓰는 S3 호환 오브젝트 스토리지다.
단일 노드 `weed server`(master + volume + filer + S3 게이트웨이를 한 프로세스로)
구성이고, S3 API 는 사내 CA 인증서로 TLS 전용이다. 컨테이너명은 `seaweedfs` 다.

**현재 상태: 실서버에서 `install.sh` 판정 36/36 통과(7절).**
2026-11-06, Ubuntu 26.04 / Docker 29.9.3 + compose v5.7.0(deb) 호스트에서 확인했다.
인증서는 `05-certs` 사내 CA 발급본(`/opt/pki/weed`)을 쓰고, 브라우저 CORS 는
전역·버킷 2계층을 적용해 preflight 를 실측했다(5절).
남은 것은 UiPath AS 연계 검증이다(6절 "아직 하지 않은 것").

---

## 1. 왜 검토하는가

| | MinIO (20-minio) | SeaweedFS (21-seaweedfs) |
|---|---|---|
| 라이선스 | AGPL-3.0 | **Apache-2.0** (이미지 라벨 `org.opencontainers.image.licenses`) |
| 업스트림 | 아카이브됨, 보안 업데이트 없음 | 릴리스 계속(4.48, 2026-09-28 빌드) |
| 배포 경로 | quay.io 이미지뿐 — **2026-10-17 현재 401 로 받을 수 없다** | Docker Hub `chrislusf/seaweedfs` |
| S3 자격증명 | 환경변수 | JSON 파일(`-s3.config`) |
| 컨테이너 uid | 1000 | 1000 (`seaweed`) |

2026-10-17 에 `verify-urls.sh` 를 돌리자 `quay.io/minio/minio` 와 `quay.io/minio/mc`
가 태그·다이제스트 모두 `unauthorized` 를 반환했다. 이미 받은 번들은 쓸 수 있지만
**20-minio 번들을 새로 만들 수 없는 상태**다.

`mc` 도 AGPL 이므로 검증 클라이언트로는 Apache-2.0 인 AWS CLI v2 를 쓴다.

---

## 2. 이미지

`versions.env` 에서 태그와 **linux/amd64 매니페스트 다이제스트**를 함께 핀한다.

| 용도 | 이미지 | amd64 다이제스트 |
|---|---|---|
| 서버 | `docker.io/chrislusf/seaweedfs:4.48` | `sha256:aba492e2…` |
| 검증 클라이언트 | `docker.io/amazon/aws-cli:2.38.1` | `sha256:387821d4…` |

태그가 가리키는 것은 멀티아치 인덱스(`sha256:4e61d15f…`)다. 번들은 skopeo 로
단일 플랫폼 이미지를 받으므로 인덱스가 아니라 amd64 자식 매니페스트를 핀해야
받은 것과 핀이 일치한다(`70-mssql` 과 같은 이유). 빌드는 다이제스트로 받고,
태그가 움직였으면 경고만 하고 핀을 그대로 쓴다.

`4.48` 은 30GB 볼륨 상한 빌드다(`weed version` → `30GB 4.48`). 볼륨 하나를
30GB 보다 크게 써야 하면 `4.48_large_disk` 로 바꾸고 다이제스트를 다시 핀한다.

---

## 3. 번들 빌드

```bash
cd offline-install
./00-common/build-in-container.sh 26.04 21-seaweedfs   # 권장 (rootless podman)
# 또는
cd 21-seaweedfs && ./build-bundle.sh                     # 호스트에서 직접
```

OS 에 의존하지 않으므로 어느 Ubuntu 이미지에서 만들어도 같다. 산출물 315MB.

```
seaweedfs-4.48/
├── BUNDLE-INFO               이미지@다이제스트, 라이선스 라벨
├── SHA256SUMS                번들 안 모든 파일의 sha256
├── install.sh                설치·판정(6절)
├── apply-cors.sh             버킷 CORS 적용(5절)
├── README.md
├── 00-common/                versions.env + site.env + common.sh + os/
├── images/                   seaweedfs, aws-cli (docker-archive tar)
└── conf/
    ├── images.list
    ├── images.digests        amd64 매니페스트 다이제스트
    ├── docker-compose.yml.tmpl
    ├── s3.json.tmpl          S3 자격증명
    └── s3-cors.json.tmpl     버킷 CORS 규칙
```

인증서는 번들에 넣지 않는다. `05-certs` 가 발급하고(`out/weed/`) `deploy-certs.sh`
가 각 노드 `/opt/pki/weed/` 에 둔다. 없으면 `install.sh` 가 로컬 CA 로 발급한다(6절).

위 트리는 2026-11-06 재빌드 기준이다. 파일 17개, tar.gz 315MB 이고
`sha256sum -c SHA256SUMS` 가 전체 일치한다. `install.sh` 와 `apply-cors.sh` 가 함께 실린다.

---

## 4. 구성 설계 (compose 템플릿)

```yaml
command:
  - server
  - -dir=/data
  - -ip=127.0.0.1
  - -ip.bind=127.0.0.1         # master/volume/filer 는 컨테이너 루프백만
  - -volume.max=0              # 볼륨 개수를 디스크 여유 공간으로 자동 산정
  - -master.telemetry=false    # 외부 통계 전송 끔
  - -s3
  - -s3.ip.bind=0.0.0.0        # S3 만 밖으로
  - -s3.port=8333               # 컨테이너 안 S3 포트. 고정
  - -s3.config=/etc/seaweedfs/s3.json
  - -s3.cert.file=/certs/weed.crt
  - -s3.key.file=/certs/weed.key
  - -s3.domainName=<WEED_HOSTNAME>
  - -s3.allowedOrigins=<WEED_CORS_ORIGINS>   # 브라우저 CORS 허용 오리진
ports: ["<SEAWEEDFS_S3_PORT>:8333"]   # 호스트 포트만 변수(기본 8333)
stop_grace_period: 1m
```

각 값의 이유(전부 실측):

- **포트는 S3 하나만 연다.** master(9333) / volume(8080) / filer(8888) 에는
  인증이 없어서, 공개하면 S3 자격증명을 우회해 파일을 읽고 지울 수 있다.
- **S3 포트는 컨테이너 안에서 8333 고정이고, 호스트 포트만 `SEAWEEDFS_S3_PORT` 로
  바꾼다.** `-s3.port` 와 healthcheck(`https://localhost:8333/healthz`)는 8333 그대로다.
  템플릿의 `__SEAWEEDFS_S3_PORT__` 는 ports 왼쪽 한 곳뿐이고 `install.sh` 가 치환한다(5절, 6절).
- **`-s3.cert.file` 을 주면 `-s3.port` 는 HTTPS 전용이 된다.** 평문 HTTP 요청은
  실패한다. 평문 포트를 따로 열려면 `-s3.port.https` 를 써야 하는데 쓰지 않는다.
- **`-volume.max=0`.** 이미지 entrypoint 가 `-master.volumeSizeLimitMB=1024` 를
  끼워 넣어 볼륨 하나가 1GB 다. 기본값 8 이면 약 8GB 에서 쓰기가 멈춘다.
- **`-master.telemetry=false`.** 기본값이면 저장량 10GiB 이후 하루 한 번
  `telemetry.seaweedfs.com` 으로 익명 통계를 보낸다고 기동 로그에 찍힌다.
  로그 안내는 `-telemetry=false` 지만 `weed server` 에서는 정의되지 않은 플래그라
  기동이 실패한다. `-master.telemetry=false` 가 맞다.
- **`stop_grace_period: 1m`.** 정상 종료에 26~27초가 걸린다. compose 기본 10초면
  SIGKILL 로 끊긴다.
- **`-s3.domainName`** 으로 가상 호스트 스타일(`<bucket>.<host>`)을 받는다.
  그래서 `05-certs` 는 MinIO 처럼 `*.<WEED_HOSTNAME>` 와일드카드를 넣는다.
- **`-s3.allowedOrigins`** 는 브라우저에서 S3 를 직접 부를 때 허용할 오리진이다.
  기본값이 `*` 라 반드시 좁힌다. 자격증명을 동반한 요청에서 모든 사이트를
  허용하게 되기 때문이다. 값은 `site.env` 의 `WEED_CORS_ORIGINS` 다(5절).

### 파일 소유권 — uid 1000

entrypoint 는 root 로 시작해 `/data` 만 chown 한 뒤 `su-exec seaweed`(uid 1000)로
내려간다. **인증서와 `s3.json` 은 직접 맞춰야 한다.** `05-certs` 가 배치한 키는
root 소유 0600 이라 그대로 마운트하면 읽지 못한다.

| 상태 | 결과 |
|---|---|
| `s3.json`·키가 root 0600 | `fail to load config file /etc/seaweedfs/s3.json: permission denied` 로 **즉시 종료** |
| 1000:1000 소유 0600 | 정상 |

읽지 못하면 익명 허용으로 넘어가지 않고 종료한다. 안전한 쪽으로 실패한다.
`install.sh` 는 `/opt/pki/weed/weed.{crt,key}` 를 `/opt/weed/certs/` 로 복사하고
`1000:1000`, 키·`s3.json` 0600 으로 둔다(6절).

---

## 5. 설정 값 (`00-common/site.env`)

| 키 | 용도 |
|---|---|
| `WEED_HOSTNAME` | 클라이언트 접속 이름. 인증서 CN/SAN, `-s3.domainName` |
| `WEED_HOST_IP` | 인증서 SAN 의 IP. 비우면 이름으로만 검증된다 |
| `WEED_ROOT_USER` | `s3.json` 의 accessKey |
| `WEED_ROOT_PASSWORD` | `s3.json` 의 secretKey. **비우면 무작위 생성**하고 설치 끝에 출력한다(권장) |
| `WEED_DATA_DIR` | S3 데이터의 호스트 경로. 기본 `/data/weed`. 컨테이너의 `/data` 에 마운트된다 |
| `SEAWEEDFS_S3_PORT` | 호스트에 노출할 S3 API(HTTPS) 포트. 기본 8333. 컨테이너 안은 8333 고정 |
| `WEED_CORS_ORIGINS` | 브라우저 CORS 허용 오리진(쉼표 구분). `-s3.allowedOrigins` 와 버킷 CORS 규칙에 함께 들어간다 |

`versions.env` 의 `SEAWEEDFS_UID`(1000), `SEAWEEDFS_REGION`(기본 `MINIO_REGION` 과
같음)도 쓴다. SeaweedFS 는 리전을 검사하지 않지만 UiPath AS 등 S3 클라이언트가 리전을
요구한다.

키가 없을 때의 기본값:

- `WEED_DATA_DIR` 은 `versions.env` 가 `${WEED_DATA_DIR:-/data/weed}` 로 받고,
  `install.sh` 도 같은 기본값을 한 번 더 둔다(`45-redis` 의 `REDIS_PORT` 와 같은 방식).
  이름은 `80-postgresql`(`PG_DATA_DIR`)·`20-minio`(`MINIO_DATA_DIR`)처럼
  `<접두어>_DATA_DIR` 이다. 그래서 이 키가 없는 기존 `site.env` 로 만든 번들도
  `/data/weed` 를 쓴다.
- `SEAWEEDFS_S3_PORT` 는 `versions.env` 가 `${SEAWEEDFS_S3_PORT:-8333}` 으로 받는다.
- `WEED_HOSTNAME` 이 비면 `weed.<도메인>`, `WEED_HOST_IP` 가 비면 기본 경로의 IP 를 쓴다.
- `WEED_CORS_ORIGINS` 가 비면 `https://<AS_FQDN>` 을 쓴다. `AS_FQDN` 도 비어 있으면
  멈춘다. 기본값을 `*` 로 두면 조용히 모든 오리진이 열리기 때문에 일부러 실패시킨다.

`install.sh` 는 `SEAWEEDFS_S3_PORT` 가 1~65535 범위의 숫자가 아니거나, `WEED_HOSTNAME`
에 영문자·숫자·`.`·`-` 외의 문자가 있거나, `WEED_DATA_DIR` 이 공백 없는 단순 절대 경로가
아니면 멈춘다. 자격증명은 `s3.json` 에 그대로 들어가므로 사용자는 영문자·숫자·`._-`
3~128자, 비밀번호는 영문자·숫자·`._~+/=-` 8~128자만 받는다.


### 브라우저 CORS — 두 계층

브라우저가 S3 를 직접 부르면(AS 의 파일 업로드 등) CORS 가 필요하다. 설정은 두 군데다.

| 계층 | 설정 위치 | 역할 |
|---|---|---|
| 서버 전역 | compose 의 `-s3.allowedOrigins` (`install.sh` 가 생성) | preflight 를 통과시킬지 결정한다(문지기) |
| 버킷 단위 | S3 `PutBucketCors` API (`apply-cors.sh` 가 적용) | 통과한 뒤 돌려줄 `ExposeHeaders` / `MaxAge` 를 정한다 |

전역만 설정해도 CORS 는 동작한다. 다만 SeaweedFS 가 돌려주는 기본 `ExposeHeaders` 는
`ETag, Content-Length, Content-Type, Last-Modified, x-amz-request-id, x-amz-version-id`
라서 `x-amz-server-side-encryption` 과 `x-amz-id-2` 가 빠지고 `Max-Age` 도 없다.
그 헤더가 필요하면 버킷 CORS 를 함께 걸어야 한다.

반대로 버킷 CORS 만 걸면 안 된다. 4.48 은 슬래시 없는 `OPTIONS /<버킷>` 에서 버킷
규칙을 무시하고 전역 기본값 `*` 를 그대로 내보낸다([seaweedfs#12025][sw12025]).
실측 결과다. 전역을 좁히면 막힌다.

```
# 버킷 CORS 만 적용, 전역은 기본값 '*' — 외부 오리진 https://evil.example
/bucket                 200  Access-Control-Allow-Origin: *      <- 누출
/bucket/                403  (헤더 없음)
/bucket/obj             403  (헤더 없음)

# 전역을 WEED_CORS_ORIGINS 로 좁힌 뒤 — 같은 외부 오리진
/bucket                 응답 없이 연결 종료
/bucket/                403
/bucket/obj             403
```

[sw12025]: https://github.com/seaweedfs/seaweedfs/issues/12025

버킷은 만들어진 뒤에만 CORS 를 걸 수 있다. 그래서 `install.sh` 에 넣지 않고
`apply-cors.sh` 로 분리했다. AS 버킷을 만든 뒤 실행한다.

```bash
sudo ./apply-cors.sh <버킷이름> [...]   # 지정한 버킷
sudo ./apply-cors.sh --all              # 현재 존재하는 모든 버킷
sudo ./apply-cors.sh --show <버킷이름>  # 적용된 설정만 확인
```

규칙은 `conf/s3-cors.json.tmpl` 이고 오리진만 치환된다. 적용 후 `GetBucketCors` 로
되읽고, 실제 `OPTIONS` 요청을 던져 허용 오리진은 200 에 정확한 오리진이 돌아오는지,
외부 오리진은 막히는지 확인한다.

오리진을 바꿀 때는 `site.env` 의 `WEED_CORS_ORIGINS` 를 고치고 `install.sh` 를 다시
실행한 뒤(전역 반영) `apply-cors.sh` 를 다시 실행한다(버킷 반영).

---

## 6. 설치 (`install.sh`)

> `install.sh` 는 실서버에서 판정 36항목을 모두 통과했다(7절). `--test-restart` 와
> `--uninstall` 은 아직 돌려 보지 않았다.
>
> **전제: docker 는 deb 패키지여야 한다.** snap docker 는 compose CLI 가 샌드박스에
> 갇혀 `/opt` 를 보지 못해, 파일이 있는데도 `compose file "/opt/weed/docker-compose.yml.new"
> is invalid: ... no such file or directory` 로 실패한다. `which docker` 가
> `/snap/bin/docker` 면 이 경우다.

```bash
# 빌드 호스트(인터넷 O)
cd offline-install/21-seaweedfs && ./build-bundle.sh

# 타깃 노드(에어갭)
scp bundle/seaweedfs-*.tar.gz{,.sha256} <타깃>:~/
sha256sum -c seaweedfs-*.tar.gz.sha256
tar xzf seaweedfs-*.tar.gz && cd seaweedfs-*

sudo ../offline-install/90-verify/airgap-on.sh   # 검증 목적
sudo ./install.sh
```

옵션은 `--check-only`(판정만), `--test-restart`(자동 복구 검증),
`--uninstall`(컨테이너만 제거, 설정·데이터 보존) 이다. `20-minio` 와 같다.

전제: `10-k8s` 로 docker + docker compose 가 설치돼 있어야 한다. 사내 CA 인증서를
쓰려면 `05-certs` 의 `make-certs.sh` + `deploy-certs.sh` 를 먼저 한다.

### 설치 단계

| 단계 | 하는 일 |
|---|---|
| 0. 사전 확인 | `SHA256SUMS` 무결성 검증, 에어갭 여부 경고, docker/compose 확인, 입력값 검증(5절), `SEAWEEDFS_S3_PORT` 선점 확인 |
| 1. 이미지 적재 | `images/*.tar` 를 `docker load`, `images.list` 의 2개가 모두 있는지 확인 |
| 2. 자격증명 | `/opt/weed`, `/opt/weed/certs`, `WEED_DATA_DIR` 생성. `/opt/weed/weed.env`(0600)가 있으면 그 값을, 없으면 `site.env` 값 또는 무작위 비밀번호로 만든다. 그 값으로 `s3.json` 을 다시 만들어 JSON 검사 후 `1000:1000` · 0600 으로 둔다 |
| 3. TLS | `/opt/pki/weed/weed.{crt,key}`(05-certs) → 기존 `/opt/weed/certs` → 로컬 CA 발급 순서로 고른다. 결과를 `1000:1000`, 키 0600 으로 맞춘다 |
| 4. compose | 템플릿의 `__SEAWEEDFS_IMAGE__` · `__SEAWEEDFS_S3_PORT__` · `__WEED_HOSTNAME__` · `__WEED_DATA_DIR__` · `__WEED_DIR__` 를 치환한다. 남은 자리표시자가 있거나 `docker compose config` 가 실패하면 멈춘다. `install_file` 로 바뀔 때만 백업 후 교체한다 |
| 5. 기동 | `docker compose up -d` 후 `https://127.0.0.1:<SEAWEEDFS_S3_PORT>/healthz` 응답을 기다린다 |
| 6. 판정 | 아래 판정 항목 |

`s3.json` 은 파일 하나를 바인드 마운트한다. 파일을 교체하면 실행 중인 컨테이너는 옛
파일을 계속 보므로, `s3.json` 이나 인증서·키 내용이 바뀐 실행에서는
`docker compose up -d --force-recreate` 로 컨테이너를 다시 만든다.

로컬 CA 발급은 `45-redis` 와 같은 방식이다. CA(`/opt/weed/certs/ca.crt`)를 만들어 서버
인증서에 서명하고 CA 키는 버린다. SAN 은 `<WEED_HOSTNAME>`, `*.<WEED_HOSTNAME>`,
`localhost`, `<WEED_HOST_IP>`, `127.0.0.1` 이다. 클라이언트는 이 `ca.crt` 를 신뢰해야 한다.
운영에는 05-certs 인증서를 권장한다.

### 판정 36항목

SAN 에 노드 IP 가 없으면 IP 검증을 건너뛰어 35항목이다.

```
docker / compose 사용 가능 · 이미지 2개 적재됨
compose 파일 · compose 문법 · env(0600)
s3.json 이 uid 1000 소유·0600 · s3.json JSON 유효
인증서·키·CA 존재 · uid 1000 소유·키 0600 · CA 체인 검증
SAN 에 <WEED_HOSTNAME> · SAN 에 *.<WEED_HOSTNAME>
데이터 디렉터리 존재
컨테이너 실행 중(크래시 루프 아님)      <- PID 10초 유지
재시작 정책 unless-stopped · StopTimeout=60(stop_grace_period 1m) · healthcheck healthy
  -- 포트 --
호스트 SEAWEEDFS_S3_PORT 수신 · S3 포트(8333)만 publish
내부 포트(9333/8080/8888)가 컨테이너 IP 로 닿지 않음   <- -ip.bind=127.0.0.1
  -- TLS --
평문 HTTP 거부 · 이름으로 TLS 검증(CA, SNI) · IP 로 TLS 검증(SAN 에 IP 가 있을 때)
telemetry 전송 로그 없음
  -- S3 왕복 (aws-cli, CA 검증 켬) --
접속 -> 버킷 생성 -> 업로드 5MB -> 업로드 20MB(멀티파트) -> 목록
다운로드 sha256 일치 · 가상 호스트 스타일 목록
잘못된 secret 거부 · 익명 요청 거부      <- 인증 오류로 거부됐는지까지 본다
호스트 볼륨에 데이터 기록됨(*.dat)
```

7절 스모크 테스트 항목을 옮겼다. 다른 점은 다음과 같다.

- "호스트 9333·8080·8888 미수신" 은 `docker port` 로 S3 포트만 publish 됐는지 본다.
  호스트의 다른 프로세스가 8080 등을 써도 거짓 실패가 나지 않게 하기 위함이다.
- "master 루프백 바인드" 는 컨테이너 IP 로 세 포트에 붙어 보는 것으로 바꿨다.
- "SIGTERM 정상 종료(27초)" 는 판정에 넣지 않았다. `StopTimeout=60` 만 본다.
- "재시작 후 객체 유지" 는 `--test-restart` 에 있다.

aws-cli 는 번들 이미지로 `--network host` 와 `--add-host <이름>:127.0.0.1` 을 붙여 돌린다.
실제 접속 이름으로 SNI·인증서를 검증하기 위함이다. 자격증명은 값 없는 `-e` 로 넘겨
`ps` 에 남지 않게 한다.

### 자동 복구

```bash
sudo ./install.sh --test-restart
```

| 단계 | 방법 | 확인 |
|---|---|---|
| 준비 | 검증용 버킷에 객체 하나 쓰기 | |
| 프로세스 사고사 | 호스트에서 컨테이너 PID 에 `kill -9` | `RestartCount` 증가 + healthz |
| 재부팅 대리 | `systemctl restart docker` | running 복귀 + healthz |
| 객체 유지 | 준비 단계 객체를 다시 받기 | 내용 일치 |

`docker kill` 로 시험하지 않는다. 수동 정지로 기록되어 `unless-stopped` 가 재시작하지
않는다(`20-minio` 7절).

### 아직 하지 않은 것

- **UiPath AS 연계 검증** — `uipathctl prereq run` 으로 `external_object_storage`
  를 SeaweedFS 로 지정해 확인해야 한다. 가장 중요한 남은 항목이다.
- **`--test-restart` / `--uninstall` 실행** — 설치·판정은 통과했지만 이 두 모드는
  아직 돌려 보지 않았다.
- **에어갭 노드에서 설치** — 확인한 호스트는 인터넷이 닿는 상태였다. 번들만으로
  설치되는지는 `90-verify/airgap-on.sh` 를 켜고 확인해야 한다.

---

## 7. 검증 상태

### `install.sh`: 실서버 판정 36/36 통과

2026-11-06, Ubuntu 26.04 / Docker 29.9.3 + compose v5.7.0(deb) 호스트에서 `sudo ./install.sh`
를 실행해 판정 36항목을 모두 통과했다.

| 항목 | 결과 |
|---|---|
| `sudo ./install.sh` | **통과 36 / 실패 0** |
| S3 왕복 | 5MB 업로드, 20MB 멀티파트, 다운로드 sha256 일치, 가상 호스트 스타일 목록 |
| 인증 | 잘못된 secret 거부, 익명 요청 거부 |
| 포트 격리 | 8333 만 publish. 9333 / 8080 / 8888 는 컨테이너 밖에서 닿지 않음 |
| TLS | 평문 HTTP 거부. 이름(SNI)·IP(SAN) 양쪽 검증 |
| 인증서 | `OU=weed, CN=weed.<도메인>`, issuer = 사내 CA. 로컬 CA 폴백이 아님 |
| CORS preflight | 허용 오리진 200 + 정확한 `Access-Control-Allow-Origin`, 그 외 403 |
| 번들 재빌드 | `build-bundle.sh` 통과. 파일 17개, 315MB, `SHA256SUMS` 전체 일치 |

`--test-restart`, `--uninstall`, AS 연계는 아직 확인하지 않았다(6절 "아직 하지 않은 것").

#### 실행 전에 했던 정적 검사

아래는 실서버 실행 이전에 한 검사다. 기록으로 남긴다.

| 검사 | 결과 |
|---|---|
| `bash -n install.sh` / `build-bundle.sh` | 통과 |
| `shellcheck -x` (`install.sh`) | 경고 이상 0건. note 만 있다(SC2329 `check` 로 넘기는 함수, SC2015 `A && B \|\| C`). `20-minio/install.sh` 와 같은 종류다 |
| compose 템플릿을 `install.sh` 의 sed 블록 그대로 치환 | 미치환 자리표시자 없음. 기본값 `"8333:8333"`, `/data/weed:/data`. 시험값 `"18333:8333"`, `-s3.port=8333`·healthcheck `localhost:8333` 그대로 |
| 치환한 compose 를 `docker compose config` 로 파싱 | 통과 (클라이언트 쪽 파싱만) |
| `s3.json` 템플릿 치환 후 `python3 -m json.tool` | 통과 |
| `WEED_DATA_DIR` 키가 없는 `site.env` 로 `versions.env` + `install.sh` 의 기본값 줄 평가 | `/data/weed` |
| 입력 검증 블록에 잘못된 포트·호스트명·경로·IP 를 넣어 실행 | 모두 멈춤. 정상값은 통과 |
| 로컬 CA 발급 블록만 임시 디렉터리에서 실행(OpenSSL) | `openssl verify` OK, SAN 에 이름·와일드카드·IP·127.0.0.1 |

### 템플릿 스모크 테스트 (`install.sh` 이전)

2026-10-17, Ubuntu 26.04.1 LTS(resolute) 빌드 호스트.

| 항목 | 결과 |
|---|---|
| `verify-urls.sh` SeaweedFS 항목(다이제스트 참조) | **2/2** |
| `build-in-container.sh 26.04 21-seaweedfs` | **성공** (315MB, 첫 빌드 4분 27초. 대부분 컨테이너 apt 준비) |
| 태그 = 핀 다이제스트 | **일치** (seaweedfs, aws-cli) |
| 라이선스 라벨 | **Apache-2.0** |
| `.tar.gz.sha256` / 번들 내 `SHA256SUMS` | **통과** |
| 적재 이미지 ID = 핀 매니페스트의 config 다이제스트 | **일치** (2개) |
| `05-certs` weed 인증서로 템플릿 기동 스모크 테스트 | **27/27** |

스모크 테스트는 번들에서 꺼낸 템플릿을 install.sh 처럼 치환해 rootless podman
으로 띄웠다. 항목:

```
렌더링: 미치환 토큰 없음 / s3.json JSON 유효 / compose YAML 유효
기동: 실행 중 / healthcheck(/healthz) / 평문 HTTP 거부
내부 포트: 호스트 9333·8080·8888 미수신 / master 루프백 바인드
TLS: 사내 CA 로 검증(SNI) / IP 로도 검증(SAN IP) / 발급자 = 사내 CA
S3(aws-cli, CA 검증 켬): 버킷 생성 / 업로드 5MB / 목록 / 다운로드 / sha 일치 /
  멀티파트 20MB / 가상 호스트 스타일 / 잘못된 secret 거부 / 익명 거부 /
  호스트 볼륨 기록
종료: telemetry 로그 없음 / stop_grace_period / SIGTERM 정상 종료(27초, exit 0)
재시작 후 객체 유지
```

위 스모크 테스트는 S3 포트를 컨테이너 8333 고정으로 나누기 전의 템플릿으로 했다.
나눈 뒤에는 다시 띄워 보지 않았다. 기본값 8333 으로 렌더링한 결과가 나누기 전과 같다는
것만 정적으로 확인했다.

검증 중 고친 것: `-volume.max=0`(entrypoint 의 1GB 볼륨), `-master.telemetry=false`
(`-telemetry` 는 기동 실패), `stop_grace_period: 1m`(10초 SIGKILL).

---

## 8. 다음 단계

```
05-certs (weed 인증서) → [21-seaweedfs] 번들 재빌드 → 에어갭 설치(install.sh 첫 실행) → AS prereq 검증
```
