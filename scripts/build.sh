#!/usr/bin/env bash
#
# ReiNAS OS — 本地构建入口
#
# 做的事：编译 reinas-release → 校验 kiwi 描述 → 出 .raw + .install.iso
#
# 用法:
#   ./scripts/build.sh                      # 完整构建
#   ./scripts/build.sh --deps               # 只装依赖
#   ./scripts/build.sh --rpm-only           # 只编译 reinas-release
#   ./scripts/build.sh --clean              # 清产物后重建
#   ./scripts/build.sh --box                # 用 kiwi 自带的 boxbuild（隔离 VM）
#   ./scripts/build.sh --debug              # 保留 chroot 便于排查
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KIWI_DIR="$REPO_ROOT/kiwi"
RPM_SPEC="$REPO_ROOT/packages/reinas-release/reinas-release.spec"
RPM_DIR="$REPO_ROOT/rpms"
OUT_DIR="$REPO_ROOT/out"

PROFILE="${PROFILE:-Disk}"
IMAGE_TYPE="${IMAGE_TYPE:-oem}"
BOXBUILD=0
DEBUG_FLAG=""

RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; BLU=$'\033[34m'; RST=$'\033[0m'
log()  { printf '%s==>%s %s\n' "$BLU" "$RST" "$*"; }
ok()   { printf '%s OK %s %s\n' "$GRN" "$RST" "$*"; }
warn() { printf '%sWARN%s %s\n' "$YEL" "$RST" "$*"; }
die()  { printf '%sFAIL%s %s\n' "$RED" "$RST" "$*" >&2; exit 1; }

need_root() { [ "$(id -u)" = 0 ] || die "需要 root（kiwi 要挂 loop 设备）。用 sudo 或 --box。"; }
need_cmd()  { command -v "$1" >/dev/null 2>&1 || die "缺少命令: $1"; }

# ---------------------------------------------------------------- deps
install_deps() {
    log "安装构建依赖"
    if command -v dnf5 >/dev/null 2>&1 || command -v dnf >/dev/null 2>&1; then
        local DNF; DNF=$(command -v dnf5 || command -v dnf)
        $DNF install -y \
            kiwi-cli kiwi-systemdeps \
            distribution-gpg-keys \
            rpm-build rpmdevtools createrepo_c \
            podman git make
    else
        die "不是 Fedora 系主机。请在 Fedora 上跑，或用容器：scripts/build-in-container.sh"
    fi
    ok "依赖就绪"
}

# ---------------------------------------------------------------- rpm
build_rpm() {
    log "编译 reinas-release"
    need_cmd rpmbuild
    mkdir -p "$RPM_DIR" "$OUT_DIR"
    rm -f "$RPM_DIR"/reinas-release-*.noarch.rpm

    # 用 spec 所在目录做 _sourcedir，这样 install 段能直接取 files/ 和 base/
    rpmbuild -bb \
        --define "_sourcedir $(dirname "$RPM_SPEC")" \
        --define "_rpmdir $RPM_DIR" \
        --define "_build_name_fmt %%{NAME}-%%{VERSION}-%%{RELEASE}.%%{ARCH}.rpm" \
        "$RPM_SPEC" 2>&1 | sed 's/^/    /'

    local built
    built="$(find "$RPM_DIR" -name 'reinas-release-*.noarch.rpm' -print -quit)"
    [ -n "$built" ] || die "rpmbuild 没有产出 rpm"
    # 拍平目录结构
    if [ "$built" != "$RPM_DIR/$(basename "$built")" ]; then
        mv -f "$built" "$RPM_DIR/"
        find "$RPM_DIR" -mindepth 1 -type d -delete 2>/dev/null || true
    fi
    ok "产物: $(basename "$RPM_DIR"/reinas-release-*.noarch.rpm)"

    log "生成仓库元数据"
    need_cmd createrepo_c
    createrepo_c --quiet "$RPM_DIR"
    ok "repodata 就绪"
}

# ---------------------------------------------------------------- kiwi
build_image() {
    log "构建镜像 (profile=$PROFILE type=$IMAGE_TYPE)"
    need_cmd kiwi-ng

    mkdir -p "$OUT_DIR"
    local args=(
        --type "$IMAGE_TYPE"
        --profile "$PROFILE"
        --description "$KIWI_DIR"
        --target-dir "$OUT_DIR"
        --logfile "$OUT_DIR/kiwi-build.log"
    )
    [ -n "$DEBUG_FLAG" ] && args+=(--debug)

    if [ "$BOXBUILD" = 1 ]; then
        log "使用 boxbuild（隔离 VM，不需要 root）"
        kiwi-ng system boxbuild --box fedora -- "${args[@]}"
    else
        need_root
        kiwi-ng system build "${args[@]}"
    fi

    echo
    log "产物清单"
    ls -lh "$OUT_DIR" | sed 's/^/    /'
    echo
    for f in "$OUT_DIR"/*.raw "$OUT_DIR"/*.install.iso; do
        [ -e "$f" ] || continue
        ( cd "$OUT_DIR" && sha256sum "$(basename "$f")" > "$(basename "$f").sha256" )
    done
    ok "完成"
}

# ---------------------------------------------------------------- main
ACTION=all
while [ $# -gt 0 ]; do
    case "$1" in
        --deps)       ACTION=deps ;;
        --rpm-only)   ACTION=rpm ;;
        --clean)      rm -rf "$OUT_DIR"; mkdir -p "$OUT_DIR"; ok "已清空 out/" ;;
        --box)        BOXBUILD=1 ;;
        --debug)      DEBUG_FLAG=--debug ;;
        -h|--help)    sed -n '2,20p' "$0"; exit 0 ;;
        *)            die "未知参数: $1" ;;
    esac
    shift
done

case "$ACTION" in
    deps) install_deps ;;
    rpm)  need_root; build_rpm ;;
    all)  install_deps; build_rpm; build_image ;;
esac
