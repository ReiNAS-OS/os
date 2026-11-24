#!/usr/bin/env bash
#
# ReiNAS OS — 构建入口
#
# 用法:
#   ./scripts/build-in-container.sh            # 在 Fedora 容器里构建
#   ./scripts/build-in-container.sh --shell    # 进容器交互调试
#
# ⚠️ 容器只适合验证前面的阶段（rpm 编译、包解析、软件安装）。
#    Docker 缺 udev，partx --add 之后 /dev/loopNpX 不会被创建，
#    kiwi 在建分区那一步必然失败：
#        KiwiMappedDeviceError: Device /dev/loop0p1 does not exist
#    这条已被 Fedora 官方描述零修改复现确认（见 docs/decisions.md D-006）。
#    要出完整镜像，必须用有真 /dev 的环境：GitHub Actions 的 KVM runner，
#    或一台真的 Fedora 主机。见 .github/workflows/build-image.yml
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

FEDORA_VER="${FEDORA_VER:-45}"

case "$(uname -m)" in
    arm64|aarch64) DEFAULT_PLATFORM=linux/arm64 ;;
    *)             DEFAULT_PLATFORM=linux/amd64 ;;
esac
PLATFORM="${PLATFORM:-$DEFAULT_PLATFORM}"

MODE=build
while [ $# -gt 0 ]; do
    case "$1" in
        --shell)   MODE=shell ;;
        -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
        *) echo "未知参数: $1" >&2; exit 1 ;;
    esac
    shift
done

if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    RUNTIME=docker
elif command -v podman >/dev/null 2>&1; then
    RUNTIME=podman
else
    echo "找不到可用的容器运行时（docker 或 podman）" >&2
    exit 1
fi

echo "运行时: $RUNTIME  平台: $PLATFORM  Fedora: $FEDORA_VER"

if [ "$PLATFORM" = "linux/amd64" ] && [ "$(uname -m)" != "x86_64" ]; then
    echo "警告: 在 $(uname -m) 上模拟 x86_64，慢 2-4 倍"
fi

# 防重复：同一时间只允许一个构建容器。
# 终止 shell 包装不会杀掉 docker run 的子进程，历史上因此并发跑过两个容器，
# 两个都往同一个日志文件写。
CONTAINER_NAME="reinas-build-$$"
cleanup() { "$RUNTIME" rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true; }
trap cleanup EXIT INT TERM

stale=$("$RUNTIME" ps -aq --filter "name=reinas-build-" 2>/dev/null || true)
if [ -n "$stale" ]; then
    echo "清理残留构建容器:"
    echo "$stale" | while read -r id; do
        "$RUNTIME" rm -f "$id" >/dev/null 2>&1 || true
        echo "  $id"
    done
fi

run_args=(
    --rm
    --name "$CONTAINER_NAME"
    --privileged
    --platform "$PLATFORM"
    -v "$REPO_ROOT":/work
    -w /work
    -e PROFILE="${PROFILE:-Disk}"
)

if [ "$MODE" = shell ]; then
    exec "$RUNTIME" run -it "${run_args[@]}" "fedora:$FEDORA_VER" bash
fi

exec "$RUNTIME" run "${run_args[@]}" "fedora:$FEDORA_VER" bash -c '
    set -o pipefail
    echo "[容器] 安装构建依赖..."
    dnf install -y -q kiwi-cli kiwi-systemdeps distribution-gpg-keys \
        createrepo_c rpm-build
    echo "[容器] 依赖就绪"
    bash /work/.docker/build-in-fedora.sh
'
