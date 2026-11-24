# 产物验证

`scripts/build.sh` 跑完会在 `out/` 得到两个文件。这份文档说明怎么在 QEMU 里验证它们，以及每个检查项证明什么。

---

## 0. 前置

```bash
sudo dnf install -y qemu-kvm qemu-img edk2-ovmf virt-install
```

`edk2-ovmf` 提供 UEFI 固件，验证 Secure Boot 必需。

### 0.1 构建时打开 root 密码

**必须做这一步，否则下文所有检查都进不去。** 默认构建出来的镜像：

- `root` 和 `reinas` 都是锁定密码
- SSH 是 `PasswordAuthentication no`，且镜像里没有预置任何公钥

结果是串口能看到登录提示，但没有可用的凭据。见 decisions.md D-007。

```bash
sudo ./scripts/build.sh --root-password     # root / 123456
```

打开后直接以 `root` 密码登录，`scripts/smoke.sh` 也就能直接跑。

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
cd out/

# CI 产物是 xz 压缩的，先解开。文件名带 `-0` 是 RPM release 号，别漏。
xz -dk ReiNAS.x86_64-0.1.0-0.raw.xz
# → ReiNAS.x86_64-0.1.0-0.raw

# 先验一下有没有解压坏
sha256sum -c ReiNAS.x86_64-0.1.0-0.raw.xz.sha256

# 造一块 40G 的假盘（比镜像大，用来验证扩盘）
qemu-img create -f raw /tmp/target.img 40G

# 写入
dd if=ReiNAS.x86_64-0.1.0-0.raw of=/tmp/target.img \
   bs=4M conv=notrunc status=progress
```

**两处容易踩的**：

- **`conv=notrunc`**：不加的话 dd 会把目标文件截断到源文件大小，扩盘就测不出来了。
- **文件名**：实际产物是 `ReiNAS.x86_64-0.1.0-0.raw.xz` —— 带 release 号 `-0`，
  且是压缩的。`ReiNAS.x86_64-0.1.0.raw` 这个写法不存在。CI 上传的 artifact
  解压出来就是这个名字。

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
| **能登录** | 控制台输入 `root` / `123456` | 进入 shell（仅 `--root-password` 构建） |
| 身份正确 | `cat /etc/os-release` | `NAME="ReiNAS"`、`VERSION="0.1.0"` |
| **扩盘生效** | `lsblk` + `df -h /` | 根分区 ≈ 40G，不是 8G |
| 子卷布局 | `btrfs subvolume list /` | 有 `root` / `home` / `var` / `srv` |
| SELinux | `getenforce` | `Enforcing` |
| 服务 | `systemctl is-enabled sshd cockpit.socket` | 都是 `enabled` |
| 默认 target | `systemctl get-default` | `multi-user.target` |
| machine-id 生成 | `cat /etc/machine-id` | 非空，且**每台机器不同** |
| root 锁定 | `passwd -S root` | `L`（locked） |
| root 密码状态 | `passwd -S root` | 开密码构建 `P`；生产构建 `L` |
| reinas 始终锁定 | `passwd -S reinas` | 恒为 `L` |
| 构建标记 | `ls /etc/reinas/BUILD-HAS-ROOT-PASSWORD` | 开密码构建存在；生产构建不存在 |
| 登录提示 | 看 console | 显示 `ReiNAS management: https://<ip>:9090` |
| **Secure Boot** | `mokutil --sb-state` 或 `dmesg \| grep -i secure` | `SecureBoot enabled` |
| dnf 可用 | `dnf repolist` | 能看到 `fedora` / `updates`，且 `$releasever` = 45 |
| 关键包在 | `rpm -q reinas-release samba nfs-utils cockpit podman` | 全部已安装 |

**最容易被忽略的三项**：

- **`$releasever` 必须是 45 不是 0.1.0**。跑 `dnf repolist -v | grep -i releasever` 确认。如果是 0.1.0，说明 `Provides: system-release(releasever)` 没生效，所有 metalink 会 404。
- **machine-id 必须是每台机器不同的**。启动之后它必然有值，所以判断标准不是「文件为空」，而是「两次部署值不同」。
  **⚠️ 这里有个未验证的顺序问题**：`config.sh` 第 22-23 行 `rm -f` + `touch /etc/machine-id` 造出空文件，但描述文件的 `<packages type="delete">` 里也列了 `/etc/machine-id`，而 kiwi 的删除阶段在 `config.sh` **之后**执行（构建日志实测：08:04:14 config.sh → 08:04:17 uninstall）。两者谁赢取决于 `<file>` 在 delete 段里是否真的生效。详见 [kiwi-pitfalls.md](kiwi-pitfalls.md) 的「delete 在 config.sh 之后执行」一节。
  启动后 `ls -l /etc/machine-id` 确认：存在且为空 → 删除没生效；不存在 → 删除生效、config.sh 被覆盖。
- **`/etc/reinas/root.conf` 不该存在于装好的系统里**。config.sh 读完就删。`ls /etc/reinas/` 只应看到 `BUILD-HAS-ROOT-PASSWORD`（开密码构建）或什么都没有（生产构建）。

---

## 3. install.iso 测试（对应"装机盘"）

### 3.1 启动装机盘

```bash
qemu-img create -f raw /tmp/install-target.img 40G

qemu-system-x86_64 \
  -enable-kvm -m 4096 -smp 2 \
  -cdrom ReiNAS.x86_64-0.1.0-0.install.iso \
  -drive file=/tmp/install-target.img,format=raw,if=virtio \
  -boot d \
  -serial mon:stdio
```

注意 ISO 的名字不带 release 号 `-0`（raw 带，ISO 不带），这是 kiwi 的命名规则。
在 `out/` 里 `ls *.iso` 确认。

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

不要照抄这份文档里的检查项 —— 用仓库里的脚本，它和本文档保持同步：

```bash
# 在已启动的 ReiNAS 系统里，以 root 跑
sudo ./scripts/smoke.sh
```

**不要在这里贴第三份副本。** 这份文档曾经抄了一份 `smoke.sh` 的全文，结果和
实际脚本对不上，还带着两条「期望串为空 = 永远通过」的假断言。需要改检查项就
改 `scripts/smoke.sh`，那是唯一来源。

脚本覆盖：身份（`NAME`/`VERSION`/`ID_LIKE`）、`releasever`、SELinux、账号锁定、
sshd 配置、服务 enable 状态、btrfs 根与子卷、压缩挂载、关键包、dnf 仓库。

---

## 6. 已知未验证项

记录在这里，避免误以为已验证：

| 项 | 状态 | 说明 |
|---|---|---|
| 完整构建 | ✅ | CI 成功，产物已作为 artifact 上传（`.raw.xz` 626 MB、`.install.iso` 863 MB） |
| 调试账号开关 | ⏳ | 逻辑本地验过（空文件/密码内容/元字符/换行），未在真镜像里跑过 |
| 镜像能启动 | ⏳ | 产物已出，尚未在 QEMU 里跑过 |
| 扩盘在真机上生效 | ⏳ | 目前只在 QEMU 测 |
| Secure Boot 真机启动 | ⏳ | 需 OVMF + 真机双验证 |
| aarch64 构建 | ❌ | `preferences arch="aarch64"` 存在但没有 aa64 的 shim/grub 包，永远跑不通 |
| 跨 Fedora 版本升级 | ❌ | 0.3 之前不做，见 decisions.md |
