# ReiNAS OS

基于 **Fedora 45** 的 NAS 发行版，用 **kiwi-ng** 构建。

一次构建产出两个制品：

| 制品 | 用途 | 怎么用 |
|---|---|---|
| `*.raw` | **dd 到磁盘**，首启自动撑满整盘 | `dd if=ReiNAS.raw of=/dev/sdX bs=4M status=progress conv=fsync` |
| `*.install.iso` | **装机盘**，把 raw 部署到目标盘 | dd 到 U 盘，UEFI 启动，交互选择目标盘 |

---

## 快速开始

构建走 kiwi 官方的 **boxbuild** 路径：在一个自带完整 `/dev` 和 udev 的虚拟机里构建。

```bash
sudo ./scripts/build.sh                # 完整构建
sudo ./scripts/build.sh --deps         # 只装依赖
sudo ./scripts/build.sh --rpm-only     # 只编译 reinas-release
./scripts/build.sh --list-boxes        # 查看可用构建箱
```

产物在 `out/`。

### 环境要求

真 Fedora 主机或 GitHub Actions runner 可以构建；macOS 和 Docker 容器不行。
原因见 [docs/decisions.md](docs/decisions.md) D-006。

---

## 为什么是 Fedora + kiwi

**Fedora 自己就用 kiwi 造镜像**（[官方说明](https://fedoraproject.org/wiki/Building_a_Fedora)：*kiwi, used for most variants of Fedora*）。所以这不是绕路，是走上游同一条路：

- Cloud 镜像（AWS/Azure/GCP/generic）、Vagrant、容器、WSL、绝大多数桌面 spin 的 live ISO 全是 kiwi 出的
- 官方描述文件在 [forge.fedoraproject.org/releng/kiwi-descriptions](https://forge.fedoraproject.org/releng/kiwi-descriptions)，按版本分支（`f43`/`f44`/`f45`/`rawhide`）
- Fedora 45 仓库里 `kiwi-cli` = **11.1.1-2.fc45**，全套 `kiwi-systemdeps-*` 齐全

**为什么用 `oem` 类型**：kiwi 的 image 类型里只有 `oem` 支持 `installiso="true"`，且自带首启扩盘（`dracut-kiwi-oem-repart`）。一份 raw 能 dd 到 128G SSD 也能 dd 到 8T HDD，首启自动撑满——这是 NAS 场景的刚需。

**注意 `oem` 的两种形态区别**：

| 配置 | 产物 | 是否扩盘 |
|---|---|---|
| `oem-resize=true` + `installiso` | `.raw` + `.install.iso` | ✅ 首启撑满 |
| `oem-resize=false` | 仅 `.raw`（云镜像形态） | ❌ 固定大小 |

我们用的是第一种。

---

## 目录结构

```
os/
├── kiwi/
│   ├── reinas.kiwi        # 镜像描述（唯一入口）
│   ├── config.sh          # 镜像内 chroot 配置脚本
│   └── root/              # overlay 树，按路径覆盖进镜像
├── packages/
│   └── reinas-release/    # 系统身份包（替代 fedora-release）
│       ├── reinas-release.spec
│       ├── files/         # os-release / issue / releasever
│       └── base/          # 从 Fedora 原样复制的 dist 宏与 preset
├── scripts/
│   └── build.sh           # 构建入口
├── rpms/                  # 编译产物 + createrepo 元数据（git 忽略）
└── out/                   # 镜像产物（git 忽略）
```

---

## 分层原则

这是架构上最重要的一条，直接决定后续维护成本：

```
┌─ 不能动（改了破签名 / 破兼容）──────────────────────┐
│  内核、shim、grub2      ← 全部用 Fedora 已签名原件   │
│  macros.dist、preset    ← 原样复制，一个字不改        │
└────────────────────────────────────────────────────┘
┌─ 可以改（只影响外观）─────────────────────────────┐
│  os-release、issue、CPE、默认主机名                 │
└────────────────────────────────────────────────────┘
┌─ 主动加（NAS 的能力）────────────────────────────┐
│  cockpit、samba、nfs、podman、btrfs、smartmontools  │
└────────────────────────────────────────────────────┘
```

**内核一改，Secure Boot 链就断。** `shim-x64` 里嵌的是 Fedora 的证书，它只认 Fedora 签名的 grub 和 kernel。想用自编译内核，就得走 MOK 手动导入或 Microsoft shim-review（志愿者评审 2–3 个月 + EV 证书 + HSM），不在当前规划内。

---

## SELinux

**保持 enforcing**。`config.sh` 里有 `touch /.autorelabel` 兜底，首启会自动重标签。

`sudo setenforce 0` 是所有自制发行版最经典的自杀方式：关掉之后没人再去修 policy，最后整台机器只能靠 permissive 跑着。真遇到阻拦，用 `ausearch -m avc -ts recent` 定位，写 policy 模块，不要关。

---

## 升级到下一个 Fedora

每年一次，改四处：

1. `kiwi/reinas.kiwi` → `<release-version>46</release-version>`
2. `packages/reinas-release/reinas-release.spec` → `%global fedora_release 46`
3. `packages/reinas-release/files/os-release` → `VERSION_ID` / `PLATFORM_ID` / `CPE_NAME`
4. `packages/reinas-release/files/releasever` → `46`

然后 `./scripts/build.sh --clean`。

**不能直接 `dnf system-upgrade`**：因为你的 release 包叫 `reinas-release`，它 `Obsoletes: fedora-release`，Fedora 的升级路径不认这个。跨版本升级需要自己写迁移脚本（`dnf distro-sync` + 换 release 包），这在 0.3 之前不做。

---

## 构建成本

| 项 | 数值 |
|---|---|
| 磁盘 | 15 GB |
| 内存 | 8 GB（boxbuild 默认） |
| CPU | 4 核 |
| 时间 | 约 19 分钟（CI 实测） |
| 费用 | 0 |

产物（CI 实测，构建 15 分钟）：

| 文件 | 大小 | 用途 |
|---|---|---|
| `.raw.xz` | 626 MB | 解压后 dd 到磁盘 |
| `.install.iso` | 863 MB | 装机盘 |

---

## 相关文档

- [docs/decisions.md](docs/decisions.md) — 为什么选 Fedora 而非 Leap/Arch，以及被否掉的方案
- [docs/testing.md](docs/testing.md) — 怎么在 QEMU 里验证产物
