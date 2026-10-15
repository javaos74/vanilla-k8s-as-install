# 2-Node Offline Kubernetes Execution Plan

## Objective

Build a Kubernetes cluster for UiPath Automation Suite with the following roles:

| Host | Address | Role |
| --- | --- | --- |
| `k8s-cp-01` | `10.32.99.3` | Single control plane and stacked etcd |
| `k8s-worker-01` | `10.32.99.4` | Worker node |

The target nodes use unrestricted egress during initial installation and validation. After the platform is stable, outbound access can be reduced to UiPath public registry (`registry.uipath.com`) and approved AWS endpoints for S3. AWS S3 bucket `charles-as-bucket` in `ap-northeast-2` is the external object store. The Automation Suite FQDN is `uipath.myrobots.co.kr`, with DNS managed in AWS Route 53. The Automation Suite release is **`2.2510.4`**.

## Deployment Profile

This is not a fully isolated air-gapped deployment because the nodes pull UiPath artifacts directly from the public registry. The rollout has two egress phases:

1. **Initial installation**: keep egress open to simplify Kubernetes, Automation Suite, and dependency validation.
2. **Post-acceptance hardening**: restrict egress to `registry.uipath.com`, the `ap-northeast-2` S3 endpoint, and only the AWS STS/KMS endpoints proven necessary by the selected credential and encryption configuration.

Kubernetes packages, Cilium images, and Automation Suite installer files can still be collected on a controlled jump host, integrity-checked, and transferred to the nodes to make the later egress-restriction transition reproducible.

The required runtime data flow is:

```text
registry.uipath.com <------------------------------- 10.32.99.3 / 10.32.99.4
AWS S3 regional endpoint <------------------------- 10.32.99.3 / 10.32.99.4
AWS S3 regional endpoint <------------------------- browsers and Robot machines
```

Do not deploy Harbor solely for UiPath images in this topology. Do not host SQL Server or stateful object storage on either Kubernetes node for a production deployment.

## Approval Gates

Do not begin installation until all items below are confirmed:

- [x] Automation Suite version is approved: `2.2510.4`.
- [ ] Enabled Automation Suite product list is approved.
- [ ] UiPath confirms the selected Automation Suite release is supported on the intended Kubernetes distribution. This repository uses Ubuntu kubeadm; UiPath's published compatibility matrix is for EKS/AKS and its Linux installer uses RKE2 on RHEL.
- [ ] Both nodes run the same supported Ubuntu release (`22.04` or `24.04`), are `amd64`, and have sufficient CPU, RAM, and disk for the selected products.
- [x] Automation Suite FQDN is assigned: `as2510.myrobots.co.kr`.
- [ ] Ingress/L4 load-balancer address and the Route 53 hosted-zone type (public or private) are assigned.
- [ ] An external SQL Server, Redis, persistent-volume storage, and backup destination are designed and reachable. Product-specific requirements determine whether PostgreSQL is also needed.
- [ ] Network security approves the later FQDN-based egress or egress-proxy policy for `registry.uipath.com`, the `ap-northeast-2` S3 endpoint, and only the required AWS STS/KMS endpoints.
- [ ] UiPath Registry pull credentials or an approved anonymous-pull policy are available and tested.
- [ ] An S3 bucket policy, encryption policy, lifecycle policy, IAM identity, and CORS policy are approved.
- [ ] License activation artifacts and the installation package version are available on the jump host.

## Network and DNS Prerequisites

- [ ] Both nodes resolve all internal names through the approved DNS service and have synchronized time.
- [ ] Configure `AS_FQDN="uipath.myrobots.co.kr"` in `offline-install/00-common/site.env`.
- [ ] In Route 53, create records for `uipath.myrobots.co.kr` and `*.uipath.myrobots.co.kr` pointing to the approved ingress L4 load balancer or virtual IP. Use an Alias record when the target is an AWS load balancer; otherwise use the approved A/AAAA record target.
- [ ] Use a Route 53 private hosted zone when access is private-only. If browsers or Robot machines outside the associated VPC must access Automation Suite, use a public hosted zone and an appropriately protected public ingress path instead.
- [ ] Issue a certificate whose SAN covers `uipath.myrobots.co.kr` and `*.uipath.myrobots.co.kr`; use Route 53 DNS validation when the selected certificate authority supports it.
- [ ] Allow `.4 -> .3` TCP `6443` for Kubernetes API access.
- [ ] Allow node-to-node kubelet, Cilium, and Kubernetes control traffic; Cilium VXLAN requires UDP `8472` with this repository's configuration.
- [ ] Keep egress open during the initial installation and record all required destination FQDNs from firewall, proxy, and application logs.
- [ ] Before hardening, allow both nodes to access `registry.uipath.com:443`, the `ap-northeast-2` S3 endpoint over TCP `443`, and the external SQL/Redis/NFS or StorageClass endpoints.
- [ ] If temporary AWS credentials are used, include the regional AWS STS endpoint. If SSE-KMS is used, include the regional AWS KMS endpoint.
- [ ] Use a firewall, secure web gateway, or egress proxy that supports FQDN policy. Do not allowlist static public IP addresses because UiPath and AWS endpoint IPs change.
- [ ] Publish `uipath.myrobots.co.kr` through a TCP/L4 load balancer. Keep the control-plane endpoint as `10.32.99.3:6443`; an API load balancer is unnecessary for a single control plane.
- [ ] Issue certificates for the Automation Suite FQDN and wildcard, internal Registry, and all private S3-compatible endpoints. Deploy the private CA to both nodes when applicable.

## Artifact Preparation on the Jump Host

1. Record target OS release and architecture from both nodes.
2. Both target nodes run Ubuntu `24.04`; on a clean Ubuntu `24.04` build environment, create the repository's Kubernetes bundle and confirm the artifact is named `k8s-1.36.4-noble.tar.gz` with `target_os: Ubuntu 24.04` in `BUNDLE-INFO`. Create the Cilium bundle in the same build run. Include the NFS CSI bundle only if NFS is an approved persistent-volume backend. Select a Metrics Server release compatible with the approved Kubernetes version and prepare its pinned manifest and image for the limited-egress deployment.
3. Verify every bundle SHA-256 digest before transfer.
4. Download the `2.2510.4` Automation Suite installer, `versions.json`, manifests, license artifacts, and other installation files on the jump host.
5. Verify artifact checksums and transfer them to the target nodes through the controlled transfer process.
6. Authenticate to `registry.uipath.com` if required, then validate Docker and OCI Helm pulls from both target nodes.
7. Keep a manifest of transferred artifacts and their digests so the installation can be reproduced without allowing extra outbound destinations.

## Cluster Installation Runbook

### 1. Site configuration

- [ ] Create `offline-install/00-common/site.env` from `site.env.example` without committing it.
- [ ] Set the actual private CIDR, NFS endpoint if used, Automation Suite FQDN, and certificate settings.
- [ ] Do not configure the sample Harbor or MinIO endpoints unless those services are actually deployed externally.

### 2. Control plane: `10.32.99.3`

- [ ] Verify bundle checksum and unpack the Kubernetes bundle.
- [ ] Run the control-plane install with the default role (`sudo ./install.sh`).
- [ ] Apply the Cilium bundle on the control plane.
- [ ] Verify the control-plane node is `Ready`, CoreDNS is running, Cilium is healthy, and a test pod can resolve cluster DNS.
- [ ] Generate a fresh worker join command. Treat the bootstrap token as a secret with a limited lifetime.
- [ ] Record the initial etcd snapshot location and validate an etcd snapshot before proceeding.

### 3. Worker: `10.32.99.4`

- [ ] Verify bundle checksum and unpack the same OS-specific Kubernetes bundle.
- [ ] Join with `--role worker` and the join command generated on `.3`.
- [ ] Apply the Cilium bundle in worker mode so the node has its required CNI images before DaemonSet scheduling.
- [ ] Verify the worker is `Ready`, the Cilium pod is running on it, and cross-node pod networking works.
- [ ] Deploy the pinned Metrics Server release after both nodes are `Ready`; verify the `v1beta1.metrics.k8s.io` APIService is `Available=True` and `kubectl top nodes` reports both nodes.
- [ ] Confirm Metrics Server can scrape both kubelets over node-to-node TCP `10250` before running UiPath prerequisite checks.

### 4. Persistent storage and ingress

- [ ] Install and test the approved StorageClass. Do not treat an unreplicated, single-host NFS service as highly available storage.
- [ ] Provision ingress/L4 load balancing for the Automation Suite FQDN and validate TLS from an intended client network.
- [ ] Confirm that the control plane remains tainted by default; only the Worker should schedule application pods unless capacity planning explicitly approves a different policy.

## Provisioned Worker Data Volumes

The following local LVM volumes are provisioned on `10.32.99.4` from the previously unused `/dev/nvme1n1` disk and are configured in `/etc/fstab` for automatic mounting:

| Purpose | Partition | LVM volume | Mount point | Usable filesystem capacity |
| --- | --- | --- | --- | --- |
| NFS | `/dev/nvme1n1p1` | `vg_nfs/lv_nfs` | `/data/nfs` | approximately 252 GiB |
| SQL Server | `/dev/nvme1n1p2` | `vg_mssql/lv_mssql` | `/data/mssql` | approximately 125 GiB |
| PostgreSQL | `/dev/nvme1n1p3` | `vg_postgresql/lv_postgresql` | `/data/postgresql` | approximately 125 GiB |

The remaining capacity on `/dev/nvme1n1` remains unpartitioned. These volumes are local to the Worker and are not highly available; loss of `10.32.99.4` affects NFS, SQL Server, PostgreSQL, and the Kubernetes workloads assigned to it. Back up each data service independently before installing Automation Suite.

## Automation Suite Dependencies

### UiPath Public Registry

- [ ] Retain `registry.uipath.com` as the `registries.docker.url` and `registries.helm.url` value, which is the Automation Suite default.
- [ ] Configure the registry username, password, or pull secret only if the selected UiPath artifacts require authentication.
- [ ] Validate an image pull and OCI Helm chart pull from both target nodes before starting Automation Suite installation.
- [ ] After installation acceptance, apply the egress policy and verify that a request to an unrelated public destination is denied without affecting a Registry pull.

### AWS S3

- [ ] Configure `external_object_storage.enabled: true`, `storage_type: "s3"`, Region `ap-northeast-2`, and the AWS S3 endpoint in the Automation Suite configuration.
- [ ] Use the AWS credentials held by local profile `uipath`; never commit, print, or copy the access key and secret key into this repository. Put resulting installation secrets in protected files or Kubernetes Secrets only.
- [ ] Configure the general external-object-storage section once so all installed products share the same S3 configuration.
- [ ] Treat `charles-as-bucket` as the required bucket namespace until the installer validates its exact bucket behavior. UiPath exposes `create_bucket` and bucket prefix/suffix settings, not a direct single-bucket-name field; do not set `create_bucket: false` until the expected bucket names and required IAM permissions are confirmed.
- [ ] Prefer an S3 VPC endpoint reachable through approved private connectivity. If public AWS S3 endpoints are used, enforce the regional FQDN allowlist at the corporate firewall or egress proxy.
- [ ] Configure S3 CORS for the Automation Suite FQDN and validate presigned upload/download from a browser and Robot network.
- [ ] Enable encryption and retain object-version and lifecycle controls according to the backup policy.

### Databases and stateful services

- [ ] Deploy or validate external SQL Server using the required supported edition, version, sizing, TLS, collation, and Full-Text Search requirements.
- [ ] Provision Redis and any product-specific PostgreSQL requirement outside this two-node cluster.
- [ ] Verify from a disposable pod that all database, cache, Registry, S3, and StorageClass connections succeed using production DNS and TLS.

## Acceptance Criteria

- [ ] `kubectl get nodes` shows `.3` as `Ready, control-plane` and `.4` as `Ready`.
- [ ] Cilium, CoreDNS, and kube-proxy are healthy on both nodes.
- [ ] Pod-to-pod, Pod-to-Service, DNS, and cross-node networking tests pass.
- [ ] During initial acceptance, Registry and S3 operations succeed with egress open.
- [ ] During the hardening acceptance, workload image pulls and Helm chart pulls reach only `registry.uipath.com`; firewall or proxy logs show no other public Registry traffic.
- [ ] During the hardening acceptance, S3 traffic reaches only the approved regional S3 endpoint and approved AWS STS/KMS endpoints, when used.
- [ ] S3 supports authenticated read/write and presigned URLs from the cluster, browser, and Robot network.
- [ ] Persistent-volume claim, mount, write, restart, and recovery tests pass.
- [ ] etcd, database, S3, and Registry backup/restore procedures are documented and tested separately.

## Repository References

- Offline installation order and bundle workflow: `offline-install/README.md`
- Kubernetes control-plane/worker installation: `offline-install/10-k8s/README.md`
- Version pins and Pod/Service CIDRs: `offline-install/00-common/versions.env`
- Per-environment configuration template: `offline-install/00-common/site.env.example`
- S3-compatible object-store reference used by this repository: `offline-install/20-minio/README.md`

## External References

- [UiPath external OCI-compliant registry configuration](https://docs.uipath.com/automation-suite/automation-suite/2.2510/installation-guide/external-oci-compliant-registry-configuration)
- [UiPath 2.2510.4 installation package links](https://docs.uipath.com/automation-suite/automation-suite/2.2510/installation-guide/installation-packages-download-links)
- [UiPath external object storage configuration](https://docs.uipath.com/automation-suite/automation-suite/2.2510/installation-guide/external-objectstore-configuration)
- [UiPath Kubernetes compatibility matrix](https://docs.uipath.com/automation-suite/automation-suite/2.2510/installation-guide-eks-aks/compatibility-matrix)
