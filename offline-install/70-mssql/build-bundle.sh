#!/usr/bin/env bash
#---------------------------------------------------------------------
# 70-mssql : 오프라인 번들 빌드 (온라인 호스트에서 실행)
#
# 산출물: bundle/mssql-<ver>/ + .tar.gz
#
# 용도: UiPath Automation Suite 의 외부 SQL Server. Full-Text Search 포함.
#
# 왜 커스텀 이미지인가:
#   공식 mcr.microsoft.com/mssql/server 이미지에는 **Full-Text Search 가
#   들어 있지 않다**(실측 확인). UiPath AS 는 FTS 를 요구하므로 공식 이미지로는
#   설치가 진행되지 않는다. 그래서 공식 이미지에 mssql-server-fts 를 설치한
#   이미지를 만들어 레지스트리에 올려 두고, 이 번들은 그것을 tar 로 담는다.
#
#   이미지: ${MSSQL_SERVER_IMAGE}
#   빌드 레시피와 게시 절차는 00-common/publish-images.sh 와
#   70-mssql/README.md 1절에 있다.
#
# 왜 deb 설치가 아닌가:
#   packages.microsoft.com 은 Ubuntu 24.04 용 mssql-server-2022 저장소를
#   제공하지 않는다(실측: 404). 24.04 에서 deb 로 가면 SQL Server 2025 가 되고
#   그것은 UiPath AS 지원 목록에 없다. 이미지 내부가 jammy 이므로 컨테이너로
#   가면 호스트 OS 와 무관하게 2022 를 쓸 수 있다.
#
# OS 의존 없음. docker / docker compose 는 10-k8s 번들에서 설치된다.
#---------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../00-common/common.sh"

require_online
require_cmds curl tar

BUNDLE_NAME="mssql-${MSSQL_VERSION}"
BUNDLE_DIR="${SCRIPT_DIR}/bundle/${BUNDLE_NAME}"
IMG_DIR="${BUNDLE_DIR}/images"
CONF_DIR="${BUNDLE_DIR}/conf"

step "SQL Server ${MSSQL_VERSION} (FTS 포함) 번들 빌드"
#---------------------------------------------------------------------
# 매 빌드에 다시 만드는 것은 먼저 지운다
#
# mkdir -p 만 쓰면 이전 빌드의 파일이 그대로 남아 새 아카이브에 실린다.
# 실측 사고: site.env 를 뺀 뒤 다시 빌드했는데도 이전 빌드의 site.env 가
# 번들에 남아 내부 IP·사내 호스트명이 그대로 들어갔다. SHA256SUMS 는 그것까지
# 포함해 만들어지므로 무결성 검사로도 걸러지지 않는다.
#
# debs / images / bin 은 의도적 다운로드 캐시라 남긴다. 아래는 매번
# 스크립트가 생성·복사하는 것들이므로 지워도 재빌드 비용이 없다.
#---------------------------------------------------------------------
rm -rf "${BUNDLE_DIR}/00-common" "${BUNDLE_DIR}/conf" "${BUNDLE_DIR}/90-verify"
rm -f  "${BUNDLE_DIR}"/*.sh "${BUNDLE_DIR}"/*.md \
       "${BUNDLE_DIR}/SHA256SUMS" "${BUNDLE_DIR}/BUNDLE-INFO"

mkdir -p "$IMG_DIR" "$CONF_DIR"

if ! command -v skopeo >/dev/null 2>&1; then
    log "skopeo 설치(빌드 도구)"
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq skopeo
fi
ok "skopeo $(skopeo --version | awk '{print $3}')"

#=====================================================================
# 1. 이미지
#
# 태그가 아니라 다이제스트로 받는다. 태그는 움직일 수 있고, 본체와 FTS 의
# 버전이 어긋나면 FTS 가 동작하지 않는다.
#=====================================================================
step "이미지 다운로드 (다이제스트 고정)"

IMG_REF="${MSSQL_SERVER_IMAGE%%:*}@${MSSQL_SERVER_IMAGE_DIGEST}"
IMG_TAR="${IMG_DIR}/$(image_to_filename "$MSSQL_SERVER_IMAGE").tar"

if [[ -s "$IMG_TAR" ]]; then
    log "이미 존재: $(basename "$IMG_TAR")"
else
    log "받는 중: ${IMG_REF}"
    # docker-archive 는 다이제스트 참조를 태그로 보존하지 못하므로
    # 원래 태그를 명시해 적재 후에도 같은 이름으로 쓰이게 한다.
    skopeo copy --retry-times 5 "docker://${IMG_REF}" \
        "docker-archive:${IMG_TAR}.part:${MSSQL_SERVER_IMAGE}" >/dev/null \
        || die "이미지 받기 실패: ${IMG_REF}"
    mv "${IMG_TAR}.part" "$IMG_TAR"
fi
ok "$(basename "$IMG_TAR") ($(du -h "$IMG_TAR" | cut -f1))"

echo "$MSSQL_SERVER_IMAGE" > "${CONF_DIR}/images.list"
cat > "${CONF_DIR}/images.digests" <<EOF
# 빌드 시점에 확인한 이미지 다이제스트
${MSSQL_SERVER_IMAGE} ${MSSQL_SERVER_IMAGE_DIGEST}
EOF

# FTS 가 실제로 들어 있는 이미지인지 빌드 시점에 확인한다.
# 타깃에서 알게 되면 되돌리기 비싸다.
step "이미지에 FTS 포함 여부 확인"
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    docker load -i "$IMG_TAR" >/dev/null 2>&1 || true
    if docker run --rm --entrypoint dpkg "$MSSQL_SERVER_IMAGE" \
         -l mssql-server-fts 2>/dev/null | grep -q '^ii'; then
        ok "mssql-server-fts 설치 확인"
    else
        die "이미지에 mssql-server-fts 가 없다. FTS 없는 이미지로는 AS 설치가 진행되지 않는다."
    fi
    docker run --rm --entrypoint bash "$MSSQL_SERVER_IMAGE" \
        -c "test -x ${MSSQL_SQLCMD}" 2>/dev/null \
        && ok "sqlcmd 존재: ${MSSQL_SQLCMD}" \
        || warn "이미지에 ${MSSQL_SQLCMD} 가 없다. install.sh 의 판정이 제한된다."
else
    warn "docker 를 쓸 수 없어 FTS 포함 여부를 확인하지 못했다."
fi

#=====================================================================
# 2. compose 템플릿
#=====================================================================
step "compose 템플릿 생성"

cat > "${CONF_DIR}/docker-compose.yml.tmpl" <<'EOF'
#---------------------------------------------------------------------
# SQL Server 2022 + Full-Text Search
#
# 이 파일은 70-mssql/install.sh 가 템플릿에서 생성한다.
# 고친 뒤에는 다음으로 반영한다:
#   sudo docker compose -f /opt/mssql/docker-compose.yml up -d
#---------------------------------------------------------------------
services:
  mssql:
    image: __MSSQL_IMAGE__
    container_name: mssql
    restart: unless-stopped
    env_file:
      - __MSSQL_DIR__/mssql.env
    ports:
      - "__MSSQL_PORT__:1433"
    volumes:
      # /var/opt/mssql 아래에 data / log / secrets 가 모두 들어간다.
      # 호스트 볼륨으로 빼지 않으면 컨테이너 재생성 시 DB 가 사라진다.
      - __MSSQL_DATA_DIR__:/var/opt/mssql
    # SQL Server 는 최소 2GB 를 요구하고, 그 이하에서는 기동 자체가 실패한다.
    # 상한을 두지 않으면 노드 메모리를 모두 쓸 수 있어 명시한다.
    # UiPath AS 운영에서는 더 늘려야 한다.
    mem_limit: __MSSQL_MEM_LIMIT__
    healthcheck:
      # sqlcmd 는 PATH 에 없다. 절대경로를 쓴다.
      # -C: 자가서명 인증서를 신뢰(mssql-tools18 은 기본이 암호화 필수)
      # -No 를 쓰지 않는 이유: 18 버전은 -C 로 신뢰만 하면 된다.
      test:
        - CMD-SHELL
        - __MSSQL_SQLCMD__ -S localhost -U sa -P "$$MSSQL_SA_PASSWORD" -C -Q "SELECT 1" -b -o /dev/null
      interval: 30s
      timeout: 10s
      retries: 5
      # 최초 기동은 DB 생성 때문에 오래 걸린다. 짧으면 healthcheck 가
      # 먼저 실패해 컨테이너가 unhealthy 로 표시된다.
      start_period: 90s
    logging:
      driver: json-file
      options:
        max-size: "20m"
        max-file: "5"
EOF
ok "docker-compose.yml.tmpl"

cat > "${CONF_DIR}/mssql.env.tmpl" <<'EOF'
#---------------------------------------------------------------------
# SQL Server 환경변수 — root 만 읽을 수 있어야 한다(0600).
#---------------------------------------------------------------------

# EULA 수락은 필수다. 없으면 컨테이너가 즉시 종료된다.
ACCEPT_EULA=Y

# sa 비밀번호. SQL Server 의 정책은 8자 이상 + 대문자/소문자/숫자/기호 중
# 3종류 이상이다. 만족하지 못하면 기동 직후 종료되고 로그에만 이유가 남는다.
MSSQL_SA_PASSWORD=__MSSQL_SA_PASSWORD__

# 에디션. 이미지에는 developer 가 박혀 있다(평가용).
# UiPath AS 운영은 Standard/Enterprise 를 요구한다.
MSSQL_PID=__MSSQL_PID__

# 데이터 정렬. UiPath AS 가 요구하는 값이며 **최초 기동 시에만** 적용된다.
# 이미 초기화된 인스턴스에서는 이 값을 바꿔도 반영되지 않는다.
MSSQL_COLLATION=__MSSQL_COLLATION__

# 타임존
TZ=__MSSQL_TZ__
EOF
ok "mssql.env.tmpl"

#=====================================================================
# 3. 검증용 SQL
#
# 파일로 두는 이유: install.sh 안에 인라인으로 넣으면 인용이 중첩되어
# 깨지기 쉽다. 파일을 컨테이너에 마운트해 실행한다.
#=====================================================================
step "검증 SQL 생성"

cat > "${CONF_DIR}/verify-fts.sql" <<'EOF'
-- Full-Text Search 가 실제로 동작하는지 확인한다.
-- SERVERPROPERTY 만 보면 "설치됨"까지만 알 수 있어, 카탈로그와 인덱스를
-- 실제로 만들고 CONTAINS 질의까지 수행한다.
SET NOCOUNT ON;

IF DB_ID('fts_smoke') IS NOT NULL
BEGIN
    ALTER DATABASE fts_smoke SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE fts_smoke;
END
CREATE DATABASE fts_smoke;
GO

USE fts_smoke;
GO

-- PK 제약에 이름을 명시한다. 이름을 주지 않으면 PK__docs__3213E83F 처럼
-- 임의 접미사가 붙어 CREATE FULLTEXT INDEX 의 KEY INDEX 에 쓸 수 없다.
CREATE TABLE docs (
    id   INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_docs PRIMARY KEY,
    body NVARCHAR(400) NULL
);
INSERT INTO docs (body) VALUES
    (N'offline install verification of full text search'),
    (N'unrelated content about storage and networking');
GO

-- 전문 검색 카탈로그와 인덱스. FTS 가 없으면 여기서 오류가 난다.
CREATE FULLTEXT CATALOG fts_smoke_cat AS DEFAULT;
CREATE FULLTEXT INDEX ON docs(body) KEY INDEX PK_docs
    WITH STOPLIST = SYSTEM;
GO

-- 인덱스 채우기를 기다린다. 비동기이므로 즉시 질의하면 0건이 나올 수 있다.
DECLARE @tries INT = 0;
WHILE @tries < 30
      AND FULLTEXTCATALOGPROPERTY('fts_smoke_cat', 'PopulateStatus') <> 0
BEGIN
    WAITFOR DELAY '00:00:01';
    SET @tries = @tries + 1;
END
GO

-- 결과를 단일 토큰으로 출력한다. install.sh 가 이 문자열을 grep 한다.
DECLARE @hits INT;
SELECT @hits = COUNT(*) FROM docs WHERE CONTAINS(body, 'verification');
IF @hits >= 1
    PRINT 'FTS_QUERY_OK';
ELSE
    PRINT 'FTS_QUERY_FAILED';
GO

USE master;
GO
ALTER DATABASE fts_smoke SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
DROP DATABASE fts_smoke;
GO
EOF
ok "verify-fts.sql"

#=====================================================================
# 4. 패키징
#=====================================================================
step "번들 패키징"
mkdir -p "${BUNDLE_DIR}/00-common"
cp "${SCRIPT_DIR}/../00-common/versions.env" "${BUNDLE_DIR}/00-common/"
if [[ -f "${SCRIPT_DIR}/../00-common/site.env" ]]; then
    cp "${SCRIPT_DIR}/../00-common/site.env" "${BUNDLE_DIR}/00-common/"
else
    cp "${SCRIPT_DIR}/../00-common/site.env.example" "${BUNDLE_DIR}/00-common/"
    warn "site.env 가 없어 예시 값으로 번들을 만든다. 타깃에서 값을 채워야 한다."
fi
cp "${SCRIPT_DIR}/../00-common/common.sh" "${BUNDLE_DIR}/00-common/"
cp "${SCRIPT_DIR}/install.sh"             "${BUNDLE_DIR}/"
cp "${SCRIPT_DIR}/README.md"              "${BUNDLE_DIR}/" 2>/dev/null || true
chmod +x "${BUNDLE_DIR}/install.sh"

cat > "${BUNDLE_DIR}/BUNDLE-INFO" <<EOF
bundle        : ${BUNDLE_NAME}
bundle_version: ${BUNDLE_VERSION}
built_at      : $(date -Is)
built_on      : $(hostname)
target_os     : Ubuntu 22.04 / 24.04 공용 (이미지 내부는 jammy)
image         : ${MSSQL_SERVER_IMAGE}
digest        : ${MSSQL_SERVER_IMAGE_DIGEST}
mssql-server  : ${MSSQL_FTS_PKG_VERSION}
FTS           : 포함 (mssql-server-fts ${MSSQL_FTS_PKG_VERSION})
포트          : ${MSSQL_PORT}
collation     : ${MSSQL_COLLATION}
에디션 기본값 : ${MSSQL_PID_DEFAULT} (운영은 Standard/Enterprise 필요)
재시작 정책   : unless-stopped
EOF

write_manifest "$BUNDLE_DIR"

TARBALL="${SCRIPT_DIR}/bundle/${BUNDLE_NAME}.tar.gz"
tar -C "${SCRIPT_DIR}/bundle" -czf "$TARBALL" "$BUNDLE_NAME"
# `sha256sum -c` 가 읽을 수 있는 형식으로 쓴다. 해시만 남기면
# "no properly formatted checksum lines found" 로 검증 자체가 되지 않는다.
# 경로가 아니라 파일명만 넣어야 타깃에서 같은 디렉터리에 두고 검증할 수 있다.
( cd "$(dirname "$TARBALL")" && sha256sum "$(basename "$TARBALL")" ) > "${TARBALL}.sha256"

step "완료"
cat "${BUNDLE_DIR}/BUNDLE-INFO"
echo
ok "번들: ${TARBALL} ($(du -h "$TARBALL" | cut -f1))"
