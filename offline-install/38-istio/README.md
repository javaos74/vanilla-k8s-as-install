# 38-istio — Istio 서비스 메시(ingressgateway) 오프라인 설치

UiPath Automation Suite(AS)가 쓰는 Istio 를 AS 설치기 대신 직접 설치한다.
`base` → `istiod` → `istio-ingressgateway` 를 helm 으로 올리고, ingressgateway 를 NodePort 로
고정해 `40-haproxy` 가 호스트 80/443/15021 을 그 NodePort 로 넘기게 한다.
그 다음 UiPath `istio-configure` 차트(WASM 라우팅 플러그인 + EnvoyFilter)를 올린다.

Istio 는 **AS 2.2510.4 오프라인 번들에 들어 있는 것(1.30.3, Echo 재빌드)을 그대로 쓴다.**
운영에서는 이미지와 차트를 AS 번들의 hydrate(`hydrate-registry.sh`)가 Harbor 에 올리고,
이 번들의 스크립트는 그 Harbor 경로에서 받는다(상위 [README 5.2·5.3절](../README.md)).

기준 문서:

- 서비스 메시 설치·구성: https://docs.uipath.com/automation-suite/automation-suite/2.2510/installation-guide-eks-aks/installing-and-configuring-the-service-mesh
- 참고 저장소: https://github.com/javaos74/automation-suite-on-samsung-cloud-ske (`ko/05-istio-install.md`)

---

## 1. 범위

| 한다 | 하지 않는다 |
|---|---|
| Istio CRD·istiod·ingressgateway 설치(helm 릴리스 `istio-base` / `istiod` / `istio-ingressgateway`) | istioctl 설치, CNI 플러그인·ambient(ztunnel), Kiali·Jaeger |
| ingressgateway Service 를 NodePort 로 고정(`ISTIO_NODEPORT_*`) | LoadBalancer Service, MetalLB |
| TLS secret `istio-ingressgateway-certs` 생성(05-certs 산출물) | 인증서 발급(05-certs 가 한다) |
| UiPath `istio-configure` 설치(릴리스 `custom-istio-configure`) | AS 라우팅 자체의 검증(AS 설치 뒤에 확인) |
| 설치 결과 판정(`--check-only`), 제거(`--uninstall`), 렌더링 미리보기(`--dry-run`) | Harbor 에 이미지·차트 올리기(AS hydrate 가 한다, 4절) |

AS `input.json` 에서는 `exclude_components` 에 `istio`, `istio-configure` 를 넣는다.
AS 설치기가 Istio 를 다시 설치하거나 `istio-configure` 를 덮어쓰지 않게 하려는 것이다(7절, 상위 README 5.1절).

전제: `10-k8s` + `60-cilium` 설치가 끝나 노드가 Ready 이고, control plane 에서 root 로 실행한다.

---

## 2. 버전과 근거

| 항목 | `versions.env` 변수(현재 값) |
|---|---|
| AS 버전 | `UIPATH_AS_VERSION`(현재 `2.2510.4`) |
| Istio 바이너리·appVersion | `ISTIO_VERSION`(현재 `1.30.3`) |
| 이미지 태그 | `ISTIO_TAG`(현재 `1.30.3-20260730_echo`) |
| pilot 이미지·다이제스트 | `ISTIO_PILOT_IMAGE`(현재 `registry.uipath.com/istio/pilot:1.30.3-20260730_echo`), `ISTIO_PILOT_DIGEST`(현재 `sha256:ba73c276…05939`) |
| proxyv2 이미지·다이제스트 | `ISTIO_PROXYV2_IMAGE`(현재 `registry.uipath.com/istio/proxyv2:1.30.3-20260730_echo`), `ISTIO_PROXYV2_DIGEST`(현재 `sha256:9545f8dd…24935`) |
| 차트 버전 | `ISTIO_CHART_VERSION`(현재 `v1.30.3`) |
| 차트 경로와 sha256 | `ISTIO_BASE_CHART`(현재 `vendor/base`, `a0f486b7…`), `ISTIO_ISTIOD_CHART`(현재 `vendor/istiod`, `b4df1f0f…`), `ISTIO_GATEWAY_CHART`(현재 `vendor/gateway`, `1b479ae4…`) |
| istio-configure 차트 | `UIPATH_ISTIO_CONFIGURE_CHART`(현재 `helm/istio-configure`), `UIPATH_ISTIO_CONFIGURE_VERSION`(현재 `${UIPATH_AS_VERSION}` = `2.2510.4`), sha256 `53319c1c…` |
| WASM 플러그인 이미지 | `UIPATH_WASM_IMAGE`(현재 `registry.uipath.com/istio-wasm-plugin:2.2510.4`), `UIPATH_WASM_DIGEST`(현재 `sha256:798040e9…`) |
| curl 이미지(hook Job) | `UIPATH_ISTIO_CURL_IMAGE`(현재 `registry.uipath.com/curlimages/curl:2026.05.11`), `UIPATH_ISTIO_CURL_DIGEST`(현재 `sha256:94c72904…`) |
| 원본 레지스트리 | `ISTIO_SOURCE_REGISTRY`(현재 `registry.uipath.com`, 익명 pull 가능) |

다이제스트와 sha256 의 전체 값은 `00-common/versions.env` 에 있다. 모두 2026-11-07 에 확인했다.

### 2.1 왜 1.30.3(Echo 재빌드)인가

- UiPath 2.2510 호환성 매트릭스가 "Istio (if you bring your own)" 로 적은 버전이 1.30.3 이다.
  https://docs.uipath.com/automation-suite/automation-suite/2.2510/installation-guide-eks-aks/compatibility-matrix
- AS 2.2510.4 오프라인 번들 목록에도 같은 버전이 들어 있다.
  - `https://download.uipath.com/automation-suite/2.2510.4/air-images.txt` 115·116행 `istio/pilot:1.30.3-20260730_echo`, `istio/proxyv2:1.30.3-20260730_echo`(44행 curl, 118행 wasm 플러그인)
  - `https://download.uipath.com/automation-suite/2.2510.4/embedded-helm-charts.txt` 103·109·110행 `vendor/base`, `vendor/gateway`, `vendor/istiod` `v1.30.3`(40행 `helm/istio-configure:2.2510.4`, 41행 `helm/istiod:2.2510.4`)
  - `https://download.uipath.com/automation-suite/2.2510.4/versions.json`
- 이미지는 echohq.com 이 docker.io/istio 1.30.3 을 다시 빌드한 것이다.
  - 라벨: `org.opencontainers.image.vendor=echohq.com`, `ai.echo.image.upstream.uri=docker.io/istio/{pilot,proxyv2}`, `ai.echo.image.upstream.tag=1.30.3`
  - 바이너리: `pilot-discovery version -s`, `pilot-agent version -s` 모두 `client version: 1.30.3`. 긴 버전은 `GitRevision:"56df41f6…-dirty"`, `BuildStatus:"Modified"`, `GolangVersion:"go1.26.5"` 이다.
  - proxyv2 는 Echo `1.30-mini` 이미지라 `sh`/`curl`/`wget` 이 없다(`openssl` 만 있다). 판정에 영향이 있다(9절).
- Istio 보안 공지 ISTIO-SECURITY-2026-006~009 의 코드 수정은 upstream 1.30.8 에만 있다.
  **Echo 재빌드 이미지에 2026-006~009 수정이 들어 있는지는 확인하지 못했다(미확인).**
  https://istio.io/latest/news/security/
- **사용자가 이 위험을 알고 UiPath 배포 버전을 골랐다**(upstream 1.30.8 대신 AS 번들의 1.30.3).
  AS 번들과 같은 아티팩트라 hydrate 한 번으로 Harbor 에 올라가고, UiPath 가 검증한 조합과 같다.
- 1.30 은 EOL 예정이 2026-12경이고 Kubernetes 1.32~1.36 을 지원한다(저장소의 k8s 1.36.4 포함).
  https://istio.io/latest/docs/releases/supported-releases/
- 다이제스트를 고정한다. 검증용 이미지 묶음은 다이제스트로 받고, 차트는 tgz sha256 을 핀과 대조한다.
  Harbor 사본의 이미지 다이제스트는 원본과 다를 수 있어 설치는 태그로 참조한다(4절).

### 2.2 왜 `vendor/istiod` 이고 UiPath 래퍼 `helm/istiod` 가 아닌가

AS 번들에는 UiPath 래퍼 `helm/istiod:2.2510.4` 도 있다. 이 번들은 `vendor/istiod` v1.30.3 을 쓴다.

1. 래퍼의 `requirements.lock` 은 `istiod` v1.30.3 하나에 의존하고, 래퍼 안 `charts/istiod` 는 `vendor/istiod` v1.30.3 과 `diff -r` 로 같다.
2. 래퍼에는 `values.yaml` 이 없고 `values-air.yaml`, `values-air-ha.yaml`, `values-rke2*.yaml` 만 있다.
3. 래퍼를 `values-air.yaml` 로 렌더링한 결과와, `vendor/istiod` 를 같은 값(`conf/istiod-values.yaml`, 한 단계 평탄화)으로 렌더링한 결과가 `# Source:` 주석 줄을 빼면 같다.
4. `base`·`gateway` 는 `vendor/` 로만 있다. 세 차트를 같은 경로 규칙(`vendor/<이름>`)과 같은 values 구조로 다룰 수 있고, 참고 저장소의 설치 순서(base → istiod → gateway)와 같다.

`vendor/` 차트 3개는 upstream 1.30.3 차트와 `diff -r` 하면 `Chart.yaml` 의 `version: v1.30.3`(upstream 은 `1.30.3`)만 다르다.

### 2.3 AS 버전을 바꿀 때 — Istio 값도 함께 바꾼다

**`UIPATH_AS_VERSION` 을 바꾸면 `versions.env` 의 Istio·istio-configure 값도 함께 바꾼다.**
AS 버전마다 번들에 든 Istio 이미지 태그, 차트 버전, istio-configure 차트가 다르다.
`versions.env` 의 "UiPath Automation Suite 와 Istio (38-istio)" 절에 같은 절차가 주석으로 있다.
`<ver>` 는 새 AS 버전이다.

1. `https://download.uipath.com/automation-suite/<ver>/air-images.txt`(UiPath 문서의 `as-images.txt`)에서 찾는다.
   - `istio/pilot:<태그>`, `istio/proxyv2:<태그>` → `ISTIO_TAG`. `ISTIO_VERSION` 은 태그의 `x.y.z` 다.
   - `istio-wasm-plugin:<태그>` → `UIPATH_WASM_TAG`(istio-configure 차트 버전과 같다)
   - `curlimages/curl:<태그>` → `UIPATH_ISTIO_CURL_TAG`
2. `https://download.uipath.com/automation-suite/<ver>/embedded-helm-charts.txt`(UiPath 문서의 `as-helm-charts.txt`)에서 찾는다.
   - `vendor/base|istiod|gateway:<버전>` → `ISTIO_CHART_VERSION`
   - `helm/istio-configure:<버전>` → `UIPATH_ISTIO_CONFIGURE_VERSION`(지금은 `${UIPATH_AS_VERSION}`)
3. `https://download.uipath.com/automation-suite/<ver>/versions.json` 에서 같은 값을 확인한다.
4. UiPath 호환성 매트릭스(`https://docs.uipath.com/automation-suite/automation-suite/<major.minor>/installation-guide-eks-aks/compatibility-matrix`)의 Istio 버전과 Kubernetes 지원 범위, Istio 지원 표(https://istio.io/latest/docs/releases/supported-releases/)를 확인한다.
5. 다이제스트와 차트 sha256 을 다시 잰다(registry.uipath.com 은 익명으로 받을 수 있다).
   ```bash
   skopeo inspect --override-os linux --override-arch amd64 --format '{{.Digest}}' \
     docker://registry.uipath.com/istio/pilot:<태그>          # ISTIO_PILOT_DIGEST (proxyv2·wasm·curl 도 같은 방식)
   helm pull oci://registry.uipath.com/vendor/base --version <버전> && sha256sum base-<버전>.tgz   # ISTIO_BASE_CHART_SHA256
   ```
6. `helm pull oci://registry.uipath.com/helm/istiod --version <ver>` 로 받은 래퍼의 `values-air.yaml` 을 `build-bundle.sh` 가 만드는 `conf/istiod-values.yaml` 과 대조한다.
7. `00-common/verify-urls.sh` 를 통과시킨다. Istio 절이 1)·2)의 AS 목록과 `versions.env` 값을 대조하고, 이미지 다이제스트 4개와 차트 태그 4개가 registry.uipath.com 에 있는지 본다.

대조 장치를 `build-bundle.sh` 가 아니라 `verify-urls.sh` 에 둔 이유:

- `versions.env` 머리말이 "버전을 바꿀 때는 반드시 `verify-urls.sh` 를 먼저 통과시킬 것" 으로 정한 저장소의 사전 관문이다.
- 빌드 호스트의 egress 를 registry.uipath.com 으로만 줄인 환경에서 download.uipath.com 에 닿지 않아도 빌드가 막히지 않는다.
- `build-bundle.sh` 도 어긋남을 잡는다. AS 버전만 바꾸면 istio-configure 차트 sha256 핀이 맞지 않아 멈추고, 렌더링한 istio-configure 이미지 집합이 `UIPATH_WASM_IMAGE`/`UIPATH_ISTIO_CURL_IMAGE` 와 다르면 멈춘다.

2026-11-07 에 `UIPATH_AS_VERSION=2.2510.3` 으로 바꾼 임시 사본에서 `verify-urls.sh` 의 AS 목록 대조 6개(pilot, proxyv2, curl, vendor 차트 3개)가 FAIL 하는 것을 확인했다.

---

## 3. 번들 구성

이 컴포넌트는 묶음을 두 개 만든다. 운영에는 첫 번째만 옮긴다.

### 3.1 운영 번들 `istio-1.30.3` (이미지 없음)

```
istio-1.30.3/                         (tar.gz 약 190KB)
├── 00-common/{versions.env, site.env|site.env.example, common.sh, os/}
├── charts/
│   ├── base-v1.30.3.tgz              vendor/base
│   ├── istiod-v1.30.3.tgz            vendor/istiod
│   ├── gateway-v1.30.3.tgz           vendor/gateway
│   └── istio-configure-2.2510.4.tgz  helm/istio-configure
├── conf/
│   ├── istiod-values.yaml            UiPath values-air.yaml 평탄화 (5절)
│   ├── gateway-values.yaml.tmpl      NodePort 자리표시 (install.sh 가 실행 때 채운다)
│   ├── istio-configure-values.yaml.tmpl
│   └── smoke.yaml.tmpl               판정용 Gateway/VirtualService
├── install.sh  istio-configure.sh  istio-lib.sh(공통 함수)
├── README.md  BUNDLE-INFO  SHA256SUMS
```

- 이미지는 넣지 않는다. 운영에서는 AS hydrate 가 Harbor 에 올린 것을 받는다(4절). 넣으면 같은 이미지를 두 번 옮기게 된다.
- 차트는 넣는다(합계 약 146KB). `--source local` 설치, `--dry-run` 렌더링에 쓴다. Harbor 에 올라가는 차트와 같은 바이트다(sha256 핀).
- `gateway-values.yaml.tmpl` 의 NodePort 는 `install.sh` 가 실행 때 `ISTIO_NODEPORT_*` 로 채운다. 타깃에서 `site.env` 로 NodePort 를 바꿔도 `40-haproxy`(실행 때 같은 변수를 읽는다)와 어긋나지 않게 하려는 것이다.

### 3.2 검증용 이미지 묶음 `istio-local-images-1.30.3` (단일 노드 전용)

`ISTIO_LOCAL_IMAGES=1` 로 빌드할 때만 만든다.

```
istio-local-images-1.30.3/            (tar.gz 약 200MB)
├── images/
│   ├── registry.uipath.com_istio_pilot_1.30.3-20260730_echo.tar
│   ├── registry.uipath.com_istio_proxyv2_1.30.3-20260730_echo.tar
│   ├── registry.uipath.com_istio-wasm-plugin_2.2510.4.tar
│   └── registry.uipath.com_curlimages_curl_2026.05.11.tar
├── conf/{images-istio.list, images-uipath.list}
├── BUNDLE-INFO  SHA256SUMS
```

- registry.uipath.com 에서 **다이제스트로** 받아 태그 이름으로 저장한다(`skopeo copy docker://<repo>@<digest> docker-archive:<tar>:<태그>`).
- `--source local` 이 `ctr -n k8s.io images import` 로 넣는다. 운영 번들과 **같은 디렉터리에 푼다.** 스크립트는 `${ISTIO_LOCAL_IMAGES_DIR:-<운영 번들>/../istio-local-images-1.30.3}` 을 보고, 그 안의 `SHA256SUMS` 를 먼저 검증한다.
- **단일 노드 검증 전용**이다. 다중 노드에서는 다른 노드의 사이드카가 proxyv2 를 받지 못한다. 다중 노드와 운영은 `--source harbor` 를 쓴다.

### 3.3 빌드

```bash
# 빌드 호스트(인터넷 O)
cd offline-install
./00-common/build-in-container.sh 24.04 38-istio                      # 운영 번들만
ISTIO_LOCAL_IMAGES=1 ./00-common/build-in-container.sh 24.04 38-istio  # + 검증용 이미지 묶음
# 또는 cd 38-istio && [ISTIO_LOCAL_IMAGES=1] ./build-bundle.sh
```

`build-bundle.sh` 가 하는 확인:

- 차트 4개를 `helm pull oci://registry.uipath.com/<경로>` 로 받고 sha256 을 핀과 대조한다. 다르면 멈춘다. helm 이 없으면 `HELM_URL` 로 임시 설치한다.
- `helm template` 으로 렌더링해 단언한다.
  - istiod Deployment 이미지가 `registry.uipath.com/istio/pilot:<ISTIO_TAG>` 하나뿐이다.
  - 주입 values 에 `"hub"`, `"tag"`, `"image": "proxyv2"` 가 있다(사이드카·게이트웨이 프록시 이미지).
  - UiPath values-air 값(`holdApplicationUntilProxyStarts`, `ENABLE_NATIVE_SIDECARS`, `system-cluster-critical`)이 반영됐다.
  - gateway Service 가 NodePort 이고 nodePort 3개, selector `istio: ingressgateway`, 이미지 `auto`(주입)다.
  - istio-configure 이미지 집합이 정확히 `{UIPATH_WASM_IMAGE, UIPATH_ISTIO_CURL_IMAGE}` 이고 pluginConfig 에 `cluster_type: exclusive`, `k8s_distribution: vanilla` 가 있다.

---

## 4. Harbor 경로(hydrate)

### 4.1 경로

운영에서는 상위 README 5.2 의 hydrate(`hydrate-registry.sh --target-registry-url <HARBOR_HOSTNAME>/<ISTIO_HARBOR_PROJECT>`)가 아래 8개를 모두 Harbor 에 올린다.
`ISTIO_HARBOR_PROJECT` 기본값은 `uipath` 이고, AS `input.json` 의 `registries.docker.url` = `<HARBOR_HOSTNAME>/uipath` 와 같은 프로젝트다.

| 아티팩트 | Harbor 위치 (`ISTIO_HARBOR_PROJECT=uipath`) |
|---|---|
| pilot | `<HARBOR_HOSTNAME>/uipath/istio/pilot:1.30.3-20260730_echo` |
| proxyv2 | `<HARBOR_HOSTNAME>/uipath/istio/proxyv2:1.30.3-20260730_echo` |
| istio-wasm-plugin | `<HARBOR_HOSTNAME>/uipath/istio-wasm-plugin:2.2510.4` |
| curl | `<HARBOR_HOSTNAME>/uipath/curlimages/curl:2026.05.11` |
| base / istiod / gateway | `oci://<HARBOR_HOSTNAME>/uipath/vendor/{base,istiod,gateway}` `--version v1.30.3` |
| istio-configure | `oci://<HARBOR_HOSTNAME>/uipath/helm/istio-configure` `--version 2.2510.4` |

경로 규칙은 2.2510.4 `hydrate-registry.sh` 본문에서 확인했다.

- 이미지: `push_and_add_image`(212~219행)가 `${TARGET_REGISTRY_URL}/${image_name}` 으로 올린다. 원본 경로(`istio/pilot` 등)가 프로젝트 아래에 그대로 붙는다.
- 차트: `import_sf_charts`(340~352행)가 `oci://${TARGET_REGISTRY_URL}/<차트 이름의 첫 경로>` 로 올린다(`vendor/`, `helm/`).

스크립트는 같은 규칙으로 경로를 만든다. 이미지는 `<HARBOR_HOSTNAME>/<ISTIO_HARBOR_PROJECT>/<원본 경로>:<태그>`, 차트는 `oci://<HARBOR_HOSTNAME>/<ISTIO_HARBOR_PROJECT>/<차트 경로>` 다.

### 4.2 별도 등록 스크립트가 없는 이유

hydrate 가 Istio 이미지 2개, 차트 3개, istio-configure 차트, WASM·curl 이미지까지 8개를 모두 올린다.
따로 올릴 것이 남지 않으므로 이 번들에는 Harbor 등록 스크립트를 두지 않는다.
번들에 이미지를 넣지 않은 것도 같은 이유다(3.1절).

### 4.3 다이제스트와 sha256

- hydrate 는 이미지를 `podman load` → `podman push --tls-verify=false` 로 올린다. 매니페스트를 다시 만들 수 있어 **Harbor 의 이미지 다이제스트는 registry.uipath.com 원본과 다를 수 있다.**
  그래서 harbor 경로는 이미지를 **태그**로 참조하고 다이제스트 일치는 판정하지 않는다. 35-metrics-server 도 같은 현상을 실측했다(그 README 4절).
- 차트는 `helm push` 가 tgz 를 그대로 레이어로 올린다. 그래서 `install.sh`/`istio-configure.sh` 는 Harbor 에서 `helm pull` 한 tgz 의 sha256 을 `versions.env` 핀과 대조하고, 다르면 멈춘다. 다르면 hydrate 한 AS 번들 버전이 `UIPATH_AS_VERSION` 과 다른 경우가 많다.

### 4.4 사전 확인 (`--source harbor`)

`install.sh` 와 `istio-configure.sh` 가 설치 전에 차례로 확인한다. 하나라도 실패하면 아무것도 바꾸지 않고 멈춘다.

1. `site.env` 의 `HARBOR_HOSTNAME` 이 있고 이 노드에서 해석된다(`getent hosts`).
2. Harbor CA 를 찾는다. 후보 순서는 35-metrics-server 와 같다: `/etc/docker/certs.d/<host>/ca.crt` → `/etc/containerd/certs.d/<host>/ca.crt` → `/opt/pki/ca/ca.crt`.
3. `/etc/containerd/certs.d/<host>/hosts.toml` 이 있다(05-certs `deploy-certs.sh --local` 이 만든다).
4. `https://<host>/api/v2.0/ping` 이 CA 검증을 통과해 `Pong` 을 돌려준다.
5. 익명 `GET /api/v2.0/projects/<project>` 로 public 여부를 본다. private 이면 자격증명으로 다시 읽는다.
6. Harbor API(`/api/v2.0/projects/<p>/repositories/<repo, '/' 는 %252F>/artifacts/<태그>`)로 이미지가 있는지 본다.
7. `crictl pull` 로 containerd(kubelet 경로)가 실제로 받는지 본다. 실패하면 파드가 `ImagePullBackOff` 가 되므로 설치 전에 멈춘다.
8. `helm pull oci://… --ca-file <CA>` 로 차트를 받아 sha256 을 대조한다(4.3절).

### 4.5 인증과 CA

- **public 프로젝트**: 자격증명 없이 받는다. pull secret 을 만들지 않는다.
- **private 프로젝트**: 다음 순서로 자격증명을 찾는다.
  1. `HARBOR_PULL_USER` / `HARBOR_PULL_PASSWORD` (Harbor robot 계정 권장)
  2. 35-metrics-server 와 같은 순서: `HARBOR_USER` / `HARBOR_PASSWORD` → `site.env` 의 `HARBOR_ADMIN_PASSWORD`(admin) → `/opt/harbor/.harbor-credentials`. 이때는 robot 계정을 쓰라는 경고를 낸다.
  - `install.sh` 가 `istio-system` 에 `uipathpullsecret`(`ISTIO_PULL_SECRET`)을 만들고 istiod·gateway 에 붙인다. `istio-configure.sh` 는 그 secret 이 있을 때만 values 에 넣는다.
  - helm 은 임시 `--registry-config` 파일에만 로그인하고 끝나면 지운다.
- CA 검증을 끄지 않는다. `--insecure-skip-tls-verify`, `--plain-http`, `insecure-registries` 를 쓰지 않는다.
- 파드는 어느 노드에도 뜰 수 있으므로 **모든 노드**가 Harbor 이름을 해석하고 CA 를 신뢰해야 한다(`05-certs/deploy-certs.sh --nodes ...`). 사이드카 proxyv2 는 AS 파드가 뜨는 모든 노드에서 받는다.

### 4.6 검증 상태

**실제 Harbor 경로는 미검증이다.** Harbor 를 설치하지 않고 패키지만 구성하기로 했으므로(사용자 결정) 검증 환경에는 Harbor 가 없다.
harbor 경로(`helm pull --ca-file`, `helm registry login --registry-config`, `crictl pull`, Harbor API, pull secret)는 `bash -n`, `shellcheck`, `--dry-run` 으로만 확인했다.

---

## 5. 설치

```bash
# control plane (root). 운영 번들과 (검증 때만) 검증용 묶음을 같은 디렉터리에 푼다.
sha256sum -c istio-1.30.3.tar.gz.sha256
tar xzf istio-1.30.3.tar.gz && cd istio-1.30.3

./install.sh --dry-run                    # root·클러스터 없이 렌더링한 이미지와 명령만 본다(= --source harbor)
sudo ./install.sh                         # hydrate 된 Harbor 에서 설치 (= --source harbor)
sudo ./istio-configure.sh                 # UiPath istio-configure (7절)
sudo ./install.sh --check-only            # 판정만 (40-haproxy 재실행 뒤 HAProxy 경유까지)
```

| 옵션 | 동작 |
|---|---|
| (없음) | 설치 + 판정. 다시 실행해도 결과가 같다(`helm upgrade --install`, secret 은 `kubectl apply`) |
| `--source harbor` | 기본값. 차트와 이미지를 hydrate 된 Harbor 에서 받는다(4절) |
| `--source local` | 단일 노드 검증 전용. 차트는 번들 `charts/`, 이미지는 검증용 묶음을 `ctr -n k8s.io images import` 로 넣는다 |
| `--check-only` | 판정만 한다. 출처는 배포된 istiod 이미지 접두사로 판별한다(`--source` 를 주면 그 값). TLS 원본 파일 없이 secret 으로 판정한다 |
| `--uninstall` | 제거한다. `custom-istio-configure` 가 있으면 멈추고 `istio-configure.sh --uninstall` 을 먼저 하라고 알린다 |
| `--dry-run` | root·클러스터·레지스트리 없이 렌더링한 이미지, NodePort, 실행할 명령(Harbor API URL, `crictl pull`, `helm pull`)만 출력한다 |

`istio-configure.sh` 도 같은 옵션(`--source harbor|local`, `--check-only`, `--uninstall`, `--dry-run`)을 받는다.

| 환경변수 | 기본값 | 용도 |
|---|---|---|
| `ISTIO_TLS_CERT_DIR` | `/opt/pki/as` | TLS 원본 `fullchain.crt`, `tls.key`, `ca.crt` 위치(6절) |
| `ISTIO_LOCAL_IMAGES_DIR` | `<번들>/../istio-local-images-1.30.3` | `--source local` 의 검증용 묶음 위치 |
| `HARBOR_PULL_USER` / `HARBOR_PULL_PASSWORD` | 없음 | private 프로젝트 pull 계정(4.5절) |
| `ISTIO_NODEPORT_HTTP` / `_HTTPS` / `_STATUS` | `31223` / `31164` / `31956` | `site.env` 로 바꾼다(8절) |
| `ISTIO_HARBOR_PROJECT` | `uipath` | hydrate 대상 프로젝트. `site.env` 로 바꾼다 |
| `UIPATH_AS_NAMESPACE` | `uipath` | istio-configure 의 `uipathServiceNamespace` |

### 5.1 설치 순서

1. 사전 확인: `SHA256SUMS`, kubectl·helm·curl·openssl, `admin.conf` 와 Ready 노드, `AS_FQDN`, TLS 원본 3개(SAN·키 짝·CA 검증), 같은 NodePort 를 쓰는 다른 Service 가 없음, 출처별 확인(harbor 는 4.4절, local 은 이미지 적재와 대조).
2. 네임스페이스 `istio-system`, TLS secret, (harbor + private) pull secret.
3. `helm upgrade --install istio-base` → `istiod` → `kubectl rollout status deploy/istiod` → `istio-ingressgateway` → rollout status.
4. 판정(9절).

60-cilium 처럼 helm `--wait` 를 쓰지 않는다. `rollout status` 와 판정에서 기다린다.

### 5.2 values 결정

istiod(`conf/istiod-values.yaml`)는 UiPath 가 Istio 를 직접 설치할 때 쓰는 값, 즉 래퍼 `helm/istiod:2.2510.4` 의 `values-air.yaml`(비 HA)을 한 단계 평탄화한 것이다. 사이드카 동작을 UiPath 가 검증한 조합에 맞추려는 것이다.

| 값 | 이유 |
|---|---|
| `global.proxy.holdApplicationUntilProxyStarts: true` | 앱 컨테이너가 사이드카보다 먼저 네트워크를 쓰다 실패하는 것을 막는다 |
| `pilot.env.ENABLE_NATIVE_SIDECARS: "false"` | upstream 1.27+ 기본값은 native sidecar 다. UiPath 는 끈다 |
| `meshConfig.accessLogFile: /dev/stdout`, `accessLogEncoding: JSON`, `global.proxy.logLevel: warning` | UiPath 값 |
| `global.priorityClassName: system-cluster-critical` | 노드 압박 때 먼저 축출되지 않게 한다 |
| `global.defaultPodDisruptionBudget.enabled: false` | 단일 replica PDB 가 단일 노드 drain 을 막는다 |
| `global.proxy.resources` requests 50m/96Mi, limits 500m/512Mi | 사이드카 리소스(UiPath 값) |

`global.hub`, `global.tag`, `global.imagePullPolicy=IfNotPresent`, `global.imagePullSecrets` 는 `install.sh` 가 `--set` 으로 준다.

| 출처 | `global.hub` | `global.tag` |
|---|---|---|
| harbor | `<HARBOR_HOSTNAME>/<ISTIO_HARBOR_PROJECT>/istio` | `ISTIO_TAG` |
| local | `registry.uipath.com/istio` (검증용 묶음에 적재된 이름) | `ISTIO_TAG` |

ingressgateway(`conf/gateway-values.yaml.tmpl`)는 `service.type: NodePort` 와 포트 3개(`status-port` 15021, `http2` 80, `https` 443)다. 포트 이름은 차트 기본값과 같다. 40-haproxy 의 NodePort 자동 탐지가 이 이름으로 찾는다.

### 5.3 `WASM_INSECURE_REGISTRIES` 를 helm 값으로 넣는 이유

UiPath 문서는 ingressgateway Deployment 에 `kubectl patch` 로 `WASM_INSECURE_REGISTRIES` 를 넣는다.
이 번들은 harbor 출처일 때 gateway 차트의 `env.WASM_INSECURE_REGISTRIES=<HARBOR_HOSTNAME>` 값으로 넣는다.

1. `helm upgrade` 때 사라지지 않는다.
2. 문서의 JSON patch(`add .../env`)는 env 목록 전체를 바꾼다.

2.2510.4 에서는 이 값이 결과에 영향이 없다(7.2절). 다른 CU 에서 쓰일 수 있어 문서대로 넣는다.

---

## 6. TLS secret `istio-ingressgateway-certs`

UiPath 형식을 따른다(https://docs.uipath.com/automation-suite/automation-suite/2.2510/installation-guide-eks-aks/managing-the-certificates).

| secret 키 | 05-certs 산출물 (`deploy-certs.sh --local` 이 `/opt/pki/as/` 에 둔다) |
|---|---|
| `tls.crt` = 서버 인증서 + 체인 | `fullchain.crt` |
| `tls.key` | `tls.key` |
| `ca.crt` = CA 번들 | `ca.crt` |

- 원본 위치는 `ISTIO_TLS_CERT_DIR`(기본 `/opt/pki/as`)로 바꾼다.
- `kubectl create secret generic ... --dry-run=client -o yaml | kubectl apply -f -` 로 만든다(멱등). 인증서를 갱신하면 `install.sh` 를 다시 실행한다.
- 설치 전에 원본을 확인한다: 파일 3개, SAN 에 `AS_FQDN` 과 `*.AS_FQDN`, 인증서와 키가 짝, `ca.crt` 로 검증됨. 하나라도 틀리면 시작 단계에서 멈춘다.
- 판정은 secret 을 꺼내 같은 4항목을 본다.
- secret 이름은 AS `input.json` 의 `ingress.ingress_gateway_secret` 과 같아야 한다(상위 README 5.1절).

---

## 7. istio-configure

UiPath 문서 Step 2 Option A 와 같다. 릴리스 이름 `custom-istio-configure`, 네임스페이스 `istio-system` 이다.
`install.sh` 다음에 실행한다.

```bash
sudo ./istio-configure.sh                 # = --source harbor
sudo ./istio-configure.sh --check-only
sudo ./istio-configure.sh --uninstall     # hook 리소스까지 지운다
```

### 7.1 values (`conf/istio-configure-values.yaml.tmpl`)

```yaml
fqdn: "<AS_FQDN>"
gateway:
  selector:
    istio: ingressgateway
global:
  cluster_type: exclusive
  kubernetesDistribution: vanilla
  imagePullSecret:
    name: "<uipathpullsecret | 빈 값>"
minProtocolVersion: TLSV1_2
uipath:
  registry: "<harbor: <HARBOR_HOSTNAME>/uipath | local: registry.uipath.com>"
uipathServiceNamespace: "uipath"
patchIstioService: false
istioGatewayServiceName: "istio-ingressgateway"
wasm:
  image:
    pullSecret: "<같은 secret | 빈 값>"
    registry: "oci://<위 registry>"
```

- `global.kubernetesDistribution: vanilla`, `global.cluster_type: exclusive` 는 사용자가 정한 값이다.
  - 같은 값의 출처: 참고 저장소 `ko/input-ske.json`, `ko/07-install-automation-suite.md` 의 **AS input.json** 에 `"cluster_type": "exclusive"`, `"kubernetes_distribution": "vanilla"` 가 있다. 그 저장소는 istio-configure 를 직접 설치하지 않고 AS 설치기에 맡기므로, istio-configure values 자체의 근거는 아니다.
  - UiPath 문서 예시는 eks/aks/openshift 뿐이다. 차트 기본값은 `kubernetesDistribution: openshift`, `cluster_type: ""` 다.
  - `vanilla` 는 차트의 `requestForwarding.services` 에 키가 없어 `default` 목록이 쓰인다(렌더링 확인).
- `patchIstioService: false`: NodePort 는 `install.sh` 가 관리한다. `true` 면 `sf-k8-utils-rhel` 이미지가 더 필요하다.
- pull secret 은 `istio-system` 에 `uipathpullsecret` 이 있을 때만 넣는다(harbor + private).
- `AS_FQDN` 을 바꾸면 다시 실행한다(WasmPlugin `pluginConfig.fqdn`).

### 7.2 2.2510.4 차트를 렌더링해 확인한 사실

- 렌더링 결과 이미지는 `istio-wasm-plugin:2.2510.4`(plugin-http Deployment)와 `curlimages/curl:2026.05.11`(hook Job) 둘뿐이다.
- WasmPlugin `uipath-routing-policy` 의 `url` 은 클러스터 안 HTTP 서비스다. post-install hook Job `update-wasm-plugin-version` 이 `http://uipath-istio-plugin-http.istio-system.svc/plugin-2.2510.4.wasm` 으로 바꾼다. 즉 Envoy 는 WASM 을 OCI 레지스트리가 아니라 plugin-http 파드에서 받는다.
- `wasm.image.registry` 와 `minProtocolVersion` 은 **2.2510.4 템플릿 어디에서도 참조되지 않는다**(`_helper.tpl` 에 `wasmRegistry` 정의만 있다). 그래서 이 두 값과 `WASM_INSECURE_REGISTRIES` 는 2.2510.4 렌더링 결과에 영향이 없다. 다른 CU 에서 쓰일 수 있어 UiPath 문서대로 넣는다.
- 만드는 리소스: Deployment/Service `uipath-istio-plugin-http`, WasmPlugin `uipath-routing-policy`, EnvoyFilter 4개(`uipath-asrobots-filter`, `uipath-response-server-passthrough-filter`, `uipath-response-filter`, `uipath-hsts-response-header`), ServiceEntry/VirtualService `uipath-fqdn`, hook 리소스(Job `update-wasm-plugin-version`, SA `wasmplugin-patcher`, Role `wasmplugin-patch-role`, RoleBinding `wasmplugin-patch-binding`).
- hook 리소스는 `helm uninstall` 로 지워지지 않는다. `--uninstall` 이 `--ignore-not-found` 로 함께 지운다.

설치는 UiPath 문서처럼 `helm upgrade --install --wait --timeout 10m` 이다. hook Job 이 끝나야 WasmPlugin url 이 바뀌기 때문이다.

### 7.3 AS input.json

이 스크립트로 istio-configure 를 설치했으면 `input.json` 의 `exclude_components` 에 `istio-configure` 를 넣는다.
istio-configure 를 AS 설치기(admin 권한 kubeconfig)에 맡기려면 이 스크립트를 실행하지 말고 `exclude_components` 에서 `istio-configure` 를 뺀다(UiPath Step 2 Option B).

---

## 8. 40-haproxy 연결

### 8.1 NodePort 고정

| 포트 이름 | Service port | NodePort (`versions.env`) | HAProxy 호스트 포트 |
|---|---|---|---|
| `http2` | 80 | `ISTIO_NODEPORT_HTTP`(현재 `31223`) | 80 |
| `https` | 443 | `ISTIO_NODEPORT_HTTPS`(현재 `31164`) | 443 |
| `status-port` | 15021 | `ISTIO_NODEPORT_STATUS`(현재 `31956`) | 15021 |

고정하는 이유:

1. 40-haproxy 기본값과 같다. 이 값은 기존 운영 클러스터에서 온 것이다.
2. 그래서 HAProxy 를 Istio 보다 먼저 설치해도(Phase 2 순서) 백엔드가 맞는다. 40-haproxy 의 기본값이 같은 변수(`ISTIO_NODEPORT_*`)를 읽는다.
3. 재설치해도 포트가 바뀌지 않는다.

40-haproxy 의 자동 탐지는 그대로다. Service 가 있으면 실제 NodePort 를 읽는다. Istio 를 설치한 뒤 40-haproxy `install.sh` 를 한 번 더 실행해 실제 값을 반영하고, 이 번들의 `--check-only` 로 HAProxy 경유까지 확인한다.
`site.env` 로 NodePort 를 바꾸면 두 번들을 같은 `site.env` 로 다시 빌드한다. `install.sh` 는 같은 NodePort 를 쓰는 다른 Service 가 있으면 멈춘다.

### 8.2 포트가 겹치지 않는 이유 (단일 노드)

- HAProxy(`l4`, `--network host`)는 호스트 소켓 80/443/15021 을 바인드한다.
- gateway 파드는 자기 네트워크 네임스페이스에서 80/443/15021 을 연다. 차트가 `net.ipv4.ip_unprivileged_port_start=0` sysctl 을 준다.
- NodePort 는 kube-proxy 의 iptables 규칙일 뿐 호스트 소켓이 아니다.

### 8.3 HAProxy 백엔드 `127.0.0.1:<NodePort>` 가 동작하는 근거

https://kubernetes.io/docs/reference/command-line-tools-reference/kube-proxy/

- kube-proxy 기본 모드는 iptables 다.
- `--iptables-localhost-nodeports` 기본값은 true 다. localhost 로 들어온 NodePort 트래픽도 처리한다.
- `--nodeport-addresses` 를 지정하지 않으면 iptables 모드에서 모든 주소다.
- 60-cilium 은 `kubeProxyReplacement: "false"` 로 kube-proxy 를 유지한다.

---

## 9. 판정 항목

### 9.1 `install.sh` (설치 끝과 `--check-only`)

```
helm 릴리스 istio-base / istiod / istio-ingressgateway deployed
Istio CRD(gateways / virtualservices / wasmplugins)
istiod Available, 이미지 <hub>/pilot:<ISTIO_TAG>, pilot-discovery version = <ISTIO_VERSION>
istio-ingressgateway Available, istio-proxy 이미지 <hub>/proxyv2:<ISTIO_TAG>, pilot-agent version = <ISTIO_VERSION>
Service type NodePort, selector istio=ingressgateway, Deployment 라벨 istio=ingressgateway
NodePort http2 / https / status-port = versions.env
EndpointSlice 에 ready 주소
TLS secret 키 3개 / SAN(AS_FQDN, *.AS_FQDN) / 인증서·키 짝 / ca.crt 검증
출처: local  = 이미지가 containerd(k8s.io)에 적재됨
      harbor = imageID 가 <HARBOR_HOSTNAME>/ 로 시작 + gateway env WASM_INSECURE_REGISTRIES
NodePort status http://<노드IP>:<NP_STATUS>/healthz/ready
smoke HTTP  NodePort -> istio-smoke-ok
smoke HTTPS NodePort (사내 CA 검증) -> istio-smoke-ok
(컨테이너 l4 가 running 이면) HAProxy 경유 127.0.0.1:80 / :443 / :15021
```

- 버전은 `version -s` 출력에서 `x.y.z` 를 뽑아 `ISTIO_VERSION` 과 비교한다. Echo 바이너리는 stderr 에 automemlimit INFO 한 줄을 더 낸다.
- Deployment 라벨 확인은 UiPath 문서가 `input.json` 의 `gateway_selector` 를 확인할 때 쓰는 명령과 같은 값이다.
- smoke 는 백엔드 없이 200 `istio-smoke-ok` 를 돌려주는 Gateway/VirtualService `istio-smoke` 를 잠시 만들고, 판정이 끝나면 지운다(중간에 끝나도 EXIT trap 이 지운다). 호스트는 `istio-smoke.<AS_FQDN>` 이고 와일드카드 SAN 이 덮는다.
- l4 가 없으면 HAProxy 경유 판정은 건너뛰고 로그만 남긴다. 40-haproxy 설치 뒤 `--check-only` 로 다시 본다.
- 판정 수는 HAProxy 경유를 빼고 local 23개, harbor 24개다. l4 가 있으면 3개가 더해진다.

### 9.2 `istio-configure.sh`

```
helm 릴리스 custom-istio-configure deployed
Deployment uipath-istio-plugin-http Available, 이미지 <registry>/istio-wasm-plugin:<UIPATH_WASM_TAG>
Job update-wasm-plugin-version succeeded=1
WasmPlugin uipath-routing-policy url = http://uipath-istio-plugin-http.istio-system.svc/plugin-<버전>.wasm
pluginConfig cluster_type=exclusive / k8s_distribution=vanilla / fqdn=AS_FQDN
EnvoyFilter 4개
plugin URL 응답 (plugin-http 파드에서 busybox wget)
istio-ingressgateway Envoy 에 Wasm 필터 uipath-routing-policy 적재 (config_dump)
istio-ingressgateway Available
출처: local  = wasm·curl 이미지가 containerd(k8s.io)에 적재됨
      harbor = plugin imageID 가 <HARBOR_HOSTNAME>/ + gateway env WASM_INSECURE_REGISTRIES
```

- proxyv2(Echo mini) 이미지에는 `curl`/`wget`/`sh` 가 없어 gateway 컨테이너에서 plugin URL 을 받아 볼 수 없다. 그래서 plugin-http 파드에서 `busybox wget` 으로 받고, gateway 쪽은 `pilot-agent request GET config_dump` 에 `envoy.extensions.filters.http.wasm.v3.Wasm` 과 `uipath-routing-policy` 가 함께 있는지 본다. 원격 모듈을 받지 못하면 istio-agent 가 다른 필터로 바꾸므로 둘이 함께 있어야 한다.
- istio-configure 를 설치한 뒤 `install.sh --check-only` 를 다시 실행해 gateway 와 smoke 가 그대로인지 본다.

---

## 10. 리소스

charles-weed(2 vCPU, 메모리 3,832MiB, swap 없음) 단일 노드 기준 requests 합계다.

| 항목 | CPU | 메모리 |
|---|---|---|
| kube-apiserver / controller-manager / scheduler / etcd | 250m + 200m + 100m + 100m | etcd 100Mi |
| coredns × 2 | 200m | 140Mi |
| istiod (차트 기본값) | 500m | 2048Mi |
| istio-ingressgateway (차트 기본값) | 100m | 128Mi |
| uipath-istio-plugin-http | 5m | 64Mi |
| **합계** | **약 1.45 vCPU** | **약 2.4GiB (2,480Mi)** |

- 할당 가능량(2 vCPU / 약 3.6GiB) 안에 들어간다. 실제 메모리 사용은 약 2GB 로 예상한다. 리소스를 낮추는 설정은 넣지 않았다.
- AS 를 올리면 사이드카마다 requests 50m/96Mi(5.2절)가 더해진다. AS 노드 사양은 UiPath 하드웨어 요구사항을 따른다.
- 디스크: 운영 번들 약 190KB, 검증용 묶음 약 200MB(이미지 4개를 containerd 에 적재하면 비슷한 크기가 더 든다).

---

## 11. 검증 상태

| 항목 | 상태 |
|---|---|
| `bash -n`, `shellcheck` | 완료 (2026-11-07) |
| 번들 빌드(`ISTIO_LOCAL_IMAGES=1 build-in-container.sh 24.04 38-istio`) | 완료 (2026-11-07, charles-weed, Ubuntu 24.04). 차트 sha256 = 핀, 렌더링 단언 통과 |
| `--dry-run --source harbor` / `--source local` (`install.sh`, `istio-configure.sh`) | 완료 (2026-11-07, charles-weed, root·클러스터 없이) |
| `verify-urls.sh` Istio 절 | 16/16 통과 (2026-11-07) |
| 단일 노드 실기 설치(`--source local`) + 판정 | **미실행** |
| istio-configure 실기 설치 + 판정 | **미실행** |
| HAProxy 경유 판정, 재실행 멱등성 | **미실행** |
| **실제 Harbor 경로(`--source harbor`)** | **미검증** (4.6절) |
| AS 라우팅(AS 설치 뒤) | **미검증** |

---

## 12. 트러블슈팅

| 증상 | 원인 | 조치 |
|---|---|---|
| `Harbor 에 uipath/istio/pilot:<태그> 가 없다` | hydrate 를 하지 않았거나, 다른 프로젝트·다른 AS 버전으로 했다 | 상위 README 5.2 의 hydrate 를 `<HARBOR_HOSTNAME>/uipath` 로 실행한다. 프로젝트가 다르면 `site.env` 의 `ISTIO_HARBOR_PROJECT` |
| `Harbor 의 차트 ... sha256 이 versions.env 핀과 다르다` | hydrate 한 AS 번들 버전과 `UIPATH_AS_VERSION` 이 다르다 | 2.3절 절차로 `versions.env` 를 맞추고 번들을 다시 빌드한다 |
| `containerd 가 ... 를 받지 못했다` | 노드가 Harbor CA 를 신뢰하지 않거나(`hosts.toml` 없음), private 인데 자격증명이 틀렸다 | `05-certs/deploy-certs.sh --local`(모든 노드는 `--nodes`). private 이면 `HARBOR_PULL_USER`/`HARBOR_PULL_PASSWORD` |
| `검증용 이미지 묶음이 없다` (`--source local`) | `ISTIO_LOCAL_IMAGES=1` 로 빌드하지 않았거나 다른 디렉터리에 풀었다 | 두 tarball 을 같은 디렉터리에 풀거나 `ISTIO_LOCAL_IMAGES_DIR` 를 준다 |
| `TLS 원본이 없다` / `SAN 에 ... 이 없다` | `/opt/pki/as` 에 05-certs 산출물이 없거나 `AS_FQDN` 이 인증서와 다르다 | `05-certs/deploy-certs.sh --local`, 다른 위치면 `ISTIO_TLS_CERT_DIR`. `AS_FQDN` 을 바꿨으면 인증서를 다시 발급한다 |
| `NodePort 를 이미 다른 Service 가 쓴다` | 다른 Service 가 31223/31164/31956 을 쓴다 | 그 Service 를 바꾸거나 `site.env` 의 `ISTIO_NODEPORT_*` 를 바꾸고 38-istio·40-haproxy 를 함께 다시 빌드한다 |
| HAProxy 백엔드가 DOWN (gateway 는 Available) | 40-haproxy 를 Istio 설치 전 값으로 띄웠고 NodePort 가 다르다 | 40-haproxy `install.sh` 를 다시 실행한다. `kubectl -n istio-system get svc istio-ingressgateway` 의 NodePort 와 `curl -s 'http://127.0.0.1:8404/;csv'` 를 비교한다 |
| `pilot-discovery version` 판정 실패 | 다른 태그의 이미지로 떠 있다 | `kubectl -n istio-system get deploy istiod -o jsonpath='{.spec.template.spec.containers[0].image}'` 를 `<hub>/pilot:<ISTIO_TAG>` 와 비교한다 |
| Wasm 필터 적재 판정 실패 | plugin-http 가 Ready 가 아니거나 hook Job 이 url 을 바꾸지 못했다 | `kubectl -n istio-system get pods,jobs`, `kubectl -n istio-system logs job/update-wasm-plugin-version`, gateway 로그의 `wasm` 줄을 본다. 고친 뒤 `istio-configure.sh` 를 다시 실행한다 |
| `--uninstall` 이 `custom-istio-configure 릴리스가 있다` 로 멈춘다 | istio-configure 를 먼저 지워야 한다 | `sudo ./istio-configure.sh --uninstall` 후 다시 실행한다. `istio-base` 를 지우면 Istio CRD 와 그 리소스가 함께 지워진다 |

---

## 13. 다음 단계

```
10-k8s → 60-cilium → 05-certs → 50-nfs-csi → 40-haproxy → 30-harbor → (AS hydrate, 상위 README 5.2)
  → [38-istio install.sh] → [38-istio istio-configure.sh] → 40-haproxy install.sh 재실행
  → [38-istio install.sh --check-only] → AS input.json(exclude_components, ingress) → uipathctl prereq ...
```

AS `input.json` 의 `ingress` 블록과 확인 명령은 상위 README 5.1절과 5.3.6절에 있다.
