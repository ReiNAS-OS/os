# ReiNAS OS — 起虚机（boot）与杂项（serve / status / clean）
#
# 被 vm.sh source。依赖 lib/vm-common.sh 的日志、固件路径、QEMU 参数底座。
# 装机逻辑在 lib/vm-install.sh —— 它比 boot 复杂得多，单独一个文件。

# ReiNAS OS — 起虚机（boot / install）与杂项（serve / status / clean）
#
# 被 vm.sh source。依赖 lib/vm-common.sh 的日志、固件路径、QEMU 参数底座。

# ─────────────────────────────────────────────────────────────
#  QEMU
# ─────────────────────────────────────────────────────────────

# 找基础镜像。BASE_IMAGE 优先，否则用 .vm 下的 raw。
#
# 只有 .raw.xz 时自动解开：pull 拉下来的是压缩包，解开的 8G raw 平时没必要
# 一直占着盘。解一次就放着，下次直接命中。
find_base_image() {
    if [ -n "${BASE_IMAGE:-}" ]; then
        [ -f "$BASE_IMAGE" ] || die "BASE_IMAGE 不存在: $BASE_IMAGE"
        printf '%s' "$BASE_IMAGE"
        return
    fi
    local dir; dir=$(vm_dir)
    local found
    found=$(find "$dir" -maxdepth 1 -name 'ReiNAS*.raw' 2>/dev/null | sort | tail -1)
    if [ -z "$found" ]; then
        local xz
        xz=$(find "$dir" -maxdepth 1 -name 'ReiNAS*.raw.xz' 2>/dev/null | sort | tail -1)
        [ -n "$xz" ] || die "找不到 raw 镜像。先跑 ./scripts/vm.sh pull"
        log "解开 $(basename "$xz")（8G，十几秒）"
        xz -dk -T0 "$xz" || die "解压失败: $xz"
        found="${xz%.xz}"
    fi
    printf '%s' "$found"
}

# UEFI 固件路径在三个平台三个地方，挨个找。
find_firmware() {
    local arch="$1" candidates
    if [ "$arch" = aarch64 ]; then
        candidates="
            /opt/homebrew/share/qemu/edk2-aarch64-code.fd|/opt/homebrew/share/qemu/edk2-arm-vars.fd
            /usr/local/share/qemu/edk2-aarch64-code.fd|/usr/local/share/qemu/edk2-arm-vars.fd
            /usr/share/AAVMF/AAVMF_CODE.fd|/usr/share/AAVMF/AAVMF_VARS.fd
            /usr/share/qemu-efi-aarch64/QEMU_EFI.fd|/usr/share/AAVMF/AAVMF_VARS.fd
            /usr/share/edk2/aarch64/QEMU_EFI-pflash.raw|/usr/share/edk2/aarch64/vars-template-pflash.raw
        "
    else
        candidates="
            /opt/homebrew/share/qemu/edk2-x86_64-code.fd|/opt/homebrew/share/qemu/edk2-i386-vars.fd
            /usr/local/share/qemu/edk2-x86_64-code.fd|/usr/local/share/qemu/edk2-i386-vars.fd
            /usr/share/OVMF/OVMF_CODE.fd|/usr/share/OVMF/OVMF_VARS.fd
            /usr/share/edk2/ovmf/OVMF_CODE.fd|/usr/share/edk2/ovmf/OVMF_VARS.fd
            /usr/share/qemu/OVMF.fd|/usr/share/qemu/OVMF.fd
        "
    fi

    local code vars
    while IFS='|' read -r code vars; do
        # candidates 是多行缩进的，左对齐后再判断，不然 -f 会带着前导空格失败
        code="${code#"${code%%[![:space:]]*}"}"
        vars="${vars#"${vars%%[![:space:]]*}"}"
        [ -n "$code" ] || continue
        if [ -f "$code" ] && [ -f "$vars" ]; then
            printf '%s|%s' "$code" "$vars"
            return
        fi
    done <<< "$candidates"
    die "找不到 ${arch} 的 UEFI 固件。aarch64 装 qemu-efi-aarch64 / edk2-aarch64，x86 装 ovmf。"
}

# 加速器：macOS 只有 hvf；Linux 有 kvm。都没有就 tcg（慢，但能跑）。
pick_accel() {
    local arch="$1" host
    host=$(uname -m)
    case "$(uname -s)" in
        Darwin)
            # hvf 只能跑同架构。x86_64 镜像在这台机器上退回 tcg。
            if [ "$arch" = aarch64 ] && [ "$host" = arm64 ]; then
                printf 'hvf'
            else
                printf 'tcg'
            fi
            ;;
        Linux)
            if [ -w /dev/kvm ] && { [ "$arch" = x86_64 ] && [ "$host" = x86_64 ] \
                 || [ "$arch" = aarch64 ] && [ "$host" = aarch64 ]; }; then
                printf 'kvm'
            else
                printf 'tcg'
            fi
            ;;
        *) printf 'tcg' ;;
    esac
}

# 准备固件变量盘。
#
# force=1 时无条件重铺一份全新的。装机必须这么做：OVMF 变量盘里会残留上次
# 启动注册的 BootXXXX 项，指向一块已经不存在的盘，UEFI 会一直试它然后退回
# PXE，表现成「装机盘不启动」。boot 反过来要复用，否则每次都得重走一遍
# GRUB 自动选。
prepare_firmware() {
    local force="${1:-0}"
    local dir; dir=$(vm_dir)
    mkdir -p "$dir"
    if [ "$force" = 1 ] || [ ! -f "$dir/OVMF_VARS.fd" ]; then
        local fw vars
        fw=$(find_firmware "$ARCH")
        vars="${fw#*|}"
        if [ "$force" = 1 ]; then
            log "重铺固件变量盘 ${vars}（清掉残留的引导项）"
        else
            log "复制固件变量盘 ${vars}"
        fi
        cp "$vars" "$dir/OVMF_VARS.fd"
        chmod u+w "$dir/OVMF_VARS.fd"
    fi
}

# 建 qcow2 分层盘 + 固件变量盘。都只建一次，之后复用。
prepare() {
    local base
    base=$(find_base_image)
    local dir; dir=$(vm_dir)

    log "基础镜像 $base"
    log "目标架构 ${ARCH}，宿主 $(uname -m)"

    local base_abs; base_abs="$(cd "$(dirname "$base")" && pwd)/$(basename "$base")"

    if [ -f "$dir/disk.qcow2" ]; then
        # overlay 绑死了某个 backing。换了 BASE_IMAGE 还复用旧 overlay，
        # 启动的还是旧镜像 —— 静默跑错，最难查。这里比对一下，不一致就重建。
        local current
        current=$(qemu-img info --output=json "$dir/disk.qcow2" \
            | python3 -c 'import json,sys;print(json.load(sys.stdin).get("backing-filename",""))' 2>/dev/null || true)
        if [ "$current" != "$base_abs" ]; then
            warn "overlay 的 backing 是 ${current:-（无）}"
            warn "和当前基础镜像 ${base_abs} 不一致，重建 overlay"
            rm -f "$dir/disk.qcow2"
        fi
    fi

    if [ ! -f "$dir/disk.qcow2" ]; then
        # overlay 的虚拟大小必须和基础镜像一致。GPT 备份分区头在磁盘末尾，
        # 尺寸不同会让 UEFI 找不到可引导分区，表现为一直 PXE 重试。
        log "建 qcow2 分层盘（backing: $(basename "$base")）"
        qemu-img create -f qcow2 -F raw -b "$base_abs" "$dir/disk.qcow2" >/dev/null
    else
        log "复用已有 overlay（想重来：rm .vm/${ARCH}/disk.qcow2）"
    fi

    prepare_firmware

    local accel
    accel=$(pick_accel "$ARCH")
    if [ "$accel" = tcg ] && [ "$ARCH" != "$(default_arch)" ]; then
        warn "${ARCH} 在这台机器上只能 tcg 纯模拟，启动到登录会很久"
    fi
    ok "环境就绪（加速器 ${accel}）"
}

# 组装 qemu 参数。boot / install 共用底座，避免两处写歪。
base_args() {
    local fw code accel
    fw=$(find_firmware "$ARCH")
    code="${fw%%|*}"
    accel=$(pick_accel "$ARCH")

    printf '%s\n' -m "$VM_MEM" -smp "$VM_CPUS" -accel "$accel"

    case "$ARCH" in
        aarch64)
            printf '%s\n' -machine virt,highmem=on
            # tcg 下 -cpu host 不可用，得给具体型号
            if [ "$accel" = tcg ]; then printf '%s\n' -cpu max; else printf '%s\n' -cpu host; fi
            ;;
        x86_64)
            printf '%s\n' -machine q35,smm=on
            if [ "$accel" = tcg ]; then printf '%s\n' -cpu max; else printf '%s\n' -cpu host; fi
            ;;
    esac

    printf '%s\n' -drive "if=pflash,format=raw,readonly=on,file=$code"
    printf '%s\n' -drive "if=pflash,format=raw,file=$(vm_dir)/OVMF_VARS.fd"

    # virtio-rng 不能省。arm64 上没有 RDRAND，缺熵时 systemd 会在
    # "Waiting for entropy" 卡住几十秒。
    printf '%s\n' -device virtio-rng-pci

    # 网络。
    #
    # 面板端口一直转发。SSH 只在 dev 模式转（DEV_SSH_PORT），用途是让宿主
    # 用 rsync 把源码推到虚机本地盘——9p/vboxsf 这类共享文件系统不投递
    # inotify 事件，dev server 的热更新在挂载目录上根本不触发，所以开发时
    # 必须走"同步到本地盘"这条路。
    #
    # 生产镜像默认禁 SSH 密码登录（D-007），开发构建（--root-password）
    # 才放开，所以 dev 模式依赖的正是开发构建的镜像。
    local netdev="user,id=n0"
    if [ "$PANEL_PORT" != 0 ]; then
        netdev="$netdev,hostfwd=tcp::${PANEL_PORT}-:5090"
    fi
    if [ "${DEV_SSH_PORT:-0}" != 0 ]; then
        netdev="$netdev,hostfwd=tcp::${DEV_SSH_PORT}-:22"
    fi
    printf '%s\n' -netdev "$netdev" -device virtio-net-pci,netdev=n0

    # 显示后端**不在**这里输出，由调用方各自决定：
    #   boot → 末尾追加 -nographic（串口即显示器）
    #   gui  → 自己加 -display cocoa
    # 早先这里输出 `-display none` 给 gui 用，结果 QEMU 收到两个 -display，
    # 虽然取最后一个能跑，但属于隐患，已去掉。
}

# 读成数组。不用 mapfile —— macOS 自带的 /bin/bash 是 3.2，没有这个内置，
# 用 `#!/usr/bin/env bash` 兜住的是 Homebrew 的 bash 5，别指望它一定在。
read_args() {
    ARGS=()
    local line
    while IFS= read -r line; do
        [ -n "$line" ] && ARGS+=("$line")
    done < <(base_args)
}

boot() {
    prepare
    local dir; dir=$(vm_dir)
    local bin="qemu-system-$ARCH"
    command -v "$bin" >/dev/null || die "找不到 ${bin}。brew install qemu / dnf install qemu-system-$ARCH"

    read_args
    ARGS+=(-drive "file=$dir/disk.qcow2,format=qcow2,if=virtio")

    log "启动（串口控制台即显示器）。退出：Ctrl-A 然后 X"
    log "登录：控制台提示 Login: 输 root / 123456（要 --root-password 构建的镜像）"
    [ "$PANEL_PORT" != 0 ] && log "面板：宿主机 http://127.0.0.1:${PANEL_PORT}"

    exec "$bin" "${ARGS[@]}" -nographic
}

# 带窗口启动（macOS 的 cocoa）。为什么要这个：-nographic 只能看串口，
# 而登录字标、颜色、字体这些**只有 VGA 上才看得出问题** —— 串口日志里
# 块字符是转义字节，看不出渐变对不对。
#
# 三种取证手段，配合这个模式用：
#   1. 肉眼看窗口
#   2. QEMU monitor 的 screendump 抓屏（脚本化，见 docs/testing.md）
#   3. serial 日志并行写文件，grep 关键字比截图快
#
# Windows/Linux 上没有 cocoa：改成 -display gtk 或 -display sdl。
gui() {
    prepare
    local dir; dir=$(vm_dir)
    local bin="qemu-system-$ARCH"
    command -v "$bin" >/dev/null || die "找不到 ${bin}。brew install qemu"

    case "$(uname -s)" in
        Darwin) : ;;
        *) warn "非 macOS：cocoa 不可用，请把 -display cocoa 改成 gtk 或 sdl" ;;
    esac

    read_args

    # virtio-gpu + USB 键盘/鼠标。不加 usb-kbd 时窗口里收不到按键。
    ARGS+=(
        -device virtio-gpu-pci
        -device qemu-xhci,id=xhci
        -device usb-kbd,bus=xhci.0
        -device usb-tablet,bus=xhci.0
    )
    ARGS+=(-drive "file=$dir/disk.qcow2,format=qcow2,if=virtio")
    ARGS+=(-display "cocoa,show-cursor=on")

    # 串口并行写文件：截图只能看到当前屏，日志能回看整段启动过程。
    # monitor 走 unix socket，用于 screendump / sendkey（见 docs/testing.md）。
    mkdir -p "$dir/logs"
    ARGS+=(-serial "file:$dir/logs/serial.log")
    ARGS+=(-monitor "unix:$dir/logs/monitor.sock,server,nowait")

    log "启动（cocoa 窗口）。关窗口或 Ctrl-C 退出"
    log "串口日志：$dir/logs/serial.log"
    log "monitor：$dir/logs/monitor.sock（screendump / sendkey 用它）"
    log "登录：Login: 输 root / 123456（要 --root-password 构建的镜像）"
    [ "$PANEL_PORT" != 0 ] && log "面板：宿主机 http://127.0.0.1:${PANEL_PORT}"

    exec "$bin" "${ARGS[@]}"
}

serve() {
    local file="${1:-}"
    local dir; dir=$(vm_dir)
    mkdir -p "$dir/serve"

    if [ -n "$file" ]; then
        [ -f "$file" ] || die "文件不存在: $file"
        cp "$file" "$dir/serve/"
        ok "已放入 $(basename "$file")"
    fi

    log "HTTP 服务 http://0.0.0.0:8000/"
    log "虚机里取：curl -O http://10.0.2.2:8000/$(basename "${file:-FILE}")"
    log "退出：Ctrl-C"
    cd "$dir/serve"
    exec python3 -m http.server 8000
}

status() {
    local dir; dir=$(vm_dir)
    [ -d "$dir" ] || { warn "还没有 ${dir}。先跑 ./scripts/vm.sh pull"; return 1; }
    log "$dir"
    ls -lh "$dir" | sed 's/^/  /'
}

clean() {
    log "删除 $VM_ROOT"
    rm -rf "$VM_ROOT"
    ok "已清理"
}
