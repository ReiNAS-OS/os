#!/bin/bash
#
# 在容器内运行的构建脚本（由 scripts/build-in-container.sh 调用）。
#
set -euo pipefail

echo "=== 环境 ==="
echo "arch: $(uname -m)   fedora: $(cat /etc/fedora-release)"
echo "kiwi:  $(kiwi-ng --version 2>&1 | tail -1)"

SITE=$(python3 -c 'import kiwi, os; print(os.path.dirname(kiwi.__file__))')
echo "kiwi 位于: $SITE"

# ─────────────────────────────────────────────────────────────────────
#  修补 kiwi 以适配 Fedora 45 的 dnf5
# ─────────────────────────────────────────────────────────────────────
# 三处问题，都是 kiwi 11.1.x 与 Fedora 45 dnf5 的适配缺陷：
#
#  1. plugin 参数
#     kiwi 硬编码 --disable-plugin=priorities,versionlock，
#     而 Fedora 45 的 dnf5-plugins 里没有这两个插件，直接报
#     "No matches were found for the following plugin name patterns"。
#
#  2. bootstrap 缺 use-host-config
#     dnf5 只要见到 --installroot，就拒绝加载宿主仓库，报
#     "No repositories were loaded from the installroot"，
#     结果只装了 filesystem，后续包的 %pre 因 /bin/sh 缺失 exit 127。
#
#  3. --config 与 --use-host-config 互斥
#     kiwi 用 --config 指向自建 runtime 配置来重定向 reposdir/cache，
#     但这会让 dnf5 完全忽略宿主 /etc/yum.repos.d。
#     去掉 --config 后 use-host-config 才能真正生效。
#
# 另外 repo 文件要同时写一份到宿主 /etc/yum.repos.d，
# 否则 bootstrap 阶段看不到 reinas 这个本地仓库。
#
# 修补是幂等的：同一个容器跑多次不会叠加。
echo "=== 修补 kiwi ==="

patch_file() {
    python3 - "$1" <<'PYPATCH'
import re
import sys

path = sys.argv[1]
src = open(path).read()
orig = src

# 1) 去掉 plugin 开关（dnf5 和 dnf4 两个后端都处理）
src = re.sub(
    r"^\s*'--(?:disable-plugin|disableplugin|enableplugin)=[^']*',?\n",
    "",
    src,
    flags=re.M,
)

# 2) 去掉 --config（只在 dnf5 的 dnf_args 构造里）
if "self.runtime_dnf_config_file.name" in src:
    src = re.sub(
        r"^(\s*)'--config',\n\s*self\.runtime_dnf_config_file\.name,\n",
        "",
        src,
        flags=re.M,
    )

# 3) bootstrap 的 installroot 前加 use-host-config（幂等）
if "'--use-host-config'" not in src:
    src = src.replace(
        "\n                '--installroot',",
        "\n                '--use-host-config',\n                '--installroot',",
    )

if src != orig:
    open(path, "w").write(src)
    print("  已修补 " + path)
else:
    print("  无需改动 " + path)
PYPATCH
}

patch_file "$SITE/repository/dnf5.py"
patch_file "$SITE/repository/dnf4.py"
patch_file "$SITE/package_manager/dnf5.py"

# 4) 关掉 rpm 数据库重定向
# kiwi 的 SystemPrepare 会调用 repo.setup_package_database_configuration()，
# 它通过 rpm 宏把 %_dbpath 指向宿主的 rpmdb 位置，并 link 回宿主。
# 在 Fedora 45 + dnf5 的组合下这让 bootstrap 事务里的 scriptlet 执行失败：
#   %prein(crypto-policies) scriptlet failed, exit status 127
# 而完全相同的 dnf5 命令行手动执行是成功的 —— 差异就在这些 rpm 宏上。
# 关掉它，让 rpm 用 installroot 内的默认数据库路径。
python3 - "$SITE/system/prepare.py" <<'PYDB'
import sys
path = sys.argv[1]
src = open(path).read()
old = "            repo.setup_package_database_configuration()"
if old in src:
    new = "            # 禁用：见构建脚本注释（Fedora 45 + dnf5 的 scriptlet 失败）\n            pass"
    open(path, "w").write(src.replace(old, new))
    print("  rpmdb 重定向: 已禁用")
else:
    print("  rpmdb 重定向: 未匹配")
PYDB

# reinas 仓库同时写一份到宿主，bootstrap 阶段（use-host-config）才看得到
if ! grep -q 'yum.repos.d.*reinas\|host_repo' "$SITE/repository/dnf5.py" 2>/dev/null; then
    python3 - "$SITE/repository/dnf5.py" <<'PYREPO'
import sys

path = sys.argv[1]
src = open(path).read()
old = """        with open(repo_file, 'w') as repo:
            repo_config.write(repo)"""
new = """        with open(repo_file, 'w') as repo:
            repo_config.write(repo)
        # 同时写一份到宿主：bootstrap 用 use-host-config，只读宿主配置。
        try:
            with open('/etc/yum.repos.d/' + name + '.repo', 'w') as repo:
                repo_config.write(repo)
        except OSError:
            pass"""
if old in src:
    open(path, "w").write(src.replace(old, new))
    print("  repo 双写: 已启用")
else:
    print("  repo 双写: 未匹配（可能已打过）")
PYREPO
fi

echo "=== XML 静态检查 ==="
python3 /work/scripts/check-xml.py /work/kiwi/reinas.kiwi || { echo "FAIL: XML 检查未通过"; exit 1; }

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
# 容器与 chroot 共享网络命名空间，所以用 127.0.0.1 上的静态服务暴露仓库。
echo "=== 启动本地仓库服务 (8888) ==="
python3 -m http.server 8888 --directory /work/rpms --bind 127.0.0.1 >/tmp/httpd.log 2>&1 &
HTTPD_PID=$!
trap 'kill $HTTPD_PID 2>/dev/null' EXIT
sleep 2
if curl -sf http://127.0.0.1:8888/repodata/repomd.xml >/dev/null; then
    echo "  仓库服务就绪"
else
    echo "FAIL: 仓库服务未就绪"
    cat /tmp/httpd.log
    exit 1
fi

# 构建目录必须在容器内部：macOS 上共享挂载是 fuse/virtiofs，
# 不支持 xattr / ACL，kiwi 会拒绝构建。
BUILD_DIR=/var/tmp/reinas-build
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

echo "=== 生成镜像 ==="
# bootstrap 阶段显式加 setup。
# 原因：glibc / bash / filesystem / setup 之间有一个极其脆弱的依赖环，
# rpm 上游 issue #3691 和 kiwi issue #2743 都记录了它：
#   crypto-policies 的 %pre 要 /bin/sh
#   /bin/sh 是 filesystem 的 %post 建的软链接
#   filesystem 依赖 setup，setup 又需要 shell
# 环的存在让 rpm 无法算出正确顺序，最终在 crypto-policies 的 %pre
# 以 exit 127 失败。rpm 维护者的结论是「打包层面解决，把其中的包
# 显式提到早期集合里」。setup 是关键的那一个。
kiwi-ng --debug --type oem --profile "${PROFILE:-Disk}" --logfile "$BUILD_DIR/kiwi-build.log" \
    system build \
    --description /work/kiwi \
    --target-dir "$BUILD_DIR" \
    --add-bootstrap-package setup \
    --add-bootstrap-package filesystem \
    --add-bootstrap-package glibc \
    --add-bootstrap-package bash

echo "=== 回传产物 ==="
mkdir -p /work/out
cp -v "$BUILD_DIR"/*.raw "$BUILD_DIR"/*.install.iso /work/out/ 2>/dev/null || true
cp -f "$BUILD_DIR/kiwi-build.log" /work/out/ 2>/dev/null || true
ls -lh /work/out/
