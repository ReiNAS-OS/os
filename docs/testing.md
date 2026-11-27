# 产物验证

`scripts/build.sh` 跑完会在 `out/` 得到两个文件。这份文档说明怎么在 QEMU 里验证它们，以及每个检查项证明什么。

---

## 0. 前置

```bash
sudo dnf install -y qemu-kvm qemu-img edk2-ovmf virt-install
```

`edk2-ovmf` 提供 UEFI 固件，验证 Secure Boot 必需。

**macOS（Apple Silicon）不需要 dnf**，装 qemu 就有固件：

```bash
brew install qemu
```

固件在 `/opt/homebrew/share/qemu/edk2-aarch64-code.fd` 和 `edk2-arm-vars.fd`。
`scripts/vm.sh` 会自己找，不用配路径。

### 0.1 直接拉 CI 产物起测

不用在本机构建。CI 构建出的镜像带 root 密码，拉下来就能登：

```bash
cd os/
./scripts/vm.sh list          # 看最近的构建
./scripts/vm.sh pull          # 拉最新一次成功构建（约 500M raw.xz + 装机 ISO）
./scripts/vm.sh boot          # 起虚机，串口控制台就是显示器
./scripts/vm.sh gui           # 同上，但开 GUI 窗口（看登录界面必须用这个）

# 控制台里
Login: root
Password:     123456
```

`boot` 是串口控制台，`gui` 开 cocoa 窗口 —— **看登录界面必须用 `gui`**，
串口日志里字标是一堆转义字节，看不出对错。两个模式的差别、抓屏和模拟按键的
做法、以及从 CI 拉产物替换本地镜像的完整流程，都在
[vm-workflow.md](vm-workflow.md)。

### 0.2 构建时打开 root 密码

自己构建时**必须做这一步，否则下文所有检查都进不去。** 默认构建出来的镜像：

- `root` 和 `reinas` 都是锁定密码
- SSH 是 `PasswordAuthentication no`，且镜像里没有预置任何公钥

结果是串口能看到登录提示，但没有可用的凭据。见 decisions-account.md D-007。

```bash
sudo ./scripts/build.sh --root-password     # root / 123456
```

打开后直接以 `root` 密码登录，`scripts/smoke.sh` 也就能直接跑。

**CI 上的构建默认也是关的**，手动触发时在 `root_password` 输入框填密码才会开。

---

## 1. 检查产物完整性

```bash
cd out/
sha256sum -c *.sha256
```

**证明什么**：文件传输/存储没损坏。发布前必做。

---

## 2. dd 镜像测试（对应"往服务器上装"）

把 raw 当一块盘直接启动。`scripts/vm.sh boot` 干的就是这件事 —— 它建一个
qcow2 overlay 盖在 raw 上，raw 保持只读，所以试坏了删 overlay 就行。

```bash
./scripts/vm.sh pull                          # 拉 CI 产物（含 raw.xz，boot 时自动解开）
./scripts/vm.sh boot                          # 起虚机
```

要自己指定镜像：

```bash
BASE_IMAGE=/path/to/ReiNAS.x86_64-0.1.0.raw ./scripts/vm.sh boot
```

**手工 dd 到一块独立盘**（想验证「装到真盘上」这条路径时才需要）：

```bash
cd out/
xz -dk ReiNAS.x86_64-0.1.0-0.raw.xz          # CI 产物是压缩的，先解开
sha256sum -c ReiNAS.x86_64-0.1.0-0.raw.xz.sha256   # 确认没解压坏

qemu-img create -f raw /tmp/target.img 40G   # 比镜像大，用来验证扩盘
dd if=ReiNAS.x86_64-0.1.0-0.raw of=/tmp/target.img \
   bs=4M conv=notrunc status=progress
```

**`conv=notrunc` 不能省**：不加的话 dd 会把目标文件截断到源文件大小，扩盘
就测不出来了。

### 2.3 验证清单

| 检查 | 命令（在启动后的系统里） | 期望 |
|---|---|---|
| 系统起来了 | — | 登录提示出现 |
| **能登录** | 控制台输入 `root` / `123456` | 进入 shell（仅 `--root-password` 构建） |
| 身份正确 | `cat /etc/os-release` | `NAME="ReiNAS"`、`VERSION="0.1.0"` |
| **扩盘生效** | `lsblk` + `df -h /` | 根分区 ≈ 40G，不是 8G |
| 子卷布局 | `btrfs subvolume list /` | 有 `root` / `home` / `var` / `srv` |
| SELinux | `getenforce` | `Enforcing` |
| 服务 | `systemctl is-enabled sshd firewalld chronyd` | 都是 `enabled` |
| 默认 target | `systemctl get-default` | `multi-user.target` |
| machine-id 生成 | `cat /etc/machine-id` | 非空，且**每台机器不同** |
| root 锁定 | `passwd -S root` | `L`（locked） |
| root 密码状态 | `passwd -S root` | 开密码构建 `P`；生产构建 `L` |
| 没有预置普通用户 | `ls /home` | 空（第一个普通用户由面板初始化创建） |
| 构建标记 | `ls /etc/reinas/BUILD-HAS-ROOT-PASSWORD` | 开密码构建存在；生产构建不存在 |
| 登录提示 | 看 console | 显示 `Web console:
 https://<ip>:5090`（面板未实现时访问会失败，正常） |
| **Secure Boot** | `mokutil --sb-state` 或 `dmesg \| grep -i secure` | `SecureBoot enabled` |
| dnf 可用 | `dnf repolist` | 能看到 `fedora` / `updates`，且 `$releasever` = 45 |
| **dnf 能装包** | `dnf install -y tree` | `Complete!`（验证 repo + GPG 密钥都在，见下） |
| 关键包在 | `rpm -q reinas-release samba nfs-utils btrfs-progs` | 全部已安装 |

**最容易被忽略的三项**：

- **`$releasever` 必须是 45 不是 0.1.0**。跑 `dnf repolist -v | grep -i releasever` 确认。如果是 0.1.0，说明 `Provides: system-release(releasever)` 没生效，所有 metalink 会 404。
- **dnf 光有 repo 文件还不够，还得有 GPG 公钥**。两个包成对存在：
  `fedora-repos`（repo 定义）和 `fedora-gpg-keys`（验签公钥）。只装前者时
  包能下载、验签失败：

  ```
  cannot open file: (2) - No such file or directory
  [/usr/share/pki/rpm-gpg/RPM-GPG-KEY-fedora-45-aarch64]
  ```

  `dnf repolist` 能列出仓库不代表能用，**必须真装一个包**（上面表里那条
  `dnf install -y tree`）才算验证过。
- **machine-id 必须是每台机器不同的**。启动之后它必然有值，所以判断标准不是「文件为空」，而是「两次部署值不同」。
  **⚠️ 这里有个未验证的顺序问题**：`config.sh` 第 22-23 行 `rm -f` + `touch /etc/machine-id` 造出空文件，但描述文件的 `<packages type="delete">` 里也列了 `/etc/machine-id`，而 kiwi 的删除阶段在 `config.sh` **之后**执行（构建日志实测：08:04:14 config.sh → 08:04:17 uninstall）。两者谁赢取决于 `<file>` 在 delete 段里是否真的生效。详见 [kiwi-pitfalls.md](kiwi-pitfalls.md) 的「delete 在 config.sh 之后执行」一节。
  启动后 `ls -l /etc/machine-id` 确认：存在且为空 → 删除没生效；不存在 → 删除生效、config.sh 被覆盖。
- **`/etc/reinas/root.conf` 不该存在于装好的系统里**。config.sh 读完就删。`ls /etc/reinas/` 只应看到 `BUILD-HAS-ROOT-PASSWORD`（开密码构建）或什么都没有（生产构建）。

---

## 3. install.iso 测试（对应"装机盘"）

### 3.1 启动装机盘

```bash
./scripts/vm.sh install        # 造 40G 空盘 + 起装机器，自动应答确认框
```

约 10 分钟。装好的盘在 `.vm/<arch>/install-target.raw`，能直接起：

```bash
BASE_IMAGE=$PWD/.vm/aarch64/install-target.raw ./scripts/vm.sh boot
```

盘大小用 `INSTALL_TARGET` 改（默认 `40G`）。

**不要照着手写 `-cdrom` 起装机盘。** ISO 里 GRUB 的 serial 模块没编进去，
菜单收不到按键，5 秒后自动选「Boot from Hard Disk」直接退出，看起来像镜像
坏了。`vm.sh install` 用 `-kernel` 直启绕过了这一步，原因见文末
「在 QEMU 里装机的两个坑」。

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
| 完整构建 | ✅ | CI 成功，产物作为 artifact 上传（aarch64：`.raw.xz` 493 MB、`.install.iso` 725 MB） |
| 调试账号开关 | ✅ | aarch64 实测：控制台 `root` / `123456` 能登，`passwd -S root` 为 `P`，`/etc/reinas/BUILD-HAS-ROOT-PASSWORD` 存在 |
| 镜像能启动 | ✅ | aarch64 + QEMU hvf 实测：GRUB → 内核 → systemd → 串口 agetty，冷启动约 20 秒 |
| 控制台 SSH 密码登录 | ❌ | 构建里 `10-reinas.conf` 关掉密码登录，`20-reinas-root.conf` 想打开，但 sshd 是**先读到的值生效**，`10` 在 `20` 前面，覆盖不成立。控制台能登、SSH 不能。改法见下 |
| 装机（install.iso → 空盘） | ✅ | aarch64 实测：`./scripts/vm.sh install` 全自动跑完，装好的盘能起 GRUB → 登录提示 |
| 首启扩盘 | ✅ | 装到 40G 盘实测：根分区 39G、`vda3` 38.5G（镜像本体 8G）。QEMU 已验证，真机未测 |
| btrfs 子卷 | ✅ | 装好的系统里 `btrfs subvolume list /` 有 root / home / var / srv 四个 |
| 扩盘在真机上生效 | ⏳ | 目前只在 QEMU 测 |
| Secure Boot 真机启动 | ⏳ | 需 OVMF + 真机双验证 |
| aarch64 构建 | ✅ | CI 用 `ubuntu-26.04-arm` 原生构建成功，产物可启动。旧记录说「没 aa64 的 shim/grub 包」已过时 |
| 跨 Fedora 版本升级 | ❌ | 0.3 之前不做，见 decisions.md |

### 登录界面的四个坑

改登录提示（`config.sh` 第 8.5 / 9 节、`kiwi/root/etc/issue.d/`）之前先看这段，
这四个都是实测踩出来的。

**1. agetty 的提示串是编译进二进制的，改不了大小写**

`login: ` 是 `/sbin/agetty` 里的字面量，没有配置项。`--nohostname` 只去掉
主机名，字母还是小写。而 `login` 程序提示的是 `Password:`，两个大小写不一致。

解法是 `--skip-login`（`-n`）：让 agetty 完全不打印提示，交给
`/usr/local/sbin/reinas-login` 自己打 `Login: `、读用户名、再 `exec` 真 login。

⚠️ 不加 `-n` 的话，agetty 会先打自己的 `login: ` 再调 `-l` 脚本，屏幕上两行
提示叠着。

**2. `getty@.service` 和 `serial-getty@.service` 是两套独立模板，不继承**

drop-in 必须**两个都写**。只给 `getty@` 加时，VGA 上已经是 `Login:`，串口却
还是 agetty 原版的。`config.sh` 里用 for 循环同时写两个。

查证方法（两个都要查，别只看一个）：

```bash
systemctl show getty@tty1.service -p ExecStart --value
systemctl show serial-getty@ttyAMA0.service -p ExecStart --value
```

**3. Fedora 自带 `/etc/issue`，不清空会多打印一段版本信息**

agetty 读 `/etc/issue` **和** `/etc/issue.d/*.issue` 两部分。Fedora 的
`/etc/issue` 内容是：

```
\S
Kernel \r on an \m (\l)
```

展开后是 `ReiNAS 0.1.0` + `Kernel 7.3.4-... (tty1)`，和字标下面的版本行重复。

**别用「放一个空文件」的办法** —— 那依赖某个包恰好提供空文件，包一变就失效。
`config.sh` 里显式 `: > /etc/issue`。

**4. issue 文件没有注释语法**

agetty 只解释 `\` 开头的转义，其余逐字节输出。写一行 `# 说明` 会原样显示在
登录界面上（实测）。所以配色、排版这些说明只能写在 `config.sh` 里，不能写进
issue 文件。

顺带：issue 里的 ANSI 颜色必须是**真实 ESC 字节**（0x1B），不是字面的 `\033`
四个字符。用 `cat -v` 看，出现 `^[[` 才是对的。

### sshd drop-in 覆盖顺序的坑

`config.sh` 里两个 drop-in 互相打架：

```
10-reinas.conf        PermitRootLogin prohibit-password / PasswordAuthentication no
20-reinas-root.conf   PermitRootLogin yes / PasswordAuthentication yes   ← 只在 --root-password 时写
```

sshd 对同一个选项**取第一次读到的值**，不是最后一次。`10-` 排在 `20-` 前面，
所以硬化段的 `no` 永远赢。`--root-password` 构建出的镜像控制台能登录，SSH 里
`Permission denied (publickey,...)`。

修法二选一：把放开密码的 drop-in 改成 `05-reinas-root.conf`（排在前面），
或者让 `10-reinas.conf` 在设置密码时不写这两行。前者改动更小。

本地验证用 QEMU 串口进去看，不要开 SSH 端口 —— 镜像默认就不该开密码登录，
验证阶段也应该按真机的方式走。

### 在 QEMU 里装机的两个坑

`./scripts/vm.sh install` 已经把这两个都绕开了，记下来免得下次重新踩。

**1. 不能直接 `-cdrom` 启动 install.iso。**

ISO 里的 `boot/grub2/grub.cfg` 写了两行：

```
terminal_input serial
terminal_output serial
```

但这版 GRUB 没编进 serial 模块，两行都执行失败（日志里的
``terminal `serial' isn't found``）。GRUB 于是收不到任何按键，
5 秒超时后自动执行第一个菜单项 —— 也就是 `Boot from Hard Disk`，直接 exit。

解法：把 ISO 里的 `boot/<arch>/loader/linux` 和 `initrd` 抽出来，用
`-kernel` / `-initrd` 直接启动。装机的 GRUB 菜单里唯一有用的选项就是
「Install ReiNAS」，跳过选择不影响任何东西。ISO 仍要挂着，
`root=install:CDLABEL=REINAS_OS` 靠它找 squashfs。

**2. 装机的确认框要往串口写，不是往 monitor 发 sendkey。**

kiwi 的 oem 安装器会问 `Destroying ALL data on /dev/vda, continue ?`。
这个 dialog 读的是内核控制台 `ttyAMA0`：

- QEMU monitor 的 `sendkey` 注入的是 USB/PS2 键盘设备，dialog 收不到
- `-serial file:` 是单向的，写不进去
- 正解是 `-chardev socket,...,logfile=...` + `-serial chardev:ser0`：
  socket 用来写确认键，logfile 用来读日志

日志必须走 chardev 的 `logfile=` 参数，不要在宿主 `nc -U` 去读 socket ——
实测连上去收不到字节。

**为什么装机必须重铺固件变量盘。** `OVMF_VARS.fd` 会记住上次启动注册的
`BootXXXX` 项。那些项指向 `boot` 用过的那块 overlay，装机时那块盘不在，
UEFI 会一直试它然后退回 PXE，看起来像装机盘没做对引导。
