#!/bin/bash
# 在 Fedora 容器里跑完整构建。由 scripts/build-in-container.sh 调用。
set -euo pipefail
echo "=== 环境 ==="
echo "arch: $(uname -m)   fedora: $(cat /etc/fedora-release)"
echo "kiwi:  $(kiwi-ng --version 2>&1 | tail -1)"

echo "=== 编译 reinas-release ==="
rpmbuild -bb \
  --define "_sourcedir /work/packages/reinas-release" \
  --define "_rpmdir /work/rpms" \
  --define "_build_name_fmt %%{NAME}-%%{VERSION}-%%{RELEASE}.%%{ARCH}.rpm" \
  /work/packages/reinas-release/reinas-release.spec 2>&1 | tail -6

built=$(find /work/rpms -name 'reinas-release-*.noarch.rpm' -print -quit)
[ -n "$built" ] || { echo "FAIL: 没产出 rpm"; exit 1; }
[ "$built" = "/work/rpms/$(basename "$built")" ] || mv -f "$built" /work/rpms/
find /work/rpms -mindepth 1 -type d -exec rm -rf {} + 2>/dev/null || true
echo "rpm: $(basename /work/rpms/reinas-release-*.noarch.rpm)"

echo "=== createrepo ==="
createrepo_c --quiet /work/rpms

echo "=== XML 静态检查 ==="
python3 /work/scripts/check-xml.py /work/kiwi/reinas.kiwi || { echo "FAIL: XML 检查未通过"; exit 1; }

echo "=== kiwi system build ==="
PROFILE="${PROFILE:-Disk}"
# ⚠️ kiwi 的选项分两层，位置错了就报 "No such option"：
#   全局  --type / --profile / --logfile / --debug  → 必须在子命令【之前】
#   子命令 --description / --target-dir             → 在 system build 之后
#   子命令没有 --logfile，写在那里会直接失败。
kiwi-ng --type oem --profile "$PROFILE" --logfile /work/out/kiwi-build.log \
  system build \
  --description /work/kiwi \
  --target-dir /work/out
