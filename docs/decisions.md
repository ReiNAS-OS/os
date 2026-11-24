# 技术决策记录

## D-001：基底选 Fedora，不选 openSUSE Leap / Arch

**日期**：2026-11-23
**状态**：已决定

### 背景

要做 ReiNAS 的发行版基底。候选：Fedora、openSUSE Leap 16.1、AlmaLinux 10、Arch Linux。最初排除 Debian（太常见、内核旧、无 OEM 工具链）。

### 决策

**Fedora 45**。

### 理由

1. **决定性的**：Fedora 自己就用 kiwi 造镜像（Cloud / Vagrant / 容器 / WSL / 大部分桌面 spin 的 live ISO）。工具链、描述文件、CI 模式全部现成，且这条路 Fedora 官方在维护。用别家底座 = 自己维护工具链。
2. **仓库丰度**：Fedora 45 Everything 有 **67,222** 个唯一二进制包名（x86_64 + noarch），对比 Leap 16.1 OSS 的 **37,131**、Arch core+extra+multilib 的 **15,782**。要"软件多"，Fedora 是这三家里最多的。
3. **用户已有肌肉记忆**：日常主力 Fedora，dnf / SELinux / systemd 那套不用重学。
4. **重品牌化最省事**：Fedora Remix 政策明确 "You can call your product a Fedora Remix without even asking"，且允许完全不同的名字与美术。比 openSUSE 的逐包替换 `*-branding-openSUSE` 更简单。
5. **Secure Boot 天然可用**：`shim-x64` + `grub2-efi-x64` + `kernel` 全用 Fedora 已签名原件，Microsoft CA 链有效，不需要自己走 shim-review。

### 代价（明确接受）

**13 个月生命周期。** Fedora 官方无 LTS，每个版本维护 13 个月。后果：

- 每年必须重新出一次镜像（改 4 处版本号，约半天工作量）
- 不能 `dnf system-upgrade`，因为 `reinas-release` 的 `Obsoletes: fedora-release` 会破坏 Fedora 官方升级路径，需要自己写迁移脚本
- 老版本机器不会自动获得安全更新，得靠用户主动升级

对一个个人自用/小范围使用的系统，这个代价可接受。**如果将来要变成要卖的产品，这条会成为硬伤，届时需重新评估 AlmaLinux 10（支持到 2035）。**

---

## D-002：镜像类型用 `oem`，不用 `iso`

**日期**：2026-11-23
**状态**：已决定

### 决策

`<type image="oem" installiso="true" installstick="true">`

### 理由

需求是**两种形态**：dd 到服务器，以及装机 ISO。

kiwi 的 image 类型里，只有 `oem` 能同时满足：

| 类型 | `.raw` | `.install.iso` | 首启扩盘 |
|---|---|---|---|
| `oem` + `installiso=true` | ✅ | ✅ | ✅ |
| `oem` + `installiso=false` | ✅ | ❌ | ⚠️ 取决 oem-resize |
| `iso`（live） | ❌ | 只有 live ISO | ❌ |

一次 `oem` 构建同时产出 `.raw` 和 `.install.iso`，**不用做两个 profile**。

### `oem-resize` 的选择

**设为 `true`**（默认）。理由：同一份 raw 要能 dd 到 128G SSD 和 8T HDD，必须首启撑满。实现依赖 `dracut-kiwi-oem-repart`（Fedora 45 仓库里有）。

注意这是 `oem` 的两种形态分界点：
- `oem-resize=true` → 可扩展盘（我们的选择）
- `oem-resize=false` → 固定大小云镜像（Fedora Cloud Base 的做法，不适合 NAS）

### 分区方案

```
/boot/efi   512M  vfat     (efipartsize=512)
/boot       1024M ext4     (bootpartition=true, bootpartsize=1024)
/           btrfs 子卷：
              @root=root   ← 根
              home         ← 用户数据
              var          ← 日志/容器/dnf 缓存
              srv          ← NAS 共享数据
```

**为什么 bootpartition=true**：btrfs 早期引导（grub 读 btrfs）在 kiwi 里需要额外验证，单独 ext4 的 /boot 是 Fedora 云镜像不做的但 NAS 更需要的稳妥选择。

**为什么 btrfs**：NAS 上快照/回滚是核心能力。`compress=zstd:1` 对日志和配置文本收益明显，对视频等已压缩数据自动跳过。

---

## D-003：不替换内核，保住 Secure Boot

**日期**：2026-11-23
**状态**：已决定

### 决策

内核、shim、grub2 全部使用 Fedora 已签名的原件。**不编译自己的内核。**

### 理由

Secure Boot 的信任链是：

```
Microsoft CA（固件 db 里）
  └─ shim-x64（Fedora 签名，内嵌 Fedora 证书）
       ├─ grub2-efi-x64（Fedora 证书签名）
       └─ kernel（Fedora 证书签名）
```

`reinas-release` 只改用户态身份，完全不碰这条链，所以**开箱即可在 Secure Boot 下启动**。

### 如果将来要自编译内核，三条路

| 方案 | 代价 |
|---|---|
| MOK 手动导入 | 每台机器首启要人按蓝屏确认，工厂部署需要物理接触 |
| 复用 Fedora shim + 自己的 MOK 密钥 | 同上，且要维护密钥分发 |
| 走 Microsoft shim-review | 志愿者 FIFO 排队 2–3 个月 + EV 代码签名证书 + FIPS 140-2 L2 HSM + 两名安全联系人 + 法人实体 |

**当前不触发的条件**：只要不改内核、不改 grub 二进制，这条链就一直有效。给 NAS 加驱动优先用 firmware 包或单包 KMP，不要动内核。

---

## D-004：被否掉的方案

### openSUSE Leap 16.1

**技术上是更好的发行版基底**——kiwi 的老家、`branding-basedonopensuse` 整套替换包、Immutable Mode 原子更新、24 个月/点版本、可平滑升 SLES 卖订阅。

**否掉的原因**：用户主力 Fedora，不想再学一套（zypper / OBS / Agama / Myrfolk）。而 Fedora 在"软件多"和"工具链现成"这两点上更好。

**如果将来要做商业产品，应该回头重新评估这个选项。** 它的 appliance 工具链是所有候选里最强的。

### Arch Linux

**技术上不可行**，不是偏好问题：

1. Arch 官方明确禁止部分升级（[wiki](https://wiki.archlinux.org/title/System_maintenance#Partial_upgrades_are_unsupported)），安全更新和功能更新是同一条流，无法只吃安全补丁
2. ALA 快照能钉住版本，但官方明说 "packages installed from an old snapshot do not receive security fixes"
3. 要做对就必须自建 unstable→testing→stable 三级仓库 = 重做 Manjaro，且该架构有结构性缺陷（一个包卡住整批卡住，曾导致一个月无安全更新）
4. 官方 ISO **不支持 Secure Boot**，而 Arch 也没有已签名的上游 shim 可借
5. 商标政策：商用需 Project Lead 明确授权，且"含自定义内核或非 Arch 仓库的包"属于 "unlikely to be approved"

**结论**：Arch 适合做桌面和"从 AUR 抄 PKGBUILD 当参考"，不适合做产品底座。

### AlmaLinux 10

支持到 2035，是企业级确定性的最佳选择。否掉原因：内核 6.12 且 kABI 十年不动，新硬件支持慢；RHEL 系已弃用 btrfs，NAS 上少了快照能力。

**如果 ReiNAS 未来要卖，这个是最应该重估的候选。**

---

## D-005：不用 kickstart / Anaconda

**日期**：2026-11-23
**状态**：已决定

### 背景

`/Users/mouyase/Projects/my/ReiNAS/distro/` 里有一套基于 `mkksiso` + kickstart 的方案，已验证能出 ISO 并引导到 GRUB，但"完整装成系统"这一步因本地内存限制未验证。

### 决策

**新仓库改用 kiwi，kickstart 方案不再延续。**

### 理由

| | kickstart + mkksiso | kiwi oem |
|---|---|---|
| 产物 | 只有安装 ISO | `.raw` + `.install.iso` |
| 首启扩盘 | 靠 Anaconda 分区 | 内建（oem-repart） |
| dd 直接可用 | ❌ | ✅ |
| 构建方式 | 注入官方 ISO（依赖官方镜像不变） | 从零组装 rootfs |
| 可复现性 | 依赖上游 ISO 内容 | 完全由描述文件定义 |
| 上游使用情况 | Fedora 仅 Server DVD 用 Anaconda | Fedora 大多数制品用 kiwi |

**决定性理由**：需求包含 "dd 到服务器"，kickstart 方案给不了 `.raw`。

### 旧方案里值得保留的东西

`distro/rpm/reinas-release.spec` 里的兼容性设计（`system-release(releasever)` provide、`Obsoletes: fedora-release`、原样复制的 `macros.dist` 和 preset）经实践验证有效，已移植到 `packages/reinas-release/`。

`distro/kickstart/reinas.ks` 里关于"NAS 不能自动清盘"的判断依然正确，在 kiwi 方案里体现为 `oem-resize` 只扩不删。

---

## D-006：必须在完整 Linux 环境构建，不能用容器

**日期**：2026-11-24
**状态**：已决定

### 结论

用 `kiwi-ng system boxbuild --box fedora`。它起一台虚拟机（完整 `/dev` + udev）在内跑 `kiwi-ng system build`。

不允许的两条路，以及各自为什么失败：

| 方式 | 结果 |
|---|---|
| Docker 容器直接构建 | ❌ 缺 udev，`/dev/loopNpX` 不创建 |
| 手搭 chroot + bind 宿主 `/dev` | ❌ loop 通了，但接着撞 grub/dracut 一串问题 |

### 容器为什么不行

构建走到建分区那一步必然失败：

```
EXEC: [sgdisk --align-end -n 4:0:0 -c 4:p.lxroot /dev/loop0]
EXEC: [partx --add /dev/loop0]
ERROR: KiwiMappedDeviceError: Device /dev/loop0p1 does not exist
```

根因：Docker 容器没有 udev。内核识别出 loop 分区（`sysfs` 里有 `loop0p1`），但没有程序去创建 `/dev/loop0p1` 设备节点。手动 `mknod` 立即可用；启动 `systemd-udevd` + `udevadm trigger` 也无效。

**这不是 kiwi 的 bug**：用 Fedora 官方 kiwi-descriptions 的 f45 分支、零修改零补丁，失败在完全相同的位置。

### 手搭 chroot 为什么也不行

bind 宿主 `/dev` 进 chroot 后 loop 节点确实能创建（`brw-rw---- root disk 259,5 /dev/loop0p1`），但接着要逐个补偿：

- `KiwiBootLoaderGrubDataError: grub path i386-pc not found` → 补 `grub2-pc` / `grub2-efi-ia32` 全套
- `dracut[E]: No '/dev/log' or 'logger' included` → 补常驻 socket 或 `util-linux-core`

这些在 boxbuild 的完整 VM 里都不存在。手搭等于把 kiwi 已经封装好的环境维护责任揽过来。

### 关键事实：包名不同于 openSUSE

| 名称 | 归属 | Fedora 有吗 |
|---|---|---|
| `kiwi-boxbuild` 命令 | openSUSE OBS | ❌ |
| `kiwi-boxed-plugin` → `kiwi-ng system boxbuild` | Fedora 官方 | ✅ |

```bash
dnf install kiwi-cli kiwi-boxed-plugin kiwi-systemdeps-boxbuild
kiwi-ng --type oem --profile Disk system boxbuild --box fedora kiwi \
  --description ./kiwi --target-dir ./out
```

### boxbuild 的共享限制

box 只共享 `--description` 和 `--target-dir` 两个目录。因此：

- 本地 rpm 仓库必须放在 description 目录**内部**（`kiwi/rpms/`），用 `this://./rpms` 引用
- 放在仓库根目录构建箱看不到
- 不能用 `127.0.0.1:8888` 的 HTTP 服务——VM 有独立网络命名空间

### 附带教训：那 5 处 kiwi 补丁是无效的

过程中给 kiwi 打过 5 处源码补丁（裁 plugin 参数、去 `--config`、加 `--use-host-config`、禁 rpmdb 重定向、强制 `use_default_location`）。事后验证：官方描述不加任何补丁也能推进到同一位置。补丁只让构建多跑十分钟，没解决任何问题。

**遇到 kiwi 行为异常，先对照 Fedora 官方描述文件，而不是改 kiwi 源码。**

---

## D-007：调试账号用显式开关，默认关闭

**日期**：2026-11-24
**状态**：已决定

### 背景

0.1.0 之前的状态是：`root` 和 `reinas` 都 `passwd -l` 锁定，SSH 是
`PasswordAuthentication no`，而 `<users>` 段里一个用户都没有。结果是镜像
能构建、能启动，但**装完没有任何人能登录**——只能 `rd.break` 或单步救援改
`/etc/shadow`。验证阶段没法做。

需要一个「开发时能进、发布时进不去」的机制。

### 决策

**一个开关，默认关。**

```bash
./scripts/build.sh                        # 关（生产形态）
./scripts/build.sh --debug-password       # 开，reinas 密码 123456
./scripts/build.sh --debug-password=xxx   # 开，自定义密码
```

CI 里对应 `workflow_dispatch` 的 `debug_password` 输入，留空即关闭。

### 实现链路

```
build.sh --debug-password
  └─ 写 kiwi/debug.conf（一行明文密码；关闭时是空文件）
       └─ reinas.kiwi 的 <file name="debug.conf" target="/etc/reinas/debug.conf">
            └─ config.sh 用 read 读它
                 ├─ 有密码 → chpasswd + passwd -u reinas
                 │           + 写 20-reinas-debug.conf 放开 SSH 密码登录
                 │           + 写 /etc/reinas/BUILD-IS-DEBUG 标记
                 └─ 无密码 → 账号保持锁定，什么也不改
```

三个设计选择，都是踩过的：

1. **用 `read` 不用 `source`。** 密码里带 `$` `` ` `` `"` `\` 时，`source`
   会把它当 shell 代码展开。实测 `a$b`c"d\e` 用 `source` 读出来是空的。
2. **关闭时写空文件，不写 `VAR=""`。** `[ -s file ]` 判断比解析一行 shell
   赋值难出错。
3. **config.sh 在两个分支里都 `rm -f /etc/reinas/debug.conf`。** 明文密码
   不能留在交付镜像里。

### 生产形态的真实含义

关闭时镜像里**没有任何已知口令**：

- `root` 锁定密码
- `reinas` 锁定密码，在 `wheel` 组
- SSH 只认公钥，但镜像里也没有预置公钥

所以当前的关闭态是「安全但进不去」，不是「安全且能进」。真正要能进，还缺
一条合法的初始凭据通道（首启向导 / ISO 装机时建账号 / 注入公钥）。这是
0.2 的事，在它做完之前**调试开关是唯一能登录的路**。

### 强制约束

`validate.yml` 里有两步守着，改动时会被拦：

- `确认调试账号默认关闭` —— 检查 `<file>` 条目在、`[ -n "$DEBUG_PASSWORD" ]`
  守卫在、`rm -f debug.conf` 分支在、`debug.conf` 没入库
- `检查调试开关的实际行为` —— 真跑一遍开关逻辑，验空文件 / 密码内容 /
  元字符不展开 / 换行被拒

`kiwi/debug.conf` 在 `.gitignore` 里，且可能含明文密码，绝不入库。
