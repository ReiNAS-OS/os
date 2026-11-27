#!/usr/bin/env bash
#
# ReiNAS OS — 本机起测（拉 CI 产物 + QEMU 起虚机）
#
# 用法:
#   ./scripts/vm.sh list                 # 列出 CI 最近的镜像构建
#   ./scripts/vm.sh pull [RUN_ID]        # 拉产物到 .vm/<arch>/（默认最新一次成功构建）
#   ./scripts/vm.sh boot                 # 首启：建 overlay + OVMF vars，串口控制台
#   ./scripts/vm.sh gui                  # 同上，但开 GUI 窗口（串口日志并行写文件）
#   ./scripts/vm.sh dev                  # 开发模式：虚机 + SSH 端口转发
#   ./scripts/vm.sh sync                 # fswatch 监听源码，rsync 进虚机本地盘
#   ./scripts/vm.sh key                  # 把宿主公钥装进虚机（rsync 免密用）
#   ./scripts/vm.sh install              # 用 install.iso 装到一块空盘（自动应答确认）
#   ./scripts/vm.sh serve [FILE]         # 宿主起 HTTP 服务，虚机里从 10.0.2.2:8000 取
#   ./scripts/vm.sh status               # 看 .vm 里有什么
#   ./scripts/vm.sh clean                # 删掉 .vm/（镜像、overlay、固件变量全清）
#
# 环境变量:
#   ARCH             目标架构，默认按宿主（Apple Silicon = aarch64，x86 = x86_64）
#   VM_MEM           内存 MB，默认 4096
#   VM_CPUS          vCPU 数，默认 4
#   PANEL_PORT       宿主转发到虚机 5090 的端口，默认 5090；设 0 关闭转发
#   BASE_IMAGE       跳过 pull，直接用现成的 .raw
#   INSTALL_TARGET   装机目标盘大小，默认 40G
#
# 为什么不用 SSH：镜像默认不开 SSH 密码登录（D-007），而且验证阶段的目标
# 就是「像真机一样用」。要往虚机里送文件用 serve + curl。
#
# boot 与 gui 的选择：boot 是串口控制台（-nographic），适合看内核日志、跑命令；
# gui 开 cocoa 窗口，是唯一能看清登录字标颜色/块字符/字体的模式 —— 串口日志里
# 那些是转义字节，肉眼没法判断。改登录界面后必须用 gui 验收。
#
# 为什么 Apple Silicon 上必须选 aarch64：qemu-system-x86_64 在这台机器上
# 只有 tcg（纯软件模拟），启动到登录 5-15 分钟；aarch64 有 hvf 硬件加速，
# 冷启动 20 秒。
#
# CI 产物是 .raw.xz（压缩的）。kiwi 出的是 8G raw，压缩后约 500M，先解开
# 再起虚机；overlay 的 backing file 指向解开的 raw，原始产物保持只读。
#
# 实现拆在 scripts/lib/ 下，按「关心的事」分文件，不按行数切：
#   vm-common.sh    日志、架构探测、固件路径、QEMU 参数底座
#   vm-artifacts.sh 从 CI 拉产物
#   vm-image.sh     起虚机、宿主 HTTP 服务、状态与清理
#   vm-dev.sh       开发模式：虚机 + SSH 转发 + fswatch/rsync 源码同步
#   vm-install.sh   装机（比 boot 复杂得多，单独一个文件）
#
# 加功能时先想它属于哪一类，别往 vm.sh 里堆。

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# shellcheck source=lib/vm-common.sh
. "$REPO_ROOT/scripts/lib/vm-common.sh"
# shellcheck source=lib/vm-artifacts.sh
. "$REPO_ROOT/scripts/lib/vm-artifacts.sh"
# shellcheck source=lib/vm-image.sh
. "$REPO_ROOT/scripts/lib/vm-image.sh"
# shellcheck source=lib/vm-dev.sh
. "$REPO_ROOT/scripts/lib/vm-dev.sh"
# shellcheck source=lib/vm-install.sh
. "$REPO_ROOT/scripts/lib/vm-install.sh"

case "${1:-}" in
    list)    list_runs ;;
    pull)    shift; pull "${1:-}" ;;
    boot)    boot ;;
    gui)     gui ;;
    dev)     dev ;;
    sync)    sync ;;
    key)     key ;;
    install) install ;;
    serve)   shift; serve "${1:-}" ;;
    status)  status ;;
    clean)   clean ;;
    *)
        # 用法说明只在本文件顶部。别用 $0 —— 脚本被 source 时它不对。
        sed -n '2,46p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'
        exit 1
        ;;
esac
