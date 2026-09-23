# 05-certs — 사내 CA 와 서비스 인증서

CA 하나로 UiPath Automation Suite · Harbor · MinIO · SQL Server · PostgreSQL 의
서버 인증서를 발급하고, 모든 노드에 CA 를 신뢰시킨다.

에어갭 노드 3대에서 발급·배포·바인딩을 검증했다(8절).

---

## 1. 왜 CA 를 하나만 두는가

서비스마다 자가서명 인증서를 쓰면 **클라이언트가 인증서 5개를 각각 신뢰**해야 한다.
노드가 늘어나면 배포 대상이 `노드수 x 서비스수` 로 커지고, 인증서를 갱신할 때마다
모든 노드를 다시 건드려야 한다.

CA 를 하나 두면 클라이언트는 **CA 1개만** 신뢰하면 되고, 서버 인증서를 갱신해도
클라이언트를 손대지 않는다.

```
        ┌──────────────────────────┐
        │  Vanilla K8s Internal CA │  ← 노드에는 ca.crt 만 배포
        └────────────┬─────────────┘
     ┌──────┬────────┼────────┬────────┐
    as   harbor    minio    mssql    pgsql      ← 서버 인증서 (키는 각 호스트)
```

**`ca.key` 는 발급 호스트에만 둔다.** 노드에 두면 그 노드가 침해될 때 PKI 전체가
무너진다. `deploy-certs.sh` 는 전송 시 `ca.key` 를 명시적으로 제외한다.

---

## 2. 구성

```
05-certs/
├── make-certs.sh      CA + 서버 인증서 발급 (관리 호스트)
├── deploy-certs.sh    CA 신뢰 설정 + 인증서 배치 (각 노드)
└── out/               발급물. git 추적 제외
    ├── ca/ca.crt ca.key
    ├── as/tls.crt tls.key fullchain.crt ca.crt
    ├── harbor/harbor.crt harbor.key ca.crt
    ├── minio/public.crt private.key ca.crt
    ├── mssql/mssql.pem mssql.key ca.crt
    └── pgsql/server.crt server.key ca.crt
```

번들(tar.gz)이 없다. `openssl` 은 Ubuntu 기본 설치에 포함되므로 받아올 것이 없고,
에어갭에서도 그대로 실행된다.

### 파일명은 서비스가 기대하는 이름을 쓴다

| 서비스 | 파일명 | 이유 |
|---|---|---|
| MinIO | `public.crt` / `private.key` | MinIO 가 이 이름을 찾는다. 바꿀 수 없다 |
| Harbor | `harbor.crt` / `harbor.key` | `harbor.yml` 이 참조 |
| SQL Server | `mssql.pem` / `mssql.key` | `mssql.conf` 가 참조 |
| PostgreSQL | `server.crt` / `server.key` | `ssl_cert_file` 이 참조 |
| AS | `tls.crt` / `tls.key` + `fullchain.crt` | k8s TLS Secret 관례 |

`fullchain.crt`(서버 인증서 + CA)도 함께 만든다. ingress 컨트롤러 등은 체인을
한 파일로 요구한다.

---

## 3. 발급

```bash
# 1) 호스트명을 먼저 채운다
cd offline-install/00-common
cp site.env.example site.env
vi site.env     # AS_FQDN, HARBOR_HOSTNAME, MINIO_HOSTNAME, MSSQL_HOSTNAME, PG_HOSTNAME

# 2) 발급
cd ../05-certs && ./make-certs.sh
```

호스트명이 비어 있는 서비스는 건너뛴다. 어떤 것을 건너뛰었는지 출력한다.

| 옵션 | 동작 |
|---|---|
| (없음) | 멱등. 이미 있는 인증서는 그대로 두고 없는 것만 발급 |
| `--check-only` | 체인·키 짝·SAN·만료만 검증 |
| `--force-leaf` | 서버 인증서만 재발급. CA 유지 |
| `--rotate-ca` | CA 까지 재생성. **기존 인증서 전부 무효**. 기존 CA 는 백업 |

### SAN 설계

이름과 IP 를 모두 넣는다. 하나만 넣으면 다른 방식으로 접속할 때 거부된다.

```
DNS:<호스트명>, DNS:localhost, IP:<노드IP>, IP:127.0.0.1
```

**와일드카드는 두 서비스에만** 넣는다. 공격면을 줄이기 위해 필요한 곳만 준다.

| 서비스 | 와일드카드 | 이유 |
|---|---|---|
| `as` | `*.<AS_FQDN>` | AS 는 `alm.<fqdn>`, `monitoring.<fqdn>` 등 하위 이름을 쓴다 |
| `minio` | `*.<MINIO_HOSTNAME>` | 가상 호스트 스타일 버킷 주소(`<bucket>.<host>`) |

### 유효기간과 키 길이

| 대상 | 기간 | 키 |
|---|---|---|
| CA | 3650일(10년) | 4096 |
| 서버 인증서 | 825일 | 2048 |

CA 를 길게 두는 이유는 교체할 때 모든 클라이언트를 다시 건드려야 하기 때문이다.
서버 인증서 825일은 공개 신뢰 CA 의 상한과 같은 값이다. 사내 CA 는 더 길게도
되지만, 갱신 절차를 주기적으로 실제로 돌려보는 편이 안전하다 — 만료 경보를
놓쳤을 때의 피해가 크다.

서버 키를 2048 로 두는 이유는 TLS 핸드셰이크마다 서명 검증 비용이 들고 2048 이
여전히 표준 강도이기 때문이다. `CA_BITS` / `LEAF_BITS` / `LEAF_DAYS` 환경변수로
바꿀 수 있다.

### 확장(extension) 설계

```
basicConstraints = CA:FALSE
keyUsage         = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
```

`keyEncipherment` 가 필요하다. **SQL Server 는 키 교환용(`AT_KEYEXCHANGE`)
인증서를 요구**하며 이 비트가 없으면 TLS 를 켜지 못한다.

CN 도 접속 이름과 같게 넣는다. SAN 만 보는 클라이언트가 대부분이지만
SQL Server 는 CN 을 보는 클라이언트가 있다.

CSR 의 확장을 그대로 신뢰하지 않는다(`-copy_extensions` 미사용). 서명 시
`-extfile` 로 확장을 명시해, 요청자가 임의 확장을 끼워넣지 못하게 한다.

CA 에는 `pathlen:0` 을 건다. 중간 CA 를 쓰지 않는 구성이므로 하위 CA 발급을
막아 오용을 줄인다.

---

## 4. 배포 — 각 노드에 CA 신뢰시키기

```bash
# 이 호스트에
sudo ./deploy-certs.sh --local

# SSH 로 여러 노드에 (master · worker 모두)
./deploy-certs.sh --nodes 'cp-node,worker-01,worker-02'
./deploy-certs.sh --nodes-file nodes.txt
./deploy-certs.sh --nodes '...' --ssh-user ubuntu --ssh-key ~/.ssh/id_rsa
```

하는 일 네 가지다.

| # | 대상 | 경로 |
|---|---|---|
| 1 | OS 신뢰 저장소 | `/usr/local/share/ca-certificates/` + `update-ca-certificates` |
| 2 | docker | `/etc/docker/certs.d/<레지스트리>/ca.crt` |
| 3 | **containerd (k8s)** | `/etc/containerd/certs.d/<레지스트리>/hosts.toml` + `config_path` |
| 4 | 서비스 인증서 | `/opt/pki/<서비스>/` |

### containerd 가 핵심이다

**kubelet 은 docker 가 아니라 containerd 를 쓴다.** `/etc/docker/certs.d` 는
k8s 이미지 pull 에 아무 영향이 없다. 파드가 사내 레지스트리에서 이미지를
받으려면 containerd 쪽 설정이 있어야 한다.

그런데 containerd 는 기본값으로 `config_path` 가 비어 있어 `certs.d` 를 읽지
않는다. `deploy-certs.sh` 가 이 값을 설정하고 containerd 를 재시작한다.

**단순 sed 로 바꾸면 안 된다.** 두 가지 함정이 있다(둘 다 실측).

1. containerd 2.x(config version 4)에서 이 키는
   `[plugins.'io.containerd.cri.v1.images'.registry]` 아래에 있다.
   1.x 의 `io.containerd.grpc.v1.cri` 가 아니다.
2. 기본 설정에 `config_path` 라는 이름이 **두 곳**에 나온다(하나는 NRI 등
   다른 플러그인용). 전역 치환하면 엉뚱한 곳을 고친다.

그래서 해당 섹션의 범위를 찾아 그 안의 첫 `config_path` 만 바꾼다. 원본은
`/etc/containerd/config.toml.bak.*` 에 남긴다.

```toml
[plugins.'io.containerd.cri.v1.images'.registry]
  config_path = '/etc/containerd/certs.d'
```

containerd 재시작은 실행 중인 파드에 영향을 주지 않는다(파드는 shim 이 들고
있다). 검증에서 재시작 후 노드 Ready 와 파드 상태를 확인했다.

### `insecure-registries` 를 쓰지 않는다

TLS 검증을 통째로 끄는 설정이다. CA 를 신뢰시키면 검증을 유지하면서 사내
레지스트리를 쓸 수 있다.

---

## 5. 서비스 바인딩

배포 후 각 서비스의 `install.sh` 를 실행하면(또는 재실행하면) `/opt/pki` 의
인증서를 자동으로 쓴다. 없으면 기존처럼 자가서명을 만든다 — 05-certs 를 쓰지
않아도 각 단계가 독립적으로 동작한다.

| 서비스 | 바인딩 방식 |
|---|---|
| `20-minio` | `/certs/{public.crt,private.key}` + `/certs/CAs/ca.crt` |
| `30-harbor` | `harbor.yml` 의 `certificate`/`private_key`. docker 신뢰에는 **CA** 를 넣는다 |
| `70-mssql` | `mssql.conf` 의 `network.tlscert`/`tlskey` (아래) |
| `80-postgresql` | `ssl_cert_file`/`ssl_key_file` |

Harbor 의 docker 신뢰에 서버 인증서가 아니라 CA 를 넣는 것이 중요하다.
서버 인증서를 넣으면 갱신할 때마다 모든 노드를 고쳐야 한다.

### SQL Server 는 TLS 설정이 따로 필요하다

인증서를 주지 않으면 SQL Server 는 기동 시 자가서명 인증서를 스스로 만든다.
암호화는 되지만 클라이언트가 검증할 수 없어 매번 `TrustServerCertificate=true`
를 써야 한다.

컨테이너에서는 `mssql-conf` 명령을 쓸 수 없으므로 `/var/opt/mssql/mssql.conf`
를 직접 쓴다. 이 경로는 우리 호스트 볼륨이다.

```ini
[network]
tlscert = /var/opt/mssql/certs/mssql.pem
tlskey = /var/opt/mssql/certs/mssql.key
tlsprotocols = 1.2
forceencryption = 0
```

요구사항이 까다롭다(Microsoft 문서 + 실측).

- 인증서·키가 **mssql 사용자 소유**여야 한다 — 컨테이너 uid/gid = `10001:10001`
- 파일 권한 **0600**, 디렉터리 **0700**
- 키는 PEM(PKCS#8). `openssl` 산출물이 이 형식이다
- **CN** 이 접속 FQDN 과 같아야 한다

`forceencryption` 은 기본 `0`(클라이언트가 선택)이다. `1` 로 두면 암호화를
지원하지 않는 기존 클라이언트가 전부 끊긴다. `site.env` 의
`MSSQL_FORCE_ENCRYPTION` 으로 바꾼다.

---

## 6. 판정

`make-certs.sh --check-only` — 서비스당 6항목 + CA 4항목.

```
CA 인증서·키 존재 / 키 권한 0600 / CA:TRUE
[서비스] 인증서·키 존재 / 키 권한 0600
[서비스] CA 로 검증됨              <- openssl verify. 체인이 깨지면 클라이언트가 거부
[서비스] 인증서와 키가 짝           <- 공개키 해시 비교. 섞이면 기동 시 조용히 실패
[서비스] SAN 에 <호스트명> 포함
[서비스] 만료까지 30일 이상
```

"인증서와 키가 짝" 을 확인하는 이유는 파일을 옮기다 섞으면 서비스가 기동
단계에서 조용히 실패하고 로그만 보고 원인을 찾기 어렵기 때문이다.

`deploy-certs.sh --local --check-only` — 11항목. OS 번들 반영, docker·containerd
신뢰, `config_path`, `/opt/pki` 배치를 확인한다.

OS 신뢰는 파일 존재만 보지 않고 **번들에 실제로 반영됐는지**까지 본다.
`/usr/local/share/ca-certificates/` 에 파일만 두고 `update-ca-certificates` 를
잊으면 신뢰되지 않는다. 확장자가 `.crt` 가 아니면(예: `.pem`) 조용히 무시되는
것도 같은 계열의 함정이다.

---

## 7. 갱신

```bash
./make-certs.sh --force-leaf          # 서버 인증서만 재발급 (CA 유지)
./deploy-certs.sh --nodes '...'       # 배포
# 각 서비스 install.sh 재실행
```

CA 를 유지하면 **노드의 CA 신뢰를 다시 건드릴 필요가 없다.** 이것이 CA 를 두는
가장 큰 실익이다.

CA 자체를 바꿔야 한다면(`--rotate-ca`) 기존 인증서가 모두 무효가 되므로
전체 재배포가 필요하다. 기존 CA 는 `out/ca-old-<날짜>/` 에 보관된다.

---

## 8. 검증 상태

2026-09-23 에 에어갭 노드 3대에서 수행했다.

| 항목 | 결과 |
|---|---|
| 발급 (CA + 서비스 5개) | **판정 36/36** |
| 배포 (노드 3대, OS·docker·containerd 신뢰 + /opt/pki) | **각 11/11** |
| containerd `config_path` 가 올바른 섹션에 적용 | **통과** (30행 registry 섹션) |
| containerd 재시작 후 k8s 정상 | **통과** (노드 Ready, 파드 12개 정상) |
| `20-minio` 사내 CA 바인딩 | **23/23** |
| `30-harbor` 사내 CA 바인딩 + login/push/pull | **26/26** |
| `70-mssql` TLS(errorlog 로드 확인 + 암호화 연결) | **24/24** |
| `80-postgresql` TLS(`pg_stat_ssl` 세션 암호화) | **25/25** |

MSSQL 의 실제 확인 내용이다.

```
errorlog: The certificate [Certificate File:'/var/opt/mssql/certs/mssql.pem',
          Private Key File:'/var/opt/mssql/certs/mssql.key']
          was successfully loaded for encryption.
인증서 발급자: C = KR, O = Vanilla K8s, CN = Vanilla K8s Internal CA
```

### 검증 중 고친 것

1. **`openssl s_client -starttls mssql` 은 쓸 수 없다.** 처음에 이 방법으로
   서버 인증서를 확인하려 했으나 OpenSSL 3.0.2 의 `-starttls` 는
   smtp/pop3/imap/ftp/xmpp 등만 지원하고 `mssql` 은 목록에 없다
   (실측: `Value must be one of`). TDS prelogin 을 직접 구현하는 것은 판정
   스크립트에 과하다.
   대신 **SQL Server 자신이 남기는 errorlog** 를 본다. 어떤 파일을 읽었는지
   경로까지 찍히므로 설정 오타나 권한 문제가 그대로 드러나고, 더 권위 있다.
   여기에 `sqlcmd -N`(암호화 필수) 성공을 더해 실제 암호화까지 확인한다.
2. **macOS 에서 판정이 거짓 실패했다.** `stat -c` 는 GNU 전용이고
   `openssl x509 -ext` 는 OpenSSL 1.1.1+ 전용이라 macOS 기본 LibreSSL 3.x 에는
   없다. 관리 호스트가 맥일 수 있으므로 `common.sh` 에 `file_mode()` 와
   `cert_san()` 헬퍼를 넣어 양쪽을 지원하게 했다.

---

## 9. 트러블슈팅

| 증상 | 원인 | 조치 |
|---|---|---|
| `x509: certificate signed by unknown authority` | CA 미신뢰 | `deploy-certs.sh --local`. docker 는 `certs.d`, k8s 는 containerd 쪽 |
| 파드만 이미지 pull 실패(docker 는 성공) | containerd 신뢰가 없다 | 4절. `config_path` 와 `hosts.toml` 확인 |
| `update-ca-certificates` 했는데 신뢰되지 않음 | 확장자가 `.crt` 가 아니다 | `.pem` 은 조용히 무시된다 |
| SQL Server 가 인증서를 무시 | 소유권/권한 | 5절. `10001:10001`, 파일 0600, 디렉터리 0700. errorlog 확인 |
| PostgreSQL 기동 실패 `private key file has group or world access` | 키 권한 | uid 999 소유 + 0600 |
| 이름으로는 되고 IP 로는 TLS 실패 | SAN 에 IP 가 없다 | `site.env` 의 `*_HOST_IP` 를 채우고 재발급 |
| 서비스 기동 후 조용히 TLS 실패 | 인증서와 키가 짝이 아니다 | `make-certs.sh --check-only` 의 짝 검사 |
| `--rotate-ca` 후 전부 실패 | 모든 인증서가 무효 | 7절. 전체 재배포 필요 |

---

## 10. 다음 단계

발급·배포는 **10-k8s 설치 후** 하는 것이 편하다. containerd 신뢰 설정이
`/etc/containerd/config.toml` 을 요구하기 때문이다. 발급 자체는 언제든 가능하다.

```
10-k8s → [05-certs] → 60-cilium → 50-nfs-csi → 40-haproxy → 30-harbor → 20-minio
                                                70-mssql · 80-postgresql
```

UiPath AS 설치 시 `out/as/` 의 인증서를 쓴다. k8s TLS Secret 으로 넣는 예다.

```bash
kubectl -n <ns> create secret tls as-tls \
  --cert=/opt/pki/as/fullchain.crt --key=/opt/pki/as/tls.key
```
