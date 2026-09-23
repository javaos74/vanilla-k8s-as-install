#!/usr/bin/env bash
#---------------------------------------------------------------------
# mssql 이미지를 실제로 띄워서 Full-Text Search 를 판정한다.
#
# 왜 이 스크립트가 따로 있는가:
#   "FTS 가 들어 있는가"를 dpkg 로만 보면 틀릴 수 있다. 패키지가 깔려 있어도
#   엔진 버전과 어긋나면 SQL Server 는 FTS 를 로드하지 않는다. 판정은 반드시
#   컨테이너를 띄워 SQL 에 물어봐야 한다.
#
#   또한 이미지 교체 전후를 같은 잣대로 비교할 수 있어야 한다. 그래서 번들
#   설치(install.sh)와 무관하게 이미지 하나만 받아 검사하는 독립 스크립트다.
#
# 사용:
#   ./verify-fts-image.sh <이미지>            # 판정
#   ./verify-fts-image.sh <이미지> --smoke    # + FTS 실동작(CONTAINS) 검증
#   ./verify-fts-image.sh <이미지> --keep     # 컨테이너를 남긴다(디버깅)
#
# 예:
#   ./verify-fts-image.sh mcr.microsoft.com/mssql/server:2022-CU25-ubuntu-22.04
#   ./verify-fts-image.sh docker.io/javaos74/mssql-fts:2022-16.0.4255.1 --smoke
#
# 종료코드: 0 = FTS 사용 가능 / 1 = 사용 불가
#
# 비밀번호는 매 실행마다 무작위 생성하고 sqlcmd 에는 SQLCMDPASSWORD 환경변수로
# 넘긴다. -P 인자로 넘기면 호스트의 ps 출력에 노출된다.
#---------------------------------------------------------------------
set -uo pipefail

IMAGE="${1:-}"
[[ -n "$IMAGE" ]] || { echo "사용법: $0 <이미지> [--smoke] [--keep]" >&2; exit 2; }
shift

SMOKE=no
KEEP=no
for a in "$@"; do
    case "$a" in
        --smoke) SMOKE=yes ;;
        --keep)  KEEP=yes ;;
        *) echo "알 수 없는 인자: $a" >&2; exit 2 ;;
    esac
done

SQLCMD="/opt/mssql-tools18/bin/sqlcmd"
CONTAINER="ftsverify-$$"
WAIT_SECONDS=240

# docker 를 sudo 로 쓸지 판단한다. 호스트에 따라 다르다.
if docker info >/dev/null 2>&1; then
    DOCKER=(docker)
elif sudo -n docker info >/dev/null 2>&1 || sudo docker info >/dev/null 2>&1; then
    DOCKER=(sudo docker)
else
    echo "docker 를 쓸 수 없다." >&2; exit 2
fi

# 정책(8자 이상 + 3종류 이상)을 확실히 만족시킨다. 미달이면 SQL Server 는
# 기동 직후 종료되고 로그에만 이유를 남긴다.
SA_PASS="Vf$(openssl rand -hex 12)#Q9"

cleanup() {
    if [[ "$KEEP" == "yes" ]]; then
        echo "  (컨테이너 유지: ${CONTAINER})"
    else
        "${DOCKER[@]}" rm -f "$CONTAINER" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

echo "== 대상 이미지"
echo "  ${IMAGE}"
"${DOCKER[@]}" image inspect "$IMAGE" -f '  digest  {{range .RepoDigests}}{{.}} {{end}}
  arch    {{.Architecture}}/{{.Os}}' 2>/dev/null || {
    echo "  로컬에 없다. 받는다."
    "${DOCKER[@]}" pull "$IMAGE" >/dev/null || { echo "pull 실패" >&2; exit 2; }
    "${DOCKER[@]}" image inspect "$IMAGE" -f '  digest  {{range .RepoDigests}}{{.}} {{end}}'
}

echo
echo "== 이미지 안의 mssql 패키지 (dpkg)"
"${DOCKER[@]}" run --rm --user root --entrypoint bash "$IMAGE" -c \
    'dpkg -l 2>/dev/null | awk "/mssql/ {printf \"  %-4s %-22s %s\n\", \$1, \$2, \$3}"; \
     if [[ -s /opt/mssql/lib/sqlservr.fts.sfp ]]; then \
        echo "  FTS 페이로드 sqlservr.fts.sfp: 있음 ($(du -h /opt/mssql/lib/sqlservr.fts.sfp | cut -f1))"; \
     else echo "  FTS 페이로드 sqlservr.fts.sfp: 없음"; fi'

echo
echo "== 컨테이너 기동 (${CONTAINER})"
"${DOCKER[@]}" rm -f "$CONTAINER" >/dev/null 2>&1 || true
"${DOCKER[@]}" run -d --name "$CONTAINER" \
    -e ACCEPT_EULA=Y \
    -e MSSQL_SA_PASSWORD="$SA_PASS" \
    -e MSSQL_PID=Developer \
    "$IMAGE" >/dev/null || { echo "기동 실패" >&2; exit 1; }

# sqlcmd 가 응답할 때까지 기다린다. 최초 기동은 DB 생성 때문에 느리다.
# -C: mssql-tools18 은 암호화가 기본 필수라 자가서명 인증서를 신뢰시켜야 한다.
ready=no
for ((i = 0; i < WAIT_SECONDS / 5; i++)); do
    if "${DOCKER[@]}" exec -e SQLCMDPASSWORD="$SA_PASS" "$CONTAINER" \
         "$SQLCMD" -S localhost -U sa -C -N -b -Q "SELECT 1" >/dev/null 2>&1; then
        ready=yes; break
    fi
    # 컨테이너가 죽었으면 더 기다릴 이유가 없다.
    if [[ "$("${DOCKER[@]}" inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null)" != "true" ]]; then
        echo "  컨테이너가 종료됐다. 로그:" >&2
        "${DOCKER[@]}" logs --tail 20 "$CONTAINER" >&2
        exit 1
    fi
    sleep 5
done
[[ "$ready" == "yes" ]] || { echo "  ${WAIT_SECONDS}초 안에 SQL 이 응답하지 않았다" >&2; exit 1; }
echo "  SQL 응답 확인"

sq() {
    "${DOCKER[@]}" exec -e SQLCMDPASSWORD="$SA_PASS" "$CONTAINER" \
        "$SQLCMD" -S localhost -U sa -C -N -b -h-1 -W -s'|' -Q "$1" 2>&1
}

# @@VERSION 은 여러 줄이라 한 줄로 접어서 받는다. CU/KB/플랫폼 문자열이 여기 있다.
VER_FULL="$(sq "SET NOCOUNT ON; SELECT LTRIM(RTRIM(REPLACE(REPLACE(REPLACE(CAST(@@VERSION AS nvarchar(max)), CHAR(13), ' '), CHAR(10), ' '), CHAR(9), ' ')));" \
            | tr -s ' ' | head -1)"

# 스칼라 4개를 한 번에 받는다.
RAW="$(sq "SET NOCOUNT ON;
SELECT 'ISFULLTEXTINSTALLED', CAST(ISNULL(SERVERPROPERTY('IsFullTextInstalled'), 0) AS varchar(32))
UNION ALL SELECT 'FTSSERVICEINSTALLED', CAST((SELECT COUNT(*) FROM sys.dm_server_services WHERE servicename LIKE '%Full%') AS varchar(32))
UNION ALL SELECT 'FULLTEXTCATALOGS', CAST((SELECT COUNT(*) FROM sys.fulltext_catalogs) AS varchar(32))
UNION ALL SELECT 'FULLTEXTLANGUAGES', CAST((SELECT COUNT(*) FROM sys.fulltext_languages) AS varchar(32))
UNION ALL SELECT 'PRODUCTVERSION', CAST(SERVERPROPERTY('ProductVersion') AS varchar(64))
UNION ALL SELECT 'EDITION', CAST(SERVERPROPERTY('Edition') AS varchar(128))
UNION ALL SELECT 'COLLATION', CAST(SERVERPROPERTY('Collation') AS varchar(128));")"

get() { echo "$RAW" | awk -F'|' -v k="$1" '$1==k {gsub(/^ +| +$/, "", $2); print $2; exit}'; }

FTS_INSTALLED="$(get ISFULLTEXTINSTALLED)"
FTS_SERVICE="$(get FTSSERVICEINSTALLED)"
FTS_CATALOGS="$(get FULLTEXTCATALOGS)"
FTS_LANGS="$(get FULLTEXTLANGUAGES)"
PRODVER="$(get PRODUCTVERSION)"
EDITION="$(get EDITION)"
COLLATION="$(get COLLATION)"

# "Microsoft SQL Server 2022 (RTM-CU25) (KB5081477) - 16.0.4255.1 (X64) ... on Linux (Ubuntu 22.04.5 LTS) <X64>"
CUKB="$(echo "$VER_FULL" | grep -oE '\(RTM[^)]*\) \(KB[0-9]+\)' \
        | sed -e 's/) (/, /' -e 's/^(//' -e 's/)$//')"
PLATFORM="$(echo "$VER_FULL" | sed -n 's/.* on \(Linux.*\)$/\1/p')"
[[ -n "$PLATFORM" ]] || PLATFORM="$(echo "$VER_FULL" | sed -n 's/.* on \(.*\)$/\1/p')"

row() { printf "  %-19s | %s\n" "$1" "$2"; }

echo
echo "== 판정"
row ISFULLTEXTINSTALLED "${FTS_INSTALLED}$([[ "$FTS_INSTALLED" == "1" ]] && echo "                                    <- 설치됨" || echo "                                    <- 미설치")"
row FTSSERVICEINSTALLED "${FTS_SERVICE}$([[ "$FTS_SERVICE" == "0" ]] && echo "                                    <- FTS 서비스 미탑재" || echo "")"
row FULLTEXTCATALOGS    "$FTS_CATALOGS"
row FULLTEXTLANGUAGES   "$FTS_LANGS"
row PRODUCTVERSION      "${PRODVER}${CUKB:+  ($CUKB)}"
row EDITION             "$EDITION"
row PLATFORM            "$PLATFORM"
row COLLATION           "$COLLATION"

VERDICT=0
[[ "$FTS_INSTALLED" == "1" ]] || VERDICT=1
[[ "$FTS_SERVICE"  != "0" ]] || VERDICT=1

#---------------------------------------------------------------------
# 실동작 검증 — SERVERPROPERTY 만으로는 "설치됨"까지만 알 수 있다.
# 카탈로그와 인덱스를 만들고 CONTAINS 질의를 해봐야 실제 동작을 안다.
#
# PK 제약에 이름을 명시해야 한다. 자동 생성 이름(PK__docs__3213E83F)은
# KEY INDEX 에 쓸 수 없다.
# 인덱스 채우기는 비동기다. 즉시 질의하면 0건이 나와 거짓 실패가 된다.
#---------------------------------------------------------------------
if [[ "$SMOKE" == "yes" && "$VERDICT" -eq 0 ]]; then
    echo
    echo "== FTS 실동작 (카탈로그 -> 인덱스 -> CONTAINS)"
    SMOKE_OUT="$(sq "
SET NOCOUNT ON;
IF DB_ID('ftssmoke') IS NOT NULL BEGIN ALTER DATABASE ftssmoke SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE ftssmoke; END
CREATE DATABASE ftssmoke;
GO
USE ftssmoke;
CREATE TABLE docs (id int NOT NULL CONSTRAINT PK_docs PRIMARY KEY, body nvarchar(400) NULL);
INSERT INTO docs VALUES (1, N'full text verification sample'), (2, N'unrelated row');
CREATE FULLTEXT CATALOG fts_smoke_cat AS DEFAULT;
CREATE FULLTEXT INDEX ON docs(body) KEY INDEX PK_docs WITH STOPLIST = SYSTEM;
GO
DECLARE @i int = 0;
WHILE @i < 60 AND FULLTEXTCATALOGPROPERTY('fts_smoke_cat', 'PopulateStatus') <> 0
BEGIN WAITFOR DELAY '00:00:01'; SET @i += 1; END
SELECT 'CONTAINS_HITS', CAST(COUNT(*) AS varchar(16)) FROM docs WHERE CONTAINS(body, 'verification');
GO
USE master;
ALTER DATABASE ftssmoke SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
DROP DATABASE ftssmoke;
")"
    HITS="$(echo "$SMOKE_OUT" | awk -F'|' '$1=="CONTAINS_HITS" {gsub(/ /,"",$2); print $2; exit}')"
    if [[ "$HITS" == "1" ]]; then
        row CONTAINS_HITS "1  <- FTS 질의 정상"
    else
        row CONTAINS_HITS "${HITS:-오류}  <- 실패"
        echo "$SMOKE_OUT" | sed 's/^/      /'
        VERDICT=1
    fi
fi

echo
if [[ "$VERDICT" -eq 0 ]]; then
    echo "  결과: FTS 사용 가능"
else
    echo "  결과: FTS 사용 불가 — 이 이미지로는 UiPath AS 설치가 진행되지 않는다"
fi
exit "$VERDICT"
