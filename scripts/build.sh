#!/usr/bin/env bash
#
# ReiNAS OS — 构建入口
#
# 用法:
#   ./scripts/build.sh              # 构建镜像（调试账号关闭，生产形态）
#   ./scripts/build.sh --debug-password          # 构建时开启调试账号 reinas/123456
#   ./scripts/build.sh --debug-password=xxx      # 用自定义调试密码
#   ./scripts/build.sh --list-boxes # 列出可用的构建箱
#   ./scripts/build.sh --deps       # 只装依赖
#   ./scripts/build.sh --rpm-only   # 只编译 reinas-release
#
# 走 kiwi 官方的 boxbuild 路径（完整 /dev + udev 的虚拟机内构建）。
# 为什么不用容器或手搭 chroot：见 docs/decisions.md D-006。
#
# 调试账号（D-007）：
#   默认关闭 —— reinas 账号锁定、SSH 禁密码登录，与生产形态一致。
#   只有显式加 --debug-password 才会写入初始密码并放开 SSH 密码登录。
#   ⚠️ 用开关构建出的镜像不要对外发布。
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

KIWI_DIR="$REPO_ROOT/kiwi"
OUT_DIR="$REPO_ROOT/out"
PROFILE="${PROFILE:-Disk}"
BOX="${BOX:-fedora}"

# 调试账号开关（D-007）。空 = 关闭，与生产形态一致。
# build.sh 会把它写成 kiwi/debug.conf，由描述文件的 <file> 带进镜像，
# config.sh 在 chroot 里读取。只有非空才设密码、才放开 SSH 密码登录。
DEBUG_PASSWORD="${DEBUG_PASSWORD:-}"

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
        distribution-gpg-keys createrepo_c rpm-build python3-zstandard
    ok "依赖就绪"
}

build_rpm() {
    log "编译 reinas-release"    # 产物必须落在 kiwi/rpms：boxbuild 只共享 description 目录，
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

# 生成调试账号配置，供 kiwi 的 <file> 带进镜像。
# 见 docs/decisions.md D-007。默认（DEBUG_PASSWORD 为空）生成空文件，
# config.sh 读到空值就不动账号，镜像与生产形态一致。
#
# 文件内容就是密码明文本身，一行，不带引号。config.sh 用 `read` 取，
# 不用 `source` —— 密码里带 $ ` " \ 之类的字符不会被当成 shell 展开。
write_debug_conf() {
    local conf="$KIWI_DIR/debug.conf"

    if [ -n "$DEBUG_PASSWORD" ]; then
        # 换行会把文件变成多行，读出来只剩第一行，直接拒绝
        case "$DEBUG_PASSWORD" in
            *$'\n'*) die "调试密码不能含换行" ;;
        esac
        log "调试账号：开启（reinas / ${DEBUG_PASSWORD}）"
        printf '%s\n' "$DEBUG_PASSWORD" > "$conf"
        printf '%s\n' \
            "⚠️  本次构建含明文调试密码，产物不可对外发布。" >&2
    else
        log "调试账号：关闭（生产形态）"
        # 空文件，不是空行 —— config.sh 里 `read` 拿不到东西即为关闭
        : > "$conf"
    fi
    chmod 0644 "$conf"
}

build_image() {
    log "构建镜像 profile=$PROFILE box=$BOX"

    write_debug_conf

    # --online 会校验包名在 Fedora 里真实存在。
    # 漏包（dracut-network）和拼错包名这类错误，不提前拦住就要等到
    # 构建跑到最末尾才暴露，白等十几分钟。
    python3 "$REPO_ROOT/scripts/check-xml.py" --online "$KIWI_DIR/reinas.kiwi" \
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
        # 调试账号开关。不带值 = 用 123456；带 = 用指定密码。
        --debug-password)
            DEBUG_PASSWORD=123456 ;;
        --debug-password=*)
            DEBUG_PASSWORD="${1#*=}"
            [ -n "$DEBUG_PASSWORD" ] || die "--debug-password= 后面不能为空"
            ;;
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
