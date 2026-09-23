# 30-harbor — Harbor 컨테이너 레지스트리 오프라인 설치

사내 컨테이너 레지스트리. UiPath Automation Suite 의 이미지 저장소로 쓴다.
HTTPS 전용(443), 내장 PostgreSQL · Redis 사용.

Ubuntu 24.04 에어갭 노드에서 **판정 26/26 통과**와 **실제 재부팅 후 9/9 자동 복구**를
확인한 구성이다(9절).

---

## 1. 공식 오프라인 인스톨러를 그대로 쓴다

Harbor 는 이미지까지 포함한 공식 오프라인 인스톨러를 제공한다. 우리가 이미지를
개별로 모으지 않는 이유다.

```
harbor-offline-installer-v2.15.2.tgz   (696MB)
├── harbor/harbor.v2.15.2.tar.gz       전체 이미지
├── harbor/install.sh                  이미지 load + prepare + compose up
├── harbor/prepare                     harbor.yml -> compose/설정 생성
├── harbor/common.sh
└── harbor/harbor.yml.tmpl
```

이미지를 직접 수집하면 업스트림이 검증한 조합을 재구성하는 셈이고, 버전이
어긋날 위험만 생긴다. 번들은 **인스톨러 tgz + 우리 래퍼**로 구성한다.

`build-bundle.sh` 는 받은 tgz 안에 `harbor.<ver>.tar.gz` 가 있는지 확인한다.
없으면 온라인 인스톨러를 받은 것이고, 그것은 설치 중 레지스트리에서 pull 하므로
에어갭에서 쓸 수 없다.

번들이 추가로 담는 것은 다음 네 개다.

| 파일 | 왜 필요한가 |
|---|---|
| `harbor.yml.tmpl` | 업스트림 기본값이 에어갭에 맞지 않다(2절) |
| `harbor-openssl.cnf.tmpl` | 타깃 SAN 으로 인증서 생성 |
| `harbor-start.sh` | 기동 순서 보장(3절) |
| `harbor.service` | 재부팅 시 자동 기동(3절) |

---

## 2. 설정에서 바꾼 것

업스트림 `harbor.yml.tmpl` 을 그대로 쓰지 않는다. 에어갭에서 문제가 되는 항목이 있다.

| 항목 | 값 | 이유 |
|---|---|---|
| `http:` 절 | **정의하지 않음** | 정의하면 평문으로도 서비스되고, docker 가 평문 레지스트리로 붙으려 해 `insecure-registries` 설정이 필요해진다 |
| `trivy.skip_update` | `true` | 에어갭에서 취약점 DB 를 갱신할 수 없다. `false` 면 기동 시 github 로 나가려 하다 실패하고 계속 재시도해 `airgap-fwd-other` 카운터를 올린다 |
| `trivy.offline_scan` | `true` | 같은 이유 |
| `harbor_admin_password` | **무작위 생성** | 기본값 `Harbor12345` 를 쓰지 않는다 |
| `database.password` | **무작위 생성** | 같은 이유 |
| `data_volume` | `/data/harbor` | 별도 볼륨을 붙이기 쉽게 분리 |

trivy 서비스 자체는 기동하지 않는다(`--with-trivy` 를 주지 않는다). 에어갭에서
DB 갱신이 안 되면 실효가 없고 컨테이너와 메모리만 늘어난다. 실제 기동되는 서비스는
9개다.

```
log  redis  registry  postgresql  core  portal  proxy  registryctl  jobservice
```

`_version` 은 인스톨러가 제공하는 `harbor.yml.tmpl` 의 값을 읽어 그대로 채운다.
다르면 `prepare` 가 "please make sure the version is correct" 로 거부한다.

생성된 `harbor.yml` 은 admin·DB 비밀번호를 담으므로 `0600` 으로 둔다.

---

## 3. systemd 유닛이 필요한 이유 — 기동 순서

**이 단계에서 가장 중요한 부분이다.** Docker 의 재시작 정책만으로는 Harbor 가
재부팅을 넘기지 못한다.

`harbor-log` 를 제외한 8개 컨테이너는 logging driver 가
`syslog / tcp://localhost:1514` 이고, 그 포트는 `harbor-log` 가 제공한다.
Docker 데몬의 재시작 정책은 compose 의 `depends_on` 순서를 지키지 않고 부팅 시
9개를 동시에 기동한다. `harbor-log` 가 1514 를 바인드하기 전에 나머지가 뜨면
컨테이너 생성 단계에서 이렇게 죽는다.

```
failed to initialize logging driver:
dial tcp 127.0.0.1:1514: connect: connection refused
```

exit 128 이 되고, 재시도 백오프를 소진한 뒤 **영구 정지**한다. 실제로 9개 중 8개가
미기동되어 443 리스너가 사라진 사례가 있다(그 영향으로 ingress gateway 가
ImagePullBackOff 가 되고 haproxy 백엔드가 전멸했다).

compose 의 `depends_on: - log` 는 "컨테이너 시작"까지만 보장하고 **포트 수신 준비를
기다리지 않는다.** 그래서 대기를 명시해야 한다.

`harbor-start.sh` 가 하는 일:

```
1) harbor-log 만 단독 기동
2) 127.0.0.1:1514 가 실제로 연결을 받을 때까지 대기 (최대 60초)
3) 나머지 전체 기동 (compose depends_on 순서를 따른다)
4) 모든 서비스가 running 인지 확인 (최대 180초). 아니면 해당 서비스 로그 출력
```

`harbor.service` 는 `Type=oneshot` + `RemainAfterExit=yes` 로 이 스크립트를 실행한다.
`ExecStop` 은 `docker compose stop` 이다 — `down` 은 네트워크와 컨테이너를 삭제해
재기동이 느려지고, `harbor-db`(PostgreSQL)의 정상 종료 시간도 필요하다.

`40-haproxy` 는 의존 대상이 없어 재시작 정책만으로 충분했다. Harbor 는 다르다.

---

## 4. 설치

```bash
# 빌드 호스트(인터넷 O) — 696MB 를 받는다
cd offline-install/30-harbor && ./build-bundle.sh

# 타깃 노드(에어갭)
scp bundle/harbor-v2.15.2.tar.gz{,.sha256} <타깃>:~/
sha256sum -c harbor-v2.15.2.tar.gz.sha256
tar xzf harbor-v2.15.2.tar.gz && cd harbor-v2.15.2

sudo ../offline-install/90-verify/airgap-on.sh   # 검증 목적
sudo ./install.sh                                 # 수 분 소요
```

옵션은 `--check-only`, `--test-restart`, `--uninstall`(데이터 보존) 이다.

### 443 충돌 — haproxy 와 같은 노드에 둘 수 없다

Harbor 는 443 을 직접 점유한다. `40-haproxy` 의 `l4` 컨테이너도 443 을 쓰므로
**같은 노드에 둘을 함께 올릴 수 없다.** `install.sh` 가 사전에 잡아 중단한다.

레지스트리는 클러스터 밖의 별도 호스트에 두는 것을 권장한다. 클러스터가 자신의
이미지 저장소에 의존하는 순환을 피할 수 있다.

### 접속 이름과 주소

접속 이름은 `site.env` 의 `HARBOR_HOSTNAME` 을 쓴다. **주소는 항상 설치 노드
자신의 IP** 다. `site.env` 의 `HARBOR_PRIVATE_IP` 를 쓰지 않는다 — 그 값은 "이미
운영 중인 다른 Harbor 에 접근할 주소"라는 뜻이고, 이 단계는 여기에 Harbor 를 새로
설치하는 것이다. 혼용하면 `/etc/hosts` 가 다른 호스트를 가리켜 `docker login` 이
x509 오류로 실패한다(실측으로 겪은 문제).

`/etc/hosts` 에 그 이름이 다른 IP 로 이미 매핑돼 있으면, `install.sh` 가 경고를
남기고 이 노드로 바로잡는다. 원본은 `/etc/hosts.bak.*` 에 보관한다.
다른 Harbor 를 계속 쓰려면 `HARBOR_HOSTNAME` 을 다른 이름으로 바꿀 것.

---

## 5. TLS

인증서는 타깃에서 만든다. SAN 에 타깃 호스트명·IP 가 들어가야 하고 그 값은
타깃에서만 알 수 있다.

**`insecure-registries` 를 쓰지 않는다.** TLS 검증을 통째로 끄는 설정이다.
대신 docker 가 이 레지스트리의 CA 만 신뢰하도록 배치한다.

```
/etc/docker/certs.d/<HARBOR_HOSTNAME>/ca.crt
```

이것이 없으면 `docker login` 이 `x509: certificate signed by unknown authority`
로 실패한다.

### 다른 노드에서 쓰려면

```bash
# 1) 이름 해석
echo "<harbor노드IP> <HARBOR_HOSTNAME>" | sudo tee -a /etc/hosts

# 2) docker 신뢰
sudo install -D -m 0644 harbor.crt /etc/docker/certs.d/<HARBOR_HOSTNAME>/ca.crt
```

---

## 6. k8s(containerd)에서 쓰려면

kubelet 은 docker 가 아니라 containerd 를 쓴다. `certs.d` 는 containerd 에
적용되지 않으므로 별도 설정이 필요하다.

```bash
# 1) CA 를 호스트 신뢰 저장소에 추가
sudo install -m 0644 harbor.crt /usr/local/share/ca-certificates/harbor.crt
sudo update-ca-certificates
sudo systemctl restart containerd

# 2) 또는 containerd 의 레지스트리 설정으로 명시
sudo mkdir -p /etc/containerd/certs.d/<HARBOR_HOSTNAME>
sudo tee /etc/containerd/certs.d/<HARBOR_HOSTNAME>/hosts.toml >/dev/null <<EOF
server = "https://<HARBOR_HOSTNAME>"
[host."https://<HARBOR_HOSTNAME>"]
  capabilities = ["pull", "resolve"]
  ca = "/etc/containerd/certs.d/<HARBOR_HOSTNAME>/ca.crt"
EOF
sudo install -m 0644 harbor.crt /etc/containerd/certs.d/<HARBOR_HOSTNAME>/ca.crt
```

2번 방식을 쓰려면 `/etc/containerd/config.toml` 에 `config_path` 가 지정돼 있어야
한다. `10-k8s` 가 생성하는 기본 설정에는 없으므로 추가해야 한다.

비공개 프로젝트에서 pull 하려면 `imagePullSecrets` 도 필요하다.

```bash
kubectl create secret docker-registry harbor-cred \
  --docker-server=<HARBOR_HOSTNAME> \
  --docker-username=<robot계정> --docker-password=<토큰>
```

운영에서는 admin 이 아니라 **robot 계정**을 쓸 것.

---

## 7. 판정 26항목

설정·서비스 확인에 더해 **실제 레지스트리 왕복**을 수행한다.

```
docker / compose 사용 가능
harbor.yml · compose 파일(prepare 완료) · 인증서 · 자격증명(0600) · 데이터 디렉터리
인증서 SAN 에 접속 이름 포함
harbor.service 설치됨 / enabled / harbor-start.sh 실행 가능
compose 서비스 전부 running          <- 9개 전수 확인
harbor-log 이 1514 수신
호스트 443 수신
80 이 HTTPS 로 리다이렉트
API /health 응답 + 모든 컴포넌트 healthy
  -- 레지스트리 왕복 --
admin API 인증 -> /etc/hosts 매핑 -> certs.d 배치 -> docker login
프로젝트 생성(API) -> 태깅 -> docker push -> (로컬 캐시 삭제) -> docker pull
API 에 아티팩트 등록 확인
```

몇 가지 설계 의도가 있다.

- **`80` 은 닫혀 있기를 기대하지 않는다.** `harbor.yml` 에 `http:` 절을 넣지 않아도
  Harbor 는 항상 80 을 publish 한다(compose 템플릿에 `80:8080` 이 박혀 있다).
  처음에 "80 이 닫혀 있어야 한다"로 판정했다가 실패했다. 확인해야 할 실제 보안
  속성은 "평문으로 서비스하지 않고 HTTPS 로 보낸다"이고, 실측 결과 `HTTP 308 ->
  https://<host>:443/` 이다.
- **개별 컴포넌트까지 healthy 를 본다.** 전체 `status` 만 보면 일부 컴포넌트가
  죽어도 통과할 수 있다.
- **pull 전에 로컬 캐시를 지운다.** 지우지 않으면 pull 이 성공해도 레지스트리에서
  받아온 것인지 알 수 없다.
- **push 원본은 Harbor 자신의 이미지를 재사용한다.** 에어갭이라 새로 받을 수 없고,
  별도 이미지를 번들에 넣으면 용량만 늘어난다.

---

## 8. 재기동 검증

```bash
sudo ./install.sh --test-restart
```

`systemctl restart harbor` 와 `systemctl restart docker` 를 각각 수행하고 전
서비스 running 복귀 · 443 재수신 · API 응답을 확인한다.

데몬 재시작이 진짜 시험이다. 데몬이 내려가면 9개 컨테이너가 동시에 다시 뜨려 하고,
`harbor-log` 가 1514 를 잡기 전에 나머지가 뜨면 exit 128 로 죽는다(3절).

실제 노드 재부팅으로도 확인했다 — 재부팅 후 `harbor.service` active, 9/9 running,
API 200, 재판정 26/26.

---

## 9. 검증 상태

2026-09-23 에 Ubuntu 24.04 에어갭 노드에서 수행했다.

| 항목 | 결과 |
|---|---|
| 번들 빌드 | **완료** (697MB, 공식 오프라인 인스톨러 포함) |
| 에어갭 설치 + 판정 | **통과 26/26** |
| 서비스 기동 | **9/9 running**, 모든 컴포넌트 healthy |
| 레지스트리 왕복(login·push·pull·API) | **통과** |
| systemd 재기동 / docker 데몬 재시작 | **통과** |
| **실제 노드 재부팅** | **통과** (9/9 자동 복구, 재판정 26/26) |
| `airgap-fwd-other` 카운터 | **0** |

검증 중 발견해 고친 것은 세 가지다.

1. **Harbor 주소를 `HARBOR_PRIVATE_IP` 로 잡았다** — `/etc/hosts` 가 기존 Harbor
   (다른 호스트)를 가리켜 `docker login` 이 x509 오류로 실패했다. 설치 노드 자신의
   IP 를 쓰도록 고치고, 충돌하는 매핑을 교정하는 로직을 넣었다(4절).
2. **`80` 이 닫혀 있다고 가정했다** — Harbor 는 항상 80 을 publish 한다.
   리다이렉트 확인으로 바꿨다(7절).
3. **`getent` 실패로 스크립트가 조용히 죽었다** — `common.sh` 의 `set -e` +
   `pipefail` 조합에서 `CURRENT_MAP="$(getent hosts ... | awk ... | head -1)"` 가
   이름을 못 찾으면 exit 2 가 되어 **로그도 남기지 않고** 종료됐다. `|| true` 를
   붙여 해결했다. 같은 계열의 함정이 `ctr images ls | grep -q` 오탐(10-k8s)과 동일하다.

---

## 10. 트러블슈팅

| 증상 | 원인 | 조치 |
|---|---|---|
| 재부팅 후 대부분의 컨테이너가 없음, `exit 128` + `dial tcp 127.0.0.1:1514` | 기동 순서 미보장 | 3절. `harbor.service` 가 enabled 인지 확인 |
| `docker login` 이 `x509: certificate signed by unknown authority` | `certs.d` 에 CA 미배치 | 5절 |
| `docker login` 이 되는데 다른 Harbor 로 붙는다 | `/etc/hosts` 가 다른 IP 를 가리킨다 | 4절. `getent hosts <이름>` 으로 확인 |
| `prepare` 가 `please make sure the version is correct` | `harbor.yml` 의 `_version` 불일치 | `install.sh` 가 인스톨러 템플릿에서 읽어 채운다 |
| 설치 중 이미지 pull 시도 후 실패 | 온라인 인스톨러를 받았다 | 1절. `build-bundle.sh` 가 사전에 잡는다 |
| `airgap-fwd-other` 가 0 이 아니다 | trivy 가 DB 갱신을 시도한다 | 2절. `skip_update: true` 확인 |
| 443 바인드 실패 | `l4`(haproxy) 등이 점유 | 4절. 별도 호스트 사용 권장 |
| 스크립트가 아무 로그 없이 종료 | `set -e` + `pipefail` 에서 명령 치환 실패 | 9절 3번. 해당 파이프라인에 `|| true` |

로그 위치:

- 인스톨러: `/var/log/harbor-install.log`
- 서비스: `cd /opt/harbor && docker compose logs <서비스>`
- 기동 스크립트: `journalctl -u harbor`
- Harbor 자체 로그: `/var/log/harbor/`

---

## 11. 다음 단계

```
10-k8s  →  60-cilium  →  50-nfs-csi  →  40-haproxy  →  [30-harbor]  →  20-minio
```

레지스트리를 UiPath AS 에 쓰려면 프로젝트와 robot 계정을 준비한다.
`00-common/publish-images.sh` 로 커스텀 이미지를 사내 Harbor 에 올릴 수도 있다
(`PUBLISH_REGISTRY` / `PUBLISH_NAMESPACE` 환경변수).
