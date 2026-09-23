# 70-mssql — SQL Server 2022 (Full-Text Search 포함) 오프라인 설치

UiPath Automation Suite 가 요구하는 외부 SQL Server. **Full-Text Search 포함.**
컨테이너명은 `mssql` 이고 1433 을 수신한다.

Ubuntu 22.04 에어갭 노드에서 **판정 19/19 통과**를 확인했다(8절).

---

## 1. 왜 커스텀 이미지인가 — 공식 이미지에는 FTS 가 없다

**`mcr.microsoft.com/mssql/server` 이미지에는 Full-Text Search 가 들어 있지 않다.**
UiPath AS 는 FTS 를 요구하므로 공식 이미지로는 설치가 진행되지 않는다.

그래서 공식 이미지에 `mssql-server-fts` 를 설치한 이미지를 만들어 레지스트리에
올려 두고, 이 번들은 그것을 tar 로 담는다.

```
docker.io/javaos74/mssql-fts:2022-16.0.4265.3
```

빌드 레시피는 이렇다. 빌드는 온라인 호스트에서 하고, 에어갭에는 `docker save`
결과만 옮기므로 폐쇄망에서 문제가 되지 않는다.

```dockerfile
FROM mcr.microsoft.com/mssql/server:2022-latest
ARG FTS_VERSION=16.0.4265.3-1
USER root
RUN apt-get update \
 && apt-get install -y --no-install-recommends curl gnupg ca-certificates \
 && curl -fsSL https://packages.microsoft.com/keys/microsoft.asc \
      | gpg --dearmor -o /usr/share/keyrings/microsoft.gpg \
 && echo "deb [signed-by=/usr/share/keyrings/microsoft.gpg] https://packages.microsoft.com/ubuntu/22.04/mssql-server-2022 jammy main" \
      > /etc/apt/sources.list.d/mssql-server.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends mssql-server-fts=${FTS_VERSION} \
 && apt-get purge -y curl gnupg && apt-get autoremove -y \
 && rm -rf /var/lib/apt/lists/*
USER mssql
```

게시는 `00-common/publish-images.sh` 로 한다. **본체와 FTS 의 버전이 반드시
같아야 한다**(`16.0.4265.3-1`). 다르면 FTS 가 동작하지 않는다. 그래서 번들은
태그가 아니라 **다이제스트로** 이미지를 받는다.

---

## 2. 왜 deb 설치가 아닌가 — 24.04 에는 2022 저장소가 없다

`packages.microsoft.com` 의 실제 응답이다.

| 호스트 OS | 제공되는 mssql 저장소 |
|---|---|
| Ubuntu 22.04 | `mssql-server-2022`, `mssql-server-2025` |
| Ubuntu 24.04 | `mssql-server-2025` 만 (**2022 는 HTTP 404**) |

UiPath AS 가 지원하는 SQL Server 는 2016/2017/2019/2022 이고 **2025 는 지원
목록에 없다.** 즉 24.04 호스트에 deb 로 깔면 AS 가 지원하지 않는 버전이 된다.

컨테이너는 이미지 내부가 jammy 이므로 호스트 OS 와 무관하게 2022 를 쓸 수 있다
(실측: 이미지 내부 = Ubuntu 22.04.5). 이 번들이 컨테이너 방식을 쓰는 이유다.

---

## 3. 번들 내용

아카이브 1.3GB. 이미지가 대부분이다.

```
mssql-16.0.4265.3/
├── BUNDLE-INFO
├── SHA256SUMS
├── install.sh
├── 00-common/
├── images/               mssql-fts (docker-archive tar)
└── conf/
    ├── images.list · images.digests
    ├── docker-compose.yml.tmpl
    ├── mssql.env.tmpl
    └── verify-fts.sql            FTS 실동작 검증 SQL
```

`build-bundle.sh` 는 받은 이미지에 `mssql-server-fts` 가 실제로 있는지
`dpkg -l` 로 확인한다. 타깃에서 알게 되면 되돌리기 비싸다.

---

## 4. 설치

```bash
# 빌드 호스트(인터넷 O)
cd offline-install/70-mssql && ./build-bundle.sh

# 타깃 노드(에어갭)
scp bundle/mssql-*.tar.gz{,.sha256} <타깃>:~/
sha256sum -c mssql-*.tar.gz.sha256
tar xzf mssql-*.tar.gz && cd mssql-*

sudo ../offline-install/90-verify/airgap-on.sh   # 검증 목적
sudo ./install.sh                                 # 최초 기동은 DB 생성으로 느리다
```

옵션은 `--check-only`, `--test-restart`, `--uninstall`(데이터 보존) 이다.

### 설정 값 (`site.env`)

| 키 | 기본 동작 |
|---|---|
| `MSSQL_SA_PASSWORD` | **비우면 무작위 생성**하고 설치 끝에 출력 |
| `MSSQL_PID` | `Developer`. **운영은 Standard/Enterprise 필요** |
| `MSSQL_MEM_LIMIT` | `4g` |
| `MSSQL_COLLATION` | `versions.env` 에 있다. AS 가 요구하는 값 |

### 기동을 막는 세 가지

SQL Server 는 아래 조건을 만족하지 못하면 **기동 직후 종료되고 로그에만 이유를
남긴다.** `install.sh` 가 사전에 잡는다.

| 조건 | 값 |
|---|---|
| `ACCEPT_EULA` | `Y` 필수 |
| `MSSQL_SA_PASSWORD` | 8자 이상 + 대문자/소문자/숫자/기호 중 **3종류 이상** |
| 메모리 | **2GB 이상** (미만이면 기동 자체가 실패) |

`MSSQL_COLLATION` 은 **최초 기동 시에만** 적용된다. 이미 초기화된 인스턴스에서는
값을 바꿔도 반영되지 않는다. 틀렸다면 데이터 디렉터리를 비우고 다시 초기화해야 한다.

---

## 5. sqlcmd 는 PATH 에 없다

이미지에 `sqlcmd` 가 들어 있지만 **PATH 에 없다**(실측). 절대경로를 써야 한다.

```
/opt/mssql-tools18/bin/sqlcmd
```

`mssql-tools18` 은 기본이 **암호화 필수**이므로 자가서명 인증서를 쓰는 로컬
접속에는 `-C`(인증서 신뢰)가 필요하다. 없으면 연결 자체가 실패한다.

`-b` 도 반드시 준다. 없으면 SQL 오류가 나도 종료코드가 0 이 되어 판정이
통과해버린다.

비밀번호는 `-P` 인자가 아니라 `SQLCMDPASSWORD` 환경변수로 넘긴다. 인자로 넘기면
호스트의 `ps` 출력에 노출된다.

---

## 6. 판정 19항목

설정 확인에 더해 **FTS 실동작**과 **DB 왕복**을 수행한다.

```
docker / compose 사용 가능 · 이미지 적재됨
compose 파일 · env 파일(0600) · 데이터 디렉터리 · compose 문법
컨테이너 실행 중(크래시 루프 아님)      <- PID 10초 유지
재시작 정책 unless-stopped · 호스트 1433 수신 · sqlcmd 존재
sa 로 SQL 접속
Full-Text Search 설치됨(IsFullTextInstalled=1)    <- 이 단계의 존재 이유
collation 이 SQL_Latin1_General_CP1_CI_AS
  -- FTS 실동작 --
FTS 카탈로그·인덱스·CONTAINS 질의 성공
  -- DB 왕복 --
DB 생성 -> 테이블·INSERT -> SELECT 값 확인
호스트 볼륨에 DB 파일 기록됨
```

### FTS 는 SERVERPROPERTY 만으로 판정하지 않는다

`SERVERPROPERTY('IsFullTextInstalled')` 는 "설치됨"까지만 알려준다. 실제로
동작하는지는 카탈로그와 인덱스를 만들고 `CONTAINS` 질의를 해봐야 안다.
`conf/verify-fts.sql` 이 그 일을 한다.

```sql
CREATE FULLTEXT CATALOG fts_smoke_cat AS DEFAULT;
CREATE FULLTEXT INDEX ON docs(body) KEY INDEX PK_docs WITH STOPLIST = SYSTEM;
-- 인덱스 채우기는 비동기다. PopulateStatus 가 0 이 될 때까지 기다린다.
SELECT COUNT(*) FROM docs WHERE CONTAINS(body, 'verification');
```

PK 제약에 **이름을 명시**해야 한다(`CONSTRAINT PK_docs`). 이름을 주지 않으면
`PK__docs__3213E83F` 처럼 임의 접미사가 붙어 `KEY INDEX` 에 쓸 수 없다.

인덱스 채우기가 비동기라는 점도 중요하다. 즉시 질의하면 0건이 나와 거짓 실패가 된다.

---

## 7. 자동 복구

```bash
sudo ./install.sh --test-restart
```

| 단계 | 방법 | 확인 |
|---|---|---|
| 프로세스 사고사 | 호스트에서 컨테이너 PID 에 `kill -9` | `RestartCount` 증가 + SQL 응답 |
| 재부팅 대리 | `systemctl restart docker` | running 복귀 + SQL 응답 |

`docker kill` 로 시험하면 안 된다. 수동 정지로 기록되어 `unless-stopped` 가
재시작하지 않는다.

**`RestartCount` 가 늘어나기를 기다려야 한다.** `status == running` 을 기다리면
안 된다 — kill 직후에는 docker 가 아직 죽음을 인지하지 못해 status 가 그대로
`running` 이고, 첫 폴링에서 즉시 통과한 뒤 `RestartCount=0` 을 읽어 **거짓 실패**가
된다. 컨테이너가 클수록 이 경쟁에서 지기 쉽다 — SQL Server 가 정확히 그 사례였다
(8절).

컨테이너 PID 1 은 `sqlservr` 가 아니라 래퍼 스크립트 `launch_sqlservr` 다.
그래도 PID 1 을 죽이면 컨테이너가 종료되므로 검증에는 문제가 없다.

SIGKILL 이후에는 SQL Server 의 crash recovery 가 돌아가므로 응답까지 시간이
걸린다. 판정에서 240초까지 기다린다.

---

## 8. 검증 상태

2026-09-23 에 Ubuntu 22.04 에어갭 노드에서 수행했다.

| 항목 | 결과 |
|---|---|
| 번들 빌드 | **완료** (1.3GB, 다이제스트 고정) |
| 이미지에 FTS 포함 확인 | **통과** (`ii mssql-server-fts 16.0.4265.3-1`) |
| 에어갭 설치 + 판정 | **통과 19/19** |
| `IsFullTextInstalled` | **1** |
| FTS 실동작(카탈로그·인덱스·CONTAINS) | **통과** |
| collation | `SQL_Latin1_General_CP1_CI_AS` |
| DB 왕복 + 호스트 볼륨 기록 | **통과** |
| 자동 복구(PID kill / 데몬 재시작) | **통과** (`RestartCount 1 -> 2`) |
| `airgap-fwd-other` 카운터 | **0** |

```
버전=16.0.4265.3 / 에디션=Developer Edition (64-bit)
collation=SQL_Latin1_General_CP1_CI_AS / IsFullTextInstalled=1
=== 검증 결과: 통과 19 / 실패 0 ===
```

검증 중 발견해 고친 것이 하나 있다. **자동 복구 판정이 거짓 실패했다.**
`status == running` 을 기다리는 방식이 경쟁 조건이었다 — kill 직후 status 가 아직
`running` 이라 즉시 통과하고 `RestartCount=0` 을 읽었다. 격리 테스트에서
`kill -9` 1초 뒤 `RestartCount 0 -> 1` 로 정상 동작함을 확인했고, 판정을
`RestartCount` 증가 대기로 바꿨다. 같은 결함이 `20-minio` / `40-haproxy` /
`80-postgresql` 에도 있어 함께 고쳤다(그쪽은 컨테이너가 작아 우연히 통과하고
있었다).

---

## 9. 트러블슈팅

| 증상 | 원인 | 조치 |
|---|---|---|
| 기동 직후 컨테이너 종료 | 비밀번호 정책 미달 / `ACCEPT_EULA` 누락 / 메모리 2GB 미만 | `docker logs mssql` 확인. `install.sh` 가 사전에 잡는다 |
| `sqlcmd: command not found` | PATH 에 없다 | 5절. `/opt/mssql-tools18/bin/sqlcmd` |
| `SSL Provider: certificate verify failed` | `mssql-tools18` 은 암호화 필수 | `-C` 추가 |
| SQL 오류인데 판정이 통과 | `sqlcmd -b` 누락 | `-b` 를 주면 오류 시 0 이 아닌 종료코드 |
| `IsFullTextInstalled=0` | FTS 없는 이미지 | 1절. 공식 이미지에는 FTS 가 없다 |
| `CREATE FULLTEXT INDEX` 가 KEY INDEX 오류 | PK 제약 이름이 자동 생성됨 | 6절. `CONSTRAINT PK_docs` 처럼 이름 명시 |
| `CONTAINS` 가 0건 | 인덱스 채우기가 비동기 | `FULLTEXTCATALOGPROPERTY(...,'PopulateStatus')` 대기 |
| collation 이 다르다 | 최초 기동 시에만 적용된다 | 데이터 디렉터리를 비우고 재초기화 |
| 데이터가 사라짐 | 볼륨 마운트 누락 | 판정의 `호스트 볼륨에 DB 파일 기록됨` 확인 |

로그: `docker logs mssql` · `docker compose -f /opt/mssql/docker-compose.yml logs`
SQL Server 자체 로그는 `/data/mssql/log/errorlog` 다.

---

## 10. UiPath Automation Suite 연계

- **Full-Text Search 필수** — 이 번들은 포함한다
- **collation** `SQL_Latin1_General_CP1_CI_AS`
- **에디션** 운영은 Standard/Enterprise. 이미지 기본값은 `Developer`(평가용)이므로
  `site.env` 의 `MSSQL_PID` 로 바꿀 것
- **sa 를 직접 쓰지 말 것.** AS 전용 로그인과 DB 를 만들고 필요한 권한만 부여한다
- AS 는 여러 DB 를 만든다. `dbcreator` 권한이 필요하다

```sql
-- 예: AS 전용 로그인
CREATE LOGIN uipath WITH PASSWORD = '<강한비밀번호>';
ALTER SERVER ROLE dbcreator ADD MEMBER uipath;
```

---

## 11. 다음 단계

```
10-k8s → 60-cilium → 50-nfs-csi → 40-haproxy → 30-harbor → 20-minio
                                  → [70-mssql] · 80-postgresql
```

DB 는 클러스터 밖 별도 호스트에 두는 것을 권장한다. UiPath AS 는 외부 SQL Server 를
전제로 하며, 클러스터 장애가 DB 까지 끌고 가지 않도록 분리하는 것이 안전하다.
