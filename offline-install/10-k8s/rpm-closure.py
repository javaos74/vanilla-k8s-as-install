#!/usr/bin/env python3
# ---------------------------------------------------------------------
# 10-k8s : RPM 의존성 폐쇄집합 계산 (pkgs-rhel.sh 가 호출한다. 빌드 전용)
#
#   rpm-closure.py --group core [--group ...] [--pkg <spec> ...]
#
# 이 호스트에 설치된 패키지(rpmdb)를 **읽지 않고** 저장소만으로 의존성을 푼다.
# 즉 "아무것도 설치되지 않은 시스템"에 설치한다고 가정한 트랜잭션을 만든다.
# Ubuntu 쪽(pkgs-debian.sh)의 "빈 dpkg 상태" 와 같은 목적이다. 빌드 호스트에
# 무엇이 깔려 있든 결과가 같아야 번들에 구멍이 생기지 않는다.
#
# 출력: 한 줄에 하나씩 "이름<TAB>NEVRA"  (예: kubelet  kubelet-0:1.36.4-150500.1.1.x86_64)
# 실패 시 0 이 아닌 값으로 끝나고 이유를 stderr 에 쓴다.
# ---------------------------------------------------------------------
import argparse
import sys

import dnf
import dnf.exceptions


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--group", action="append", default=[],
                    help="comps 그룹 id (mandatory+default 패키지를 넣는다)")
    ap.add_argument("--pkg", action="append", default=[],
                    help="패키지 spec (이름 또는 이름-버전-릴리스)")
    a = ap.parse_args()

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

    if a.group:
        base.read_comps(arch_filter=True)
        for gid in a.group:
            grp = base.comps.group_by_pattern(gid)
            if grp is None:
                sys.exit("comps 그룹을 찾지 못했다: %s" % gid)
            base.group_install(grp.id, ("mandatory", "default"))

    for spec in a.pkg:
        try:
            base.install(spec)
        except dnf.exceptions.MarkingError as e:
            sys.exit("패키지를 찾지 못했다: %s (%s)" % (spec, e))

    try:
        base.resolve(allow_erasing=False)
    except dnf.exceptions.DepsolveError as e:
        sys.exit("의존성 해결 실패: %s" % e)

    seen = set()
    for p in sorted(base.transaction.install_set, key=lambda x: x.name):
        if p.name in seen:
            continue
        seen.add(p.name)
        print("%s\t%s-%s:%s-%s.%s" % (p.name, p.name, p.epoch, p.version, p.release, p.arch))


if __name__ == "__main__":
    main()
