#---------------------------------------------------------------------
# 85-ollama-embedding : 공식 ollama/ollama + 임베딩 모델 내장 이미지
#
# 빌드는 build-bundle.sh 가 한다. 같은 Dockerfile 로 flavor 마다 한 번씩 빌드한다.
#   cpu : EMBED_MODEL=qwen3-embedding:8b      (Q4_K_M)
#   gpu : EMBED_MODEL=qwen3-embedding:8b-q8_0 (Q8_0)
# 두 이미지의 차이는 모델뿐이다. 베이스 이미지 하나에 CPU·CUDA 백엔드가 모두 있다.
#
# 왜 모델을 이미지에 굽는가:
#   에어갭 타깃은 registry.ollama.ai 에 갈 수 없다. 모델을 이미지 레이어에 넣으면
#   docker load 한 번으로 실행 파일과 가중치가 함께 들어오고, 설치·실행 중에
#   `ollama pull` 이 필요 없다.
#
# 왜 VOLUME 을 두지 않는가:
#   VOLUME /root/.ollama 를 선언하면 컨테이너를 만들 때마다 수 GB 모델을 익명
#   볼륨으로 복사한다. 실행 시 /root/.ollama 에 bind mount·볼륨을 걸면 이미지에
#   넣은 모델이 가려진다(README 7절). 공식 Dockerfile 에도 VOLUME 이 없다.
#
# 왜 모델 ID 를 검사하는가:
#   `ollama pull` 은 다이제스트 지정을 지원하지 않는다. 태그가 다른 가중치로
#   재지정되면 조용히 다른 모델이 들어가므로, `ollama list` 의 ID(매니페스트
#   sha256 앞 12자리)가 versions.env 의 핀과 다르면 빌드를 실패시킨다.
#
# 왜 id_ed25519 를 지우는가:
#   `ollama serve` 첫 기동이 /root/.ollama/id_ed25519(개인키)를 만든다. 지우지 않으면
#   이 이미지를 쓰는 모든 배포가 같은 개인키를 갖는다. 기동할 때 다시 생성된다.
#
# ENTRYPOINT / CMD / ENV 는 베이스 것을 그대로 쓴다.
#   ENTRYPOINT ["/bin/ollama"] / CMD ["serve"] / OLLAMA_HOST=0.0.0.0:11434
#   NVIDIA_VISIBLE_DEVICES=all / NVIDIA_DRIVER_CAPABILITIES=compute,utility
#---------------------------------------------------------------------
# 기본값은 versions.env 와 같은 값이다. build-bundle.sh 가 항상 --build-arg 로 덮어쓴다.
ARG OLLAMA_BASE=docker.io/ollama/ollama:0.40.13@sha256:93c1376d651a9f1579ee40cc5763852f08b204466371e4bb64bca2a1d8d08e2d
FROM ${OLLAMA_BASE}

# 이름을 EMBED_* 로 둔다. OLLAMA_* 는 ollama 자체가 읽는 환경변수와 겹친다.
# 기본값은 CPU flavor 다.
ARG EMBED_MODEL=qwen3-embedding:8b
ARG EMBED_MODEL_ID=64b933495768

# 빌드 중에만 서버를 띄워 pull 하고, 같은 RUN 안에서 내린다.
# 레이어에는 /root/.ollama/models 만 남는다.
RUN set -eu; \
    /bin/ollama serve >/tmp/ollama-serve.log 2>&1 & pid=$!; \
    i=0; \
    until /bin/ollama list >/dev/null 2>&1; do \
        i=$((i + 1)); \
        if [ "$i" -ge 60 ]; then \
            echo "ollama serve 가 60초 안에 응답하지 않았다" >&2; \
            cat /tmp/ollama-serve.log >&2; exit 1; \
        fi; \
        sleep 1; \
    done; \
    if ! /bin/ollama pull "$EMBED_MODEL" >/tmp/ollama-pull.log 2>&1; then \
        echo "ollama pull 실패: $EMBED_MODEL" >&2; \
        tail -n 40 /tmp/ollama-pull.log >&2; exit 1; \
    fi; \
    id="$(/bin/ollama list | awk -v m="$EMBED_MODEL" '$1 == m {print $2}')"; \
    if [ "$id" != "$EMBED_MODEL_ID" ]; then \
        echo "모델 ID 불일치: 기대 ${EMBED_MODEL_ID} / 실제 ${id:-없음} (${EMBED_MODEL})" >&2; \
        /bin/ollama list >&2; exit 1; \
    fi; \
    echo "모델 포함: ${EMBED_MODEL} (ID ${id})"; \
    kill "$pid"; wait "$pid" || true; \
    rm -f /tmp/ollama-serve.log /tmp/ollama-pull.log \
          /root/.ollama/id_ed25519 /root/.ollama/id_ed25519.pub

LABEL org.opencontainers.image.title="ollama-qwen3-embedding" \
      io.ollama.model="${EMBED_MODEL}" \
      io.ollama.model.id="${EMBED_MODEL_ID}"
