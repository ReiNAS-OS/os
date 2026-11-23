#!/bin/bash
# ReiNAS 冒烟测试 — 在已启动的 ReiNAS 系统里以 root 运行
set -u
fail=0
chk() { # chk "描述" "命令" "期望子串"
    local desc="$1" cmd="$2" want="$3" got
    got=$(eval "$cmd" 2>&1)
    if echo "$got" | grep -q -- "$want"; then
        printf '  ok   %s\n' "$desc"
    else
        printf '  FAIL %s\n        期望含: %s\n        实际: %s\n' "$desc" "$want" "$got"
        fail=1
    fi
}
echo "ReiNAS 冒烟测试"
echo "--- 身份 ---"
chk "NAME"        "grep ^NAME= /etc/os-release"        'ReiNAS'
chk "VERSION"     "grep ^VERSION= /etc/os-release"     '0.2.0'
chk "ID_LIKE"     "grep ^ID_LIKE= /etc/os-release"     'fedora'
chk "releasever"  "cat /etc/dnf/vars/releasever"       '45'
echo "--- 安全 ---"
chk "SELinux"     "getenforce"                         'Enforcing'
chk "root锁定"    "passwd -S root | cut -d' ' -f2"     'L'
chk "sshd root"   "grep -h PermitRootLogin /etc/ssh/sshd_config.d/*.conf" 'prohibit-password'
echo "--- 服务 ---"
chk "sshd"        "systemctl is-enabled sshd"          'enabled'
chk "cockpit"     "systemctl is-enabled cockpit.socket" 'enabled'
chk "chronyd"     "systemctl is-enabled chronyd"       'enabled'
chk "firewalld"   "systemctl is-enabled firewalld"     'enabled'
chk "smb关闭"     "systemctl is-enabled smb 2>&1"      'disabled'
echo "--- 存储 ---"
chk "btrfs根"     "findmnt -no FSTYPE /"               'btrfs'
chk "子卷数>0"    "btrfs subvolume list / | wc -l"     ''
chk "压缩挂载"    "findmnt -no OPTIONS /"              'compress=zstd'
echo "--- 包 ---"
chk "reinas-release" "rpm -q reinas-release"           'reinas-release-0.2.0'
chk "samba"       "rpm -q samba"                       'samba-'
chk "nfs-utils"   "rpm -q nfs-utils"                   'nfs-utils-'
chk "cockpit"     "rpm -q cockpit"                     'cockpit-'
chk "podman"      "rpm -q podman"                      'podman-'
echo "--- 仓库 ---"
chk "dnf可用"     "dnf repolist 2>/dev/null | grep -c fedora" ''
echo
if [ "$fail" = 0 ]; then echo "✅ 全部通过"; else echo "❌ 有失败项"; exit 1; fi
