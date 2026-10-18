#!/usr/bin/env python3
# ---------------------------------------------------------------------
# 10-k8s : RPM 번들 목록 계산 (pkgs-rhel.sh 가 호출한다. 빌드 전용)
#
#   rpm-closure.py --group core --pkg <spec> ... [--dist el10_2] [--all-versions <이름>]
#
# 이 호스트에 설치된 패키지(rpmdb)를 **읽지 않고** 저장소만으로 의존성을 푼다.
# "아무것도 설치되지 않은 시스템"에 설치한다고 가정한 트랜잭션을 두 번 만든다.
#   기준선   = 그룹(--group)만
#   기준선+대상 = 그룹 + 패키지(--pkg)
# 그 차이가 번들이다. Ubuntu 쪽(pkgs-debian.sh)의 "빈 dpkg 상태" 와 같은 목적이다.
#
# 버전 결합(--dist):
#   번들 패키지와 기준선 패키지가 **정확한 버전(=)** 으로 묶여 있으면, 타깃의
#   기준선 패키지가 저장소 최신보다 오래된 경우 설치가 실패한다.
#   실측(RHEL 10.2 Azure 이미지): 타깃의 sssd-common 2.12.0-3.el10_2.1 이
#     (sssd-nfs-idmap = 2.12.0-3.el10_2.1 if libnfsidmap)
#   를 요구하는데 번들에는 최신 sssd-nfs-idmap 2.12.0-3.el10_2.2 만 있어 충돌했다.
#   그래서 이런 패키지는 같은 부 버전(dist 토큰, 예: el10_2)의 **모든 빌드**를 넣고,
#   설치 시 dnf 가 타깃에 맞는 것을 고르게 한다(번들을 로컬 저장소로 쓴다).
#
# 출력(탭 구분):
#   EXTRA    <이름>  <NEVRA>   번들에 넣을 패키지(기준선+대상 - 기준선, 이름으로 준 패키지 포함)
#   COUPLED  <이름>  <NEVRA>   위 중 버전 결합된 것의 같은 dist 모든 빌드
#   ALLVER   <이름>  <NEVRA>   --all-versions 로 요청한 패키지의 같은 dist 모든 빌드
# 요약은 stderr 에 쓴다. 실패 시 0 이 아닌 값으로 끝난다.
# ---------------------------------------------------------------------
import argparse
import re
import sys

import dnf
import dnf.exceptions


def nevra(p):
    return "%s-%s:%s-%s.%s" % (p.name, p.epoch, p.version, p.release, p.arch)


def new_base():
    base = dnf.Base()
    base.conf.read()                 # /etc/dnf/dnf.conf
    # /etc/dnf/vars 의 releasever 등을 읽는다. 이것이 없으면 API 는 $releasever 를
    # system-release 에서 "9" 로 추정하는데, Azure RHUI EUS 저장소 URL 은 "9.6" 이라
    # repomd.xml 을 받지 못한다(실측: RHEL 9.6 Azure 이미지).
    base.conf.substitutions.update_from_etc(base.conf.installroot)
    base.conf.assumeyes = True
    # 빌드 호스트가 설치된 노드이면 dnf.conf 에 excludepkgs(kubelet 등, pkg_hold)가
    # 있어 대상 패키지가 걸러진다(실측). 계산에는 exclude 를 적용하지 않는다.
    base.conf.disable_excludes = ["all"]
    base.read_all_repos()            # /etc/yum.repos.d (RHUI 포함)
    # load_system_repo=False: rpmdb 를 읽지 않는다 = 빈 시스템으로 가정
    base.fill_sack(load_system_repo=False, load_available_repos=True)
    base.read_comps(arch_filter=True)
    return base


def resolve(base, groups, pkgs):
    base.reset(goal=True)
    for gid in groups:
        grp = base.comps.group_by_pattern(gid)
        if grp is None:
            sys.exit("comps 그룹을 찾지 못했다: %s" % gid)
        base.group_install(grp.id, ("mandatory", "default"))
    for spec in pkgs:
        try:
            base.install(spec)
        except dnf.exceptions.MarkingError as e:
            sys.exit("패키지를 찾지 못했다: %s (%s)" % (spec, e))
    try:
        base.resolve(allow_erasing=False)
    except dnf.exceptions.DepsolveError as e:
        sys.exit("의존성 해결 실패: %s" % e)
    out = {}
    for p in base.transaction.install_set:
        out.setdefault(p.name, p)
    return out


def exact_names(reldeps):
    """요구 목록에서 '이름 = 버전' 형태로 묶인 이름들. rich dep '(a = v if b)' 포함."""
    names = set()
    for r in reldeps:
        for m in re.finditer(r"(?:^|[(\s])([A-Za-z0-9_.+-]+) = ", str(r)):
            names.add(m.group(1))
    return names


def all_versions(base, name, dist, arches=("x86_64", "noarch")):
    # 다른 아키텍처 빌드(i686 등)는 넣지 않는다(실측: nftables i686 가 함께 받아졌다).
    q = base.sack.query().available().filter(name=name, arch=list(arches))
    return sorted((p for p in q if dist and dist in p.release), key=nevra)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--group", action="append", default=[], help="comps 그룹 id (mandatory+default)")
    ap.add_argument("--pkg", action="append", default=[], help="패키지 spec")
    ap.add_argument("--dist", default="", help="같은 부 버전 dist 토큰 (예: el10_2, el9_6)")
    ap.add_argument("--all-versions", action="append", default=[], help="같은 dist 모든 빌드를 넣을 패키지")
    a = ap.parse_args()

    base = new_base()
    base_set = resolve(base, a.group, [])
    joint = resolve(base, a.group, a.pkg)
    extras = {n: p for n, p in joint.items() if n not in base_set}
    # 이름만 준 패키지(OS 의존 패키지)는 기준선에 있어도 넣는다. 클라우드 이미지가
    # 기준선(@core)을 다 갖고 있지 않을 수 있다(실측: Rocky 9.8 Azure 이미지에 nftables /
    # firewalld / ipset 이 없었다). 설치는 이름으로 하므로 이미 깔린 패키지는 바뀌지 않는다.
    for spec in a.pkg:
        if spec in joint and spec not in extras:
            extras[spec] = joint[spec]

    for n in sorted(extras):
        print("EXTRA\t%s\t%s" % (n, nevra(extras[n])))

    coupled = set()
    if a.dist:
        # (1) 기준선 패키지가 번들 패키지를 정확한 버전으로 요구한다 (sssd-common -> sssd-nfs-idmap)
        for bp in base_set.values():
            for n in exact_names(bp.requires) & set(extras):
                coupled.add(n)
        # (2) 번들 패키지가 기준선 패키지를 정확한 버전으로 요구한다
        base_provides = {}
        for bp in base_set.values():
            base_provides[bp.name] = bp
            for pr in bp.provides:
                base_provides.setdefault(str(pr).split(" ")[0], bp)
        for n, p in extras.items():
            if exact_names(p.requires) & set(base_provides):
                coupled.add(n)
        for n in sorted(coupled):
            for p in all_versions(base, n, a.dist):
                print("COUPLED\t%s\t%s" % (n, nevra(p)))

    for n in a.all_versions:
        vs = all_versions(base, n, a.dist)
        if not vs:
            sys.exit("%s 의 %s 빌드를 찾지 못했다" % (n, a.dist))
        for p in vs:
            print("ALLVER\t%s\t%s" % (n, nevra(p)))

    sys.stderr.write("기준선 %d / 기준선+대상 %d / 번들 %d / 버전결합 %s\n"
                     % (len(base_set), len(joint), len(extras), ",".join(sorted(coupled)) or "-"))


if __name__ == "__main__":
    main()
