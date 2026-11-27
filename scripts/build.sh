#!/usr/bin/env bash
#
# ReiNAS OS — 构建入口
#
# 用法:
#   ./scripts/build.sh              # 构建镜像（root 锁定，生产形态）
#   ./scripts/build.sh --root-password          # 给 root 设密码 123456
#   ./scripts/build.sh --root-password=xxx      # 用自定义 root 密码
#   ./scripts/build.sh --list-boxes # 列出可用的构建箱
#   ./scripts/build.sh --deps       # 只装依赖
#   ./scripts/build.sh --rpm-only   # 只编译 reinas-release
#
# 版本锁定（D-008）：
#   默认每次都吃仓库最新版本，构建不可复现。
#   ./scripts/build.sh --lock-out            # 构建后导出 out/*.lock
#   ./scripts/build.sh --lock path/to.lock   # 按锁文件复现
#
# 直接在宿主机跑 kiwi-ng system build，不套 VM。宿主要有完整 /dev（udev 在跑）。
# 为什么不用容器或手搭 chroot：见 docs/decisions.md D-006。
#
# root 密码（D-007）：
#   默认关闭 —— root 和 reinas 都锁定，SSH 禁密码登录，与生产形态一致。
#   只有显式加 --root-password 才会给 root 设密码并放开 SSH root 密码登录。
#   ⚠️ 用开关构建出的镜像不要对外发布。
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

KIWI_DIR="$REPO_ROOT/kiwi"
OUT_DIR="$REPO_ROOT/out"
PROFILE="${PROFILE:-Disk}"

# 目标架构。空 = 用宿主架构。
# 显式指定时传给 kiwi 的 --target-arch，让它选对应的 <preferences arch="...">。
#
# 为什么不做交叉构建：kiwi 装包的脚本要能执行，跨架构跑不起来。
# 要出 aarch64 镜像就在 arm64 runner 上跑，原生构建，不交叉。
TARGET_ARCH="${TARGET_ARCH:-}"

# root 密码开关（D-007）。空 = 锁定 root，与生产形态一致。
# build.sh 会把它写成 kiwi/root.conf，由描述文件的 <file> 带进镜像，
# config.sh 在 chroot 里读取。只有非空才给 root 设密码、才放开 SSH root
# 密码登录。
ROOT_PASSWORD="${ROOT_PASSWORD:-}"

# 版本锁定（D-008）。
#   LOCK_OUT=1       构建后把实际装到的版本导出成 out/*.lock
#   LOCK_FILE=path   按这个锁文件构建（锁定显式包版本）
LOCK_OUT=0
LOCK_FILE=""

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
        kiwi-cli kiwi-systemdeps-filesystems kiwi-systemdeps-bootloaders \
        distribution-gpg-keys createrepo_c rpm-build python3-zstandard
    ok "依赖就绪"
}

build_rpm() {
    log "编译 reinas-release"    # 产物必须落在 kiwi/rpms：kiwi 只把 description 目录当仓库源，
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
    # 只有 rpm 文件没有 repodata 的话，kiwi 会报
    #   Failed to download metadata (baseurl: "file:///description/rpms/")
    log "生成仓库元数据"
    command -v createrepo_c >/dev/null || die "找不到 createrepo_c"
    createrepo_c --quiet "$rpm_dir"
    ok "repodata 就绪"
}

# 生成 root 密码配置，供 kiwi 的 <file> 带进镜像。
# 见 docs/decisions-account.md D-007。默认（ROOT_PASSWORD 为空）生成空文件，
# config.sh 读到空值就不动账号，镜像与生产形态一致。
#
# 文件内容就是密码明文本身，一行，不带引号。config.sh 用 `read` 取，
# 不用 `source` —— 密码里带 $ ` " \ 之类的字符不会被当成 shell 展开。
write_root_conf() {
    local conf="$KIWI_DIR/root.conf"

    if [ -n "$ROOT_PASSWORD" ]; then
        # 换行会把文件变成多行，读出来只剩第一行，直接拒绝
        case "$ROOT_PASSWORD" in
            *$'\n'*) die "root 密码不能含换行" ;;
        esac
        log "root 密码：开启（root / ${ROOT_PASSWORD}）"
        printf '%s\n' "$ROOT_PASSWORD" > "$conf"
        printf '%s\n' \
            "⚠️  本次构建启用了 root 密码登录，产物不可对外发布。" >&2
    else
        log "root 密码：关闭（生产形态，root 锁定）"
        # 空文件，不是空行 —— config.sh 里 `read` 拿不到东西即为关闭
        : > "$conf"
    fi
    chmod 0644 "$conf"
}

# ─────────────────────────────────────────────────────────────
#  版本锁定（D-008）
#
#  默认构建吃仓库最新版本，不可复现。锁文件是「某次构建实际装了什么」的
#  快照，用它重建能装回同一批版本。
#
#  锁文件格式（与 kiwi 自己导出的 .packages 同构，可直接当输入）：
#     包名|epoch|版本|发布|arch
#  注释以 # 开头。只锁 <packages type="image"> 里显式列出的包 —— 依赖闭包
#  跟着走，因为显式包版本一钉，dnf 会把依赖解析到能满足它们的版本上。
#
#  ⚠️ 锁文件不入库、CI 不提交代码。它只是构建产物，跟着镜像一起分发。
# ─────────────────────────────────────────────────────────────

# 从 kiwi 导出的 out/*.packages（`NAME|EPOCH|VERSION|RELEASE|ARCH|DISTURL|LICENSE`）
# 里抽出显式包，生成紧凑锁文件。
gen_lock() {
    local src="$1" dst="$2"
    [ -f "$src" ] || die "找不到 kiwi 的包清单: $src"

    # 显式包名单从描述文件读，保证锁文件只含我们声明过的包
    local explicit
    explicit=$(python3 "$REPO_ROOT/scripts/check-xml.py" --list-explicit "$KIWI_DIR/reinas.kiwi") \
        || die "读不到显式包列表"

    log "生成锁文件 $(basename "$dst")"
    python3 - "$src" "$dst" "$explicit" <<'PY'
import sys

src, dst, explicit = sys.argv[1], sys.argv[2], sys.argv[3].split()
want = set(explicit)

rows = []
missing = []
seen = set()
for line in open(src, encoding='utf-8'):
    line = line.strip()
    if not line or line.startswith('#'):
        continue
    parts = line.split('|')
    if len(parts) < 5:
        continue
    name, epoch, ver, rel, arch = parts[:5]
    if name not in want:
        continue
    seen.add(name)
    e = f"{epoch}:" if epoch and epoch != '0' and epoch != '(none)' else ''
    rows.append(f"{name}|{e}{ver}|{rel}|{arch}")

missing = sorted(want - seen)

with open(dst, 'w', encoding='utf-8') as f:
    f.write("# ReiNAS 版本锁文件\n")
    f.write("# 由 scripts/build.sh --lock-out 生成，格式：包名|版本|发布|arch\n")
    f.write("# 用法：./scripts/build.sh --lock <本文件>\n")
    f.write("# ⚠️ 只锁显式列出的包；依赖跟随仓库解析。\n")
    f.write("#\n")
    for r in sorted(rows):
        f.write(r + "\n")

print(f"  {len(rows)} 个包写入 {dst}")
if missing:
    print(f"  ⚠️ 描述文件里列了但没装上（可能是 glob 或被 uninstall 移除）：")
    for m in missing:
        print(f"     {m}")
PY
    ok "锁文件: $(basename "$dst")"
}

# 读锁文件，派生一个把显式包改写成 NEVRA 的描述文件。
# 不改 reinas.kiwi 本体 —— 锁定的变体是派生物，用完可丢。
apply_lock() {
    local lock="$1"
    [ -f "$lock" ] || die "找不到锁文件: $lock"

    # 锁文件放在 kiwi/ 外面时 kiwi 看不到；所以派生描述放 kiwi/
    local locked_desc="$KIWI_DIR/reinas.locked.kiwi"

    log "按锁文件构建: $(basename "$lock")"
    python3 - "$KIWI_DIR/reinas.kiwi" "$lock" "$locked_desc" <<'PY'
import re
import sys

src, lock, dst = sys.argv[1], sys.argv[2], sys.argv[3]

# 解析锁文件：包名 -> (版本, 发布, arch)
pinned = {}
for line in open(lock, encoding='utf-8'):
    line = line.strip()
    if not line or line.startswith('#'):
        continue
    parts = line.split('|')
    if len(parts) != 4:
        raise SystemExit(f"锁文件格式错误（应为 4 段）: {line}")
    name, ver, rel, arch = parts
    pinned[name] = (ver, rel, arch)

xml = open(src, encoding='utf-8').read()

def pin(m):
    """把 <package name="x"/> 换成 <package name="x-ver-rel.arch"/>"""
    indent, name, arch_attr = m.group(1), m.group(2), m.group(3) or ''
    if name not in pinned:
        return m.group(0)
    ver, rel, arch = pinned[name]
    # 描述文件里已有 arch 属性时以它为准，避免重复指定
    if arch_attr:
        return f'{indent}<package name="{name}-{ver}-{rel}"{arch_attr}/>'
    return f'{indent}<package name="{name}-{ver}-{rel}.{arch}"/>'

new, n = re.subn(
    r'(?m)^(\s*)<package name="([^"]+)"(\s+arch="[^"]+")?\s*/>',
    pin,
    xml,
)

open(dst, 'w', encoding='utf-8').write(new)
print(f"  改写 {n} 处 <package>，输出 {dst}")
PY
    ok "派生描述: reinas.locked.kiwi"
    LOCKED_DESC="$locked_desc"
}

build_image() {
    log "构建镜像 profile=$PROFILE arch=${TARGET_ARCH:-宿主}"

    write_root_conf

    # 描述文件：默认用 reinas.kiwi，带 --lock 时改用派生的锁定版本。
    local desc="$KIWI_DIR/reinas.kiwi"
    if [ -n "$LOCK_FILE" ]; then
        apply_lock "$LOCK_FILE"
        desc="$LOCKED_DESC"
    fi

    # --online 会校验包名在 Fedora 里真实存在。
    # 漏包（dracut-network）和拼错包名这类错误，不提前拦住就要等到
    # 构建跑到最末尾才暴露，白等十几分钟。
    #
    # 锁定的描述里包名带 NEVRA 后缀，--online 的「包名存在」校验认不出来
    # （它只认裸包名，会把 cockpit-372-1.fc45 判成不存在），所以锁定构建
    # 只做离线静态检查。锁文件本身来自一次成功构建，包名必然合法。
    if [ -n "$LOCK_FILE" ]; then
        python3 "$REPO_ROOT/scripts/check-xml.py" "$desc" \
            || die "锁定的描述文件未通过静态检查"
    else
        python3 "$REPO_ROOT/scripts/check-xml.py" --online "$desc" \
            || die "kiwi 描述未通过静态检查"
    fi

    command -v kiwi-ng >/dev/null || die "找不到 kiwi-ng，先跑 --deps"

    mkdir -p "$OUT_DIR"

    # 全局选项（--type/--profile/--logfile/--target-arch/--kiwi-file）必须在
    # 子命令之前，子命令选项（--description/--target-dir）在 "system build" 之后。
    #
    # ⚠️ 锁定构建必须显式 --kiwi-file。kiwi 找描述文件时对 *.kiwi 做 glob
    #    然后 sorted 取第一个，reinas.locked.kiwi 排在 reinas.kiwi 前面，
    #    不指定就会静默用错文件。
    local kiwi_file_opt=()
    if [ -n "$LOCK_FILE" ]; then
        kiwi_file_opt=(--kiwi-file "$(basename "$desc")")
    fi

    # --target-arch 让 kiwi 选匹配的 <preferences arch="...">。不传则用宿主架构。
    local arch_opt=()
    if [ -n "$TARGET_ARCH" ]; then
        arch_opt=(--target-arch "$TARGET_ARCH")
        log "目标架构：$TARGET_ARCH"
    fi

    # 跑 kiwi-ng system build，不套 boxbuild 的 VM。
    #
    # 为什么不用 boxbuild：
    #   1. arm64 runner 没有 /dev/kvm，QEMU 起不来：
    #        qemu-system-aarch64: -accel accel=kvm: Could not access KVM
    #   2. boxbuild 的 VM 只是为了提供「有 udev 的完整环境」。CI 已经在
    #      Fedora chroot 里跑，chroot bind 了宿主的 /dev，而 udev 在 runner
    #      上跑着，/dev/loopNpX 能正常创建。
    #
    # kiwi 维护者 Conan-Kudo 在 mock#1554 的说法：非 VM 的镜像类型用
    # simple isolation/chroot 模式即可。
    #
    # 前提：本机（或 CI 的 chroot）是 Fedora，装了 kiwi 和系统依赖。
    # 本地装依赖用 --deps；CI 见 .github/actions/build-image/action.yml
    # 的「安装 kiwi」步骤。
    $SUDO kiwi-ng --type oem --profile "$PROFILE" \
        --logfile "$OUT_DIR/kiwi-build.log" \
        "${arch_opt[@]}" \
        "${kiwi_file_opt[@]}" \
        system build \
        --description "$KIWI_DIR" \
        --target-dir "$OUT_DIR"

    # 压缩 raw。8G 的原始文件压到 ~620MB，分发时省带宽也省用户下载时间。
    #
    # -T0 用所有核心。xz 的单线程很慢（8G 要十几分钟），多线程能压到 2-3 分钟。
    # -6 是默认档位，实测和 -9 差不到 1%，但快好几倍。
    #
    # 压缩完删掉未压缩的：CI 上传 artifact 时两个都传太浪费。
    # 需要未压缩版本时用 xz -dk 就地解开。
    local raw
    raw=$(find "$OUT_DIR" -maxdepth 1 -name '*.raw' -print -quit 2>/dev/null || true)
    if [ -n "$raw" ]; then
        log "压缩 $(basename "$raw")"
        $SUDO xz -T0 -6 -f "$raw"
        ok "已压缩: $(basename "$raw").xz"
    fi

    echo
    log "产物"
    ls -lh "$OUT_DIR" | sed 's/^/    /'
    for f in "$OUT_DIR"/*.raw.xz "$OUT_DIR"/*.install.iso; do
        [ -e "$f" ] || continue
        ( cd "$OUT_DIR" && sha256sum "$(basename "$f")" > "$(basename "$f").sha256" )
    done

    # 导出锁文件：把这次实际装到的显式包版本记下来，
    # 下次用 --lock 就能装回同一批。分布式取得，不入库（D-008）。
    if [ "$LOCK_OUT" = 1 ]; then
        local pkgs
        pkgs=$(ls "$OUT_DIR"/*.packages 2>/dev/null | head -1)
        if [ -n "$pkgs" ]; then
            gen_lock "$pkgs" "$OUT_DIR/ReiNAS-$PROFILE.lock"
        else
            printf '%s\n' "⚠️  没找到 out/*.packages，无法导出锁文件" >&2
        fi
    fi

    ok "完成"
}

ACTION=all
while [ $# -gt 0 ]; do
    case "$1" in
        --deps)       ACTION=deps ;;
        --rpm-only)   ACTION=rpm ;;
        --list-boxes) ACTION=boxes ;;
        # 只跑构建（不装依赖）。CI 用它：runner 上的依赖由 workflow 自己准备，
        # 而 install_deps 走 dnf，Ubuntu 上没有。
        --build-only) ACTION=build ;;
        --clean)      rm -rf "$OUT_DIR"; mkdir -p "$OUT_DIR"; ok "已清空 out/" ;;
        # 版本锁定（D-008）
        --lock-out)      LOCK_OUT=1 ;;
        --lock)
            shift
            [ $# -gt 0 ] || die "--lock 后面要跟锁文件路径"
            LOCK_FILE="$1"
            [ -f "$LOCK_FILE" ] || die "锁文件不存在: $LOCK_FILE"
            LOCK_FILE="$(cd "$(dirname "$LOCK_FILE")" && pwd)/$(basename "$LOCK_FILE")"
            ;;
        --lock=*)
            LOCK_FILE="${1#*=}"
            [ -n "$LOCK_FILE" ] || die "--lock= 后面不能为空"
            [ -f "$LOCK_FILE" ] || die "锁文件不存在: $LOCK_FILE"
            LOCK_FILE="$(cd "$(dirname "$LOCK_FILE")" && pwd)/$(basename "$LOCK_FILE")"
            ;;
        # root 密码开关。不带值 = 用 123456；带 = 用指定密码。
        --root-password)
            ROOT_PASSWORD=123456 ;;
        --root-password=*)
            ROOT_PASSWORD="${1#*=}"
            [ -n "$ROOT_PASSWORD" ] || die "--root-password= 后面不能为空"
            ;;
        -h|--help)    sed -n '2,25p' "$0"; exit 0 ;;
        *)            die "未知参数: $1" ;;
    esac
    shift
done

# --lock-out 与 --lock 语义冲突：一次构建不可能「既锁定版本又导出这次装到的
# 版本」。锁定构建的产物清单没有比对意义（它就是按锁装的），而导出锁文件的
# 构建必须是跟最新版的。同时给说明比让用户猜好。
if [ "$LOCK_OUT" = 1 ] && [ -n "$LOCK_FILE" ]; then
    die "--lock-out 与 --lock 不能同时用：锁定构建不导出锁文件"
fi

case "$ACTION" in
    deps)  install_deps ;;
    rpm)   build_rpm ;;
    boxes) kiwi-ng system boxbuild --list-boxes ;;
    build) build_rpm; build_image ;;
    all)   install_deps; build_rpm; build_image ;;
esac
