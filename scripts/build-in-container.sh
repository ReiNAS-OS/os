#!/usr/bin/env bash
#
# ReiNAS OS — 在容器里构建（不需要宿主是 Fedora）
#
# 用法:
#   ./scripts/build-in-container.sh              # 完整构建，日志实时输出
#   ./scripts/build-in-container.sh --shell      # 进容器交互调试
#   ./scripts/build-in-container.sh --quiet      # 只输出关键行
#
# 前置：docker 或 podman，且容器要有 loop 设备和 mount 权限（--privileged）。
#   macOS: OrbStack / Docker Desktop 均可，本脚本默认走 amd64 平台模拟。
#   Linux: 直接跑，速度快得多。
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

FEDORA_VER="${FEDORA_VER:-45}"
# 默认跟随宿主架构。硬编码 linux/amd64 在 Apple Silicon 上会让 Rosetta
# 参与进来，而 amd64 容器的动态链接器在 arm64 内核下会解析失败：
#   OrbStack ERROR: Dynamic loader not found: /lib64/ld-linux-x86-64.so.2
# 需要交叉构建 x86_64 镜像时显式传 PLATFORM=linux/amd64，但要知道代价。
case "$(uname -m)" in
    arm64|aarch64) DEFAULT_PLATFORM=linux/arm64 ;;
    *)             DEFAULT_PLATFORM=linux/amd64 ;;
esac
PLATFORM="${PLATFORM:-$DEFAULT_PLATFORM}"
MODE=build

while [ $# -gt 0 ]; do
    case "$1" in
        --shell)  MODE=shell ;;
        --quiet)  MODE=quiet ;;
        -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
        *) echo "未知参数: $1" >&2; exit 1 ;;
    esac
    shift
done

# 选容器运行时
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    RUNTIME=docker
elif command -v podman >/dev/null 2>&1; then
    RUNTIME=podman
else
    cat >&2 <<'EOF'
找不到可用的容器运行时。

  没有 docker/podman          → 装 Docker Desktop / OrbStack / podman
  有 docker 但连不上 daemon   → 启动 OrbStack 或 Docker Desktop
EOF
    exit 1
fi
echo "运行时: $RUNTIME  平台: $PLATFORM  Fedora: $FEDORA_VER"

# ─────────────────────────────────────────────────────────────────────
# 防重复：同一时间只允许一个构建容器
# ─────────────────────────────────────────────────────────────────────
# 用固定名字 + 启动前清理。历史上这里出过事故：终止 shell 包装不会杀掉
# docker run 的子进程，结果两个容器并发写同一个日志文件。
CONTAINER_NAME="reinas-build-$$"
cleanup() {
    "$RUNTIME" rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

# 检查是否有残留的 reinas 构建容器
stale=$("$RUNTIME" ps -aq --filter "name=reinas-build-" 2>/dev/null || true)
if [ -n "$stale" ]; then
    echo "发现残留构建容器，先清理："
    echo "$stale" | while read -r id; do
        "$RUNTIME" rm -f "$id" >/dev/null 2>&1 || true
        echo "  已删除 $id"
    done
fi

# 宿主架构和目标架构不一致时（如 Apple Silicon 建 x86_64）要显式指定
HOST_ARCH="$(uname -m)"
case "$HOST_ARCH" in
    arm64|aarch64) HOST_ARCH=aarch64 ;;
    x86_64|amd64)  HOST_ARCH=x86_64 ;;
esac
if [ "$HOST_ARCH" = aarch64 ] && [ "$PLATFORM" = "linux/amd64" ]; then
    echo "警告: 在 arm64 宿主上模拟 x86_64。除了慢 2-4 倍，"
    echo "      还可能撞上 Rosetta 的动态链接器问题导致构建失败。"
    echo "      交叉构建请优先在真 x86_64 机器或 CI 上做。"
fi

run_args=(
    --rm
    --name "$CONTAINER_NAME"
    --privileged                      # kiwi 要 losetup / mount / mknod
    --platform "$PLATFORM"
    -v "$REPO_ROOT":/work
    -w /work
    -e PROFILE="${PROFILE:-Disk}"
)

case "$MODE" in
    shell)
        exec "$RUNTIME" run -it "${run_args[@]}" "fedora:$FEDORA_VER" bash
        ;;
    quiet)
        # 只保留里程碑行，避免刷屏
        exec "$RUNTIME" run "${run_args[@]}" "fedora:$FEDORA_VER" bash -c '
            dnf install -y -q kiwi-cli kiwi-systemdeps distribution-gpg-keys \
                createrepo_c rpm-build 2>&1 | grep -E "^(Error|Failed)" || true
            bash /work/.docker/build-in-fedora.sh 2>&1 \
                | grep -E "^(===|rpm:|FAIL|\[ *(INFO|WARN|ERROR) *\])|Kiwi.*Error|Traceback"
        '
        ;;
    build)
        # 不用 tail/head —— 它们会缓冲到进程结束才吐，构建期间看不到任何东西。
        # 这里直接透传，kiwi 自带进度条和阶段日志。
        exec "$RUNTIME" run "${run_args[@]}" "fedora:$FEDORA_VER" bash -c '
            set -o pipefail
            echo "[容器] 安装构建依赖..."
            dnf install -y -q kiwi-cli kiwi-systemdeps distribution-gpg-keys \
                createrepo_c rpm-build
            echo "[容器] 依赖就绪，开始构建"
            bash /work/.docker/build-in-fedora.sh
        '
        ;;
esac
