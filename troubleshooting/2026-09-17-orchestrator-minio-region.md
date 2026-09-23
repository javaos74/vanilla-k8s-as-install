# Orchestrator CrashLoopBackOff — MinIO SigV4 리전 불일치

작업일 2026-09-17 / 클러스터 `k8s` / Automation Suite 2.2510.3 / Orchestrator 이미지 `26.3.1`

---

## 1. 증상

`uipath` 네임스페이스 재구성 후 배포에서 Application 13개 중 2개가 Degraded.

```
orchestrator                     Degraded
webhook                          Degraded

orchestrator-*                                          CrashLoopBackOff (restarts 7)
webhook-service-*                                       CrashLoopBackOff (restarts 7)
platform-services-initialize-default-organization-job-* CrashLoopBackOff (restarts 6)
orchestrator-storage-migration-job-2.2510.3-*           Init:0/2 (무한 대기)
```

## 2. 근본 원인

Orchestrator가 시작 시 플러그인을 내려받는 단계에서 MinIO가 요청을 거부하고, 예외가 처리되지 않아
`Program.Main`에서 프로세스가 종료된다. 웹 서버가 뜨기 전에 죽는다.

```
Starting plugins download.
Unhandled exception. UiPath.Storage.Client.StorageException: Unknown exception.
 ---> Amazon.S3.AmazonS3Exception:
       The authorization header is malformed; the region is wrong; expecting 'ap-northeast-2'.
   at UiPath.Storage.AWS.AmazonS3StorageClient.GetItemsAsync
   at UiPath.Orchestrator.Startup.InitPlugins.PluginsDownloader.TryDownloadPluginsAsync
   at UiPath.Orchestrator.Startup.Program.Main
```

**MinIO는 SigV4 서명의 리전이 `ap-northeast-2`이기를 요구하는데, Orchestrator는 그와 다른 리전(AWS SDK
기본값)으로 서명한다.**

### 왜 리전이 전달되지 않는가

`input.json`에는 리전이 올바르게 들어 있다.

```
external_object_storage.region = ap-northeast-2
```

uipathctl은 이 값을 시크릿까지 전달한다.

```
secret/orchestrator-external-storage-secret
  FQDN=minio.myrobots.co.kr  PORT=9000  BUCKET=uipath
  REGION=ap-northeast-2      ACCESSKEY=***  SECRETKEY=***
```

그런데 Deployment가 이 시크릿을 앱 설정으로 주입할 때 **REGION만 빠진다.** `app-secrets-generated`
projected 볼륨의 매핑:

```
orchestrator-external-storage-secret | FQDN      -> APPSETTINGS__OBJECT_STORAGE_HOST
orchestrator-external-storage-secret | PORT      -> APPSETTINGS__OBJECT_STORAGE_PORT
orchestrator-external-storage-secret | BUCKET    -> APPSETTINGS__OBJECT_STORAGE_BUCKET
orchestrator-external-storage-secret | BUCKET    -> APPSETTINGS__Storage.PluginsDownload.Bucket
orchestrator-external-storage-secret | ACCESSKEY -> APPSETTINGS__OBJECT_STORAGE_ACCESSKEY
orchestrator-external-storage-secret | SECRETKEY -> APPSETTINGS__OBJECT_STORAGE_SECRETKEY
                                     ( REGION 매핑 없음 )
```

이 키들이 `secret/orchestrator`의 `Storage.Location` 플레이스홀더를 채운다.

```
Storage.Type     = Amazon
Storage.Location = ServiceUrl=https://{OBJECT_STORAGE_HOST}:{OBJECT_STORAGE_PORT}
                   ExternalServiceUrl=https://{OBJECT_STORAGE_HOST}:{OBJECT_STORAGE_PORT}
                   UseHttp=false; ForcePathStyle=true
                   AccessKey=...; SecretKey=...
                   BucketName={OBJECT_STORAGE_BUCKET}; ContentPrefix=orchestrator
                   ( 리전 파라미터 없음 )
```

즉 **리전을 기대하도록 설정된 UiPath 클라이언트가 하나도 없는데 MinIO만 사이트 리전을 강제하고 있었다.**
어긋난 쪽은 MinIO다.

## 3. 조치 (실제 적용)

`/opt/minio/minio.env`에서 `MINIO_SITE_REGION` 주석 처리 → compose 재생성.

```bash
# 백업: /opt/minio/minio.env.bak.20260917-032932
sudo sed -i 's|^MINIO_SITE_REGION=|#MINIO_SITE_REGION=|' /opt/minio/minio.env
cd /opt/minio && sudo docker compose up -d
```

**이것만으로는 부족했다.** MinIO는 사이트 리전을 데이터 디렉터리의 내부 설정에 영속 저장하므로,
환경변수를 지워도 그대로 남아 동일 오류가 재현된다.

```bash
sudo docker exec minio sh -c '
  mc --insecure alias set hc https://localhost:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD"
  mc --insecure admin config get hc site     # -> site name= region=ap-northeast-2
  mc --insecure admin config reset hc site'
cd /opt/minio && sudo docker compose restart   # reset 후 재시작 필수
# 확인: site name= region=
```

이후 Orchestrator 재기동.

```bash
kubectl -n uipath rollout restart deploy/orchestrator
```

## 4. 결과

```
orchestrator-5b5876455f-bdt54    2/2 Running    r=0
orchestrator-5b5876455f-p56zb    2/2 Running    r=0
webhook-service-6dc7978bd8-zhwd6 2/2 Running    (이전 크래시로 r=17, 이후 안정)

job/orchestrator-storage-migration-job-2.2510.3            Complete
job/platform-services-initialize-default-organization-job  Complete

Application 13개: orchestrator 만 Progressing(레플리카 증설 중), 나머지 12개 Healthy
```

webhook-service의 `Waiting for orch... 503`, default-organization job의
`Connection refused (orchestrator.uipath.svc:80)`는 모두 Orchestrator 미기동에서 파생된 것이라
자동 해소됐다.

## 5. 시도했으나 실패한 접근 (재시도 금지)

처음에는 MinIO를 건드리지 않고 Orchestrator 쪽에 리전을 주입하려 했다. 두 방법 모두 막혔다.

**(1) `Storage.Type=Amazon` + `EndpointRegion=ap-northeast-2`** — 실패.
`uipathctl config orchestrator update-config --app-settings`로 주입했고 설정은 실제로 반영됐지만
(별도 검증: 호스트명을 존재하지 않는 값으로 바꾸자 오류 메시지가 그 호스트로 변경됨 → customconfig가
읽히고 app-secrets보다 우선함이 확인됨) 리전 오류는 그대로였다.
AWS SDK for .NET은 `ServiceURL`이 지정되면 `RegionEndpoint`를 무시하므로 `EndpointRegion`으로는
서명 리전을 바꿀 수 없다. 서명 리전을 바꾸는 건 `AuthenticationRegion`인데 UiPath 연결 문자열에
해당 파라미터가 노출되지 않는다.

**(2) `Storage.Type=Minio`** — 부분 성공 후 실패.
주 스토리지는 정상 동작했다(`orchestrator-storage-migration-job`이 `Init:0/2`에서 `Completed`로 통과).
그러나 플러그인 다운로더가 이 타입을 거부한다.

```
System.ArgumentException: Storage type 'Minio' is invalid  for download plugins
```

결론: Orchestrator 설정만으로 S3 호환 엔드포인트의 서명 리전을 제어할 방법이 없다. 서버 쪽 리전
강제를 푸는 것이 유일한 해법이며, 앞서 본 것처럼 애초에 아무 클라이언트도 리전을 쓰지 않으므로
기능 손실도 없다.

## 6. 참고 / 부작용

- `cm/orchestrator-customconfig`는 ArgoCD 추적 대상이 아니다(`tracking-id` 없음). 검증 과정에서
  사용했고 작업 후 `{"AppSettings":{}}`로 되돌렸다. Orchestrator appSettings를 self-heal에
  되돌려지지 않게 오버라이드해야 할 때 쓸 수 있는 지점이다.
  변경 명령: `uipathctl config orchestrator update-config --app-settings <file>`
- 작업 중 사용한 파일은 infra-01 `~/as.2510.3/`에 남아 있다:
  `appsettings.custom.json`(Amazon+EndpointRegion), `appsettings.minio.json`(Minio 타입),
  `appsettings.empty.json`(원복용), `appsettings.custom.json.real`
- MinIO 인증서가 2026-09-17 00:31 UTC에 재발급되어 있었다(이 작업과 무관). 이 때문에
  `minio-test/mc-client`가 신뢰하던 CA가 구버전이 되어 TLS 검증에 실패했다.
  `minio-client/setup.sh` 재실행 + 파드 재시작으로 해결. 인증서를 갱신하면 이 절차가 필요하다.
- MinIO 재시작 중 오브젝트 스토리지가 수초간 중단됐다. 데이터는 `/data/minio` 바인드 마운트라 영향 없음.

## 7. input.json 의 region 값은 어떻게 둘 것인가 (실측 근거)

`MINIO_SITE_REGION`을 제거한 것은 **us-east-1 을 강제한 것이 아니라 리전 검증을 끈 것**이다.
컨테이너 내부 mc로 확인:

```
us-east-1  OK    eu-west-1  OK    ap-northeast-2  OK    totally-bogus-region-xyz  OK
```

`input.json`의 `ap-northeast-2`는 **실제로 사용된다.** MinIO 트레이스를 켜고 Orchestrator 파드를
재시작해 잡은 SigV4 Credential 스코프:

```
36건  Credential=<키>/20260917/ap-northeast-2/s3/aws4_request
 5건  Credential=<키>/20260917/us-east-1/s3/aws4_request   ← Orchestrator
```

리전을 소비하는 워크로드:

```
intsvcs-gallupx-server / -worker / -cron-task-consumer   env AWS_REGION    <- REGION
intsvcs-periodic                                         env AWS_S3_REGION <- REGION
dataservice-runtime / -taskrunner                        시크릿 전체 마운트(REGION 포함)
platform-organization-management-service                 시크릿 전체 마운트(REGION 포함)
orchestrator                                             REGION 매핑 없음  ← 이것만 예외
```

**현 클러스터 기준 결론: `input.json`은 `ap-northeast-2`로 유지한다.** 지금 상태에서 us-east-1로
바꾸면 Orchestrator에는 아무 영향이 없고(값을 받지 않으므로), 값을 실제로 쓰는 Integration Service가
실제 배포 리전과 다른 리전으로 서명하게 된다. MinIO가 이미 어떤 리전이든 받으므로 이득이 없다.
(신규 설치는 결론이 다르다 — 아래 참조.)

**필수 조건: MinIO에 사이트 리전을 다시 설정하지 말 것.** 설정하면 Orchestrator는 구성으로 대응할
방법이 없어 즉시 같은 크래시로 돌아간다.

### 신규 설치라면 처음부터 us-east-1 로 구성한다 (권고)

위 결론은 "이미 설치되어 돌아가는 이 클러스터"에 한정된 것이다. **처음 설치하는 경우에는
`region`을 `us-east-1`로 잡는 것이 옳다.**

근거: Orchestrator의 서명 리전은 설정으로 바꿀 수 없고 항상 SDK 기본값 `us-east-1`이다
(5절 참조). 따라서 `us-east-1`은 전 구성요소가 합의할 수 있는 유일한 값이다. 이 값으로 통일하면
Integration Service도 같은 리전으로 서명하므로 **오브젝트 스토어의 리전 검증을 끄지 않고
정상 설정으로 운영할 수 있다.** 리전 검증이 필수인 다른 S3 호환 스토리지(Ceph RGW zonegroup,
Dell ECS 등)로 이전해도 그대로 통한다.

```jsonc
"external_object_storage": {
  "enabled": true,
  "storage_type": "s3",
  "fqdn": "minio.myrobots.co.kr",
  "port": 9000,
  "region": "us-east-1",   // S3 호환 스토리지에서는 us-east-1 고정.
                           // Orchestrator 는 이 값을 받지 못하고 us-east-1 로 서명하므로
                           // 다른 값을 쓰면 리전 검증이 있는 스토어에서 Orchestrator 만 실패한다.
}
```
```bash
MINIO_SITE_REGION=us-east-1   # 같은 값으로 맞추면 검증 유지 가능
```

UiPath 문서는 이 필드에 권고값을 제시하지 않는다. 설명은 "Specify the AWS region where buckets
are hosted"로, MinIO에는 대응 개념이 없다.

**기존 클러스터를 이 방식으로 바꿀 때 순서 주의.** 리전 값은 Integration Service 등이 실제로
사용하므로(현재 `ap-northeast-2` 서명 36건) 양쪽을 함께 바꿔야 한다.
`input.json` region 변경 → `uipathctl` 재적용 → 해당 파드 재시작 → `MINIO_SITE_REGION` 설정 및
MinIO 내부 `site region` 설정 → 검증. MinIO만 먼저 켜면 그 36건이 전부 깨진다.

## 8. 남은 별개 이슈

- **`uipathpullsecret` 시크릿 없음.** 여러 파드가 `FailedToRetrieveImagePullSecret` 경고를 낸다.
  이미지가 노드에 캐시되어 현재는 pull이 성공하지만 새 이미지에서는 실패한다.
- **asrobots 파드 스케줄 불가.** `0/4 nodes are available: 1 node(s) had untolerated taint(s),
  3 node(s) didn't match Pod's node affinity/selector`. Serverless robots용 노드 라벨이 필요하다.
  파드 `c779d72e-0400-0000-e667-0b4a2318b8d3`가 계속 `Pending`.
- **`location-service-seed` 최초 실패 원인 미확인.** 이전 설치 시도에서 이 hook Job이 실패해
  네임스페이스 삭제 데드락의 출발점이 됐다. 이번 재설치에서는 통과했으나 원인은 규명되지 않았다.
