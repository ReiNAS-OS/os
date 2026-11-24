#!/bin/bash
#
# 在构建箱内运行（由 scripts/build-in-container.sh 调用）。
#
# 前置：宿主的 /dev 是完整的（真实 KVM 主机，或 kiwi 的 boxbuild 虚拟机）。
#       容器里跑不通——Docker 缺 udev，partx --add 之后 /dev/loopNpX
#       不会被创建，kiwi 报 KiwiMappedDeviceError。详见 docs/decisions.md。
#
set -euo pipefail

echo "=== 环境 ==="
echo "arch: $(uname -m)   fedora: $(cat /etc/fedora-release 2>/dev/null || echo unknown)"
echo "kiwi: $(kiwi-ng --version 2>&1 | tail -1)"

echo "=== XML 静态检查 ==="
python3 /work/scripts/check-xml.py /work/kiwi/reinas.kiwi

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

# image 阶段是 chroot 内的 dnf5，本地目录在 chroot 里不可达。
# 用 127.0.0.1 上的静态服务暴露仓库，chroot 与宿主共享网络命名空间。
echo "=== 启动本地仓库服务 (8888) ==="
python3 -m http.server 8888 --directory /work/rpms --bind 127.0.0.1 >/tmp/httpd.log 2>&1 &
HTTPD_PID=$!
trap 'kill $HTTPD_PID 2>/dev/null' EXIT
sleep 2
curl -sf http://127.0.0.1:8888/repodata/repomd.xml >/dev/null \
    || { echo "FAIL: 仓库服务未就绪"; cat /tmp/httpd.log; exit 1; }
echo "  就绪"

# 构建目录不能用共享挂载：macOS 上是 fuse/virtiofs，不支持 xattr / ACL，
# kiwi 会直接拒绝。放在本地临时目录，结束后回传。
BUILD_DIR=/var/tmp/reinas-build
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

echo "=== 生成镜像 ==="
kiwi-ng --type oem --profile "${PROFILE:-Disk}" --logfile "$BUILD_DIR/kiwi-build.log" \
    system build \
    --description /work/kiwi \
    --target-dir "$BUILD_DIR"

echo "=== 回传产物 ==="
mkdir -p /work/out
cp -v "$BUILD_DIR"/*.raw "$BUILD_DIR"/*.install.iso /work/out/ 2>/dev/null || true
cp -f "$BUILD_DIR/kiwi-build.log" /work/out/ 2>/dev/null || true
ls -lh /work/out/
