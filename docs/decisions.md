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
