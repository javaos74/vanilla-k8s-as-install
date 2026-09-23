# 80-postgresql — PostgreSQL 오프라인 설치 (TLS 활성)

UiPath Automation Suite 일부 구성요소용 PostgreSQL. TLS 활성, 5432 수신.
컨테이너명은 `postgres` 다.

Ubuntu 22.04 에어갭 노드에서 **판정 25/25 통과**를 확인했다(7절).

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

`command:` 로 넘기는 값들이다. 운영 중인 환경에서 검증된 조합이다.

| 항목 | 값 | 근거 |
|---|---|---|
| `max_connections` | 200 | AS 구성요소가 다수의 커넥션을 연다 |
| `shared_buffers` | 2GB | `shm_size: 1gb` 와 함께 조정. 공유 메모리가 부족하면 기동 실패 |
| `effective_cache_size` | 6GB | 플래너 힌트. 실제 할당이 아니다 |
| `work_mem` / `maintenance_work_mem` | 16MB / 512MB | |
| `wal_compression` | on | WAL 용량 절감 |
| `password_encryption` | **scram-sha-256** | `md5` 는 취약하고 최신 클라이언트가 기본으로 scram 을 요구한다 |
| `ssl_min_protocol_version` | TLSv1.2 | |
| `data_checksums` | on (initdb 인자) | **나중에 켤 수 없다.** 처음에 켜야 한다 |

`PGDATA` 를 볼륨 루트가 아니라 하위 디렉터리(`data/pgdata`)로 둔다. 볼륨 루트에
바로 초기화하면 `lost+found` 같은 항목이 있을 때 `initdb` 가 거부한다.

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

번들 크기는 145MB 다.

---

## 5. 판정 25항목

```
docker / compose 사용 가능 · 이미지 적재됨
compose 파일 · env(0600) · 인증서 · 데이터 디렉터리 · compose 문법
컨테이너 실행 중(크래시 루프 아님)      <- PID 10초 유지
재시작 정책 unless-stopped · 호스트 5432 수신
인증서가 컨테이너 uid(999) 소유 · server.key 0600 · SAN 에 접속 이름 포함
pg_isready · psql 접속
ssl=on (AS 의 SQL_TLS=true 요구)
password_encryption=scram-sha-256 · data_checksums=on
  -- TLS 접속 --
sslmode=require 로 접속 성공
세션이 실제로 암호화됨(pg_stat_ssl)
  -- DB 왕복 --
DB 생성 -> 테이블·INSERT -> SELECT 값 확인
호스트 볼륨에 데이터 기록됨
```

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

2026-09-23 에 Ubuntu 22.04 에어갭 노드에서 수행했다.

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

---

## 10. 다음 단계

```
10-k8s → 60-cilium → 50-nfs-csi → 40-haproxy → 30-harbor → 20-minio
                                  → 70-mssql · [80-postgresql]
```

DB 는 클러스터 밖 별도 호스트에 두는 것을 권장한다.
