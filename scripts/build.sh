#!/usr/bin/env bash
#
# ReiNAS OS — 构建入口
#
# 用法:
#   ./scripts/build.sh              # 构建镜像
#   ./scripts/build.sh --list-boxes # 列出可用的构建箱
#   ./scripts/build.sh --deps       # 只装依赖
#   ./scripts/build.sh --rpm-only   # 只编译 reinas-release
#
# 走 kiwi 官方的 boxbuild 路径：在一个自带完整 /dev 和 udev 的虚拟机里构建。
#
# 为什么不能用容器：
#   Docker 里没有 udev，内核识别 loop 分区后不创建 /dev/loopNpX，
#   kiwi 建分区时必然失败：
#       KiwiMappedDeviceError: Device /dev/loop0p1 does not exist
#   已用 Fedora 官方描述零修改复现确认，见 docs/decisions.md D-006。
#
# 为什么不用手搭 chroot：
#   手工 bind /dev 后 loop 节点可用，但会接连撞上缺 grub i386-pc 模块、
#   dracut 找不到 /dev/log 等一堆问题——这些在 boxbuild 的完整 VM 里都不存在。
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

KIWI_DIR="$REPO_ROOT/kiwi"
OUT_DIR="$REPO_ROOT/out"
PROFILE="${PROFILE:-Disk}"
BOX="${BOX:-fedora}"

# 已经是 root 就不需要 sudo（CI 里 chroot 进去就是 root）
if [ "$(id -u)" = 0 ]; then SUDO=""; else SUDO="sudo"; fi

BLUE=$'\033[34m'; GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'
log() { printf '%s==>%s %s\n' "$BLUE" "$RESET" "$*"; }
ok()  { printf '%s OK %s %s\n' "$GREEN" "$RESET" "$*"; }
die() { printf '%sFAIL%s %s\n' "$RED" "$RESET" "$*" >&2; exit 1; }

install_deps() {
    log "安装构建依赖"
    local dnf
    dnf=$(command -v dnf5 || command -v dnf) || die "找不到 dnf，请在 Fedora 上运行"
    $SUDO "$dnf" install -y -q --skip-unavailable \
        kiwi-cli kiwi-boxed-plugin kiwi-systemdeps-boxbuild \
        distribution-gpg-keys createrepo_c rpm-build
    ok "依赖就绪"
}

build_rpm() {
    log "编译 reinas-release"
    # 产物必须落在 kiwi/rpms：boxbuild 只共享 description 目录，
    # 描述文件里用 this://./rpms 引用它。
    local rpm_dir="$KIWI_DIR/rpms"
    mkdir -p "$rpm_dir" "$OUT_DIR"
    rm -f "$rpm_dir"/reinas-release-*.rpm

    rpmbuild -bb \
        --define "_sourcedir $REPO_ROOT/packages/reinas-release" \
        --define "_rpmdir $rpm_dir" \
        --define "_build_name_fmt %%{NAME}-%%{VERSION}-%%{RELEASE}.%%{ARCH}.rpm" \
        "$REPO_ROOT/packages/reinas-release/reinas-release.spec" 2>&1 | sed 's/^/    /'

    local built
    built=$(find "$rpm_dir" -name 'reinas-release-*.noarch.rpm' -print -quit)
    [ -n "$built" ] || die "rpmbuild 没有产出 rpm"
    if [ "$built" != "$rpm_dir/$(basename "$built")" ]; then
        mv -f "$built" "$rpm_dir/"
        find "$rpm_dir" -mindepth 1 -type d -delete 2>/dev/null || true
    fi
    ok "产物: $(basename "$rpm_dir"/reinas-release-*.noarch.rpm)"

    # 必须生成仓库元数据：kiwi 把 reinas 当 rpm-md 仓库用，
    # 只有 rpm 文件没有 repodata 的话，boxbuild 里会报
    #   Failed to download metadata (baseurl: "file:///description/rpms/")
    log "生成仓库元数据"
    command -v createrepo_c >/dev/null || die "找不到 createrepo_c"
    createrepo_c --quiet "$rpm_dir"
    ok "repodata 就绪"
}

build_image() {
    log "构建镜像 profile=$PROFILE box=$BOX"

    python3 "$REPO_ROOT/scripts/check-xml.py" "$KIWI_DIR/reinas.kiwi" \
        || die "kiwi 描述未通过静态检查"

    command -v kiwi-ng >/dev/null || die "找不到 kiwi-ng，先跑 --deps"

    mkdir -p "$OUT_DIR"

    # 全局选项（--type/--profile/--logfile）必须在子命令之前，
    # 子命令选项（--description/--target-dir）在 boxbuild 的 "kiwi" 之后。
    $SUDO kiwi-ng --type oem --profile "$PROFILE" \
        --logfile "$OUT_DIR/kiwi-build.log" \
        system boxbuild --box "$BOX" kiwi \
        --description "$KIWI_DIR" \
        --target-dir "$OUT_DIR"

    echo
    log "产物"
    ls -lh "$OUT_DIR" | sed 's/^/    /'
    for f in "$OUT_DIR"/*.raw "$OUT_DIR"/*.install.iso; do
        [ -e "$f" ] || continue
        ( cd "$OUT_DIR" && sha256sum "$(basename "$f")" > "$(basename "$f").sha256" )
    done
    ok "完成"
}

ACTION=all
while [ $# -gt 0 ]; do
    case "$1" in
        --deps)       ACTION=deps ;;
        --rpm-only)   ACTION=rpm ;;
        --list-boxes) ACTION=boxes ;;
        --clean)      rm -rf "$OUT_DIR"; mkdir -p "$OUT_DIR"; ok "已清空 out/" ;;
        -h|--help)    sed -n '2,20p' "$0"; exit 0 ;;
        *)            die "未知参数: $1" ;;
    esac
    shift
done

case "$ACTION" in
    deps)  install_deps ;;
    rpm)   build_rpm ;;
    boxes) kiwi-ng system boxbuild --list-boxes ;;
    all)   install_deps; build_rpm; build_image ;;
esac
