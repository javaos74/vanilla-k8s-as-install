# 38-istio — Istio 서비스 메시(ingressgateway) 오프라인 설치

UiPath Automation Suite(AS)가 쓰는 Istio 를 AS 설치기 대신 직접 설치한다.
`base` → `istiod` → `istio-ingressgateway` 를 helm 으로 올리고, ingressgateway 를 NodePort 로
고정해 `40-haproxy` 가 호스트 80/443/15021 을 그 NodePort 로 넘기게 한다.
그 다음 UiPath `istio-configure` 차트(WASM 라우팅 플러그인 + EnvoyFilter)를 올린다.

Istio 는 **AS 2.2510.4 오프라인 번들에 들어 있는 것(1.30.3, Echo 재빌드)을 그대로 쓴다.**
`install.sh`·`istio-configure.sh` 는 이미지와 차트를 Harbor 에서 받는다. Harbor 에 올리는 방법은 두 가지이고 경로·태그가 같다.

- AS 전체 hydrate(`hydrate-registry.sh` + `as-cmk`, 상위 [README 5.2절](../README.md)). AS 이미지 전부와 함께 올라간다.
- 이 번들의 `feed-istio-to-harbor.sh`(4.2절, 상위 README 5.2.8절). 번들에 든 Istio 아티팩트 8개만 올린다. AS 전체 hydrate 전이나 Harbor 를 새로 설치한 뒤에 쓴다.

역할은 이렇게 나뉜다(사용자 결정 2026-11-10).

| 도구 | 어디서 | 하는 일 |
|---|---|---|
| `build-bundle.sh` | 온라인 빌드 호스트 | registry.uipath.com 에서 8개를 다이제스트·sha256 핀으로 받아 번들에 넣는다 |
| `feed-istio-to-harbor.sh` | Harbor 에 닿는 아무 호스트(오프라인) | 번들의 8개 중 Harbor 에 없는 것만 올린다. 지우거나 덮어쓰지 않는다 |
| `install.sh`, `istio-configure.sh` | control plane | Harbor 에서 받아 설치만 한다 |

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
| 설치 결과 판정(`--check-only`), 제거(`--uninstall`), 렌더링 미리보기(`--dry-run`) | AS 이미지·차트 전체를 Harbor 에 올리기(AS hydrate 가 한다) |
| Istio 아티팩트 8개를 Harbor 에 올리기(`feed-istio-to-harbor.sh`, 4.2절) | Harbor 프로젝트 만들기, Harbor 에서 지우기·덮어쓰기 |

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
- 다이제스트를 고정한다. 번들 이미지(3.1절)와 검증용 이미지 묶음은 다이제스트로 받고, 차트는 tgz sha256 을 핀과 대조한다(Harbor 차트가 다시 패키징돼 tgz 만 다르면 내용을 비교한다, 4.3절).
  `feed-istio-to-harbor.sh` 가 올린 이미지는 Harbor 다이제스트도 핀과 같다. hydrate 사본의 이미지 다이제스트는 원본과 다를 수 있어 설치는 태그로 참조한다(4.3절).

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

### 3.1 운영 번들 `istio-1.30.3` (이미지·차트 8개 포함)

```
istio-1.30.3/                         (tar.gz 약 205MB, 대부분 이미지 레이어)
├── 00-common/{versions.env, site.env|site.env.example, common.sh, os/}
├── charts/
│   ├── base-v1.30.3.tgz              vendor/base
│   ├── istiod-v1.30.3.tgz            vendor/istiod
│   ├── gateway-v1.30.3.tgz           vendor/gateway
│   └── istio-configure-2.2510.4.tgz  helm/istio-configure
├── images/                           skopeo dir 형식 (manifest.json, version, <sha256 hex> blob)
│   ├── registry.uipath.com_istio_pilot_1.30.3-20260730_echo/      약 97MB
│   ├── registry.uipath.com_istio_proxyv2_1.30.3-20260730_echo/    약 71MB
│   ├── registry.uipath.com_istio-wasm-plugin_2.2510.4/            약 2.7MB
│   └── registry.uipath.com_curlimages_curl_2026.05.11/            약 34MB
├── conf/
│   ├── istiod-values.yaml            UiPath values-air.yaml 평탄화 (5절)
│   ├── gateway-values.yaml.tmpl      NodePort 자리표시 (install.sh 가 실행 때 채운다)
│   ├── istio-configure-values.yaml.tmpl
│   └── smoke.yaml.tmpl               판정용 Gateway/VirtualService
├── install.sh  istio-configure.sh  feed-istio-to-harbor.sh  istio-lib.sh(공통 함수)
├── README.md  BUNDLE-INFO  SHA256SUMS
```

- 이미지 크기는 registry.uipath.com 매니페스트의 압축 레이어 크기 합이다(2026-11-10 `skopeo inspect --raw` 로 잼). 실제 번들 크기는 빌드 뒤 `BUNDLE-INFO` 와 `du` 로 확인한다.
- **이미지와 차트를 기본 번들에 항상 넣는다**(사용자 결정 2026-11-10). AS 전체 hydrate(약 57GB) 없이도, Harbor 를 새로 설치한 뒤에도 이 번들만으로 Harbor 를 채워 Istio 를 설치할 수 있어야 한다. 옵션으로 두지 않은 이유는 같은 이름의 번들이 두 가지가 되면 `feed-istio-to-harbor.sh` 가 어느 번들에서 멈출지 알 수 없기 때문이다. hydrate 를 하는 사이트에서는 약 205MB 를 더 옮긴다.
- 이미지 형식은 skopeo `dir` 이다. 원본 매니페스트 바이트와 압축 레이어를 그대로 둔다. 그래서 `manifest.json` 의 sha256 이 `versions.env` 다이제스트 핀과 같고, `feed-istio-to-harbor.sh` 가 Harbor 에 올린 이미지의 다이제스트도 핀과 같다.
  - wasm·curl 은 docker v2s2 매니페스트다(pilot·proxyv2 는 OCI). `oci`·`oci-archive` 는 OCI 매니페스트만 담으므로 v2s2 를 OCI 로 바꾸고 다이제스트가 달라진다.
  - `docker-archive` 는 레이어를 압축 없이 담아, 다시 올릴 때 레이어와 매니페스트가 새로 만들어진다.
- 차트(합계 약 146KB)는 `feed-istio-to-harbor.sh` 가 올리는 원본이고, `--source local` 설치와 `--dry-run` 렌더링에도 쓴다. registry.uipath.com 원본과 같은 바이트다(sha256 핀). `--source harbor` 에서 Harbor 차트의 tgz sha256 이 핀과 다르면 이 차트와 내용을 비교한다(4.3절).
- `gateway-values.yaml.tmpl` 의 NodePort 는 `install.sh` 가 실행 때 `ISTIO_NODEPORT_*` 로 채운다. `site.env` 로 NodePort 를 바꿔도(두 번들을 같은 `site.env` 로 다시 빌드, 8.1절) `40-haproxy`(실행 때 같은 변수를 읽는다)와 어긋나지 않게 하려는 것이다.
- `install.sh` 는 시작할 때 `SHA256SUMS` 로 번들 전체(이미지 blob 포함)를 검증한다. 이미지 때문에 몇 초 더 걸린다.

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

- registry.uipath.com 에서 **다이제스트로** 받아 태그 이름으로 저장한다(`skopeo copy docker://<repo>@<digest> docker-archive:<tar>:<태그>`). 운영 번들의 `images/` 와 같은 이미지를 `ctr import` 가 읽는 형식으로 한 번 더 담은 것이다.
- `--source local` 이 `ctr -n k8s.io images import` 로 넣는다. 운영 번들과 **같은 디렉터리에 푼다.** 스크립트는 `${ISTIO_LOCAL_IMAGES_DIR:-<운영 번들>/../istio-local-images-1.30.3}` 을 보고, 그 안의 `SHA256SUMS` 를 먼저 검증한다.
- **단일 노드 검증 전용**이다. 다중 노드에서는 다른 노드의 사이드카가 proxyv2 를 받지 못한다. 다중 노드와 운영은 `--source harbor` 를 쓴다.

### 3.3 빌드

```bash
# 빌드 호스트(인터넷 O)
cd offline-install
./00-common/build-in-container.sh 24.04 38-istio                      # 운영 번들(이미지·차트 8개 포함)
ISTIO_LOCAL_IMAGES=1 ./00-common/build-in-container.sh 24.04 38-istio  # + 검증용 이미지 묶음
# 또는 cd 38-istio && [ISTIO_LOCAL_IMAGES=1] ./build-bundle.sh
```

- 빌드 도구는 helm 과 skopeo 다. helm 이 없으면 `HELM_URL` 로 임시 설치하고, skopeo 가 없으면 OS 패키지로 설치한다(`sudo apt-get install skopeo` / `dnf install skopeo`).
- 번들에 들어가는 `site.env` 는 빌드 작업 사본의 `00-common/site.env` 다(없으면 `site.env.example`). `feed-istio-to-harbor.sh` 와 `install.sh` 는 그 안의 `HARBOR_HOSTNAME`·`AS_FQDN` 을 쓰므로 빌드 전에 대상 사이트 값으로 채운다. 번들을 푼 뒤 `site.env` 를 고치면 `SHA256SUMS` 검증에서 멈춘다.
- 10-k8s 를 설치한 노드에서는 `build-in-container.sh` 가 실패한 적이 있다(charles-weed). 그때는 그 노드에서 일반 사용자로 `38-istio/build-bundle.sh` 를 직접 실행한다(as2510-vanilla ascp 에서 성공, 2026-11-09).

`build-bundle.sh` 가 하는 확인:

- 차트 4개를 `helm pull oci://registry.uipath.com/<경로>` 로 받고 sha256 을 핀과 대조한다. 다르면 멈춘다.
- 이미지 4개를 `skopeo copy [--preserve-digests] docker://registry.uipath.com/<경로>@<다이제스트 핀> dir:images/<이름>` 으로 받고, `manifest.json` 의 sha256 이 핀과 같은지 본다. 다르면 멈춘다. 이미 받은 것은 sha256 이 핀과 같을 때만 다시 쓴다.
- `helm template` 으로 렌더링해 단언한다.
  - istiod Deployment 이미지가 `registry.uipath.com/istio/pilot:<ISTIO_TAG>` 하나뿐이다.
  - 주입 values 에 `"hub"`, `"tag"`, `"image": "proxyv2"` 가 있다(사이드카·게이트웨이 프록시 이미지).
  - UiPath values-air 값(`holdApplicationUntilProxyStarts`, `ENABLE_NATIVE_SIDECARS`, `system-cluster-critical`)이 반영됐다.
  - gateway Service 가 NodePort 이고 nodePort 3개, selector `istio: ingressgateway`, 이미지 `auto`(주입)다. gateway Deployment 에 `imagePullPolicy: IfNotPresent` 가 있다(5.2절).
  - istio-configure 이미지 집합이 정확히 `{UIPATH_WASM_IMAGE, UIPATH_ISTIO_CURL_IMAGE}` 이고 pluginConfig 에 `cluster_type: exclusive`, `k8s_distribution: vanilla` 가 있다.

---

## 4. Harbor 경로(hydrate 또는 feed-istio-to-harbor.sh)

### 4.1 경로

아래 8개는 상위 README 5.2 의 hydrate(`hydrate-registry.sh --target-registry-url <HARBOR_HOSTNAME>/<ISTIO_HARBOR_PROJECT>`)가 AS 이미지와 함께 올리거나, 이 번들의 `feed-istio-to-harbor.sh`(4.2절)가 번들에서 올린다. 두 도구의 위치는 같다.
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

### 4.2 `feed-istio-to-harbor.sh` — 번들의 8개를 Harbor 에 올린다

AS 전체 hydrate 없이 Istio 만 먼저 설치할 때, 또는 Harbor 를 새로 설치해 Istio 아티팩트가 없을 때 쓴다.
이 절차가 없던 때는 hydrate 하지 않은 새 Harbor 에서 `install.sh` 가 `Harbor 에 uipath/istio/pilot:… 가 없다` 로 멈췄다(2026-11-10, 4.6절).

```bash
# 번들을 푼 디렉터리에서. root·kubeconfig·인터넷이 필요 없다.
./feed-istio-to-harbor.sh --dry-run     # 올릴 목록·원본 다이제스트·번들 위치·Harbor 경로·명령, 이 호스트의 도구 유무. Harbor 에 접속하지 않는다
./feed-istio-to-harbor.sh               # 계정·비밀번호를 프롬프트로 묻는다(비밀번호는 화면에 나오지 않는다)
```

터미널이 아니면 stdin 두 줄(계정, 비밀번호)을 읽는다. 스크립트나 원격 실행에서 쓴다.

```bash
read -r -p 'Harbor user: ' HU; read -rs -p 'Harbor password: ' HP; echo
printf '%s\n' "$HU" "$HP" | ./feed-istio-to-harbor.sh
unset HU HP
```

하는 일(순서대로, 하나라도 실패하면 그 자리에서 멈춘다):

1. 사전 확인. 여기까지는 Harbor 를 바꾸지 않는다.
   - 번들 `SHA256SUMS`, 이미지 4개의 `manifest.json` sha256 = 다이제스트 핀(가리키는 blob 이 모두 있음), 차트 4개의 tgz sha256 = 핀.
   - 도구 `skopeo`, `helm`(3.8 이상, helm 4 포함), `curl`, `base64`, `sha256sum`, `tar`, `diff`, `getent`.
   - `HARBOR_HOSTNAME` 해석, `https://<host>/api/v2.0/ping` 이 CA 검증을 통과해 `Pong`.
   - 계정·비밀번호(stdin)로 `GET /api/v2.0/projects/<project>` 가 200. 401 은 계정·비밀번호, 403·404 는 프로젝트가 없거나 볼 수 없는 것이다. 프로젝트는 만들지 않는다(상위 README 5.2.3).
2. 8개 각각 Harbor API(`/projects/<p>/repositories/<repo, '/' 는 %252F>/artifacts/<태그>`)로 있는지 본다. 200 이면 건너뛰고 404 면 올릴 목록에 넣는다. 다른 응답이면 멈춘다.
3. 없는 것만 올린다.
   - 이미지: `skopeo copy [--preserve-digests] --retry-times 3 --dest-tls-verify=true --dest-authfile <임시> [--dest-cert-dir <CA 사본>] dir:images/<이름> docker://<host>/<project>/<원본 경로>:<태그>`. 매니페스트와 압축 레이어를 그대로 올린다.
   - 차트: `helm push charts/<차트>.tgz oci://<host>/<project>/<첫 경로> --registry-config <임시> [--ca-file <CA>]`. helm 은 Chart.yaml 의 name 으로 저장소를 만들고 버전을 태그로 쓴다(`vendor/base:v1.30.3`). hydrate `import_sf_charts` 와 같은 규칙이다.
4. 8개 모두(이미 있던 것 포함) 결과를 확인한다.
   - 이미지: Harbor API 의 태그가 있고 다이제스트가 핀과 같다. 이번에 올린 이미지가 핀과 다르면 실패다. 이미 있던 이미지(hydrate 사본 등)가 핀과 다르면 경고만 하고 통과한다. `install.sh` 는 태그로 받기 때문이다(4.3절).
   - 차트: `helm pull --version <버전>` 으로 받아 tgz sha256 = 핀이면 통과한다. 다르면 번들 차트와 내용을 비교해(`install.sh` 와 같은 기준, 4.3절) 같으면 통과, 다르면 실패다. 실패해도 덮어쓰지 않는다.
   - 끝에 `검증 결과: 통과 N / 실패 M` 과 `올림 / 건너뜀 / 전체` 를 출력한다. 실패가 있으면 종료 코드 1 이다.

규칙:

- **Harbor 에서 아무것도 지우거나 덮어쓰지 않는다.** 같은 태그가 있으면 내용이 달라도 올리지 않는다. 다시 실행하면 8개 모두 건너뛴다(멱등).
- hydrate 와 경로·태그가 같으므로 순서를 가리지 않는다.
  - hydrate 를 먼저 했으면 feed 는 8개를 모두 건너뛰고 확인만 한다.
  - feed 를 먼저 했으면 나중의 hydrate 가 같은 태그를 다시 push 할 수 있다(hydrate 가 이미 있는 태그를 건너뛰는지는 확인하지 않았다). 그러면 이미지 다이제스트가 hydrate 사본의 것으로 바뀔 수 있지만 경로·태그가 같아 `install.sh` 에 영향이 없다(4.3절).
- 올리는 도중 실패하면(네트워크, 권한) 이미 올린 것은 남는다. 원인을 고친 뒤 다시 실행하면 없는 것만 올린다.

인증:

- 비밀번호는 stdin 으로만 받는다. 환경변수와 명령 인자로는 받지 않는다. `sudo VAR=… ./명령` 은 비밀번호가 `sudo` 의 프로세스 인자에 보이기 때문이다. 이 도구는 root 가 필요 없어 `sudo` 없이 실행한다.
- 넘기는 방법: Harbor API 는 `curl -K -`(stdin 설정, `hcurl_auth`), helm 은 `helm registry login --password-stdin --registry-config <임시>`, skopeo 는 임시 인증 파일(`mktemp -d` 0700 디렉터리의 `auth.json`, base64 `계정:비밀번호`)이다. `skopeo --dest-creds` 는 인자에 보여서 쓰지 않는다. 임시 파일은 끝나면(실패해도) 지운다.
- 계정은 `uipath` 프로젝트에 push 권한이 있어야 한다(robot 계정 권장). pull 만 되는 계정이면 첫 push 에서 멈춘다.

CA:

- `install.sh` 와 같은 후보(`/etc/docker/certs.d/<host>/ca.crt` → `/etc/containerd/certs.d/<host>/ca.crt` → `/opt/pki/ca/ca.crt`)를 쓰고, 없으면 OS 신뢰 저장소로 검증한다(4.4절 2·3번). containerd `hosts.toml` 은 보지 않는다(클러스터 노드가 아닐 수 있다).
- skopeo 에는 CA 만 복사한 임시 디렉터리를 `--dest-cert-dir` 로 준다. `--dest-cert-dir` 은 그 디렉터리의 `*.key` 를 클라이언트 키로 읽으므로 키가 함께 있을 수 있는 `/opt/pki/ca` 를 그대로 주지 않는다.
- 검증을 끄지 않는다. `--dest-tls-verify=true` 를 명시해 `registries.conf` 에 insecure 로 적힌 레지스트리라도 검증한다. `--insecure-skip-tls-verify`, `--plain-http` 를 쓰지 않는다.

도구가 없을 때:

- 도구가 하나라도 없으면 Harbor 에 접속하기 전에 멈춘다. `--dry-run` 이 이 호스트에 무엇이 없는지 미리 보여 준다.
- skopeo: OS 패키지로 설치한다(Ubuntu universe·RHEL AppStream 의 `skopeo`, 에어갭이면 사내 미러). 또는 skopeo 가 있고 Harbor 에 닿는 다른 호스트에서 실행한다. 이 도구는 kubeconfig 가 필요 없어 어느 호스트에서도 된다.
- skopeo 를 대신하는 경로(podman·docker 의 load → push)는 두지 않았다. 레이어를 다시 압축해 다이제스트가 바뀌기 때문이다. 결과는 hydrate 와 같은 성질이 되고, "올린 이미지 다이제스트 = 핀" 으로 확인할 수 없다.
- `--preserve-digests` 가 없는 옛 skopeo 도 쓸 수 있다. `dir` → registry 는 형식을 바꾸지 않으므로 다이제스트가 그대로이고, 4번 확인이 핀과 같은지 본다.
- helm: 10-k8s 로 설치한 노드에는 있다. 다른 호스트면 10-k8s 번들 `bin/helm-v3.22.0-linux-amd64.tar.gz` 를 푼다(상위 README 5.2.2). helm 4 는 쓰는 플래그(`helm push --ca-file`, `helm registry login --password-stdin`, `--registry-config`)가 같다(2026-11-10 `--help` 로 확인, 실행은 미검증).

환경별 도구 상태(2026-11-10 확인):

| 호스트 | skopeo | helm | 비고 |
|---|---|---|---|
| ascp(10.32.99.3, control plane) | 1.13.3(`--preserve-digests` 있음) | v3.22.0 | 그대로 실행할 수 있다 |
| asw3(10.32.99.7, Harbor 호스트) | 없음 | v4.3.1(snap) | skopeo 를 설치해야 한다. 빌드(`build-bundle.sh`)도 skopeo 가 없으면 apt 로 설치하려 한다 |

### 4.3 다이제스트와 sha256

- hydrate 는 이미지를 `podman load` → `podman push --tls-verify=false` 로 올린다. 매니페스트를 다시 만들 수 있어 **Harbor 의 이미지 다이제스트는 registry.uipath.com 원본과 다를 수 있다.**
  그래서 harbor 경로(`install.sh`·`istio-configure.sh`)는 이미지를 **태그**로 참조하고 다이제스트 일치는 판정하지 않는다. 35-metrics-server 도 같은 현상을 실측했다(그 README 4절).
- `feed-istio-to-harbor.sh` 가 올린 것은 원본과 같다. 이미지는 다이제스트 = 핀(올린 뒤 확인한다), 차트는 번들 tgz 그대로라 tgz sha256 = 핀이다. 그래서 `install.sh` 의 차트 대조는 아래 1단계에서 통과한다.
- 차트도 Harbor 의 tgz 가 원본과 **바이트까지 같다는 보장이 없다.**
  - `hydrate-registry.sh`(2.2510.4, `import_sf_charts`)는 번들의 tgz 를 `helm push` 로 그대로 올린다.
  - 하지만 as2510-vanilla 의 Harbor 차트 4개는 tar 항목 시각이 Harbor `push_time`(2026-11-06 03:01)과 같았다. 올리기 직전에 다시 패키징된 것이다. 어떤 도구로 올렸는지는 확인하지 못했다.
  - 풀어 놓은 내용은 `diff -r` 로 핀 차트와 같았고, tgz sha256 만 달랐다(2026-11-09 실측).
- 그래서 `install.sh`/`istio-configure.sh` 는 Harbor 에서 `helm pull` 한 차트를 두 단계로 대조한다(`istio-lib.sh` 의 `harbor_chart_pull`).
  1. tgz sha256 이 `versions.env` 핀과 같으면 통과한다.
  2. 다르면 번들의 같은 차트와 내용을 비교한다. 번들 차트는 `SHA256SUMS` 로 검증됐고, 여기서 다시 sha256 = 핀을 확인한다. 같으면 `재패키징, 내용 = 핀` 으로 통과하고 Harbor 에서 받은 차트로 설치한다. 다르면 멈춘다. 다르면 hydrate 한 AS 번들 버전이 `UIPATH_AS_VERSION` 과 다른 경우가 많다.
- 내용 비교의 기준
  - 비교 범위: 압축을 푼 차트 디렉터리 전체를 `diff -r` 로 본다. 파일·디렉터리 이름(경로) 집합과 모든 일반 파일의 바이트 내용이다. `Chart.yaml`, `values*.yaml`, `templates/`, `crds/`, `files/`, README 등 차트에 든 것 전부가 들어간다. 하위 차트(`charts/*.tgz`)는 tgz 바이트로 비교한다.
  - 무시하는 것: tar 메타데이터(항목 시각, 소유자 uid/gid·이름), 파일 모드(`diff` 는 권한을 보지 않고, helm 도 차트 파일 권한을 쓰지 않는다), tar 항목 순서, gzip 헤더와 압축 바이트. 다시 패키징하면 이것들만 바뀐다.
  - 판정 로그에는 두 tgz 의 sha256, 비교한 파일 수, 결과를 남긴다. 다르면 다른 경로를 최대 10줄 출력한다.

### 4.4 사전 확인 (`--source harbor`)

`install.sh` 와 `istio-configure.sh` 가 설치 전에 차례로 확인한다. 하나라도 실패하면 아무것도 바꾸지 않고 멈춘다. 두 스크립트는 Harbor 에 아무것도 올리지 않는다. 6번에서 이미지가 없으면 hydrate 또는 `feed-istio-to-harbor.sh`(4.2절)를 먼저 실행하라고 알린다.

1. `site.env` 의 `HARBOR_HOSTNAME` 이 있고 이 노드에서 해석된다(`getent hosts`).
2. Harbor CA 를 찾는다. 후보 순서는 35-metrics-server 와 같다: `/etc/docker/certs.d/<host>/ca.crt` → `/etc/containerd/certs.d/<host>/ca.crt` → `/opt/pki/ca/ca.crt`.
3. CA 파일을 찾았으면 `/etc/containerd/certs.d/<host>/hosts.toml` 도 있어야 한다(05-certs `deploy-certs.sh --local` 이 만든다).
   - CA 파일이 하나도 없으면 노드 OS 신뢰 저장소로 검증한다. 사내 CA 를 `update-ca-certificates` 로 OS 신뢰 저장소에만 넣은 클러스터가 있기 때문이다(as2510-vanilla 실측: certs.d·`/opt/pki` 없음, containerd `config_path = ''`).
   - 이때 curl 과 helm 은 `--cacert`/`--ca-file` 없이 OS 신뢰 저장소를 쓴다. containerd 도 `config_path` 를 쓰지 않으면 같은 저장소로 검증한다. containerd 쪽은 7번 `crictl pull` 이 실제로 확인한다.
4. `https://<host>/api/v2.0/ping` 이 CA 검증(CA 파일 또는 OS 신뢰 저장소)을 통과해 `Pong` 을 돌려준다.
5. 익명 `GET /api/v2.0/projects/<project>` 로 public 여부를 본다. private 이면 자격증명으로 다시 읽는다.
6. Harbor API(`/api/v2.0/projects/<p>/repositories/<repo, '/' 는 %252F>/artifacts/<태그>`)로 이미지가 있는지 본다.
7. `crictl pull` 로 containerd(kubelet 경로)가 실제로 받는지 본다. 실패하면 파드가 `ImagePullBackOff` 가 되므로 설치 전에 멈춘다.
8. `helm pull oci://… [--ca-file <CA>]` 로 차트를 받아 sha256 을 대조한다. 다르면 번들 차트와 내용을 비교한다(4.3절).

### 4.5 인증과 CA

- **public 프로젝트**: 자격증명 없이 받는다. pull secret 을 만들지 않는다.
- **private 프로젝트**: 다음 순서로 자격증명을 찾는다.
  1. `HARBOR_PULL_USER` / `HARBOR_PULL_PASSWORD` (Harbor robot 계정 권장)
  2. 35-metrics-server 와 같은 순서: `HARBOR_USER` / `HARBOR_PASSWORD` → `site.env` 의 `HARBOR_ADMIN_PASSWORD`(admin) → `/opt/harbor/.harbor-credentials`. 이때는 robot 계정을 쓰라는 경고를 낸다.
  - `install.sh` 가 `istio-system` 에 `uipathpullsecret`(`ISTIO_PULL_SECRET`)을 만들고 istiod·gateway 에 붙인다. `istio-configure.sh` 는 그 secret 이 있을 때만 values 에 넣는다.
  - **2번 경로로 설치하면 그 계정의 비밀번호가 pull secret 에 그대로 저장된다.** `HARBOR_USER` 가 없으면 계정은 admin 이다. 그러면 `istio-system` secret 을 읽을 수 있는 주체는 누구나 Harbor admin 권한(모든 프로젝트 push·삭제, 계정 관리)을 얻는다. 경고는 설치 로그에만 남고 secret 은 계속 남는다.
    - 운영에서는 `uipath` 프로젝트 pull 권한만 있는 robot 계정을 `HARBOR_PULL_USER` 로 준다.
    - 이미 admin 으로 만들었으면 robot 계정으로 `install.sh` 를 다시 실행한다. secret 은 `kubectl apply` 로 바뀐다. 확인: `kubectl -n istio-system get secret uipathpullsecret -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d | grep -o '"auth":"[^"]*"' | cut -d'"' -f4 | base64 -d | cut -d: -f1`(계정 이름만 출력, jq 불필요).
  - `istio-configure.sh` 도 사전 확인(Harbor API, `crictl pull`, `helm pull`)에 같은 자격증명이 필요하다. 아래 예의 `./install.sh` 를 `./istio-configure.sh` 로 바꿔 실행한다.
  - helm 은 임시 `--registry-config` 파일에만 로그인하고 끝나면 지운다.
  - 비밀번호를 프로세스 인자(`ps` 에 보인다)로 넘기지 않는다. Harbor API 는 `curl -K -`(stdin 설정), `crictl pull` 은 환경변수 `CRICTL_CREDS`, helm 은 `--password-stdin` 이다. pull secret 은 dockerconfigjson(auth 만)을 셸 안에서 만들어 `kubectl apply -f -` 로 넣는다.
  - `sudo HARBOR_PULL_USER=… HARBOR_PULL_PASSWORD=… ./install.sh` 처럼 명령줄에 쓰지 않는다. 비밀번호가 셸 히스토리와 `sudo` 프로세스의 인자(`ps`)에 남는다.
  - `sudo` 로 실행할 때 비밀번호를 명령줄에 쓰지 않으려면 stdin 으로 읽어 넘긴다. 계정 이름도 같이 stdin 으로 넘긴다.
    - robot 계정 이름(`robot$<프로젝트>+<이름>`)을 `bash -c '...'` 문자열 안에 쓰면 안쪽 셸이 `$<프로젝트>` 를 빈 변수로 확장해 `robot+<이름>` 으로 로그인한다.
    - stdin 으로 넘기면 따옴표나 sudoers 의 환경변수 정책(env_reset)과 상관없이 값이 그대로 전달되고, 계정 이름도 프로세스 인자에 남지 않는다. 예:
    ```bash
    read -r -p 'Harbor user: ' HARBOR_PULL_USER; read -rs -p 'Harbor password: ' HARBOR_PULL_PASSWORD; echo
    printf '%s\n' "$HARBOR_PULL_USER" "$HARBOR_PULL_PASSWORD" | sudo bash -c \
      'IFS= read -r HARBOR_PULL_USER; IFS= read -r HARBOR_PULL_PASSWORD; export HARBOR_PULL_USER HARBOR_PULL_PASSWORD; exec ./install.sh'
    unset HARBOR_PULL_USER HARBOR_PULL_PASSWORD
    ```
- `feed-istio-to-harbor.sh` 의 push 계정은 이 pull 계정과 따로다. feed 는 stdin 으로만 받고 pull secret 을 만들지 않는다(4.2절).
- CA 검증을 끄지 않는다. `--insecure-skip-tls-verify`, `--plain-http`, `insecure-registries` 를 쓰지 않는다.
- 파드는 어느 노드에도 뜰 수 있으므로 **모든 노드**가 Harbor 이름을 해석하고 CA 를 신뢰해야 한다(`05-certs/deploy-certs.sh --nodes ...`). 사이드카 proxyv2 는 AS 파드가 뜨는 모든 노드에서 받는다.

### 4.6 검증 상태

**Harbor 위치가 바뀌었다(2026-11-10).** as2510-vanilla 의 `harbor.myrobots.co.kr` 은 asw2(10.32.99.6)에 있었다. 사용자가 Harbor 를 asw3(10.32.99.7)에 다시 설치했고, 사내 DNS 의 `harbor.myrobots.co.kr` 이 10.32.99.7 을 가리킨다. asw2 는 클러스터에서 빠졌고 10.32.99.6 은 응답하지 않는다. 아래 2026-11-09 결과는 asw2 의 예전 Harbor 기준이다.

- 새 Harbor 에는 hydrate 를 하지 않았다. 그래서 ascp 에서 `install.sh` 가 사전 확인 6번에서 `Harbor 에 uipath/istio/pilot:1.30.3-20260730_echo 가 없다` 로 멈췄다(사용자 실행, 2026-11-10). istiod 파드는 새 Harbor 에서 pilot 을 받지 못해 `ImagePullBackOff` 였고, gateway·plugin-http 는 노드에 남은 이미지로 Running 이었다(읽기 전용 확인).
- 이 경우를 위해 `feed-istio-to-harbor.sh`(4.2절)를 더했다. **실제 Harbor 에서 실행한 것은 아직 없다(실기 미검증).** 지금까지 한 확인은 다음과 같다.
  - `bash -n`, `shellcheck`(기준 커밋 `d6f45b9` 대비 새 경고 없음).
  - 실제 매니페스트(registry.uipath.com, crane)와 실제 차트 4개, 가짜 blob 으로 만든 시험 번들에서 `--dry-run` 을 ascp(skopeo 1.13.3, helm v3.22.0)와 asw3(skopeo 없음, helm v4.3.1)에서 실행했다. 사전 확인은 ascp 에서 Harbor `ping`·CA 검증까지 통과한 뒤 계정이 없어 멈췄고, asw3 에서는 skopeo 가 없어 Harbor 에 접속하기 전에 멈췄다. Harbor 는 바뀌지 않았다.
  - `build-bundle.sh` 의 이미지 단계(`skopeo copy … dir:`)는 아직 실행하지 않았다.
- **Harbor 에서 받아 설치하는 경로(`--source harbor`)는 실기로 검증했다**(2026-11-09, as2510-vanilla 3노드, 그때의 Harbor `harbor.myrobots.co.kr` = asw2, private 프로젝트 `uipath`, Harbor 2.15.2).
  - 확인한 것: Harbor API 조회(자격증명), `crictl pull`(3노드), `helm registry login --registry-config` + `helm pull`(CA 파일 없이 OS 신뢰 저장소), 차트 대조(4개 모두 재패키징, 내용 = 핀), pull secret, imageID 판정.
  - 8개 아티팩트는 이미 Harbor 에 있어 push 하지 않았다.
  - **이 결과는 이전 Istio 잔여물을 손으로 정리한 뒤에 나왔다.** 이 클러스터에는 릴리스 `base` 가 남긴 CRD 15개와, 없는 istiod 를 가리키는 `failurePolicy: Fail` webhook 2개가 있었다. 설치 전에 CRD 15개의 소유 annotation 을 `base` → `istio-base` 로 바꾸고 webhook 2개를 지웠다(12.1절). `install.sh` 는 이 정리를 하지 않고, 사전 확인도 이 상태를 찾지 않는다.
- **hydrate 실행은 미검증이다.** 2026-11-09 에 검증한 Harbor 는 사용자가 이전에(2026-11-06) 채운 것이다. 어떤 도구로 채웠는지는 확인하지 못했다. 그때 30-harbor 는 설치하지 않았다(사용자 결정).
- `HARBOR_CA` 파일을 쓰는 경로(`/etc/containerd/certs.d/<host>/hosts.toml` 요구, `--cacert`/`--ca-file`)는 실기로 실행되지 않았다(as2510-vanilla 에는 certs.d 가 없다). `bash -n`, `shellcheck`, `--dry-run` 으로만 확인했다.

---

## 5. 설치

```bash
# control plane (root). 운영 번들과 (검증 때만) 검증용 묶음을 같은 디렉터리에 푼다.
sha256sum -c istio-1.30.3.tar.gz.sha256
tar xzf istio-1.30.3.tar.gz && cd istio-1.30.3

./feed-istio-to-harbor.sh --dry-run       # Harbor 에 8개가 없으면(hydrate 전, 새 Harbor) 올릴 것을 미리 본다(4.2절)
./feed-istio-to-harbor.sh                 # 없는 것만 올린다. 계정·비밀번호는 stdin(프롬프트). root 불필요
./install.sh --dry-run                    # root·클러스터 없이 렌더링한 이미지와 명령만 본다(= --source harbor)
sudo ./install.sh                         # Harbor 에서 설치 (= --source harbor). private 이면 pull 계정은 4.5절대로 stdin
sudo ./istio-configure.sh                 # UiPath istio-configure (7절)
sudo ./install.sh --check-only            # 판정만 (40-haproxy 재실행 뒤 HAProxy 경유까지)
```

| 옵션 | 동작 |
|---|---|
| (없음) | 설치 + 판정. 다시 실행해도 결과가 같다(`helm upgrade --install`, secret 은 `kubectl apply`) |
| `--source harbor` | 기본값. 차트와 이미지를 Harbor 에서 받는다(hydrate 또는 `feed-istio-to-harbor.sh` 가 올린 것, 4절) |
| `--source local` | 단일 노드 검증 전용. 차트는 번들 `charts/`, 이미지는 검증용 묶음을 `ctr -n k8s.io images import` 로 넣는다 |
| `--check-only` | 판정만 한다. 출처는 배포된 istiod 이미지 접두사로 판별한다(`--source` 를 주면 그 값). TLS 원본 파일 없이 secret 으로 판정한다 |
| `--uninstall` | 제거한다. `custom-istio-configure` 가 있으면 멈추고 `istio-configure.sh --uninstall` 을 먼저 하라고 알린다. Istio CRD 는 차트의 `helm.sh/resource-policy: keep` 때문에 남는다(12절) |
| `--dry-run` | root·클러스터·레지스트리 없이 렌더링한 이미지, NodePort, 실행할 명령(Harbor API URL, `crictl pull`, `helm pull`)만 출력한다 |

`istio-configure.sh` 도 같은 옵션(`--source harbor|local`, `--check-only`, `--uninstall`, `--dry-run`)을 받는다.

| 환경변수 | 기본값 | 용도 |
|---|---|---|
| `ISTIO_TLS_CERT_DIR` | `/opt/pki/as` | TLS 원본 `fullchain.crt`, `tls.key`, `ca.crt` 위치(6절) |
| `ISTIO_LOCAL_IMAGES_DIR` | `<번들>/../istio-local-images-1.30.3` | `--source local` 의 검증용 묶음 위치 |
| `HARBOR_PULL_USER` / `HARBOR_PULL_PASSWORD` | 없음 | private 프로젝트 pull 계정(4.5절) |
| `ISTIO_NODEPORT_HTTP` / `_HTTPS` / `_STATUS` | `31223` / `31164` / `31956` | `site.env` 로 바꾼다(8절) |
| `ISTIO_HARBOR_PROJECT` | `uipath` | hydrate·`feed-istio-to-harbor.sh` 대상 프로젝트. `site.env` 로 바꾼다 |
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

ingressgateway 에는 `imagePullPolicy: IfNotPresent` 도 넣는다(charles-weed 실측 뒤 사용자 결정).

- gateway 차트는 컨테이너 이미지를 태그 없는 `image: auto`(주입 자리표시)로 두고 `imagePullPolicy` 기본값이 `""` 다. 그래서 Kubernetes 가 태그 없는 이미지의 기본값 `Always` 를 채운다(https://kubernetes.io/docs/concepts/containers/images/#imagepullpolicy-defaulting).
- Deployment 에 들어간 이 값이 주입 템플릿의 `global.imagePullPolicy=IfNotPresent` 보다 우선한다. 실측에서 proxyv2 를 containerd 에 미리 넣었는데도 gateway 파드가 뜰 때마다 레지스트리에서 다시 받았다.
- 그대로 두면 Harbor 가 내려갔을 때, 또는 `--source local` 에어갭에서 gateway 가 뜨지 못한다.
- 이 수정으로 레지스트리 없이 gateway 가 뜨는지는 확인하지 못했다(11절). as2510-vanilla 에서 Deployment·파드 값은 `IfNotPresent` 였지만, 노드별 첫 gateway 파드는 이미지가 있는데도 Harbor 에서 다시 받았다(원인 미확인). charles-weed `--source local` 경로는 수정 뒤 다시 실행하지 못했다.
- 이 값은 gateway Deployment 에만 쓰인다. 사이드카(proxyv2 주입)는 istiod 의 `global.imagePullPolicy` 를 따르고 바꾸지 않았다.
- `build-bundle.sh` 가 렌더링한 gateway Deployment 에 이 값이 있는지 확인한다.

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
istio-ingressgateway Envoy 에 Wasm 필터 uipath-routing-policy 적재 (config_dump ECDS, smoke Gateway)
istio-ingressgateway Available
출처: local  = wasm·curl 이미지가 containerd(k8s.io)에 적재됨
      harbor = plugin imageID 가 <HARBOR_HOSTNAME>/ + gateway env WASM_INSECURE_REGISTRIES
```

- proxyv2(Echo mini) 이미지에는 `curl`/`wget`/`sh` 가 없어 gateway 컨테이너에서 plugin URL 을 받아 볼 수 없다. 그래서 plugin-http 파드에서 `busybox wget` 으로 받는다.
- gateway 쪽은 `pilot-agent request GET 'config_dump?resource=ecds_filters'` 에서 `istio-system.uipath-routing-policy` 항목의 타입이 `envoy.extensions.filters.http.wasm.v3.Wasm` 인지 본다. 원격 모듈을 받지 못하면 istio-agent 가 같은 이름의 다른 필터로 바꾸므로 이름과 타입이 같은 항목에 있어야 한다. 전체 `config_dump` 를 grep 하면 부트스트랩의 지원 확장 목록에 Wasm 타입이 늘 있어 판정이 의미가 없다(charles-weed 실측).
- Wasm 필터는 HTTP 리스너에 붙는다. AS 를 설치하기 전에는 Gateway 리소스가 없어 gateway 에 정적 리스너(15090, 15021)만 있고 필터가 들어갈 곳이 없다. 그래서 이 판정 동안만 install.sh 와 같은 smoke Gateway/VirtualService 를 만들고 지운다.
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
- 디스크: 운영 번들 약 205MB(tar.gz 와 푼 디렉터리가 각각), 검증용 묶음 약 200MB(이미지 4개를 containerd 에 적재하면 비슷한 크기가 더 든다). Harbor 에는 `feed-istio-to-harbor.sh` 가 약 205MB(압축 레이어)를 올린다.

---

## 11. 검증 상태

| 항목 | 상태 |
|---|---|
| `bash -n`, `shellcheck` | 완료 (2026-11-10, `feed-istio-to-harbor.sh` 추가 뒤). 38-istio 는 SC1091 note 만, 번들 배치로 `-x` 로 따라가면 경고 없음. 기준 커밋 `d6f45b9` 와 같다 |
| 번들 빌드(`ISTIO_LOCAL_IMAGES=1 build-in-container.sh 24.04 38-istio`) | 완료 (2026-11-07, charles-weed, Ubuntu 24.04). 차트 sha256 = 핀, 렌더링 단언 통과. **이미지 4개를 넣는 지금 빌드(`images/`, 3.1절)는 아직 실행하지 않았다** |
| `feed-istio-to-harbor.sh --dry-run` | 시험 번들(실제 매니페스트·차트, 가짜 blob)로 확인 (2026-11-10, ascp·asw3). 사전 확인은 Harbor `ping`·CA 검증까지 통과(ascp), skopeo 없음으로 멈춤(asw3) |
| **`feed-istio-to-harbor.sh` 실제 등록·재실행 멱등성** | **미검증** (4.6절). asw3 의 새 Harbor 에 아직 올리지 않았다 |
| `--dry-run --source harbor` / `--source local` (`install.sh`, `istio-configure.sh`) | 완료 (2026-11-07, charles-weed, root·클러스터 없이) |
| `verify-urls.sh` Istio 절 | 16/16 통과 (2026-11-07) |
| 단일 노드 실기 설치(`--source local`) + 판정 | 완료 (2026-11-08, charles-weed 단일 노드, Ubuntu 24.04). `install.sh` 23/0, HAProxy 경유 포함 `--check-only` 26/0. 그 뒤 VM 연결이 끊겨 local 경로의 재실행 멱등성은 보지 못했다 |
| istio-configure 실기(`--source local`) | 완료 (2026-11-08, charles-weed). 첫 판정 12/1(Wasm 판정 결함, 고침) → `--check-only` 13/0 |
| **Harbor 경로(`--source harbor`) 실기 설치 + 판정** | 완료 (2026-11-09, as2510-vanilla 3노드, k8s 1.36.4, 기존 Harbor). `install.sh` 27/0(HAProxy 경유 포함), `istio-configure.sh` 14/0. 이전 Istio 잔여물(CRD 15개 소유 annotation, webhook 2개)을 손으로 정리한 뒤의 결과다(4.6절, 12.1절) |
| 다른 릴리스가 남긴 Istio CRD·webhook | `install.sh` 는 정리하지 않고 사전 확인도 찾지 않는다. as2510-vanilla 에서는 12.1절 절차를 손으로 했다 |
| 버전·이미지 | `pilot-discovery`/`pilot-agent version -s` = `1.30.3`. 이미지 `<HARBOR>/uipath/istio/{pilot,proxyv2}:1.30.3-20260730_echo`, 다이제스트는 핀과 같다(`ba73c276…`, `9545f8dd…`) |
| HAProxy 경유 80/443/15021 | 완료 (charles-weed, as2510-vanilla). 443 은 사내 CA 로 검증해 200 `istio-smoke-ok` |
| 재실행 멱등성 | 완료 (as2510-vanilla). 두 번째 `install.sh`·`istio-configure.sh` 뒤 기존 파드 UID·재시작 수가 같고, pod-template-hash 가 같다. 늘어난 gateway 파드는 HPA 확장이다(12절) |
| Harbor 차트 대조 | as2510-vanilla Harbor 의 차트 4개가 다시 패키징돼 tgz sha256 이 핀과 달랐다. 내용 대조(4.3절)로 통과 |
| **hydrate 실행** | **미검증** (4.6절) |
| Harbor 재설치(asw2 → asw3, 2026-11-10) 뒤 `--source harbor` 재설치 | **미실시**. 새 Harbor 에 8개가 없어 `install.sh` 가 사전 확인에서 멈췄다(4.6절) |
| CA 파일(`certs.d`) 경로 | **미실행** (4.6절) |
| AS 라우팅(AS 설치 뒤) | **미검증**. Wasm 필터 적재와 smoke 응답까지만 봤다 |
| 에어갭(`airgap-on.sh`) | **미실시**. 두 환경 모두 인터넷에 연결된 상태였다 |
| Harbor 중단·에어갭에서 gateway 기동(`imagePullPolicy: IfNotPresent`, 5.2절) | **미검증**. as2510-vanilla 에서 노드별 첫 gateway 파드는 `IfNotPresent` 인데도 Harbor 에서 다시 받았다(원인 미확인). 같은 노드의 다음 파드들은 `already present on machine` 이었다. charles-weed `--source local` 경로는 수정 뒤 다시 실행하지 못했다 |
| `--uninstall` | **미실행**. CRD 가 남는다는 것은 핀 base 차트를 `helm template` 으로 렌더링해 확인했다(CRD 15개 모두 `helm.sh/resource-policy: keep`) |

---

## 12. 트러블슈팅

| 증상 | 원인 | 조치 |
|---|---|---|
| `Harbor 에 uipath/istio/pilot:<태그> 가 없다` | hydrate 도 `feed-istio-to-harbor.sh` 도 하지 않았거나(Harbor 를 새로 설치한 경우 포함), 다른 프로젝트·다른 AS 버전으로 했다 | 이 번들의 `./feed-istio-to-harbor.sh` 로 8개만 올리거나(4.2절), 상위 README 5.2 의 hydrate 를 `<HARBOR_HOSTNAME>/uipath` 로 실행한다. 프로젝트가 다르면 `site.env` 의 `ISTIO_HARBOR_PROJECT` |
| feed: `필요한 명령이 없다: skopeo` | 이 호스트에 skopeo 가 없다(예: asw3) | skopeo 를 OS 패키지로 설치하거나, skopeo·helm 이 있고 Harbor 에 닿는 다른 호스트(예: control plane)에서 실행한다(4.2절). Harbor 는 바뀌지 않았다 |
| feed: `Harbor 인증 실패` / `프로젝트 … 가 없거나 … 볼 수 없다` | 계정·비밀번호가 틀렸거나, 프로젝트가 없거나, 그 계정이 프로젝트 멤버가 아니다 | 계정을 확인한다. 프로젝트는 feed 가 만들지 않는다. 상위 README 5.2.3 대로 먼저 만든다 |
| feed: `skopeo copy 실패` / `helm push 실패` | push 권한이 없거나(pull 전용 robot), 네트워크·CA 문제다. 이미 올린 것은 남는다 | push 권한이 있는 계정으로 다시 실행한다. 없는 것만 올린다 |
| feed: 이미지 `다이제스트 … ≠ 핀` 경고 | 이미 있던 이미지(hydrate 사본 등)의 다이제스트가 원본과 다르다 | 정상이다. 덮어쓰지 않는다. `install.sh` 는 태그로 받는다(4.3절) |
| feed: 차트 `내용이 핀과 다르다` 실패 | Harbor 에 같은 태그의 다른 차트가 이미 있다. 다른 AS 버전으로 hydrate 했을 때 생긴다. `install.sh` 도 이 차트에서 멈춘다 | feed 는 덮어쓰지 않는다. 2.3절 절차로 `versions.env` 를 hydrate 한 AS 버전에 맞추거나, Harbor 관리자가 확인한 뒤 그 태그를 정리하고 다시 실행한다 |
| `Harbor 의 차트 ... 내용이 핀 차트와 다르다` | hydrate 한 AS 번들 버전과 `UIPATH_AS_VERSION` 이 다르다. tgz sha256 만 다른 것은 재패키징이라 통과한다(4.3절) | 2.3절 절차로 `versions.env` 를 맞추고 번들을 다시 빌드한다 |
| `containerd 가 ... 를 받지 못했다` | 노드가 Harbor CA 를 신뢰하지 않거나(`hosts.toml` 없음), private 인데 자격증명이 틀렸다 | `05-certs/deploy-certs.sh --local`(모든 노드는 `--nodes`). private 이면 `HARBOR_PULL_USER`/`HARBOR_PULL_PASSWORD` |
| `curl`·`openssl` 로는 Harbor 가 검증되는데 `crictl pull` 만 `x509: certificate signed by unknown authority` | containerd 는 기동할 때 읽은 OS 신뢰 저장소를 계속 쓴다. 그 뒤에 넣은 CA 는 모른다(as2510-vanilla 실측) | 그 노드에서 `sudo systemctl restart containerd`(실행 중인 컨테이너는 유지된다). 05-certs README 9절 |
| Harbor 노드 재부팅 뒤 `/api/v2.0/ping` 이 401 `'Authorization' should start with 'Harbor-Secret'` | Harbor 컨테이너 IP 가 바뀌었는데 Harbor nginx 가 `core` 를 예전 IP 로 들고 있어 요청이 jobservice 로 간다(as2510-vanilla 실측) | Harbor 호스트에서 `sudo docker restart nginx`(또는 `systemctl restart harbor.service`). 10-k8s `install.sh` 의 Harbor 주석과 같은 계열이다 |
| Wasm 적재·smoke 판정 직후 gateway 파드가 2~5개로 늘었다 | gateway 차트 기본 HPA(min 1/max 5, CPU 목표 80%, requests 100m). as2510-vanilla 에서는 istio-configure 적재와 판정용 smoke 적용 직후 HPA 가 "cpu resource utilization above target" 으로 1→3→5 로 늘렸다(metrics-server 가 없는 charles-weed 에서는 HPA 가 동작하지 않았다) | 5분 뒤 1개로 줄어든다. 고정하려면 gateway values 의 `autoscaling`·`resources` 를 조정한다(이 번들은 차트 기본값을 쓴다) |
| `검증용 이미지 묶음이 없다` (`--source local`) | `ISTIO_LOCAL_IMAGES=1` 로 빌드하지 않았거나 다른 디렉터리에 풀었다 | 두 tarball 을 같은 디렉터리에 풀거나 `ISTIO_LOCAL_IMAGES_DIR` 를 준다 |
| `TLS 원본이 없다` / `SAN 에 ... 이 없다` | `/opt/pki/as` 에 05-certs 산출물이 없거나 `AS_FQDN` 이 인증서와 다르다 | `05-certs/deploy-certs.sh --local`, 다른 위치면 `ISTIO_TLS_CERT_DIR`. `AS_FQDN` 을 바꿨으면 인증서를 다시 발급한다 |
| `NodePort 를 이미 다른 Service 가 쓴다` | 다른 Service 가 31223/31164/31956 을 쓴다 | 그 Service 를 바꾸거나 `site.env` 의 `ISTIO_NODEPORT_*` 를 바꾸고 38-istio·40-haproxy 를 함께 다시 빌드한다 |
| HAProxy 백엔드가 DOWN (gateway 는 Available) | 40-haproxy 를 Istio 설치 전 값으로 띄웠고 NodePort 가 다르다 | 40-haproxy `install.sh` 를 다시 실행한다. `kubectl -n istio-system get svc istio-ingressgateway` 의 NodePort 와 `curl -s 'http://127.0.0.1:8404/;csv'` 를 비교한다 |
| `pilot-discovery version` 판정 실패 | 다른 태그의 이미지로 떠 있다 | `kubectl -n istio-system get deploy istiod -o jsonpath='{.spec.template.spec.containers[0].image}'` 를 `<hub>/pilot:<ISTIO_TAG>` 와 비교한다 |
| Wasm 필터 적재 판정 실패 | plugin-http 가 Ready 가 아니거나 hook Job 이 url 을 바꾸지 못했다 | `kubectl -n istio-system get pods,jobs`, `kubectl -n istio-system logs job/update-wasm-plugin-version`, gateway 로그의 `wasm` 줄을 본다. 고친 뒤 `istio-configure.sh` 를 다시 실행한다 |
| `helm upgrade --install istio-base` 가 `... exists and cannot be imported into the current release: invalid ownership metadata; annotation validation error: key "meta.helm.sh/release-name" must equal "istio-base": current value is "base"` 로 멈춘다 | 다른 릴리스 이름(예: `base`)으로 Istio 를 설치했다가 지운 클러스터다. base 차트의 CRD 는 `helm.sh/resource-policy: keep` 이라 uninstall 뒤에도 남고, 소유 annotation 은 이전 릴리스를 가리킨다. Helm 은 소유 annotation 이 다른 기존 리소스를 넘겨받지 않는다 | CRD 를 지우지 않고(지우면 그 CRD 의 리소스도 모두 지워진다) 소유 annotation 을 `istio-base` / `istio-system` 으로 바꾼다(12.1절). Helm 3.2 부터 annotation·label 이 맞는 기존 리소스를 릴리스로 받아들인다(https://github.com/helm/helm/pull/7649) |
| 파드 생성이나 Istio 리소스 생성이 `failed calling webhook "...istio.io": ... service "istiod" not found` 류로 거부된다 | 이전 istiod 가 남긴 `failurePolicy: Fail` webhook(`istio-sidecar-injector`, `istio-validator-istio-system`)이 없는 `istio-system/istiod` 를 가리킨다. 사이드카 주입 대상 파드와 Istio 리소스가 거부된다 | webhook 의 대상 Service 가 없는지 확인하고, YAML 을 백업한 뒤 istiod 를 설치하기 바로 전에 지운다. istiod 차트가 같은 이름으로 다시 만든다(12.1절) |
| `--uninstall` 이 `custom-istio-configure 릴리스가 있다` 로 멈춘다 | istio-configure 를 먼저 지워야 한다 | `sudo ./istio-configure.sh --uninstall` 후 다시 실행한다 |
| `--uninstall` 뒤에도 Istio CRD 와 Gateway/VirtualService 등이 남는다 | 핀 base 차트의 CRD 15개가 모두 `helm.sh/resource-policy: keep` 이다(`helm template` 으로 확인). helm 은 keep 리소스를 지우지 않는다 | 의도한 동작이다. 모두 지우려면 `kubectl get crd -o name \| grep '\.istio\.io$' \| xargs -r kubectl delete`(그 CRD 의 리소스도 모두 지워진다). 같은 클러스터에 다시 설치하면 `istio-base` 가 남은 CRD 를 그대로 넘겨받는다 |

### 12.1 이전 Istio 잔여물 정리 (다른 릴리스 이름으로 설치했던 클러스터)

as2510-vanilla(2026-11-09)에서 손으로 한 절차다. `install.sh` 는 이 정리를 하지 않는다. 위 표의 두 오류 문구는 Helm·Kubernetes 의 동작에서 옮긴 것이다. as2510-vanilla 에서는 설치 전에 정리해서 이 오류를 직접 보지는 않았다.

1. 이전 Istio 릴리스가 남아 있지 않은지 본다. `helm list -A` 에 Istio 릴리스(예: `base`, `istiod`)가 있으면 다른 Istio 가 아직 설치된 것이다. 이 절차를 쓰지 말고 그 Istio 를 먼저 지운다.
2. 남은 CRD 의 소유 릴리스를 본다.
   ```bash
   kubectl get crd -o custom-columns='NAME:.metadata.name,RELEASE:.metadata.annotations.meta\.helm\.sh/release-name,RELEASE_NS:.metadata.annotations.meta\.helm\.sh/release-namespace,POLICY:.metadata.annotations.helm\.sh/resource-policy' \
     | awk 'NR==1 || $1 ~ /\.istio\.io$/'
   ```
3. `RELEASE` 가 `istio-base` 가 아니면 넘겨받게 바꾼다. CRD 는 지우지 않는다. as2510-vanilla 에서는 15개 모두 `base` → `istio-base` 였다.
   ```bash
   for c in $(kubectl get crd -o name | grep '\.istio\.io$'); do
     kubectl annotate --overwrite "$c" meta.helm.sh/release-name=istio-base meta.helm.sh/release-namespace=istio-system
     kubectl label --overwrite "$c" app.kubernetes.io/managed-by=Helm
   done
   ```
4. webhook 이 없는 istiod 를 가리키는지 본다.
   ```bash
   kubectl get mutatingwebhookconfigurations,validatingwebhookconfigurations \
     -o custom-columns='NAME:.metadata.name,SVC:.webhooks[*].clientConfig.service.name,SVC_NS:.webhooks[*].clientConfig.service.namespace,POLICY:.webhooks[*].failurePolicy' \
     | grep -iE '^NAME|istio'
   kubectl -n istio-system get svc istiod          # NotFound 면 위 webhook 은 대상이 없다
   ```
5. 대상이 없고 `POLICY` 가 `Fail` 이면 YAML 을 백업하고 istiod 를 설치하기 바로 전에 지운다. 지운 뒤 설치할 때까지의 빈 시간을 줄이려는 것이다. istiod 차트가 같은 이름으로 다시 만든다(as2510-vanilla: 04:35:39Z 에 지움, istiod 설치 05:07:48Z 에 다시 생김).
   ```bash
   kubectl get mutatingwebhookconfiguration istio-sidecar-injector -o yaml > istio-sidecar-injector.bak.yaml
   kubectl get validatingwebhookconfiguration istio-validator-istio-system -o yaml > istio-validator-istio-system.bak.yaml
   kubectl delete mutatingwebhookconfiguration istio-sidecar-injector
   kubectl delete validatingwebhookconfiguration istio-validator-istio-system
   # 바로 이어서 install.sh 를 실행한다(5절, private 프로젝트면 4.5절 자격증명)
   ```
6. 다른 클러스터 리소스(ClusterRole·ClusterRoleBinding 등)도 Helm 이 같은 소유권 검사를 한다. as2510-vanilla 의 ClusterRole·ClusterRoleBinding 6개는 이미 `istiod` / `istio-system` 소유라 그대로 넘겨받았다. 소유 릴리스가 `istiod`·`istio-ingressgateway` 와 다르면 helm 오류에 나온 리소스를 3번처럼 바꾼다.

- base 차트의 `istiod-default-validator`(ValidatingWebhookConfiguration)는 `failurePolicy: Ignore` 라 대상이 없어도 요청을 막지 않는다. 다만 다른 릴리스가 남겼다면 같은 소유권 오류가 날 수 있다.
- `install.sh` 의 사전 확인은 NodePort 충돌은 찾지만, 다른 릴리스가 소유한 Istio CRD 나 대상 없는 webhook 은 찾지 않는다. 이 상태에서 실행하면 namespace·TLS secret·pull secret 을 만든 뒤 helm 단계에서 멈춘다.

---

## 13. 다음 단계

```
10-k8s → 60-cilium → 05-certs → 50-nfs-csi → 40-haproxy → 30-harbor
  → (AS hydrate, 상위 README 5.2) 또는 [38-istio feed-istio-to-harbor.sh, 상위 README 5.2.8]
  → [38-istio install.sh] → [38-istio istio-configure.sh] → 40-haproxy install.sh 재실행
  → [38-istio install.sh --check-only] → AS input.json(exclude_components, ingress) → uipathctl prereq ...
```

AS `input.json` 의 `ingress` 블록과 확인 명령은 상위 README 5.1절과 5.3.6절에 있다.
