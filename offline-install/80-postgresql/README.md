# 80-postgresql — PostgreSQL 오프라인 설치 (TLS 활성)

UiPath Automation Suite 일부 구성요소용 PostgreSQL. TLS 활성, 5432 수신.
컨테이너명은 `postgres` 다.

Ubuntu 22.04 에어갭 노드에서 이전 번들로 **판정 25/25 통과**를 확인했다(7절).
`template1` 의 `btree_gin` 과 `max_connections=300` 을 더한 지금의 판정 29항목은
실제 서버에서 아직 실행하지 않았다. 정적 검사만 했다(7절).

> Harbor 는 내장 PostgreSQL(`harbor-db`)을 쓰므로 이 단계와 무관하다.
> `30-harbor` 를 위해 이 단계를 설치할 필요는 없다.

---

## 1. 공식 이미지를 쓴다

업스트림이 유지·보안 갱신을 계속하므로 자체 빌드보다 낫다.

```
postgres:16.10-bookworm
```

베이스 OS 를 jammy 로 맞춰야 하는 제약이 있을 때만 대안 이미지를 쓴다.
공식 이미지는 Debian bookworm 기반이다.

```
docker.io/javaos74/postgres-jammy:16.15
```

바꾸려면 `versions.env` 의 `POSTGRES_IMAGE` 를 `POSTGRES_JAMMY_IMAGE` 로,
`POSTGRES_IMAGE_DIGEST` 를 `POSTGRES_JAMMY_*` 로 바꾼다. 번들은 태그가 아니라
**다이제스트로** 이미지를 받는다.

`20-minio`(업스트림 아카이브됨)와 달리 여기는 업스트림이 살아 있으므로 자체
이미지를 기본으로 두지 않는다.

---

## 2. TLS 를 반드시 켜는 이유

**UiPath AS 의 `temporal-sql-tool`(taas-temporal-schema 잡)이 `SQL_TLS=true` 로
실행된다.** 평문 서버에는 붙지 못하므로 `ssl=on` 이 필수다.

다만 같은 잡이 `SQL_TLS_DISABLE_HOST_VERIFICATION=true` 도 설정한다. 즉
**CA 체인 검증도 호스트명 검증도 하지 않는다.** 그래서 자가서명 인증서로 충분하다.

이 사실을 모르면 두 방향으로 시간을 버린다. TLS 를 끄고 시작해 잡이 실패하거나,
반대로 사내 CA 발급 절차를 먼저 밟느라 지연된다.

### postgres 는 키 파일 권한에 엄격하다

키 파일이 자기 소유가 아니거나 권한이 넓으면 **기동을 거부한다.**

```
FATAL: private key file "/etc/postgresql/certs/server.key" has group or world access
```

그래서 `install.sh` 가 소유권을 컨테이너 uid(999)로, 권한을 `0600` 으로 맞춘다.
판정에도 두 항목이 들어 있다.

---

## 3. 설정 값과 근거

`command:` 로 넘기는 값들이다. 운영 중인 환경에서는 `max_connections=200` 으로
검증한 조합이다. `max_connections` 는 그 뒤 300 으로 올렸고 실제 서버에서는 아직
검증하지 않았다(7절).

| 항목 | 값 | 근거 |
|---|---|---|
| `max_connections` | 300 | AS 구성요소가 다수의 커넥션을 연다. 200 에서 올렸다. 정렬·해시 연산 하나가 `work_mem` 까지 쓰므로 연결 300 개가 연산을 하나씩만 해도 최대 약 4.7GB 다. 호스트 메모리를 함께 본다. 서버 시작 때만 바뀐다(9절) |
| `shared_buffers` | 2GB | `shm_size: 1gb` 와 함께 조정. 공유 메모리가 부족하면 기동 실패 |
| `effective_cache_size` | 6GB | 플래너 힌트. 실제 할당이 아니다 |
| `work_mem` / `maintenance_work_mem` | 16MB / 512MB | |
| `wal_compression` | on | WAL 용량 절감 |
| `password_encryption` | **scram-sha-256** | `md5` 는 취약하고 최신 클라이언트가 기본으로 scram 을 요구한다 |
| `ssl_min_protocol_version` | TLSv1.2 | |
| `data_checksums` | on (initdb 인자) | **나중에 켤 수 없다.** 처음에 켜야 한다 |

`PGDATA` 를 볼륨 루트가 아니라 하위 디렉터리(`data/pgdata`)로 둔다. 볼륨 루트에
바로 초기화하면 `lost+found` 같은 항목이 있을 때 `initdb` 가 거부한다.

### `template1` 에 `btree_gin` 을 넣는다

AS 의 PostgreSQL DB 에 `btree_gin` 확장이 있어야 한다. 참고로 업스트림 Temporal 의
PostgreSQL visibility 스키마가 `btree_gin` 을 쓴다.

`install.sh` 는 기동 직후 `template1` 에서 다음을 실행한다.

```sql
CREATE EXTENSION IF NOT EXISTS btree_gin;
```

`CREATE DATABASE` 는 `TEMPLATE` 을 지정하지 않으면 `template1` 을 복사한다. 그래서
이후 만드는 DB 는 모두 `btree_gin` 을 갖고 만들어진다. AS 가 만드는
`AutomationSuite_*` 만이 아니라 9절의 `uipath_db` 같은 다른 DB 도 마찬가지다.

다음 DB 에는 들어가지 않는다.

- 이미 있던 DB. `template1` 은 복사하는 시점의 내용만 넘긴다. 9절의 수동 절차를 쓴다
- `TEMPLATE template0` 로 만드는 DB. AS 설치기가 어느 template 을 쓰는지는 확인하지
  못했다. AS 가 DB 를 만든 뒤 9절의 확인 절차로 본다
- initdb 때 만들어진 `postgres` DB

`btree_gin` 은 PostgreSQL contrib 확장이다. 이미지에 확장 파일이 없으면 설치 단계가
`extension "btree_gin" is not available` 로 멈춘다.

---

## 4. 설치

```bash
# 빌드 호스트(인터넷 O)
cd offline-install/80-postgresql && ./build-bundle.sh

# 타깃 노드(에어갭)
scp bundle/postgresql-*.tar.gz{,.sha256} <타깃>:~/
sha256sum -c postgresql-*.tar.gz.sha256
tar xzf postgresql-*.tar.gz && cd postgresql-*

sudo ../offline-install/90-verify/airgap-on.sh   # 검증 목적
sudo ./install.sh
```

옵션은 `--check-only`, `--test-restart`, `--uninstall`(데이터 보존) 이다.

### 설정 값 (`site.env`)

| 키 | 기본 동작 |
|---|---|
| `PG_HOSTNAME` | 인증서 SAN 에 들어간다. 비우면 `postgres[.도메인]` 추정 |
| `PG_PASSWORD` | **비우면 무작위 생성**하고 설치 끝에 출력 |
| `PG_SUPERUSER` | `postgres` |
| `PG_TZ` | `Asia/Seoul` |
| `PG_DATA_DIR` | 호스트 데이터 경로 `/data/postgresql`; 컨테이너의 `/var/lib/postgresql/data`에 마운트. 실제 PGDATA는 하위 `pgdata` |

번들 크기는 145MB 다.

---

## 5. 판정 29항목

```
docker / compose 사용 가능 · 이미지 적재됨
compose 파일 · env(0600) · 인증서 · 데이터 디렉터리 · compose 문법
컨테이너 실행 중(크래시 루프 아님)      <- PID 10초 유지
재시작 정책 unless-stopped · 호스트 5432 수신
인증서가 컨테이너 uid(999) 소유 · server.key 0600 · SAN 에 접속 이름 포함
pg_isready · psql 접속
ssl=on (AS 의 SQL_TLS=true 요구)
password_encryption=scram-sha-256 · data_checksums=on · max_connections=300
btree_gin 사용 가능(이미지에 포함) · template1 에 btree_gin 설치됨
  -- TLS 접속 --
sslmode=require 로 접속 성공
세션이 실제로 암호화됨(pg_stat_ssl)
  -- DB 왕복 --
DB 생성 -> 새 DB 가 template1 의 btree_gin 을 물려받음
테이블·INSERT -> SELECT 값 확인
호스트 볼륨에 데이터 기록됨
```

이전 번들(판정 25항목)로 설치한 서버에서 새 번들의 `--check-only` 를 먼저 실행하면
`max_connections=300`, `template1 에 btree_gin 설치됨`, `새 DB 가 template1 의 btree_gin 을
물려받음` 이 FAIL 이고 종료 코드가 1 이다. `--check-only` 는 설치 단계를 실행하지 않기
때문이다. 반영 방법은 9절에 있다.

### `SHOW ssl` 만으로 판정하지 않는다

`SHOW ssl` 은 "서버가 TLS 를 켰다"까지만 알려준다. 실제로 TLS 세션이 성립하는지는
`sslmode=require` 로 붙어 보고, 그 세션이 정말 암호화됐는지 확인해야 안다.

```sql
SELECT ssl FROM pg_stat_ssl WHERE pid = pg_backend_pid();   -- t 여야 한다
```

비밀번호는 `PGPASSWORD` 환경변수로 넘긴다. 인자로 넘기면 호스트의 `ps` 에 노출된다.

---

## 6. 자동 복구

```bash
sudo ./install.sh --test-restart
```

| 단계 | 방법 | 확인 |
|---|---|---|
| 프로세스 사고사 | 호스트에서 컨테이너 PID 에 `kill -9` | `RestartCount` 증가 + psql 응답 |
| 재부팅 대리 | `systemctl restart docker` | running 복귀 + psql 응답 |

`docker kill` 로 시험하면 안 된다. 수동 정지로 기록되어 `unless-stopped` 가
재시작하지 않는다.

**`RestartCount` 증가를 기다린다.** `status == running` 을 기다리면 kill 직후
docker 가 아직 죽음을 인지하지 못해 즉시 통과하고 `RestartCount=0` 을 읽어 거짓
실패가 된다(`70-mssql` 8절 참고).

SIGKILL 이후에는 crash recovery 가 돌아가므로 응답까지 시간이 걸린다.

---

## 7. 검증 상태

### `template1` 의 `btree_gin` · `max_connections=300` 변경: 정적 검사만 했다

**실제 서버나 VM 에서 설치를 실행하지 않았다.** 다음은 확인하지 않았다.

- 판정 29항목 통과 여부
- 이미지에 `btree_gin` 확장 파일이 들어 있는지
- AS 설치기가 `template1` 로 DB 를 만드는지
- `max_connections=300` 에서 호스트 메모리가 충분한지

| 검사 | 결과 |
|---|---|
| `bash -n` (`install.sh`, `build-bundle.sh`) | 통과 |
| `shellcheck -x -S warning` (두 파일) | 새 경고 없음. 기존 `install.sh` 22행 SC1090 1건만 남음 |
| `build-bundle.sh` 의 compose 템플릿 생성 부분만 네트워크 없이 실행 | 템플릿에 `max_connections=300` 확인 |
| `run_checks()` 의 `check` 호출 수 | 29. 5절 목록과 같음 |

### 이전 번들 (판정 25항목, `max_connections=200`)

2026-09-23 에 Ubuntu 22.04 에어갭 노드에서 수행했다. 이 결과는 위 변경 전 번들의 것이다.

| 항목 | 결과 |
|---|---|
| 번들 빌드 | **완료** (145MB, 다이제스트 고정) |
| 에어갭 설치 + 판정 | **통과 25/25** |
| `ssl` / `password_encryption` / `data_checksums` | `on` / `scram-sha-256` / `on` |
| TLS 세션 실제 암호화(`pg_stat_ssl`) | **통과** |
| DB 왕복 + 호스트 볼륨 기록 | **통과** |
| 자동 복구(PID kill / 데몬 재시작) | **통과** (`RestartCount 0 -> 1`) |
| `airgap-fwd-other` 카운터 | **0** |

```
버전=16.10 (Debian 16.10-1.pgdg12+1) / ssl=on
password_encryption=scram-sha-256 / data_checksums=on
=== 검증 결과: 통과 25 / 실패 0 ===
```

검증 중 고친 것이 두 가지다.

1. **호스트명이 `postgres.` 로 만들어졌다.** `hostname -d` 는 도메인이 없을 때
   오류가 아니라 **빈 문자열**을 반환하므로 `|| echo local` 폴백이 동작하지 않았다.
   빈 값을 따로 처리하도록 고쳤다. 같은 결함이 `20-minio` 에도 있어 함께 고쳤다.
2. **자동 복구 판정의 경쟁 조건** — `70-mssql` 8절과 같은 문제다.

---

## 8. 트러블슈팅

| 증상 | 원인 | 조치 |
|---|---|---|
| `FATAL: private key file has group or world access` | 키 파일 권한/소유권 | 2절. uid 999 소유 + 0600 |
| `initdb: directory exists but is not empty` | `PGDATA` 가 볼륨 루트 | 3절. 하위 디렉터리를 쓴다 |
| 기동 실패, 공유 메모리 관련 로그 | `shared_buffers` > `shm_size` | compose 의 `shm_size` 를 늘린다 |
| 클라이언트가 `SSL is not enabled` | `ssl=off` | 판정의 `ssl=on` 항목 확인 |
| `password authentication failed` (구 클라이언트) | `scram-sha-256` 미지원 클라이언트 | 클라이언트를 올린다. `md5` 로 내리지 말 것 |
| `data_checksums=off` 인데 켜고 싶다 | initdb 시점에만 가능 | 덤프 후 재초기화 필요 |
| 호스트명이 `postgres.` 처럼 나온다 | `hostname -d` 가 빈 문자열 | 7절 1번. 고쳐졌다. `site.env` 의 `PG_HOSTNAME` 로 명시 권장 |
| 설치가 `extension "btree_gin" is not available` 로 멈춘다 | 이미지에 확장 파일이 없다 | 이미지에 PostgreSQL contrib 확장이 들어 있는지 확인. 판정의 `btree_gin 사용 가능` 항목 |
| `--check-only` 에서 `max_connections=300` 이나 `btree_gin` 항목이 FAIL | 이전 번들로 설치한 서버 | 9절 "이미 설치된 서버에 반영하기" |
| `AutomationSuite_*` DB 에 `btree_gin` 이 없다 | `template1` 에 넣기 전에 만들어졌거나 `template0` 로 만들어졌다 | 9절 "이미 있는 `AutomationSuite_*` DB 에 넣기" |

로그: `docker logs postgres` · `docker compose -f /opt/postgresql/docker-compose.yml logs`

---

## 9. UiPath Automation Suite 연계

```
postgresql://<user>@<PG_HOSTNAME>:5432/<db>?sslmode=require
```

- **TLS 필수** (`SQL_TLS=true`). 자가서명으로 충분하다(2절)
- **슈퍼유저를 직접 쓰지 말 것.** AS 전용 롤과 DB 를 만든다

```sql
CREATE ROLE uipath LOGIN PASSWORD '<강한비밀번호>';
CREATE DATABASE uipath_db OWNER uipath;
```

클라이언트가 CA 를 검증해야 하는 경우에만 `/opt/postgresql/certs/server.crt` 를
배포한다. AS 는 검증하지 않으므로 보통 필요하지 않다.

아래 명령의 `-U postgres` 는 `PG_SUPERUSER` 를 바꿨다면 그 이름으로 바꾼다. 컨테이너
안의 Unix 소켓으로 붙으므로 비밀번호를 묻지 않는다.

### 이미 설치된 서버에 반영하기

이전 번들(`max_connections=200`, `template1` 에 확장 없음)로 설치한 서버에는 두 변경이
없다. **AS 가 DB 를 만들기 전에** 반영해야 새 DB 가 `btree_gin` 을 물려받는다.

표준 절차는 새 번들로 `install.sh` 를 다시 실행하는 것이다. **점검 시간에 한다.**

```bash
sudo ./install.sh
```

- 데이터, `postgres.env`, 인증서는 그대로 쓴다
- compose 파일이 바뀌므로 기존 파일을 `docker-compose.yml.bak.<시각>` 으로 백업하고 교체한다
- `docker compose up -d` 가 컨테이너를 다시 만든다. **PostgreSQL 이 재시작되어 접속 중인
  연결이 모두 끊긴다.** `max_connections` 는 서버 시작 때만 바뀌고, `-c` 로 넘기는 값이라
  `ALTER SYSTEM` 으로는 바꿀 수 없다
- 이어서 설치 단계가 `template1` 에 `btree_gin` 을 넣고 판정 29항목을 실행한다

지금 재시작할 수 없는데 AS 가 곧 DB 를 만들어야 한다면 `template1` 만 먼저 넣는다.
재시작이 필요 없다.

```bash
sudo docker exec postgres psql -U postgres -d template1 -v ON_ERROR_STOP=1 \
  -c 'CREATE EXTENSION IF NOT EXISTS btree_gin'
```

이때 `max_connections` 는 200 그대로이고 `--check-only` 의 `max_connections=300` 항목은
FAIL 로 남는다. 점검 시간에 위의 `install.sh` 재실행으로 반영한다.

`template1` 에 대화형 세션을 열어 둔 채로 두지 않는다. `template1` 에 다른 세션이 붙어
있으면 `CREATE DATABASE` 가 실패한다. 위처럼 `psql -c` 로 실행하면 바로 끊긴다.

어느 방법이든 이미 있는 DB 에는 들어가지 않는다. 다음 절차를 따로 한다.

### 이미 있는 `AutomationSuite_*` DB 에 넣기

`install.sh` 는 이미 있는 DB 를 고치지 않는다. `template1` 에 넣기 전에 만들어진 DB 나
`TEMPLATE template0` 로 만들어진 DB 에는 직접 넣는다.

대상은 이름이 `AutomationSuite_` 로 시작하는 DB 다. 대소문자를 구분하고 `_` 도 글자
그대로 비교하므로 `starts_with` 를 쓴다. `LIKE` 에서 `_` 는 아무 한 글자이고, `ILIKE` 는
대소문자를 구분하지 않는다.

DB 이름은 짐작해 적지 말고 서버에서 조회한다. 예를 들어 TaaS DB 는 출처에 따라
`AutomationSuite_TaaS` 와 `AutomationSuite_Taas` 두 표기가 있고, 실제 서버에서 확인하지
않았다. 따옴표 없이 만든 DB 라면 이름이 소문자라 아래 조건에 걸리지 않는다. 1) 의 결과가
비어 있으면 `sudo docker exec postgres psql -U postgres -l` 로 전체 목록을 본다.

```bash
# 1) 대상 확인
sudo docker exec postgres psql -U postgres -d postgres -tAc \
  "SELECT datname FROM pg_database WHERE starts_with(datname, 'AutomationSuite_') ORDER BY 1"

# 2) DB 마다 설치. 이미 있으면 NOTICE 만 나오고 넘어간다.
sudo docker exec postgres psql -U postgres -d postgres -tAc \
  "SELECT datname FROM pg_database WHERE starts_with(datname, 'AutomationSuite_') ORDER BY 1" |
while IFS= read -r db; do
  echo "== ${db}"
  sudo docker exec postgres psql -U postgres -d "$db" -v ON_ERROR_STOP=1 \
    -c 'CREATE EXTENSION IF NOT EXISTS btree_gin' </dev/null
done

# 3) 확인. DB 마다 btree_gin 버전이 나와야 한다. 비어 있으면 설치되지 않은 것이다.
sudo docker exec postgres psql -U postgres -d postgres -tAc \
  "SELECT datname FROM pg_database WHERE starts_with(datname, 'AutomationSuite_') ORDER BY 1" |
while IFS= read -r db; do
  printf '%s\t%s\n' "$db" "$(sudo docker exec postgres psql -U postgres -d "$db" -tAc \
    "SELECT extversion FROM pg_extension WHERE extname = 'btree_gin'" </dev/null)"
done
```

AS 의 `uipathctl prereq create` 가 새로 만든 DB 도 3) 으로 확인한다. 버전이 비어 있으면
설치기가 `template1` 이 아닌 template 으로 만든 것이므로 2) 를 실행한다.

---

## 10. 다음 단계

```
10-k8s → 60-cilium → 50-nfs-csi → 40-haproxy → 30-harbor → 20-minio
                                  → 70-mssql · [80-postgresql]
```

DB 는 클러스터 밖 별도 호스트에 두는 것을 권장한다.
