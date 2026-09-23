#!/usr/bin/env bash
#---------------------------------------------------------------------
# 커스텀 이미지를 컨테이너 레지스트리에 게시한다 (기본: docker.io/javaos74)
#
# 대상은 "업스트림에 그대로 존재하지 않는" 이미지다.
#   1) mssql-fts        : 공식 mssql 이미지에는 Full-Text Search 가 없어서
#                         직접 빌드해야 한다. 업스트림 대체물이 없다.
#   2) postgres-jammy   : 공식 postgres 는 Debian bookworm 기반이다.
#                         베이스 OS 를 jammy 로 맞춰야 할 때 쓰는 자체 빌드.
#
# 왜 레지스트리에 올리는가:
#   에어갭 번들은 이미지를 tar 로 담는다(docker save / skopeo copy).
#   그 tar 를 만들 때 "매번 docker build 를 다시 하는" 방식은 재현성이 없다.
#   apt 저장소 상태에 따라 결과가 달라지기 때문이다. 레지스트리에 한 번 올려
#   다이제스트로 핀하면, 이후 번들 빌드는 build 없이 copy 만 하면 된다.
#
# 사용:
#   ./publish-images.sh --check          # 로컬 이미지 확인만 (푸시 없음)
#   ./publish-images.sh --dry-run        # 실행할 명령만 출력
#   ./publish-images.sh                  # 태깅 + 푸시
#   ./publish-images.sh --only mssql-fts:2022-16.0.4255.1   # 대상 하나만
#   PUBLISH_NAMESPACE=myorg ./publish-images.sh
#
# --only 가 필요한 이유: 게시 표의 원본 이미지들이 한 호스트에 다 있는 경우는
# 드물다. 빌드 호스트마다 만든 것만 있다. 필터가 없으면 "로컬에 없는 이미지"
# 검사에서 죽어 아무것도 올릴 수 없다.
#
# 전제: 이 호스트에 원본 이미지가 있고, `docker login` 이 끝나 있어야 한다.
#       자격증명은 이 스크립트가 다루지 않는다(히스토리·로그에 남기지 않기 위해).
#
#   docker login -u <계정>        # 비밀번호 대신 Access Token(PAT) 사용 권장
#
# 주의 — MSSQL 재배포 라이선스:
#   mssql 이미지는 Microsoft 독점 소프트웨어를 포함한다. 파생 이미지를 공개
#   저장소에 올리는 것은 배포 조건 검토가 필요하다. 확실하지 않으면 저장소를
#   private 으로 만들 것. 이 스크립트는 판단하지 않고 경고만 한다.
#---------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

MODE="push"
ONLY=""
while (($#)); do
    case "$1" in
        --check)   MODE="check" ;;
        --dry-run) MODE="dry-run" ;;
        --only)    shift; ONLY="${1:-}"
                   [[ -n "$ONLY" ]] || die "--only 에 로컬 이미지 이름이 필요하다" ;;
        *)         die "알 수 없는 인자: $1 (--check | --dry-run | --only <이미지>)" ;;
    esac
    shift
done

NAMESPACE="${PUBLISH_NAMESPACE:-${PUBLISH_NAMESPACE_DEFAULT}}"
REGISTRY="${PUBLISH_REGISTRY:-docker.io}"

require_cmds docker

#---------------------------------------------------------------------
# 게시 대상 표
#
# 형식: <로컬 이미지>|<원격 저장소명>|<태그들(공백 구분)>|<라이선스 주의>
#
# 태그를 두 개 준다. 버전 고정 태그는 번들이 참조하고, floating 태그는
# 사람이 쓴다. 번들은 결국 다이제스트로 핀하므로 floating 태그가 움직여도
# 이미 만들어진 번들에는 영향이 없다.
#---------------------------------------------------------------------
PUBLISH_TARGETS=(
    "mssql-fts:2022|mssql-fts|${MSSQL_FTS_TAGS}|yes"
    "mssql-fts:2022-${MSSQL_CU25_VERSION}|mssql-fts|${MSSQL_CU25_FTS_TAGS}|yes"
    "postgresql:16|postgres-jammy|${POSTGRES_JAMMY_TAGS}|no"
)

# --only 로 대상을 하나만 고를 수 있다. 원본 이미지가 호스트마다 흩어져 있어서
# 표 전체를 한 호스트에서 올릴 수 있는 경우가 드물다.
if [[ -n "$ONLY" ]]; then
    FILTERED=()
    for entry in "${PUBLISH_TARGETS[@]}"; do
        [[ "${entry%%|*}" == "$ONLY" ]] && FILTERED+=("$entry")
    done
    ((${#FILTERED[@]} > 0)) || die "$(cat <<MSG
--only ${ONLY} 에 해당하는 대상이 게시 표에 없다. 가능한 값:
$(printf '  %s\n' "${PUBLISH_TARGETS[@]%%|*}")
MSG
)"
    PUBLISH_TARGETS=("${FILTERED[@]}")
fi

#=====================================================================
# 1. 로컬 이미지 확인
#=====================================================================
step "로컬 이미지 확인"

MISSING=()
for entry in "${PUBLISH_TARGETS[@]}"; do
    IFS='|' read -r local_img repo tags license <<<"$entry"
    if docker image inspect "$local_img" >/dev/null 2>&1; then
        arch="$(docker image inspect "$local_img" -f '{{.Architecture}}/{{.Os}}')"
        # 크기는 `docker images` 값을 쓴다. `docker image inspect .Size` 는
        # containerd 이미지 스토어에서 content store 기준(압축) 크기를 돌려주며
        # 실제 전개 크기와 3배 이상 차이난다(실측: 1.41GB vs 5.05GB).
        # 번들 용량 산정에는 전개 크기가 필요하다.
        size="$(docker images --format '{{.Repository}}:{{.Tag}} {{.Size}}' \
                | awk -v i="$local_img" '$1==i {print $2; exit}')"
        ok "${local_img}  (${arch}, ${size:-크기불명} 전개 기준)"
        # 번들은 amd64 전용이다. 다른 아키텍처가 섞이면 에어갭 타깃에서 실행되지 않는다.
        [[ "$arch" == "${BUNDLE_ARCH}/linux" ]] \
            || warn "  아키텍처가 ${BUNDLE_ARCH} 가 아니다. 타깃에서 동작하지 않을 수 있다."
    else
        MISSING+=("$local_img")
        echo "${_C_RED}[$(_ts)] FAIL${_C_RST} ${local_img} 없음" >&2
    fi
done

if ((${#MISSING[@]} > 0)); then
    die "$(cat <<MSG
로컬에 없는 이미지: ${MISSING[*]}

이 스크립트는 이미지를 빌드하지 않는다. 원본이 있는 호스트에서 실행할 것.
현재 원본 보유 호스트: infra-01 (AWS profile=uipath, <AWS_INFRA_HOST_PUBLIC_IP>)
빌드 레시피는 PROGRESS.md 5절에 있다.
MSG
)"
fi

#=====================================================================
# 2. 게시 계획 출력
#=====================================================================
step "게시 계획 (${REGISTRY}/${NAMESPACE})"

for entry in "${PUBLISH_TARGETS[@]}"; do
    IFS='|' read -r local_img repo tags license <<<"$entry"
    for t in $tags; do
        echo "  ${local_img}  ->  ${REGISTRY}/${NAMESPACE}/${repo}:${t}"
    done
    [[ "$license" == "yes" ]] && \
        warn "  ${repo}: Microsoft 독점 소프트웨어 포함. 공개 저장소 게시 전 배포 조건을 확인할 것."
done

if [[ "$MODE" == "check" ]]; then
    echo
    ok "확인만 수행했다. 푸시하려면 인자 없이 다시 실행할 것."
    exit 0
fi

#=====================================================================
# 3. 로그인 상태 확인
#
# `docker login` 여부를 직접 알아내는 공식 방법이 없다. config.json 의
# auths 키를 본다. credsStore 를 쓰는 환경에서는 auths 가 비어 있을 수 있어
# 실패로 단정하지 않고 경고만 한다.
#=====================================================================
step "레지스트리 인증 확인"

DOCKER_CFG="${DOCKER_CONFIG:-$HOME/.docker}/config.json"
if [[ -f "$DOCKER_CFG" ]] && grep -qE '"(https://)?index\.docker\.io|"docker\.io' "$DOCKER_CFG" 2>/dev/null; then
    ok "Docker Hub 자격증명이 설정돼 있다"
elif [[ -f "$DOCKER_CFG" ]] && grep -q '"credsStore"' "$DOCKER_CFG" 2>/dev/null; then
    warn "credsStore 를 사용 중이다. 로그인 여부를 확인할 수 없으니 푸시 결과로 판단한다."
else
    warn "Docker Hub 로그인 기록이 없다. 푸시가 거부되면 먼저 로그인할 것:"
    warn "  docker login -u <계정>     # 비밀번호 대신 Access Token(PAT) 권장"
fi

#=====================================================================
# 4. 태깅 + 푸시
#=====================================================================
step "태깅 및 푸시"

declare -a PUSHED=()

for entry in "${PUBLISH_TARGETS[@]}"; do
    IFS='|' read -r local_img repo tags license <<<"$entry"
    for t in $tags; do
        remote="${REGISTRY}/${NAMESPACE}/${repo}:${t}"

        if [[ "$MODE" == "dry-run" ]]; then
            echo "  docker tag ${local_img} ${remote}"
            echo "  docker push ${remote}"
            continue
        fi

        docker tag "$local_img" "$remote" || die "태깅 실패: ${remote}"
        log "푸시: ${remote}"
        docker push "$remote" >/dev/null || die "$(cat <<MSG
푸시 실패: ${remote}

흔한 원인:
  - 로그인이 안 돼 있다              -> docker login -u <계정>
  - 네임스페이스 권한이 없다          -> ${NAMESPACE} 소유 계정으로 로그인했는지 확인
  - 저장소가 없다(자동 생성 안 되는 경우) -> Docker Hub 에서 먼저 저장소를 만들 것
MSG
)"
        ok "완료: ${remote}"
        PUSHED+=("$remote")
    done
done

if [[ "$MODE" == "dry-run" ]]; then
    echo
    ok "dry-run 이므로 아무것도 푸시하지 않았다."
    exit 0
fi

#=====================================================================
# 5. 게시 결과 검증 + 다이제스트 출력
#
# 푸시 성공만으로는 부족하다. 원격 다이제스트를 받아와야 versions.env 에
# 핀할 값을 얻을 수 있다. 번들은 태그가 아니라 이 값으로 고정한다.
#=====================================================================
step "원격 다이제스트 확인 (versions.env 에 핀할 값)"

for remote in "${PUSHED[@]}"; do
    # 로컬 캐시가 아니라 레지스트리에 실제로 올라간 것을 조회한다.
    dg="$(docker manifest inspect -v "$remote" 2>/dev/null \
          | python3 -c 'import sys,json
d=json.load(sys.stdin)
d=d[0] if isinstance(d,list) else d
print(d.get("Descriptor",{}).get("digest",""))' 2>/dev/null)"
    if [[ -n "$dg" ]]; then
        printf "  %-60s %s\n" "$remote" "$dg"
    else
        warn "  ${remote}: 다이제스트를 확인하지 못했다(권한 또는 네트워크)."
    fi
done

step "다음 단계"
cat <<'NEXT'
  1) 위 다이제스트를 00-common/versions.env 에 핀한다.
  2) 번들 빌드는 build 없이 copy 만 하면 된다. 예:
       skopeo copy --retry-times 5 \
         docker://docker.io/<ns>/mssql-fts@sha256:<digest> \
         docker-archive:images/mssql-fts.tar:<태그>
  3) 저장소를 private 으로 두면 번들 빌드 호스트에도 docker login 이 필요하다.
     그 경우 skopeo 에 --src-creds 를 넘기거나 인증 파일을 지정할 것.
NEXT
