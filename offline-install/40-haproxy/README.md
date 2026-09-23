# 40-haproxy — ingress L4 로드밸런서 오프라인 설치

호스트의 `80` / `443` / `15021` 을 받아 ingress gateway 의 NodePort 로 넘기는
TCP 패스스루 LB. 컨테이너명은 `l4` 다.

---

## 1. 범위

**API 서버(6443) LB 는 만들지 않는다.** 단일 노드이므로 실익이 없다.
ingress 경로만 담당한다.

**TLS 를 종료하지 않는다.** `mode tcp` 패스스루이므로 인증서는 게이트웨이가 갖는다.
대가로 클라이언트 원본 IP 가 백엔드에서 보이지 않는다. 필요하면 게이트웨이가
PROXY protocol 을 받도록 설정하고 `server` 줄에 `send-proxy-v2` 를 붙인다.

번들은 OS 에 의존하지 않는다(이미지 + 설정뿐). docker 는 `10-k8s` 에서 설치된다.

**worker 노드에는 설치하지 않는다.** ingress 진입점은 한 곳이면 되고, 백엔드는
NodePort 이므로 어느 노드로 보내도 kube-proxy 가 게이트웨이 파드까지 전달한다.
이 번들은 백엔드를 루프백(`127.0.0.1`)으로 잡으므로, 게이트웨이 파드가 없는 노드에
올리면 그 노드의 NodePort 를 경유해 돌아가는 경로가 된다. 진입점을 여러 노드로
늘리려면 앞단에 별도 LB(또는 DNS 라운드로빈)가 필요하며, 그때는 백엔드를 각 노드의
사설 IP 로 바꿔야 한다.

---

## 2. `--network host` 를 쓰는 이유

기존 운영 클러스터의 `l4` 는 bridge + 포트 매핑이었다. 이 번들은 host 네트워크를 쓴다.

| | bridge + `-p` | **host** |
|---|---|---|
| 백엔드가 같은 노드의 NodePort | docker0 게이트웨이 경유, NAT 1회 추가 | 루프백으로 직접 |
| stats `127.0.0.1:8404` | 컨테이너 네임스페이스 안에만 열림. `docker exec` 없이 확인 불가 | 호스트에서 바로 조회 |
| 호스트 포트 점유 | 매핑으로 점유 | 직접 점유 |

단일 노드에서는 백엔드가 자기 자신이므로 host 쪽이 단순하고 관측도 쉽다.
실제로 기존 환경에서 stats 를 호스트에서 조회할 수 없어 불편했던 부분이다.

---

## 3. 재시작 정책 — `unless-stopped` 필수

기존 환경의 `l4` 는 `RestartPolicy=no` 로 떠 있었고, 설정 파일 주석의 권장값
(`--restart unless-stopped`)과 달랐다. 그 상태로는 **노드를 재부팅하면 haproxy 가
올라오지 않는다.**

이 번들은 `--restart unless-stopped` 로 생성하고 판정에서 정책을 확인한다.

```
[OK] 재시작 정책 unless-stopped
```

설정만 보는 것으로는 부족해서 실동작 검증 모드를 따로 뒀다.

```bash
sudo ./install.sh --test-restart
```

두 단계를 수행한다.

| 단계 | 방법 | 확인 |
|---|---|---|
| 프로세스 사고사 | 호스트에서 컨테이너 PID 에 `kill -9` | `RestartCount` 증가 + stats 복구 |
| 재부팅 대리 | `systemctl restart docker` | 컨테이너 running 복귀 + 80/443/15021 재수신 |

### `docker kill` 로 시험하면 안 된다

처음에는 `docker kill l4` 로 시험했는데 **60초간 복구되지 않았다.** 정책 문제가
아니라 시험 방법이 틀린 것이다. `docker kill` 과 `docker stop` 은 모두 "사용자가
의도적으로 멈췄다"로 기록되고(`HasBeenManuallyStopped`), `unless-stopped` 는 그
경우 재시작하지 않는다. docker 데몬을 재시작해도 `exited` 로 남는다.

프로세스가 죽는 상황을 재현하려면 호스트에서 컨테이너 PID 를 직접 죽여야 한다.

```bash
sudo kill -9 "$(docker inspect -f '{{.State.Pid}}' l4)"
```

실측으로 `RestartCount 0 -> 1` 과 포트 복구를 확인했다. 실제 노드 재부팅으로도
확인했다(`l4` 가 자동 기동, 80/443/15021 재수신).

Harbor 에서 얻은 교훈도 참고할 것. Docker 재시작 정책은 compose 의 `depends_on`
순서를 지키지 않는다. haproxy 는 의존 대상이 없어 정책만으로 충분하지만,
기동 순서 의존이 있는 서비스라면 systemd 유닛이 필요하다(`30-harbor` 참고).

---

## 3-1. `--user root` 가 필요한 이유

haproxy 공식 이미지는 `Config.User=haproxy` 로 비특권 사용자로 기동한다.
그 상태에서는 특권 포트 바인드가 실패하고 컨테이너가 재시작 루프에 빠진다.

```
[ALERT] Binding [...] for frontend fe_https: protocol tcpv4:
        cannot bind socket (Permission denied) for [0.0.0.0:443].
```

`--cap-add NET_BIND_SERVICE` 로는 해결되지 않는다. docker 는 ambient capability 를
설정하지 않으므로, 파일 capability 가 없는 바이너리를 비root 로 실행하면 permitted
집합에 있어도 effective 가 되지 않는다.

그래서 컨테이너를 `--user root` 로 띄운다. 마스터 프로세스가 80/443 을 바인드한
뒤 설정의 `user haproxy` / `group haproxy` 지시자에 따라 **워커가 권한을
내려놓는다.** haproxy 의 표준 동작이며, 실제 서비스 트래픽을 처리하는 프로세스는
여전히 비root 다.

이 문제는 `haproxy -c` 문법 검사로는 잡히지 않는다. 문법 검사는 바인드를 시도하지
않기 때문이다. 판정에 "호스트 80/443/15021 수신"과 "크래시 루프 아님"이 들어간
이유다.

---

## 4. NodePort 자동 탐지

고정값을 쓰다 실제 서비스와 어긋나는 것을 막기 위해, `install.sh` 가
`istio-ingressgateway` 서비스에서 NodePort 를 읽어 설정에 채운다.

```bash
kubectl -n istio-system get svc istio-ingressgateway \
  -o jsonpath="{.spec.ports[?(@.name=='https')].nodePort}"
```

서비스가 없으면 기본값(`http2=31223`, `https=31164`, `status-port=31956`)을 쓰고
경고를 남긴다. **게이트웨이 설치 후 이 스크립트를 다시 실행하면 실제 값으로 갱신된다.**

기존 운영 클러스터의 cfg 에는 서버 레이블이 `k8s-01/02/03` 인데 실제 IP 는
`NODE-07/05/04` 였다. 이름과 실체가 어긋나면 장애 시 로그 해석을 오도한다.
그래서 이 번들은 단일 노드용으로 `node1` 하나만 두고 IP 도 루프백으로 고정한다.

---

## 5. 헬스체크 — Envoy 상태 포트의 함정

```
option httpchk
http-check send meth GET uri /healthz/ready ver HTTP/1.1 hdr Host localhost
http-check expect status 200
```

`ver HTTP/1.1` 과 `hdr Host` 가 반드시 필요하다. **Envoy 의 상태 포트는 HTTP/1.0
요청을 `426 Upgrade Required` 로 거부한다.** 이것을 빼면 게이트웨이가 정상인데도
모든 백엔드가 영구 DOWN 으로 보인다.

`default-server inter 5s fall 3 rise 2` 이므로 장애 감지 15초, 복구 10초다.

---

## 6. 빌드와 설치

```bash
# 온라인 호스트
cd offline-install/40-haproxy && ./build-bundle.sh      # 45MB

# 노드
tar xzf haproxy-3.4.4.tar.gz && cd haproxy-3.4.4
sudo ./install.sh
```

설정은 `/etc/haproxy-l4/haproxy.cfg` 에 생성된다.

`install.sh` 는 컨테이너를 재생성하기 **전에** 생성된 설정을 `haproxy -c` 로 검사한다.
잘못된 설정으로 재생성하면 서비스가 내려간 채 올라오지 않기 때문이다.
설치 전에는 `80`/`443`/`15021` 을 다른 프로세스가 점유하고 있는지도 확인한다.

설정을 직접 고친 뒤에는 무중단 반영이 가능하다.

```bash
sudo docker kill -s HUP l4
```

---

## 7. 판정 항목

11항목이다.

```
docker 사용 가능
haproxy 이미지 적재됨
설정 파일 존재
haproxy 설정 문법 유효(-c)
컨테이너 l4 실행 중(크래시 루프 아님)   <- PID 가 10초간 유지되는지 확인
재시작 정책 unless-stopped
네트워크 모드 host
호스트 80 / 443 / 15021 수신
stats 응답(127.0.0.1:8404)
```

`컨테이너 실행 중` 을 `.State.Running` 으로만 보면 안 된다. 바인드 실패로 크래시
루프에 빠진 컨테이너도 재시작하는 순간에는 `true` 로 보인다. 실제로 3-1절의
Permission denied 상태에서 이 판정이 통과해버렸다. 그래서 PID 유지까지 확인한다.

**백엔드 UP/DOWN 은 판정 항목이 아니다.** 정보로만 출력한다.
ingress gateway 는 UiPath AS 설치 단계에서 들어오므로, 이 단계에서는 없는 것이
정상이고 백엔드는 DOWN 으로 보인다. 스크립트가 그 사실을 구분해 알려준다.

```
[INFO] ingress gateway 서비스가 없다. 백엔드 DOWN 은 정상이다.
         (게이트웨이는 UiPath AS 설치 단계에서 들어온다)
```

---

## 8. 트러블슈팅

| 증상 | 원인 | 조치 |
|---|---|---|
| 모든 백엔드 영구 DOWN (게이트웨이는 정상) | 헬스체크가 HTTP/1.0 으로 나간다 | 5절. `ver HTTP/1.1 hdr Host` 필수 |
| 백엔드 DOWN, `ECONNREFUSED` | NodePort 에 엔드포인트가 없다(게이트웨이 파드 0개) | `kubectl -n istio-system get endpointslice` 확인. 파드가 Ready 여야 한다 |
| 클라이언트 503, 로그에 `be_https/<NOSRV>` + `SC` | 백엔드가 전부 DOWN 인 상태에서 요청이 들어왔다 | 위 두 항목과 동일 원인 |
| 포트 바인드 실패 | 다른 프로세스가 80/443 점유 | `install.sh` 가 사전에 잡는다. `ss -lntp` 로 점유자 확인 |
| `cannot bind socket (Permission denied)` + `Restarting` 루프 | 컨테이너가 비특권 사용자(`haproxy`)로 떠 있다 | 3-1절. `--user root` 로 기동해야 한다 |
| `--test-restart` 가 복구 실패로 나온다 | `docker kill` 로 시험했다(수동 정지로 기록됨) | 3절. 호스트에서 컨테이너 PID 에 `kill -9` |
| 노드 재부팅 후 haproxy 없음 | 재시작 정책이 `no` 다 | 3절. `--test-restart` 로 검증 |
| stats 에 접근 불가 | bridge 네트워크로 떠 있다 | `docker inspect -f '{{.HostConfig.NetworkMode}}' l4` 가 `host` 여야 한다 |
| 설정 변경이 반영되지 않음 | `docker restart` 로는 안 되는 경우가 있다 | `docker kill -s HUP l4` 또는 `install.sh` 재실행(재생성) |

로그는 `docker logs l4` 다. `mode tcp` + `option tcplog` 이므로 연결 단위로 남는다.

---

## 9. 검증 상태

2026-09-22 에 Ubuntu 24.04 / 22.04 두 노드에서 에어갭 설치를 수행했다.

| 항목 | 상태 |
|---|---|
| 번들 빌드 | **완료** (45MB, 이미지 1개) |
| 에어갭 설치 + 판정 | **양쪽 OS 통과 11/11** |
| 프로세스 사고사 후 자동 복구 | **통과** (`RestartCount 0 -> 1`, stats 복구) |
| docker 데몬 재시작 후 복구 | **통과** (running 복귀, 80/443/15021 재수신) |
| 실제 노드 재부팅 후 자동 기동 | **통과** (22.04 노드, `l4` 자동 기동 + 3포트 수신) |
| `airgap-fwd-other` 카운터 | **0** (설치 중 인터넷 접근 시도 없음) |

검증 중 발견해 고친 것은 두 가지다.

1. **비특권 사용자 바인드 실패** — 컨테이너가 이미지 기본값인 `haproxy` 사용자로
   떠서 80/443 을 바인드하지 못하고 재시작 루프에 빠졌다. `--user root` 추가(3-1절).
   `haproxy -c` 문법 검사만으로는 드러나지 않는 문제다.
2. **잘못된 자동 복구 시험 방법** — `docker kill` 은 수동 정지로 기록되어 정책이
   적용되지 않는다. 호스트 PID `kill -9` 로 바꿨고 데몬 재시작 단계를 추가했다(3절).

재검증 절차는 다음과 같다.

```bash
sudo ./install.sh
sudo ./install.sh --test-restart
sudo ./install.sh --check-only     # 판정만
```

---

## 10. 다음 단계

```
10-k8s  →  60-cilium  →  50-nfs-csi  →  [40-haproxy]  →  30-harbor  →  20-minio
```
