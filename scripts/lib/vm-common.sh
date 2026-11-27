# ReiNAS OS — vm.sh 与 vm-install.sh 共用的底座
#
# 被 source，不单独执行。调用方必须先 cd 到仓库根、定义好 ARCH/VM_MEM 等
# 变量，再 source 本文件。
#
# 这里只放「两个脚本都要」的东西：日志、架构探测、镜像版本、固件路径、
# QEMU 参数底座。装机特有的逻辑在 lib/vm-install.sh。

set -euo pipefail

# 调用方（vm.sh）必须先把仓库根设进 REPO_ROOT。这里不从 BASH_SOURCE 推 ——
# 被 source 时那是 lib/ 目录，算出来的路径差一层。
: "${REPO_ROOT:?必须先定义 REPO_ROOT（仓库根）再 source 本文件}"
cd "$REPO_ROOT"

readonly REPO="ReiNAS-OS/os"
readonly WORKFLOW="image-build.yml"
readonly VM_ROOT="$REPO_ROOT/.vm"

VM_MEM="${VM_MEM:-4096}"
VM_CPUS="${VM_CPUS:-4}"
PANEL_PORT="${PANEL_PORT:-5090}"
# dev 模式下转发虚机 22 到宿主的这个端口，给 rsync 用。0 = 不转发。
DEV_SSH_PORT="${DEV_SSH_PORT:-5099}"
# 源码在虚机里的落点。必须是本地盘（不是挂载目录），否则热更新不工作。
DEV_REMOTE_DIR="${DEV_REMOTE_DIR:-/root/reinas}"

BLUE=$'\033[34m'; GREEN=$'\033[32m'; RED=$'\033[31m'; YELLOW=$'\033[33m'; RESET=$'\033[0m'
# 日志全部走 stderr。有几个函数（find_base_image 等）用 $(...) 把路径返回给
# 调用方，日志落 stdout 会被一起抓走，拼出不存在的路径。
log()  { printf '%s==>%s %s\n' "$BLUE" "$RESET" "$*" >&2; }
ok()   { printf '%s OK %s %s\n' "$GREEN" "$RESET" "$*" >&2; }
warn() { printf '%s !! %s %s\n' "$YELLOW" "$RESET" "$*" >&2; }
die()  { printf '%sFAIL%s %s\n' "$RED" "$RESET" "$*" >&2; exit 1; }

# 宿主架构决定默认目标架构。Apple Silicon 上跑 x86_64 只能 tcg，慢到没法用。
default_arch() {
    case "$(uname -m)" in
        arm64|aarch64) printf 'aarch64' ;;
        *)             printf 'x86_64' ;;
    esac
}
ARCH="${ARCH:-$(default_arch)}"

vm_dir() { printf '%s/%s' "$VM_ROOT" "$ARCH"; }

# 产物文件名里版本号是 0.1.0，release 号 -0 只在 raw 上出现。别写死，
# 从仓库里读出来，改版本时不用动这个脚本。
#
# 只认行首的 <version>：描述文件的注释里也提到过 <version>0.1.0</version>，
# 通配匹配会把注释抓进来。
image_version() {
    local v
    v=$(sed -n 's:^[[:space:]]*<version>\([^<]*\)</version>[[:space:]]*$:\1:p' kiwi/reinas.kiwi | head -1)
    [ -n "$v" ] || die "读不到 kiwi/reinas.kiwi 里的 <version>"
    printf '%s' "$v"
}
