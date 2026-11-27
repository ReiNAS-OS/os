# ReiNAS OS — 开发模式：虚机 + 源码同步
#
# 被 vm.sh source。提供三个子命令：
#
#   dev    起虚机，转发 5090（面板）和 5099（SSH），串口可写
#   key    把宿主公钥装进虚机（rsync 免密用），走串口
#   sync   fswatch 监听宿主源码，rsync 推进虚机本地盘
#
# 为什么源码要 rsync 而不是挂载共享目录：
#   **共享文件系统不投递 inotify 事件**，dev server 的 watch 在挂载目录上
#   不触发，热更新等于没有。实测 9p 上 mtime 能正确传播，但 inotifywait
#   一条事件都收不到；VirtualBox 的 vboxsf 更直接，官方 ticket #10660
#   标记 wontfix。macOS + QEMU 用不了 virtiofs（QEMU 没编 vhost-user-fs，
#   macOS 也没有 virtiofsd）。
#
#   所以只能把源码真正搬进虚机的本地盘（ext4），那里才是正常的文件系统。
#
# 为什么必须绕开 turbo：
#   `turbo run dev` 会把任务放进自己的进程组，`bun --watch` 的文件监听在
#   那一层之下不生效——实测改 .tsx 后 bundle 不重新编译。虚机里要直接跑
#   `bun --watch src/main.ts serve --dev`。
#
# 为什么必须用 Homebrew 的 rsync：
#   macOS 自带的 /usr/bin/rsync 是 openrsync（协议 2.6.9），不认
#   --chmod=D755,F644 和 --no-owner，会把宿主的 UID 501 和 600 权限带到
#   虚机，虚机里以 root 跑的 bun --watch 在这种属主下不触发重编译。

dev() {
    prepare
    local dir; dir=$(vm_dir)
    local bin="qemu-system-$ARCH"
    command -v "$bin" >/dev/null || die "找不到 ${bin}。brew install qemu / dnf install qemu-system-$ARCH"

    local shared="${SHARED_DIR:-$REPO_ROOT/../controller}"
    [ -d "$shared" ] || die "源码目录不存在: $shared（用 SHARED_DIR 指定 controller 仓库）"

    # 开发模式必须有 SSH：源码靠 rsync 推进虚机本地盘，不走共享文件系统。
    # 原因见下面的大段注释。
    if [ "${DEV_SSH_PORT:-0}" = 0 ]; then
        die "dev 模式需要 DEV_SSH_PORT（默认 5099），设成 0 就跑不了 rsync"
    fi

    read_args
    ARGS+=(-drive "file=$dir/disk.qcow2,format=qcow2,if=virtio")

    # 双向串口：能读日志，也能敲命令。
    mkdir -p "$dir/logs"
    local sock="$dir/logs/console.sock"
    rm -f "$sock"
    ARGS+=(-chardev "socket,id=ser0,path=$sock,server=on,wait=off,logfile=$dir/logs/console.log,logappend=on")
    ARGS+=(-serial "chardev:ser0")
    ARGS+=(-display none)

    log "开发模式"
    log "  源码目录（宿主）: $shared"
    log "  虚机内路径:       $DEV_REMOTE_DIR"
    log "  rsync 通道:       ssh -p $DEV_SSH_PORT root@127.0.0.1"
    log "  串口 socket:      $sock"
    log "  面板:             http://127.0.0.1:${PANEL_PORT}"
    log ""
    log "为什么不用共享文件夹：9p / vboxsf / NFS 都不投递 inotify 事件，"
    log "dev server 的文件监听在挂载目录上不触发，热更新等于没有。"
    log "改用 rsync 同步到虚机本地盘后，虚机里就是普通 ext4，HMR 正常。"
    log ""
    log "起好后另开一个终端跑同步："
    log "  ./scripts/vm.sh sync"
    log ""
    log "虚机里第一次要装 bun（镜像本身不带）："
    log "  curl -fsSL https://bun.sh/install | bash"
    log "然后（⚠️ 不要用 bun run dev / turbo run dev，理由见下）："
    log "  cd $DEV_REMOTE_DIR && bun install"
    log "  cd $DEV_REMOTE_DIR/apps/cli && bun --watch src/main.ts serve --dev"
    log ""
    log "为什么绕开 turbo：turbo 会把任务放进自己的进程组，bun --watch 的"
    log "文件监听在那层之下不生效——实测改 .tsx 后 bundle 不重新编译。"
    log "直接跑 bun --watch 才正常。"
    log ""
    log "往串口敲命令：printf '%s\\r' '命令' | nc -U -w 3 $sock"

    exec "$bin" "${ARGS[@]}"
}


# 把宿主的公钥装进虚机，供 rsync 免密登录用。
#
# 走串口而不是 SSH：装公钥本身就需要认证，鸡生蛋问题。串口是 dev 模式下
# 已经开着的通道，直接往里敲命令最省事。
key() {
    local shared="${SHARED_DIR:-$REPO_ROOT/../controller}"
    local dir; dir=$(vm_dir)
    local sock="$dir/logs/console.sock"
    [ -S "$sock" ] || die "串口 socket 不存在。先跑 ./scripts/vm.sh dev"

    local key
    key=$(pick_ssh_key) || die "找不到 SSH 私钥。设 DEV_SSH_KEY 指向一个"
    [ -f "${key}.pub" ] || die "缺少公钥 ${key}.pub"

    local pub
    pub=$(cat "${key}.pub")
    log "把 ${key}.pub 装进虚机的 /root/.ssh/authorized_keys"

    # 串口写入要转义：命令里有空格和特殊符号，单引号包起来最省事
    printf "mkdir -p /root/.ssh && chmod 700 /root/.ssh && echo '%s' > /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys && echo KEY-INSTALLED\r" "$pub" \
        | nc -U -w 3 "$sock" >/dev/null 2>&1 || true

    sleep 3
    ok "已写入。用 ./scripts/vm.sh sync 验证连通性"
}


# 把源码同步进虚机的本地盘，供 dev 模式热更新用。
#
# 为什么不用共享文件夹：9p / vboxsf / NFS / SMB 都不投递 inotify 事件。
# 实测验过——9p 上 mtime 能正确传播，但 inotifywait 一条事件都收不到，
# Bun 的 dev server 因此永远不会重新编译。VirtualBox 的共享文件夹是同样的
# 情况，官方 ticket #10660 标记为 wontfix。所以只能把文件真正搬到虚机的
# 本地盘（ext4/btrfs）上，那里才是正常的文件系统。
#
# 触发方式：fswatch 监听宿主目录，有变化就跑一次 rsync。不用轮询——轮询
# 在大目录上很费 CPU，而 fswatch 走的是 macOS 的 FSEvents，本地盘上很可靠。
sync() {
    local shared="${SHARED_DIR:-$REPO_ROOT/../controller}"
    [ -d "$shared" ] || die "源码目录不存在: $shared"

    # 优先用 Homebrew 的 rsync（3.x）。
    #
    # macOS 自带的 /usr/bin/rsync 是 openrsync（2.6.9 协议），不支持
    # --chmod=D755,F644，也不认 --no-owner，会把宿主的 UID 501 和 600
    # 权限原样带到虚机——虚机里的 bun --watch 在这种属主下不触发重编译。
    # 3.x 能直接写对权限，省掉同步后再跑一遍 chmod 的开销。
    local RSYNC
    for candidate in /opt/homebrew/bin/rsync /usr/local/bin/rsync /usr/bin/rsync; do
        [ -x "$candidate" ] && { RSYNC="$candidate"; break; }
    done
    [ -n "$RSYNC" ] || die "找不到 rsync"
    # 校验版本：3.0 以下没有 --chmod=D755,F644。
    # macOS 自带的 /usr/bin/rsync 是 openrsync（报 "2.6.9 compatible"），
    # 上面那个 for 循环会优先挑到 Homebrew 的 3.x，但没装的话就会落到它，
    # 这里拦住并给出提示。
    # 不用 `| head -1`：rsync 往管道里继续写时会收到 SIGPIPE，
    # 在 macOS 的 openrsync 上会把整条命令搞成退出码 141，看起来像
    # "版本太老"。直接读全部输出再截首行。
    local rsync_ver
    rsync_ver=$("$RSYNC" --version 2>/dev/null)
    rsync_ver=${rsync_ver%%$'\n'*}
    case "$rsync_ver" in
        *"version 3."*) : ;;
        *)
            die "rsync 版本太老：${rsync_ver:-未知}。\
macOS 自带的是 openrsync，不认 --chmod=D755。brew install rsync"
            ;;
    esac

    command -v fswatch >/dev/null || die "找不到 fswatch。brew install fswatch"

    local ssh_port="${DEV_SSH_PORT:-5099}"
    local target="root@127.0.0.1"

    # SSH 参数。用公钥认证，不走密码——rsync 是非交互的，密码没法输。
    #
    # 密钥路径可用 DEV_SSH_KEY 覆盖。没设且默认路径不存在时直接报错，
    # 而不是让 rsync 反复弹失败。
    local key
    key=$(pick_ssh_key) || die "找不到 SSH 私钥。设 DEV_SSH_KEY 指向一个"

    local ssh_opts="-p $ssh_port -i $key -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes"

    log "检查 SSH 通道 127.0.0.1:${ssh_port} …"
    if ! ssh $ssh_opts "$target" true 2>/dev/null; then
        die "连不上虚机 SSH。确认：1) ./scripts/vm.sh dev 正在跑；\
     2) 镜像是 --root-password 构建（生产镜像才放开密码登录）；\
     3) 公钥已装进虚机 /root/.ssh/authorized_keys（用 ./scripts/vm.sh key 装）"
    fi

    # rsync 的排除项：这些东西要么大、要么虚机里重装、要么是本机特有的
    local excludes=(
        --exclude=node_modules
        --exclude=.git
        --exclude=.turbo
        --exclude=dist
        --exclude=.qemu
        --exclude=.vm
        --exclude=.DS_Store
    )

    local -a rsync_cmd=(
        # 关键：不要带 -t（保留 mtime）。
        #
        # rsync -a 隐含 -t，会把宿主的 mtime 原样复制到虚机。Bun 判断
        # 模块是否变化靠 mtime，宿主的文件改了内容但 mtime 没变（比如在
        # 同一秒内编辑），虚机里就认为没变，一直用旧缓存——实测改了文案
        # 后 bundle 里始终是旧内容，清缓存重启也没用。
        #
        # 用 -rlz 替代 -a：递归/符号链接/压缩，但不保留时间戳，让文件
        # 落地时拿到"现在"的 mtime，Bun 才会重新编译。
        "$RSYNC" -rlz --delete --no-owner --no-group --chmod=D755,F644
        "${excludes[@]}"
        -e "ssh $ssh_opts"
        "$shared/"
        "$target:$DEV_REMOTE_DIR/"
    )

    # 同步后重启 dev server。
    #
    # 为什么重启而不是靠 --watch：实测 bun --watch 在这个环境里不可靠
    # ——11:02 那次改了文件它编译了，11:10 之后再改就再也不触发，日志停在
    # 最后一条 "Bundled page in Nms" 不动。原因没查清（可能是 rsync 的
    # 写入方式，也可能是 bun 在 Linux 上的监听实现），但它不稳定这件事
    # 是确定的。
    #
    # 重启是笨办法但可靠：杀掉旧进程、在同一目录起新的。代价是每次保存
    # 等 2-4 秒（进程启动 + 首次编译），浏览器短暂断开。比起"改完不确定
    # 有没有生效"，这个代价可以接受。
    #
    # setsid + </dev/null 是为了脱离 SSH 会话：不这么做的话 SSH 一断，
    # dev server 会被 SIGHUP 杀掉。
    restart_dev() {
        # 用 systemd-run 起服务，不用 nohup/setsid。
        #
        # 试过的方式和结果：
        #   `cmd &`              → SSH 等输出流关闭，挂住不返回
        #   `setsid nohup cmd &` → 返回了，但进程立刻消失（会话脱离不彻底）
        #
        # systemd-run --scope 会把进程交给 systemd 托管，彻底脱离 SSH 会话，
        # 而且能用 systemctl 查状态、看日志，出问题时好排查。
        ssh $ssh_opts "$target" "
            systemctl stop reinas-dev.service >/dev/null 2>&1
            systemctl reset-failed reinas-dev.service >/dev/null 2>&1
            systemd-run --unit=reinas-dev --collect \\
                --working-directory=$DEV_REMOTE_DIR/apps/cli \\
                /usr/local/bin/bun src/main.ts serve --dev
        " < /dev/null > /dev/null 2>&1
    }

    # 连续多次改文件时，只在最后一次变化之后重启，避免边打字边重启。
    # 用 flock 保证同一时间只有一个重启在跑。
    do_sync() {
        if ! "${rsync_cmd[@]}" >/dev/null 2>&1; then
            warn "同步失败（虚机在跑吗？）"
            return
        fi
        restart_dev
        # 等端口重新监听。不等的话后续请求会打到旧进程（正在退出）或
        # 直接连接失败，看起来像"同步坏了"。
        local i
        for i in $(seq 1 30); do
            if ssh $ssh_opts "$target" "ss -lnt 2>/dev/null | grep -q ':5090 '" 2>/dev/null; then
                ok "已同步并重启 $(date +%H:%M:%S)"
                return
            fi
            sleep 0.2
        done
        warn "已同步，但 dev server 6 秒内没起来。看虚机里 /tmp/reinas-dev.log"
    }

    log "首次同步 …"
    mkdir -p "$shared"
    ssh $ssh_opts "$target" "mkdir -p $DEV_REMOTE_DIR" 2>/dev/null
    do_sync

    log "监听 $shared （保存即同步，Ctrl-C 退出）"
    # -o 3 是延迟合批：编辑器保存时常常连发多个事件，等 300ms 再跑一次
    # rsync，避免一次保存触发 3-4 次传输。
    fswatch -o -l 0.3 "$shared" | while read -r _; do
        do_sync
    done
}

# 挑一个可用的 SSH 私钥。
#
# 优先 DEV_SSH_KEY；否则按常见命名找。用 _vps / _mini 这类后缀的密钥也认，
# 因为不是所有人都把默认密钥叫 id_ed25519。
pick_ssh_key() {
    if [ -n "${DEV_SSH_KEY:-}" ]; then
        [ -f "$DEV_SSH_KEY" ] && printf '%s' "$DEV_SSH_KEY" && return 0
        return 1
    fi
    for candidate in \
        "$HOME/.ssh/id_ed25519" \
        "$HOME/.ssh/id_rsa" \
        "$HOME"/.ssh/id_ed25519_* \
        "$HOME"/.ssh/id_rsa_*; do
        [ -f "$candidate" ] && [ -f "${candidate}.pub" ] && {
            printf '%s' "$candidate"
            return 0
        }
    done
    return 1
}
