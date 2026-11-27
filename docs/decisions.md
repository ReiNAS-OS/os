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

早期有一套基于 `mkksiso` + kickstart 的方案，已验证能出 ISO 并引导到 GRUB，但
"完整装成系统"这一步未验证。该方案位于另一个仓库，不在本仓库内。

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

1. **release 包的兼容性设计**——`system-release(releasever)` provide、
   `Obsoletes: fedora-release`、原样复制的 `macros.dist` 和 preset。经实践验证
   有效，已移植到 `packages/reinas-release/`。
2. **"NAS 不能自动清盘"的判断**依然正确，在 kiwi 方案里体现为 `oem-resize`
   只扩不删。

---

## D-006：在 Fedora chroot 里构建，不套 VM

**日期**：2026-11-24
**状态**：已决定

### 结论

**在 Fedora chroot 里跑 `kiwi-ng system build`。不套 VM。**

```
runner (Ubuntu) → Fedora 45 chroot → kiwi-ng system build
```

| 方式 | 结果 |
|---|---|
| Docker 容器直接构建 | ❌ 缺 udev，`/dev/loopNpX` 不创建 |
| **Fedora chroot + bind 宿主 `/dev`** | ✅ **当前方案** |
| boxbuild（chroot 里再套 VM） | ⚠️ 能用但多余，见下 |

### 容器为什么不行

构建走到建分区那一步必然失败：

```
EXEC: [sgdisk --align-end -n 4:0:0 -c 4:p.lxroot /dev/loop0]
EXEC: [partx --add /dev/loop0]
ERROR: KiwiMappedDeviceError: Device /dev/loop0p1 does not exist
```

根因：Docker 容器**没有 udev 在跑**。内核识别出 loop 分区（`sysfs` 里有
`loop0p1`），但没有程序去创建 `/dev/loop0p1` 设备节点。手动 `mknod` 立即可用；
启动 `systemd-udevd` + `udevadm trigger` 也无效。

**这不是 kiwi 的 bug**：用 Fedora 官方 kiwi-descriptions 的 f45 分支、零修改
零补丁，失败在完全相同的位置。

### chroot 为什么可以

关键区别：**bind 了宿主 `/dev`，而宿主的 udev 在跑。**

```bash
for p in dev proc sys run; do
  mount --bind "/$p" "/mnt/fedora/$p"
done
```

内核在宿主上识别出 loop 分区，宿主的 udev 创建 `/dev/loopNpX`，chroot 里
因为共享 `/dev` 直接就能看到。

### 为什么不套 boxbuild 的 VM

boxbuild 起一台 QEMU 虚拟机，在 VM 里跑同样的 `kiwi-ng system build`。它的
唯一作用是提供「有 udev 的完整环境」——而 chroot 已经提供了。

不用的三个理由：

1. **arm64 runner 没有 `/dev/kvm`**：
   ```
   qemu-system-aarch64: -accel accel=kvm: Could not access KVM kernel module
   ```
   x86_64 的 runner 有，arm64 的没有。这是 GitHub 的硬限制。
2. **多一层 VM 慢一倍**：boxbuild 约 15 分钟，chroot 直接跑 6-9 分钟。
3. **box 只有 openSUSE 系可选**：fedora box 仅 x86_64，aarch64 得用
   universal（openSUSE 的通用环境）。虽然不进产物，但多一层不必要的依赖。

### 曾经的错误尝试：在 Ubuntu 上 native 构建

看到 arm64 没有 KVM 后，试过跳过 chroot 直接在 runner 上跑。连撞三次墙：

1. `error: Failed build dependencies: systemd-rpm-macros` —— Ubuntu 没这包
2. `error: File must begin with "/": %{_presetdir}/90-default.preset` ——
   Fedora 的 rpm 宏 Ubuntu 没有
3. 修一个冒一个，没有尽头

**这是把手搭环境的维护责任揽过来，和下面那条教训是同一个错误。**

rpm 宏、dnf、包名、路径约定，全都是 Fedora 的。要么用 Fedora 环境
（chroot），要么别做。

### 附带教训：那 5 处 kiwi 补丁是无效的

过程中给 kiwi 打过 5 处源码补丁（裁 plugin 参数、去 `--config`、加
`--use-host-config`、禁 rpmdb 重定向、强制 `use_default_location`）。事后验证：
官方描述不加任何补丁也能推进到同一位置。补丁只让构建多跑十分钟，没解决任何
问题。

**遇到 kiwi 行为异常，先对照 Fedora 官方描述文件，而不是改 kiwi 源码。**

---

## D-007：root 密码用显式开关，默认关闭

**日期**：2026-11-24
**状态**：已决定

账号相关的内容（root 密码开关的完整理由、为什么不是预置普通账号、
以及后续「镜像不再预置 reinas 账号」的修订）已移到
**[decisions-account.md](decisions-account.md)**。

一句话总结：镜像默认 root 锁定、SSH 仅公钥、**不预置任何普通用户**；
开发构建用 `./scripts/build.sh --root-password` 给 root 设密码。

---

## D-008：默认跟最新，用锁文件复现

**日期**：2026-11-24
**状态**：已决定

### 背景

描述文件里的 `<package>` 只写包名，不写版本。三个仓库（`fedora` /
`updates` / `reinas`）都是浮动源，`dnf-defaults.conf` 里也没有 `exclude`。

**后果**：同一份代码，今天构建和下周构建装出的东西不一样。

实测差距（Fedora 45 的 `releases/45` 冻结快照 vs `updates/45` 滚动）：

| 包 | releases/45 | updates/45 |
|---|---|---|
| kernel-core | 7.2.11-300.fc45 | 7.3.4-300.fc45 |
| systemd | 262-3.fc45 | 262.1-1.fc45 |
| glibc | 2.44-1.fc45 | 2.44-2.fc45 |
| cockpit | 368-1.fc45 | 372-1.fc45 |

还有 `metalink` 的隐藏变量：落到哪台 mirror、那台是否已同步，也会影响结果。

### 决策

**默认不锁，构建时吃最新；需要复现时用锁文件。**

```bash
./scripts/build.sh --lock-out            # 构建，并把实际装到的版本导出成 out/*.lock
./scripts/build.sh --lock path/to.lock   # 按锁文件复现
```

### 为什么是这个方向

**不默认锁定**：NAS 长期在线，镜像带当时最新的安全补丁有实际价值。默认锁死会让
用户拿到一个出生即过期的系统。

**但必须能复现**：出问题时要知道「是代码改坏了，还是上游包更新了」，就得能装回
同一批版本。

**不自己维护版本号**：锁文件是 `--lock-out` 从一次成功构建里**生成**的，不是人手写
的。用的时候也不用改 `reinas.kiwi`。

### 实现要点

**1. 锁文件格式**

沿用 kiwi 自己导出的 `.packages` 的同构格式（`NAME|EPOCH|VERSION|RELEASE|ARCH|
DISTURL|LICENSE`），裁成三列：

```
# ReiNAS 版本锁文件
samba|4.25.1|1.fc45|x86_64
kernel-core|7.3.4|300.fc45|x86_64
```

只含 `<packages type="image">` 里**显式列出的 86 个包**，不含依赖闭包。理由：显式包
版本一钉，dnf 会把依赖解析到能满足它们的版本上；锁全量的话锁文件会变成几百行，且
与每年 Fedora 升级严重耦合。

**2. 不改 `reinas.kiwi` 本体**

`--lock` 时派生一个 `kiwi/reinas.locked.kiwi`，把每个 `<package name="x"/>` 换成
`<package name="x-版本-发布.arch"/>`。原文件保持「跟最新」的真相，派生文件用完即弃
（已在 `.gitignore`）。

**3. dnf5 支持 NEVRA，不需要 versionlock 插件**

kiwi 的 `<package name>` 是 `xsd:text`，原样传给包管理器。dnf5 官方文档明确支持
`dnf5 install tito-0.6.21-1.fc36` 这种精确版本语法，且会主动升降到该版本。

**Fedora 45 没有 dnf5 版 versionlock**（只有 dnf4 的
`python3-dnf-plugin-versionlock`），所以不能走 versionlock 那条路。

**4. 必须显式 `--kiwi-file`**

kiwi 找描述文件时对 `*.kiwi` 做 glob 然后 `sorted()` 取**第一个**：

```python
glob_match = description_directory + '/*.kiwi'
for kiwi_file in sorted(glob.iglob(glob_match)):
    config_file = kiwi_file
    break
```

`sorted()` 下 `reinas.locked.kiwi` 排在 `reinas.kiwi` **前面**，不指定就会静默用错
文件。所以锁定构建必须传 `--kiwi-file reinas.locked.kiwi`（boxbuild 会透传这个全局
选项）。

**5. 锁文件不入库、CI 不提交代码**

这一点是关键约束：构建跑在 GitHub Actions 上，如果 CI 把锁文件提交回仓库，就会
和「push 触发构建」形成循环，而且 CI 拿着写权限改代码本身是坏设计。

所以锁文件只作为**构建产物**跟着镜像一起分发。拿到的 `.lock` 由使用者手动
`--lock` 指过去。

### 已知限制

- **只锁显式包**。依赖闭包不锁，所以严格来说不是逐字节复现。若某个依赖在两次
  构建之间发布了新版本且仍满足约束，装到的依赖版本会不同。要彻底复现得锁全量。
- **锁文件里的版本必须还在仓库里**。Fedora 的 `updates` 会清理旧版本包，几个月后
  拿老锁文件可能装不上。这时的表现是 dnf 报「找不到该版本」，而不是静默装新版。
- **`reinas-release` 不在锁文件里**（它是自建包，版本由 spec 控制）。

---

**从 D-009 起的决策在 [decisions-panel.md](decisions-panel.md)。** 这份文件已接近
提交钩子的 20 KB 上限，后续决策往新文件写。
