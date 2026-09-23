#!/usr/bin/env bash
#---------------------------------------------------------------------
# SQL Server 2022 + Full-Text Search 이미지를 빌드하고 그 자리에서 검증한다.
# 인터넷이 되는 호스트에서 실행한다(packages.microsoft.com + mcr 접근 필요).
#
# 왜 빌드 직후 검증까지 한 스크립트에서 하는가:
#   "패키지가 깔렸다"(dpkg)까지만 확인하고 게시하면, 엔진과 FTS 의 버전이
#   어긋난 이미지를 그대로 내보낼 수 있다. 그 사실은 에어갭 타깃에서
#   IsFullTextInstalled=0 으로 드러난다. 그 시점에는 되돌리기 비싸다.
#   그래서 컨테이너를 실제로 띄워 SQL 에 물어보는 것까지가 빌드다.
#
# 사용:
#   ./build-image.sh                                    # 기본값(CU25)
#   BASE_IMAGE=mcr.microsoft.com/mssql/server:2022-CU26-ubuntu-22.04 \
#     MSSQL_PKG_VERSION=16.0.4265.3-1 ./build-image.sh  # 다른 CU
#   ./build-image.sh --no-verify                        # 빌드만
#
# 다른 CU 로 갈 때는 두 값을 반드시 함께 바꾼다. 사용 가능한 FTS 버전 확인:
#   docker run --rm --user root --entrypoint bash <베이스> -c \
#     'apt-get update -qq >/dev/null 2>&1; \
#      apt-get install -y -qq --no-install-recommends curl gnupg2 >/dev/null 2>&1; \
#      curl -fsSL https://packages.microsoft.com/config/ubuntu/22.04/mssql-server-2022.list \
#        -o /etc/apt/sources.list.d/mssql-server-2022.list; \
#      apt-get update -qq >/dev/null 2>&1; apt-cache madison mssql-server-fts'
#
# 게시는 이 스크립트가 하지 않는다(자격증명을 다루지 않기 위해).
#   00-common/publish-images.sh 를 쓴다.
#---------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

BASE_IMAGE="${BASE_IMAGE:-mcr.microsoft.com/mssql/server:2022-CU25-ubuntu-22.04}"
# 리비전 접미사까지 정확해야 한다. CU25 는 -1 이 아니라 -8 이다.
MSSQL_PKG_VERSION="${MSSQL_PKG_VERSION:-16.0.4255.1-8}"
IMAGE_VERSION="${MSSQL_PKG_VERSION%-*}"

# 태그는 버전 고정 태그 **하나만** 붙인다.
#
# 왜 floating 태그(mssql-fts:2022)를 자동으로 붙이지 않는가:
#   publish-images.sh 의 게시 표는 로컬 이미지 `mssql-fts:2022` 를 찾아
#   versions.env 의 MSSQL_FTS_TAGS(현재 "2022-16.0.4265.3 2022")로 올린다.
#   여기서 CU25 로 빌드한 이미지에 mssql-fts:2022 를 붙여 두면, 그 이미지가
#   16.0.4265.3 이라는 **틀린 이름으로 게시된다.** 태그는 사람이 의도해서
#   붙여야 한다.
VERSIONED_TAG="${VERSIONED_TAG:-mssql-fts:2022-${IMAGE_VERSION}}"

VERIFY=yes
[[ "${1:-}" == "--no-verify" ]] && VERIFY=no

if docker info >/dev/null 2>&1; then DOCKER=(docker); else DOCKER=(sudo docker); fi

echo "== 빌드 계획"
echo "  베이스       ${BASE_IMAGE}"
echo "  FTS 패키지   ${MSSQL_PKG_VERSION}"
echo "  태그         ${VERSIONED_TAG}"
echo

# 베이스 다이제스트를 남긴다. 2022-latest 처럼 움직이는 태그로 빌드했을 때
# "무엇으로 빌드했는지"를 나중에 추적할 유일한 근거다.
"${DOCKER[@]}" pull "$BASE_IMAGE" >/dev/null
BASE_DIGEST="$("${DOCKER[@]}" image inspect "$BASE_IMAGE" -f '{{range .RepoDigests}}{{.}}{{end}}')"
echo "  베이스 다이제스트: ${BASE_DIGEST}"
echo

echo "== 빌드"
# provenance / sbom 을 끈다. 켜 두면 buildkit 이 attestation 을 붙여 결과가
# 단일 매니페스트가 아닌 매니페스트 리스트가 된다. 번들 파이프라인은
# skopeo copy -> docker-archive 로 단일 이미지를 기대한다.
"${DOCKER[@]}" build \
    --provenance=false --sbom=false \
    --build-arg "BASE_IMAGE=${BASE_IMAGE}" \
    --build-arg "MSSQL_PKG_VERSION=${MSSQL_PKG_VERSION}" \
    -t "$VERSIONED_TAG" \
    "$SCRIPT_DIR"

echo
echo "== 크기"
"${DOCKER[@]}" images | awk -v b="${BASE_IMAGE%%:*}" '$1=="REPOSITORY" || $1 ~ /mssql-fts/ || $1 ~ b {print "  " $0}'

if [[ "$VERIFY" == "no" ]]; then
    echo
    echo "  --no-verify 이므로 검증을 건너뛴다. 게시 전에 반드시 실행할 것:"
    echo "    ./verify-fts-image.sh ${VERSIONED_TAG} --smoke"
    exit 0
fi

echo
# set -e 아래에서 실패를 잡아야 하므로 일시 해제한다. 대입문에 그대로 두면
# 검증이 실패한 순간 스크립트가 죽어서 출력도 판정 메시지도 남지 않는다.
set +e
VERIFY_OUT="$(bash "${SCRIPT_DIR}/verify-fts-image.sh" "$VERSIONED_TAG" --smoke 2>&1)"
VERIFY_RC=$?
set -e
echo "$VERIFY_OUT"
[[ "$VERIFY_RC" -eq 0 ]] || { echo; echo "  검증 실패. 게시하지 말 것."; exit 1; }

# 엔진 버전과 FTS 패키지 버전이 같은지 실행 결과로 확인한다.
# 베이스에 구워진 엔진 버전은 이미지 안에서 알아낼 방법이 마땅치 않다
# (sqlservr --version 은 없는 옵션이다 — 실측). 그래서 띄워서 묻는다.
RUNTIME_VER="$(echo "$VERIFY_OUT" | awk -F'|' '/PRODUCTVERSION/ {print $2}' | awk '{print $1}')"
echo
if [[ "$RUNTIME_VER" == "$IMAGE_VERSION" ]]; then
    echo "  엔진/FTS 버전 일치: ${RUNTIME_VER}"
else
    echo "  엔진/FTS 버전 불일치: 엔진 ${RUNTIME_VER} vs FTS ${IMAGE_VERSION}"
    echo "  베이스 이미지와 FTS 패키지 버전을 맞출 것. 게시하지 말 것."
    exit 1
fi

cat <<NEXT

== 다음 단계 (게시)
  게시는 이 스크립트가 하지 않는다. 순서는 이렇다.

  1) versions.env 를 이 이미지에 맞춘다.
       MSSQL_VERSION="${IMAGE_VERSION}"
       MSSQL_FTS_PKG_VERSION="${MSSQL_PKG_VERSION}"
     (맞추지 않고 게시하면 이미지 내용과 태그의 버전이 어긋난다)

  2) publish-images.sh 가 찾는 이름을 **의도해서** 붙인다.
       docker tag ${VERSIONED_TAG} mssql-fts:2022

  3) docker login -u <계정>        # 비밀번호 대신 Access Token 권장
     cd ../../00-common && ./publish-images.sh

  4) 출력된 원격 다이제스트를 versions.env 의 MSSQL_FTS_IMAGE_DIGEST 에 핀한다.
     번들은 태그가 아니라 이 값을 받는다.

  5) 번들 재빌드: cd ../ && ./build-bundle.sh

  에어갭으로 직접 옮길 거라면 게시 없이 tar 로도 된다.
       docker save ${VERSIONED_TAG} | gzip > mssql-fts-${IMAGE_VERSION}.tar.gz
NEXT
