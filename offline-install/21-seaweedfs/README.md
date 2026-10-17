# 21-seaweedfs — SeaweedFS S3 오브젝트 스토리지 (MinIO 대안 검토)

`20-minio` 의 라이선스 대안으로 검토 중인 S3 호환 오브젝트 스토리지다.
단일 노드 `weed server`(master + volume + filer + S3 게이트웨이를 한 프로세스로)
구성이고, S3 API 는 사내 CA 인증서로 TLS 전용이다. 컨테이너명은 `seaweedfs` 다.

**현재 상태: 번들 빌드 + 템플릿 기동 검증까지 완료, `install.sh` 는 아직 없다(6절).**
Ubuntu 26.04 빌드 호스트에서 번들 빌드와 S3 왕복 스모크 테스트 27/27 을
확인했다(7절).

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
├── SHA256SUMS                10개 파일
├── README.md
├── 00-common/                versions.env + site.env + common.sh
├── images/                   seaweedfs, aws-cli (docker-archive tar)
└── conf/
    ├── images.list
    ├── images.digests        amd64 매니페스트 다이제스트
    ├── docker-compose.yml.tmpl
    └── s3.json.tmpl          S3 자격증명
```

인증서는 번들에 넣지 않는다. `05-certs` 가 발급하고(`out/weed/`) `deploy-certs.sh`
가 각 노드 `/opt/pki/weed/` 에 둔다.

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
  - -s3.port=8333
  - -s3.config=/etc/seaweedfs/s3.json
  - -s3.cert.file=/certs/weed.crt
  - -s3.key.file=/certs/weed.key
  - -s3.domainName=<WEED_HOSTNAME>
ports: ["8333:8333"]
stop_grace_period: 1m
```

각 값의 이유(전부 실측):

- **포트는 8333 하나만 연다.** master(9333) / volume(8080) / filer(8888) 에는
  인증이 없어서, 공개하면 S3 자격증명을 우회해 파일을 읽고 지울 수 있다.
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
`1000:1000`, 키·`s3.json` 0600 으로 둬야 한다.

---

## 5. 설정 값 (`00-common/site.env`)

| 키 | 용도 |
|---|---|
| `WEED_HOSTNAME` | 클라이언트 접속 이름. 인증서 CN/SAN, `-s3.domainName` |
| `WEED_HOST_IP` | 인증서 SAN 의 IP. 비우면 이름으로만 검증된다 |
| `WEED_ROOT_USER` | `s3.json` 의 accessKey |
| `WEED_ROOT_PASSWORD` | `s3.json` 의 secretKey. 비워 두는 것을 권장(무작위 생성 예정) |

`versions.env` 의 `SEAWEEDFS_S3_PORT`(8333), `SEAWEEDFS_UID`(1000),
`SEAWEEDFS_REGION`(기본 `MINIO_REGION` 과 같음)도 쓴다. SeaweedFS 는 리전을
검사하지 않지만 UiPath AS 등 S3 클라이언트가 리전을 요구한다.

---

## 6. 아직 하지 않은 것

- **`install.sh`** — 이미지 적재, `/opt/weed` 생성, 템플릿 치환, 소유권, 기동,
  판정. 4절의 소유권과 7절의 판정 항목을 그대로 옮기면 된다. 빌드는
  `install.sh` 가 없으면 경고하고 이미지·템플릿만 담는다.
- **UiPath AS 연계 검증** — `uipathctl prereq run` 으로 `external_object_storage`
  를 SeaweedFS 로 지정해 확인해야 한다.
- **에어갭 노드 설치** — 스모크 테스트는 온라인 빌드 호스트에서 했다.

---

## 7. 검증 상태

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

검증 중 고친 것: `-volume.max=0`(entrypoint 의 1GB 볼륨), `-master.telemetry=false`
(`-telemetry` 는 기동 실패), `stop_grace_period: 1m`(10초 SIGKILL).

---

## 8. 다음 단계

```
05-certs (weed 인증서) → [21-seaweedfs] install.sh 작성 → 에어갭 설치 → AS prereq 검증
```
