# ReiNAS OS — 装机
#
# 被 vm.sh source。依赖 lib/vm-common.sh 的日志、固件路径、QEMU 参数底座。

# ─────────────────────────────────────────────────────────────
#  装机
#
#  ⚠️ 不能直接 -cdrom 启动 ISO：ISO 里 GRUB 的 grub.cfg 写了
#     `terminal_input serial`，但这版 GRUB 没编进 serial 模块，那两行执行失败
#     （日志里的 "terminal `serial' isn't found"）。结果 GRUB 收不到任何按键，
#     5 秒超时后自动选第一个菜单项——也就是 "Boot from Hard Disk"，直接 exit。
#
#     绕过办法：把 ISO 里的内核和 initrd 抽出来，用 -kernel/-initrd 直接启动。
#     install 分支不需要在 GRUB 里做选择，跳过去就行。ISO 仍然挂着，因为
#     root=install:CDLABEL=REINAS_OS 要靠它找 squashfs。
#
#     装机的交互（"Destroying ALL data on /dev/vda, continue ?"）走文本界面，
#     那是 kiwi 的 dialog，读内核控制台 ttyAMA0。所以要一个双向串口：
#     socket 用来写确认键，logfile 用来读日志。
#       - monitor 的 sendkey 不行，它注入的是 USB/PS2 键盘，dialog 收不到
#       - -serial file: 不行，单向，写不进去
#       - 宿主 nc -U 去读 socket 也不行，实测收不到字节
# ─────────────────────────────────────────────────────────────

# 装机目标盘大小。只有 install 用，所以不放进 vm-common.sh。
INSTALL_TARGET="${INSTALL_TARGET:-40G}"

# 从 ISO 抽出装机内核。抽过一次就复用。
#
# 结果放 INSTALLER_DIR 而不是 echo 给调用方 —— 日志走 stderr 了，理论上
# 不会污染命令替换，但让「函数返回路径」和「函数打日志」共用一条流始终是
# 隐患，用全局变量最省心。
extract_installer() {
    local iso="$1"
    local out
    out="$(vm_dir)/installer"
    local kdir="$out/boot/$ARCH/loader"
    if [ -f "$kdir/linux" ] && [ -f "$kdir/initrd" ]; then
        INSTALLER_DIR="$out"
        return
    fi
    mkdir -p "$out"
    log "从 ISO 抽装机内核和 initrd"
    bsdtar -xf "$iso" -C "$out" "boot/$ARCH/loader/linux" "boot/$ARCH/loader/initrd" \
        || die "从 ISO 抽文件失败。要 bsdtar（macOS 自带，Linux 装 libarchive-tools）"
    [ -f "$kdir/linux" ] && [ -f "$kdir/initrd" ] || die "ISO 里没有 boot/$ARCH/loader/"
    INSTALLER_DIR="$out"
}

# 往虚机串口写字节（等于在串口终端上敲键盘）。
# 用 nc -w 兜住：socket 是 server 模式，写完不关会一直等。
serial_send() {
    local sock="$1" bytes="$2"
    printf '%s' "$bytes" | nc -U -w 2 "$sock" >/dev/null 2>&1 || true
}

# 等串口日志里出现某个串。返回 0 = 出现，1 = 超时。
wait_for_log() {
    local file="$1" pattern="$2" timeout="${3:-180}"
    local i
    for i in $(seq 1 "$timeout"); do
        if [ -f "$file" ] && LC_ALL=C grep -aq -- "$pattern" "$file" 2>/dev/null; then
            return 0
        fi
        sleep 1
    done
    return 1
}

install() {
    local dir; dir=$(vm_dir)
    local iso
    iso=$(find "$dir" -maxdepth 1 -name '*.install.iso' | sort | tail -1)
    [ -n "$iso" ] || die "找不到 install.iso。先跑 ./scripts/vm.sh pull"

    local target="$dir/install-target.raw"
    if [ ! -f "$target" ]; then
        log "造一块 ${INSTALL_TARGET} 空盘（验证首启扩盘）"
        qemu-img create -f raw "$target" "$INSTALL_TARGET" >/dev/null
    else
        log "复用装机盘 $target"
    fi

    local bin="qemu-system-$ARCH"
    command -v "$bin" >/dev/null || die "找不到 ${bin}"
    command -v nc >/dev/null || die "需要 nc（往虚机串口写确认键）"

    # 装机盘用 raw 直接写，不是 overlay —— overlay 的 backing 是镜像，
    # 装机会把备份分区头写穿到 backing 里。
    #
    # 固件变量盘必须重铺：残留的 BootXXXX 指向 boot 用过的那块盘，UEFI 会
    # 一直试它、失败后退回 PXE，看起来像装机盘没做对引导。
    prepare_firmware 1

    extract_installer "$iso"
    local kdir="$INSTALLER_DIR/boot/$ARCH/loader"
    [ -f "$kdir/linux" ] && [ -f "$kdir/initrd" ] || die "ISO 里没有装机内核 $kdir"

    local serial="$dir/install-serial.log"
    local sock="$dir/inst.sock"
    rm -f "$serial" "$sock"

    read_args
    ARGS+=(-drive "file=$target,format=raw,if=virtio")
    ARGS+=(-drive "file=$iso,media=cdrom,if=none,id=cd0")
    ARGS+=(-device virtio-scsi-pci -device scsi-cd,drive=cd0)
    ARGS+=(-kernel "$kdir/linux")
    ARGS+=(-initrd "$kdir/initrd")
    ARGS+=(-append "cdinst=1 console=ttyAMA0,115200n8 root=install:CDLABEL=REINAS_OS")
    ARGS+=(-display none)
    # 串口用 chardev + logfile：
    #   socket 是为了往里写确认键（安装器的确认框从 ttyAMA0 读）
    #   logfile 是为了读输出（nc -U 连上去收不到数据，QEMU 的 socket
    #   chardev 只在有客户端且对端可写时才转发，实测读不到）
    # 两个都要，缺一个就看不见安装过程或者没法应答。
    ARGS+=(-chardev "socket,id=ser0,path=$sock,server=on,wait=off,logfile=$serial,logappend=on")
    ARGS+=(-serial "chardev:ser0")

    # 上一个 qemu 没退干净会占着面板端口，新进程起不来，报错还藏在后台。
    if [ "$PANEL_PORT" != 0 ] && lsof -nP -iTCP:"$PANEL_PORT" -sTCP:LISTEN >/dev/null 2>&1; then
        die "端口 ${PANEL_PORT} 已被占用（多半是上次没退干净的 qemu）。先 kill 掉，或 PANEL_PORT=0 跳过转发。"
    fi

    log "启动装机器（-kernel 直启，跳过 GRUB）"
    log "目标盘 $target"
    log "串口日志 $serial"

    "$bin" "${ARGS[@]}" &
    local qpid=$!
    trap 'kill "$qpid" 2>/dev/null || true' EXIT INT TERM

    # kiwi 的 oem 安装器会问「真的要抹掉 /dev/vda 吗」，默认高亮 Yes。
    if wait_for_log "$serial" "Destroying ALL data" 300; then
        log "安装器已就绪，确认抹盘"
        sleep 3
        serial_send "$sock" $'\r'
    else
        warn "等不到安装器的确认提示，看 ${serial} 排查"
    fi

    # 安装器解压完会 kexec 起真系统，然后跑 oem-repart 扩盘。
    # 判据用 kexec 那条 "Bye!" —— 它一定出现在部署完成之后。
    if wait_for_log "$serial" "kexec_core: Starting new kernel" 1800; then
        ok "镜像已写入目标盘，kexec 进入已安装系统"
    else
        warn "等不到 kexec，安装可能没走完，看 ${serial}"
    fi

    sleep 15
    kill "$qpid" 2>/dev/null || true
    wait "$qpid" 2>/dev/null || true
    trap - EXIT INT TERM

    ok "装机完成：$target"
    log "从装好的盘启动：BASE_IMAGE=$target ./scripts/vm.sh boot"
    log "（boot 会为它建 overlay，原盘保持只读，可以反复重来）"
}

# 宿主起 HTTP 服务，虚机里从 10.0.2.2:8000 取文件。
# QEMU user 网络的网关固定是 10.0.2.2，不用配 IP。
