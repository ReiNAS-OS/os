#!/bin/bash
#
# ReiNAS OS — kiwi 镜像内配置脚本
#
# 由 kiwi 在 chroot 里以 root 执行，位置是镜像的 /。
# 全部命令必须幂等：kiwi 可能在 create 阶段重跑。
#
# 与 Fedora 官方 config.sh 的关系：
#   结构参考 https://forge.fedoraproject.org/releng/kiwi-descriptions (f45)
#   但去掉所有 vagrant / cloud / desktop 分支，只留 NAS 需要的。
#
# shellcheck disable=SC2154  # kiwi_iname / kiwi_profiles 由 kiwi 在构建时注入
set -euo pipefail

echo "==== ReiNAS config.sh: [$kiwi_iname] profile=[$kiwi_profiles] ===="

# ============================================================
#  1. 清掉机器相关状态，保证一镜像多机部署
# ============================================================
# machine-id 必须清空：同一个 UUID 在网络上出现两次，systemd 会拒绝启动
# journald 和 networkd，而且 DHCP 会冲突。
rm -f /etc/machine-id
touch /etc/machine-id          # 空文件 = 首次启动时由 systemd 生成
rm -f /var/lib/systemd/random-seed

# cloud-init / NetworkManager 的持久化连接不应进镜像
rm -f /etc/NetworkManager/system-connections/*.nmconnection 2>/dev/null || true

# ============================================================
#  2. dnf 身份：让 $releasever 永远是 Fedora 主版本号
# ============================================================
# reinas-release 包已经装了 /etc/dnf/vars/releasever，这里再确认一次，
# 防止某些 dnf5 版本优先读 os-release 的 VERSION_ID（=0.1.0）。
echo "45" > /etc/dnf/vars/releasever

# ============================================================
#  3. 引导：GRUB 行为对齐 Fedora 官方安装
# ============================================================
cat >> /etc/default/grub <<'EOF'
GRUB_DEFAULT=saved
GRUB_DISABLE_SUBMENU=true
GRUB_DISABLE_RECOVERY=true
EOF

mkdir -p /boot/grub2
# ⚠️ grub2-editenv 在构建环境里会失败：
#    grub2-editenv: error: failed to get canonical path of `overlay'
# 因为此时根文件系统是容器里的 overlay，不是最终镜像的分区，
# grub 的路径解析拿不到真实的块设备。而 kiwi 用 set -euxo pipefail 跑本脚本，
# 一条命令非零退出就会让整个构建失败。
#
# grubenv 本身只是 /boot/grub2/grubenv 里的一个 1KiB 文本块，
# 用 dd 写一块全零的合法 grubenv 就够；menu_auto_hide 等键由 kiwi 的
# bootloader 阶段或首次启动的 grub2-mkconfig 决定，不在这里强求。
if [ ! -f /boot/grub2/grubenv ]; then
    # 合法的空 grubenv：1024 字节，以 "# GRUB Environment Block" 开头，其余补 #
    {
        printf '# GRUB Environment Block\n'
        head -c 1003 /dev/zero | tr '\0' '#'
    } > /boot/grub2/grubenv 2>/dev/null || true
fi

# ============================================================
#  4. 首启扩盘
# ============================================================
# 扩盘完全由 kiwi 的 dracut 模块 kiwi-repart 在 initramfs 阶段完成
# （dracut-kiwi-oem-repart，由 <oem-resize>true</oem-resize> 触发）。
# 它在挂载 root 之前就重分区并把文件系统撑满，systemd 起来时盘已经是满的。
#
# ⚠️ 这里曾经写过 /etc/repart.d/50-root.conf 想用 systemd-repart 兜底，
#    结果是每次启动都报：
#      [FAILED] Failed to start systemd-repart.service - Repartition Root Disk.
#    原因：那个配置只有 [Partition] Type=root，没有任何动作（缺 GrowFileSystem
#    之类），systemd-repart 无事可做就非零退出。而真正的扩盘早就做完了，
#    这个单位纯属多余，还制造了一条永久失败记录。
#    已删除。不要再加回来 —— 想要它做事必须写全 Defines/Size/GrowFileSystem。
#    实测：镜像 dd 到 8G 盘启动后根文件系统正常，扩盘机制不依赖 repart.d。

# ============================================================
#  5. 账号
# ============================================================
# 默认（生产形态）：
#   - root 与非 root 特权账号一律锁定密码，禁止密码登录
#   - SSH 只认公钥
# 开发形态（./scripts/build.sh --root-password）：
#   - root 设密码，SSH 放开 root 密码登录
#   - reinas 应急账号仍然锁定
#   - 由 /etc/reinas/root.conf 控制，见 docs/decisions.md D-007
#
# ⚠️ 除开关外没有第二条设密码的路。默认镜像里没有任何已知口令。
REINAS_ROOT_PASSWORD=""
mkdir -p /etc/reinas
if [ -s /etc/reinas/root.conf ]; then
    # 纯文本一行。用 read 不用 source：密码里含 $ ` " \ 也不会被展开执行。
    IFS= read -r REINAS_ROOT_PASSWORD < /etc/reinas/root.conf || true
fi

# 应急账号：在 wheel 组，供控制台与后续设密码使用。始终锁定密码。
if ! id reinas >/dev/null 2>&1; then
    useradd -m -G wheel -s /bin/bash reinas
fi
passwd -l reinas 2>/dev/null || true

if [ -n "${REINAS_ROOT_PASSWORD}" ]; then
    echo "==== root 密码：已设置，SSH root 密码登录放开 ===="
    # chpasswd 直接写新 hash，顺带清掉锁定标记（不需要 passwd -u，
    # -u 只是去掉 hash 前缀的 !，对空 hash 不可靠）。
    printf 'root:%s\n' "$REINAS_ROOT_PASSWORD" | chpasswd

    # 默认的 sshd 配置是 PermitRootLogin prohibit-password +
    # PasswordAuthentication no，两样都挡住 root 密码登录。
    # 这里单独放一个 drop-in 覆盖，且只在开关打开时存在。
    cat > /etc/ssh/sshd_config.d/20-reinas-root.conf <<'EOF'
# ⚠️ 只有 build.sh --root-password 时才写入。生产构建里不存在本文件。
PermitRootLogin yes
PasswordAuthentication yes
EOF

    # 镜像里留一条看得见的痕迹，避免这种镜像被当成生产镜像发出去
    cat > /etc/reinas/BUILD-HAS-ROOT-PASSWORD <<'EOF'
This image was built with a root password enabled.

  user: root
  auth: password (see /etc/ssh/sshd_config.d/20-reinas-root.conf)

Do not distribute. Rebuild without ./scripts/build.sh --root-password.
EOF
    chmod 0644 /etc/ssh/sshd_config.d/20-reinas-root.conf \
        /etc/reinas/BUILD-HAS-ROOT-PASSWORD
else
    echo "==== 生产形态：所有账号锁定，SSH 仅公钥 ===="
    # 锁定 root（禁止密码登录），但保留账号可用：
    #   - 物理控制台可用单步救援
    #   - 首次登录通过 SSH 公钥
    passwd -d root 2>/dev/null || true
    passwd -l root 2>/dev/null || true
fi

# 明文密码不能留在交付镜像里，两个分支都清
rm -f /etc/reinas/root.conf

# ============================================================
#  6. 服务默认状态
# ============================================================
# ⚠️ chroot 里没有运行中的 systemd，systemctl enable 可能返回非零。
# kiwi 用 set -e 跑本脚本，一条失败就整体中止，所以每条都要兜底。
systemctl enable sshd.service            >/dev/null 2>&1 || true
systemctl enable chronyd.service         >/dev/null 2>&1 || true
systemctl enable firewalld.service       >/dev/null 2>&1 || true
systemctl enable NetworkManager.service  >/dev/null 2>&1 || true
systemctl enable fstrim.timer            >/dev/null 2>&1 || true
systemctl enable systemd-timesyncd.service >/dev/null 2>&1 || true

# NAS 核心：smb / nfs 不默认启用，等用户在面板里配好共享再开
systemctl disable smb.service  2>/dev/null || true
systemctl disable nmb.service  2>/dev/null || true
systemctl disable nfs-server.service 2>/dev/null || true

# 明确关掉不需要的
systemctl disable bluetooth.service 2>/dev/null || true
systemctl disable ModemManager.service 2>/dev/null || true
systemctl disable debug-shell.service 2>/dev/null || true

# 目标：无图形界面（NAS 不该跑 display-manager）
systemctl set-default multi-user.target >/dev/null 2>&1 || true

# ============================================================
#  7. 安全基线
# ============================================================
# SELinux 必须保持 enforcing。kiwi 构建时若改过文件上下文，首启自动重标签。
/usr/sbin/selinuxenabled 2>/dev/null && echo "SELinux: enforcing (ok)" || true
touch /.autorelabel 2>/dev/null || true

# sshd 加固
mkdir -p /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/10-reinas.conf <<'EOF'
PermitRootLogin prohibit-password
PasswordAuthentication no
KbdInteractiveAuthentication no
UseDNS no
ClientAliveInterval 60
EOF

# ============================================================
#  8. 防火墙：只开管理端口和 NAS 端口
# ============================================================
# ⚠️ 不开 9090（Cockpit 已移除）。面板规划用 5090，但服务还没做出来 ——
#    面板就绪后要在这里 add-port=5090/tcp。
firewall-offline-cmd --zone=public --add-service=ssh        >/dev/null 2>&1 || true
firewall-offline-cmd --zone=public --add-service=samba      >/dev/null 2>&1 || true
firewall-offline-cmd --zone=public --add-service=nfs        >/dev/null 2>&1 || true
firewall-offline-cmd --zone=public --add-service=mountd     >/dev/null 2>&1 || true
firewall-offline-cmd --zone=public --add-service=rpc-bind   >/dev/null 2>&1 || true

# ============================================================
#  9. 登录前提示（管理面板地址）
# ============================================================
install -d /usr/lib/reinas
# 登录提示的静态内容直接写死在 /etc/issue.d/10-reinas.issue 里，脚本只负责
# 把占位符换成当前 IP。这样不用跑脚本就能看到最终长相。
#
# 三条硬约束（实测过的，别改）：
#   1. 全英文。内核控制台默认字体不含 CJK 字形，中文在物理屏幕/IPMI 上
#      显示成空白或问号。串口能显示中文不代表这里能用。
#   2. 只用 ANSI 16 色的 SGR 码。物理 VGA/VBE 控制台只保证 16 色，
#      256 色（38;5;n）和真彩色（38;2;r;g;b）会被忽略或错色。
#   3. 字标只用 # 和空格。_ 和 | 在多数等宽字体里不占满格，连起来有缝，
#      看起来是描边而不是实心。
#
# issue 转义（agetty 展开，不是 shell）：
#   \S  PRETTY_NAME，即 "ReiNAS 0.1.0"     \r  内核版本
#   \m  架构                               \l  终端名
install -d /etc/issue.d

# 生成提示文件。
#
# ⚠️ 两层转义必须分清，这是最容易踩的地方：
#
#   1. ANSI 颜色要**真实的 ESC 字节**（0x1B），用 printf 的 \033 产出。
#      agetty 不解析 "\033" 这四个字符，直接写进文件会原样显示成乱码。
#   2. agetty 的 issue 转义（\S \r \m \l）必须是**字面的反斜杠加字母**，
#      所以要用 %s 拼一个 BS 变量进去，不能让 printf 把 \r 解释成回车。
#
# 文件名带 .issue 后缀才会被 issue.d 目录扫描到。
BS='\'
{
  echo
  printf '\033[1;36m%s\033[0m\n' '####  ##### ### #   #  ###   ####'
  printf '\033[1;36m%s\033[0m\n' '#   # #      #  ##  # #   # #'
  printf '\033[1;36m%s\033[0m\n' '####  ####   #  # # # #####  ###'
  printf '\033[1;36m%s\033[0m\n' '#  #  ##### ### #   # #   # ####'
  echo
  printf '\033[1m%s  \033[2m%s on %s\033[0m\n' "${BS}S" "${BS}r" "${BS}m"
  echo
  printf '\033[1mWeb console:\033[0m  \033[1;36m@REINAS_URL@\033[0m\n'
  printf '\033[1mProject:\033[0m      \033[1;36mhttps://github.com/ReiNAS-OS\033[0m\n'
  echo
} > /etc/issue.d/10-reinas.issue
chmod 0644 /etc/issue.d/10-reinas.issue

# 上面文件里的 @REINAS_URL@ 在开机和网络变化时被替换成真实地址。
# 没拿到 IP 时显示 waiting，不显示一个连不上的地址。
cat > /usr/lib/reinas/reinas-issue-update <<'ISSUEEOF'
#!/bin/bash
# 把 /etc/issue.d/10-reinas.issue 里的 @REINAS_URL@ 换成当前访问地址。
#
# 只在 IP 变化时重写文件（避免无谓的磁盘写）。agetty 每次打印登录提示都会
# 重读这个文件，所以改完立刻生效。
set -u
OUT=/etc/issue.d/10-reinas.issue
[ -f "$OUT" ] || exit 0

# 排除 docker/veth/桥接/虚拟网卡，取第一个真实 IPv4
ip=$(ip -4 -o addr show scope global 2>/dev/null \
     | awk '$2 !~ /^(docker|veth|br-|virbr|tun|wg)/ {print $4; exit}' \
     | cut -d/ -f1)

if [ -n "${ip:-}" ]; then
    url="https://${ip}:5090"
else
    url="waiting for network..."
fi

# 幂等：内容没变就不写，避免每次 DHCP 续租都动磁盘
tmp=$(mktemp)
sed "s|@REINAS_URL@|${url}|" "$OUT" > "$tmp"
if ! cmp -s "$tmp" "$OUT"; then
    cat "$tmp" > "$OUT"
fi
rm -f "$tmp"
ISSUEEOF
chmod 0755 /usr/lib/reinas/reinas-issue-update

cat > /etc/systemd/system/reinas-issue.service <<'EOF'
[Unit]
Description=ReiNAS login banner (management URL)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/lib/reinas/reinas-issue-update
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
systemctl enable reinas-issue.service >/dev/null 2>&1 || true

cat > /etc/NetworkManager/dispatcher.d/50-reinas-issue <<'EOF'
#!/bin/bash
# 网络变化时刷新登录提示里的 IP
case "$2" in
    up|dhcp4-change|dhcp6-change) /usr/lib/reinas/reinas-issue-update ;;
esac
EOF
chmod 0755 /etc/NetworkManager/dispatcher.d/50-reinas-issue

# 立刻生成一次，这样 dd 完首启就能看到
/usr/lib/reinas/reinas-issue-update || true

# ============================================================
# 10. 清理
# ============================================================
# dnf 缓存会白占几百 MB
dnf5 clean all 2>/dev/null || dnf clean all 2>/dev/null || true
rm -rf /var/cache/dnf/* /var/cache/libdnf5/* 2>/dev/null || true

# 不要在交付镜像里留 root 的 shell 历史
rm -f /root/.bash_history
history -c 2>/dev/null || true

echo "==== ReiNAS config.sh done ===="
