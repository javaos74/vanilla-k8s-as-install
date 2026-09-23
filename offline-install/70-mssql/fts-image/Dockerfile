#---------------------------------------------------------------------
# SQL Server 2022 + Full-Text Search
#
# 왜 필요한가:
#   mcr.microsoft.com/mssql/server 공식 이미지에는 Full-Text Search 가 들어
#   있지 않다. 공식 CU25 이미지를 그대로 띄우면 이렇게 나온다(실측).
#       ISFULLTEXTINSTALLED | 0
#       FTSSERVICEINSTALLED | 0
#       FULLTEXTLANGUAGES   | 0
#   UiPath Automation Suite 는 FTS 를 요구하므로 설치가 진행되지 않는다.
#
# 왜 `apt-get install mssql-server-fts` 가 아닌가 — 이것이 이 파일의 핵심이다:
#   FTS 패키지의 의존 관계는 느슨하다(실측).
#       Depends: mssql-server (>= 14.0.405.163-2)
#   그리고 공식 이미지의 엔진은 **deb 로 등록돼 있지 않다**(실측: 베이스의
#   dpkg 목록에는 mssql-tools18 만 있다). 따라서 apt 는 의존이 미충족이라고
#   판단하고 저장소의 **최신** 엔진 deb 를 함께 끌어온다.
#       Inst mssql-server (16.0.4295.3-1 ...)      <- CU28. 베이스는 CU25다
#       Inst mssql-server-fts (16.0.4255.1-8 ...)
#   결과는 두 가지 문제다.
#     1) "CU25 이미지" 라는 전제가 조용히 깨진다. 엔진이 CU28 로 올라간다.
#     2) 이미지가 커진다. 구워진 엔진을 덮어써도 베이스 레이어의 원본은
#        그대로 남기 때문에 엔진 하나가 두 번 들어간다.
#        실측: 2.31GB(베이스) -> 5.06GB. FTS 만 넣으면 3.23GB 다.
#
#   그래서 엔진 deb 를 끌어오지 않고 FTS 패키지만 설치한다. 베이스에 구워진
#   엔진을 그대로 두므로 버전이 어긋날 여지가 아예 없다. dpkg 의 의존 검사만
#   우회하면 되고(--force-depends), 실제로 필요한 것은 FTS 페이로드
#   /opt/mssql/lib/sqlservr.fts.sfp (407MB) 다.
#
#   dpkg 상태에 "mssql-server 미충족" 이 남는다. 런타임에는 영향이 없다
#   (검증: IsFullTextInstalled=1, CONTAINS 질의 정상). 이 이미지 안에서
#   apt 로 무언가를 더 설치할 일은 없다.
#
# FTS 패키지 버전은 베이스 엔진 버전과 **정확히 같아야** 한다.
# CU25 = 16.0.4255.1-8 이다(리비전이 -1 이 아니다. madison 으로 확인할 것).
#       apt-cache madison mssql-server-fts
#
# 빌드는 인터넷이 되는 호스트에서 한다. 에어갭에는 결과 이미지 tar 만 옮긴다.
#       ./build-image.sh                  # 빌드 + 실기동 검증
#       ./verify-fts-image.sh <이미지>     # 이미지만 따로 판정
#---------------------------------------------------------------------
ARG BASE_IMAGE=mcr.microsoft.com/mssql/server:2022-CU25-ubuntu-22.04
FROM ${BASE_IMAGE}

ARG MSSQL_PKG_VERSION=16.0.4255.1-8

# 기본 사용자는 mssql(uid 10001) 이라 apt 가 권한 오류로 실패한다(실측:
# "List directory /var/lib/apt/lists/partial is missing. - Acquire (13: Permission denied)").
USER root

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends curl gnupg2 ca-certificates; \
    # 베이스에는 /usr/share/keyrings/microsoft-prod.gpg 가 없다(MS 키는
    # /etc/apt/trusted.gpg.d/ 에 있다). 덮어쓰기 충돌이 없다.
    curl -fsSL https://packages.microsoft.com/keys/microsoft.asc \
      | gpg --dearmor -o /usr/share/keyrings/microsoft-prod.gpg; \
    curl -fsSL https://packages.microsoft.com/config/ubuntu/22.04/mssql-server-2022.list \
      -o /etc/apt/sources.list.d/mssql-server-2022.list; \
    apt-get update; \
    # install 이 아니라 download + dpkg 다. 이유는 위 주석 참고.
    cd /tmp; \
    apt-get download "mssql-server-fts=${MSSQL_PKG_VERSION}"; \
    # 빌드 도구 정리를 dpkg -i **앞에** 둔다. 순서가 중요하다:
    # --force-depends 로 설치한 뒤에는 dpkg 상태에 미충족 의존이 남아 이후의
    # 모든 apt 조작이 거부된다(실측: "E: Unmet dependencies. Try
    # 'apt --fix-broken install'"). 그래서 apt 가 필요한 일은 먼저 끝낸다.
    apt-get purge -y --auto-remove curl gnupg2; \
    rm -rf /var/lib/apt/lists/*; \
    dpkg -i --force-depends ./mssql-server-fts_*.deb; \
    rm -f ./mssql-server-fts_*.deb /var/cache/apt/archives/*.deb; \
    # 빌드 시점에 결과를 확인한다. 타깃에서 알게 되면 되돌리기 비싸다.
    dpkg -l mssql-server-fts | grep '^ii'; \
    test -s /opt/mssql/lib/sqlservr.fts.sfp

USER mssql
