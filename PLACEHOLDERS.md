# 플레이스홀더 목록

공개 저장소이므로 실제 계정/리소스 식별자와 IP는 아래 플레이스홀더로 치환되어 있다.
매니페스트나 스크립트를 적용하기 전에 자신의 환경 값으로 바꿀 것.

## AWS

| 플레이스홀더 | 설명 |
|---|---|
| `<AWS_ACCOUNT_ID>` | AWS 계정 번호 (12자리) |
| `<VPC_ID>` | 클러스터가 속한 VPC (`172.31.0.0/16`) |
| `<SECURITY_GROUP_ID>` | 노드용 Security Group. 자기 참조 규칙으로 내부 통신 전체 허용 |
| `<SG_RULE_ID_6443>` | 6443 인바운드 규칙 ID |
| `<CP_INSTANCE_ID>` | control plane 인스턴스 |
| `<WORKER01_INSTANCE_ID>` ~ `<WORKER03_INSTANCE_ID>` | 워커 인스턴스 |
| `<NFS_INSTANCE_ID>` | NFS/MinIO 서버(myubuntu) 인스턴스 |
| `<NFS_DATA_VOLUME_ID>` | NFS 데이터용 500GB EBS (`DeleteOnTermination: false`) |
| `<OTHER_EIP_1>` ~ `<OTHER_EIP_3>` | 같은 계정의 무관한 EIP (재사용 금지 대상) |
| `<CP_EIP_ALLOCATION_ID>` | CP 에 붙인 EIP 의 할당 ID (`eipalloc-...`) |

## 사설 IP (stop/start 후에도 유지, 클러스터 설정의 기준값)

| 플레이스홀더 | 서버 |
|---|---|
| `<CP_PRIVATE_IP>` | K8S-CP — apiserver 주소, etcd |
| `<WORKER01_PRIVATE_IP>` ~ `<WORKER03_PRIVATE_IP>` | K8S-01~03 |
| `<NFS_PRIVATE_IP>` | myubuntu — NFS export, MinIO, CoreDNS 응답 대상 |

## 퍼블릭 IP / DNS

| 플레이스홀더 | 설명 |
|---|---|
| `<CP_PUBLIC_IP>` | CP의 EIP. 고정. 맥 kubeconfig와 인증서 SAN에 포함 |
| `<CP_PUBLIC_DNS>` | 위 EIP의 `ec2-...compute.amazonaws.com` 이름. 인증서 SAN에 포함 |
| `<OLD_CP_PUBLIC_IP>` | EIP 연결 전 자동 할당됐던 주소 (AWS에 반납됨) |
| `<NFS_PUBLIC_IP>`, `<WORKER0N_PUBLIC_IP>` | 동적 할당. 재시작마다 바뀜. SSH 접속용으로만 사용 |
| `<HARBOR_PUBLIC_IP>` | 외부 Harbor 레지스트리(`harbor.myrobots.co.kr`, Azure) |
| `<ADMIN_IP_1>`, `<ADMIN_IP_2>` | SSH/6443 접근을 허용한 관리자 소스 IP |

## 치환하지 않은 값

- Pod CIDR `10.244.0.0/16`, Service CIDR `10.96.0.0/12`, VPC CIDR `172.31.0.0/16`
- 노드 호스트명 `k8s-cp`, `k8s-01~03`, `myubuntu`
- 도메인 `k8s.myrobots.co.kr`, `minio.myrobots.co.kr`, `harbor.myrobots.co.kr`

## 저장소에 포함하지 않은 것

- `backups/*.db` — etcd 스냅샷. 클러스터의 모든 Secret이 평문으로 들어있다
- `uipathctl` — 116MB 바이너리
- `*.key`, `*.pem`, `*.env` — 개인키 및 자격증명
- `init-cp.log`의 bootstrap token과 `--certificate-key` 값은 `<REDACTED-...>`로 마스킹
