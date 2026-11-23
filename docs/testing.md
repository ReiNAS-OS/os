# 产物验证

`scripts/build.sh` 跑完会在 `out/` 得到两个文件。这份文档说明怎么在 QEMU 里验证它们，以及每个检查项证明什么。

---

## 0. 前置

```bash
sudo dnf install -y qemu-kvm qemu-img edk2-ovmf virt-install
```

`edk2-ovmf` 提供 UEFI 固件，验证 Secure Boot 必需。

---

## 1. 检查产物完整性

```bash
cd out/
sha256sum -c *.sha256
```

**证明什么**：文件传输/存储没损坏。发布前必做。

---

## 2. dd 镜像测试（对应"往服务器上装"）

### 2.1 造一块目标盘并写入

```bash
# 造一块 40G 的假盘（比镜像大，用来验证扩盘）
qemu-img create -f raw /tmp/target.img 40G

# 写入
dd if=ReiNAS.x86_64-0.2.0.raw of=/tmp/target.img \
   bs=4M conv=notrunc status=progress
```

**注意 `conv=notrunc`**：不加的话 dd 会把目标文件截断到源文件大小，扩盘就测不出来了。

### 2.2 启动

```bash
qemu-system-x86_64 \
  -enable-kvm -m 4096 -smp 2 \
  -drive file=/tmp/target.img,format=raw,if=virtio \
  -drive file=/usr/share/OVMF/OVMF_CODE.fd,format=raw,if=pflash,readonly=on \
  -drive file=/tmp/OVMF_VARS.fd,format=raw,if=pflash \
  -serial mon:stdio
```

先把 `OVMF_VARS.fd` 复制一份可写副本：

```bash
cp /usr/share/OVMF/OVMF_VARS.fd /tmp/OVMF_VARS.fd
```

### 2.3 验证清单

| 检查 | 命令（在启动后的系统里） | 期望 |
|---|---|---|
| 系统起来了 | — | 登录提示出现 |
| 身份正确 | `cat /etc/os-release` | `NAME="ReiNAS"`、`VERSION="0.2.0"` |
| **扩盘生效** | `lsblk` + `df -h /` | 根分区 ≈ 40G，不是 8G |
| 子卷布局 | `btrfs subvolume list /` | 有 `root` / `home` / `var` / `srv` |
| SELinux | `getenforce` | `Enforcing` |
| 服务 | `systemctl is-enabled sshd cockpit.socket` | 都是 `enabled` |
| 默认 target | `systemctl get-default` | `multi-user.target` |
| machine-id 唯一 | `cat /etc/machine-id` | **每次部署都不一样**（非空非固定） |
| root 锁定 | `passwd -S root` | `L`（locked） |
| 登录提示 | 看 console | 显示 `ReiNAS management: https://<ip>:9090` |
| **Secure Boot** | `mokutil --sb-state` 或 `dmesg \| grep -i secure` | `SecureBoot enabled` |
| dnf 可用 | `dnf repolist` | 能看到 `fedora` / `updates`，且 `$releasever` = 45 |
| 关键包在 | `rpm -q reinas-release samba nfs-utils cockpit podman` | 全部已安装 |

**最容易被忽略的两项**：

- **`$releasever` 必须是 45 不是 0.2.0**。跑 `dnf repolist -v | grep -i releasever` 确认。如果是 0.2.0，说明 `Provides: system-release(releasever)` 没生效，所有 metalink 会 404。
- **machine-id 必须为空**。如果 dd 出去两台机器 machine-id 相同，systemd 会拒绝启动 journald/networkd，DHCP 也会冲突。

---

## 3. install.iso 测试（对应"装机盘"）

### 3.1 启动装机盘

```bash
qemu-img create -f raw /tmp/install-target.img 40G

qemu-system-x86_64 \
  -enable-kvm -m 4096 -smp 2 \
  -cdrom ReiNAS.x86_64-0.2.0.install.iso \
  -drive file=/tmp/install-target.img,format=raw,if=virtio \
  -boot d \
  -serial mon:stdio
```

### 3.2 验证清单

| 检查 | 期望 |
|---|---|
| ISO 能启动到 kiwi 安装器 | 出现部署界面 |
| 目标盘可选 | 能选到 `/dev/vda` |
| **⚠️ 只碰选定盘** | 若另挂一块数据盘，确认它未被写入 |
| 部署完成能启动 | 拔掉 ISO 后从硬盘启动成功 |

**最关键的是第三项**。kiwi 的 `oem` 安装器默认只部署到选定盘，但要实测确认——这是 NAS 场景里"不能误删数据盘"的直接对应。

---

## 4. Secure Boot 专项

```bash
# 确认 OVMF 的 Secure Boot 已启用
qemu-system-x86_64 ... -machine q35,smm=on \
  -global driver=cfi.pflash01,property=secure,value=on \
  ...
```

启动后：

```bash
mokutil --sb-state          # 期望 SecureBoot enabled
bootctl status 2>/dev/null | grep -i secure   # 若用 systemd-boot
```

**如果 Secure Boot 下起不来**，几乎一定是这三件事之一：

1. `shim-x64` / `grub2-efi-x64` / `kernel` 有一个不是 Fedora 签名的原件
2. 你自己替换过 grub 或内核
3. `efibootmgr` 注册的启动项指向了非签名路径

用 `sbverify --list /boot/efi/EFI/fedora/shimx64.efi` 可以看到签名者是不是 Microsoft。

---

## 5. 冒烟测试脚本

把 2.3 的检查项做成一个脚本，构建后跑一次：

```bash
#!/bin/bash
# scripts/smoke.sh — 在已启动的 ReiNAS 系统里跑
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
chk "系统身份"   "grep ^NAME= /etc/os-release"            'ReiNAS'
chk "版本"       "grep ^VERSION= /etc/os-release"         '0.2.0'
chk "SELinux"    "getenforce"                             'Enforcing'
chk "releasever" "cat /etc/dnf/vars/releasever"           '45'
chk "默认target" "systemctl get-default"                  'multi-user'
chk "sshd"       "systemctl is-enabled sshd"              'enabled'
chk "cockpit"    "systemctl is-enabled cockpit.socket"    'enabled'
chk "root锁定"   "passwd -S root | cut -d' ' -f2"         'L'
chk "子卷"       "btrfs subvolume list / | wc -l"         ''
chk "关键包"     "rpm -q reinas-release"                  'reinas-release-0.2.0'
chk "dnf仓库"    "dnf repolist 2>/dev/null | wc -l"       ''
[ "$fail" = 0 ] && echo "全部通过" || { echo "有失败项"; exit 1; }
```

---

## 6. 已知未验证项

记录在这里，避免误以为已验证：

| 项 | 状态 | 原因 |
|---|---|---|
| 完整构建成功 | ⏳ | 需要一台 Fedora 45 机器或 boxbuild 环境 |
| 扩盘在真机上生效 | ⏳ | 目前只在 QEMU 测 |
| Secure Boot 真机启动 | ⏳ | 需 OVMF + 真机双验证 |
| aarch64 构建 | ❌ | 描述文件里已注释，需要板级引导脚本 |
| 跨 Fedora 版本升级 | ❌ | 0.3 之前不做，见 decisions.md |
