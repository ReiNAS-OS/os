# ReiNAS OS

基于 **Fedora 45** 的 NAS 发行版，用 **kiwi-ng** 构建。

一次构建产出两个制品：

| 制品 | 用途 | 怎么用 |
|---|---|---|
| `*.raw` | **dd 到磁盘**，首启自动撑满整盘 | `xz -d *.raw.xz && dd if=*.raw of=/dev/sdX bs=4M status=progress conv=fsync` |
| `*.install.iso` | **装机盘**，把 raw 部署到目标盘 | dd 到 U 盘，UEFI 启动，交互选择目标盘 |

---

## 快速开始

构建在 **Fedora chroot** 里跑 `kiwi-ng system build`，不套虚拟机。宿主（CI 是
Ubuntu runner，本地是 Fedora）只要有 udev 在跑、`/dev/loopN` 齐全就行。
细节见 `docs/decisions.md` D-006。

```bash
sudo ./scripts/build.sh                # 完整构建（生产形态：无任何已知口令）
sudo ./scripts/build.sh --deps         # 只装依赖
sudo ./scripts/build.sh --rpm-only     # 只编译 reinas-release
./scripts/build.sh --list-boxes        # 查看可用构建箱

sudo ./scripts/build.sh --root-password    # 开发构建：root / 123456
```

产物在 `out/`。

### 拉 CI 产物直接起测

不想在本机构建（macOS 建不了，见 D-006），拉 CI 的镜像用 QEMU 跑：

```bash
./scripts/vm.sh list      # 看最近的构建
./scripts/vm.sh pull      # 拉最新一次成功构建到 .vm/<arch>/
./scripts/vm.sh boot      # 起虚机，串口控制台
```

控制台提示 `reinas login:` 输 `root` / `123456`（CI 构建时开了 root 密码）。
Apple Silicon 默认拉 aarch64 —— `qemu-system-x86_64` 在这台机器上只有 tcg，
启动要 5-15 分钟；aarch64 有 hvf，20 秒。

往虚机里送文件用 `./scripts/vm.sh serve <file>`，虚机里 `curl 10.0.2.2:8000/<file>`。
不开 SSH：镜像默认禁密码登录，验证阶段按真机方式走串口。

装机盘也能全自动跑（约 10 分钟），装好的盘可以反复起：

```bash
./scripts/vm.sh install     # install.iso → .vm/<arch>/install-target.raw（40G）
BASE_IMAGE=$PWD/.vm/aarch64/install-target.raw ./scripts/vm.sh boot
```

### root 密码（默认关闭）

默认构建出来的镜像**没有任何口令，SSH 只认公钥，而镜像里也没有公钥** ——
装完进不去。要在开发阶段登录，必须显式打开开关：

```bash
sudo ./scripts/build.sh --root-password        # root / 123456
sudo ./scripts/build.sh --root-password=自定义  # 换一个密码
```

开关打开时：`root` 设了密码、SSH 放开 root 密码登录（`PermitRootLogin yes` +
`PasswordAuthentication yes`），镜像里会留下
`/etc/reinas/BUILD-HAS-ROOT-PASSWORD` 标记。`reinas` 应急账号始终锁定。

**这种镜像不要对外发布。** CI 的 `构建镜像` workflow 有对应的 `root_password`
输入，留空即关闭。

为什么不默认给密码 —— 以及「关闭态其实进不去」这个待解的缺口，见
[docs/decisions.md](docs/decisions.md) D-007。

### 版本锁定（默认跟最新）

默认每次构建都**吃仓库最新版本** —— 同一份代码不同时间构建，装到的包不一样。

CI 每次构建会导出 `out/*.lock`（作为 `reinas-lock` artifact 分发，保留 90 天），
记录这次实际装到的版本。要复现某次构建：

```bash
# 从 CI 下载 reinas-lock，解压出 ReiNAS-Disk.lock
sudo ./scripts/build.sh --lock /path/to/ReiNAS-Disk.lock
```

锁文件**不入库**，只跟着镜像分发。原因和限制见
[docs/decisions.md](docs/decisions.md) D-008。只锁显式列出的 86 个包，依赖仍跟随
仓库解析 —— 不是逐字节复现。

### 环境要求

真 Fedora 主机或 GitHub Actions runner 可以构建；macOS 和 Docker 容器不行。
原因见 [docs/decisions.md](docs/decisions.md) D-006。

---

## 为什么是 Fedora + kiwi

**一句话**：Fedora 自己就用 kiwi 造镜像，走的是上游同一条路，不是绕路。
完整理由（仓库丰度对比、重品牌化政策、Secure Boot）和被否掉的 Leap / Arch /
AlmaLinux，见 [docs/decisions.md](docs/decisions.md) D-001 与 D-004。

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
│   └── config.sh          # 镜像内 chroot 配置脚本
├── packages/
│   └── reinas-release/    # 系统身份包（替代 fedora-release）
│       ├── reinas-release.spec
│       ├── files/         # os-release / issue / releasever
│       └── base/          # 从 Fedora 原样复制的 dist 宏与 preset
├── scripts/
│   ├── build.sh           # 构建入口
│   ├── check-xml.py       # 描述文件静态检查（含包名真实性）
│   ├── smoke.sh           # 镜像内冒烟测试
│   ├── vm.sh              # 拉 CI 产物 + QEMU 起测（实现在 lib/）
│   └── lib/               # vm.sh 的实现，按关心的事分文件
├── rpms/                  # 编译产物 + createrepo 元数据（git 忽略）
└── out/                   # 镜像产物（git 忽略）
```

---

## CI

三个 workflow，**文件名保持英文（动词在前），显示名和每个步骤名用中文**：

| 文件 | 显示名 | 触发 | 干什么 | 耗时 |
|---|---|---|---|---|
| `static-check.yml` | 校验 | push、PR、手动 | 静态检查，不产出镜像 | ~20 秒 |
| `image-build.yml` | 构建镜像 | push 到 `main`（`kiwi/` `packages/` `scripts/` 变动）、手动 | 出 `.raw.xz` + `.install.iso` + `.lock` | ~15 分钟 |
| `image-rebuild.yml` | 锁定重建 | 只有手动 | 拿历史 `.lock` 重建，验证版本一致 | ~15 分钟 |

构建步骤抽在 `.github/actions/build-image` 这个 composite action 里，
`image-build.yml` 和 `image-rebuild.yml` 共用同一份，改构建流程只需改一处。

### 校验查什么

kiwi 描述（注释里的连续减号、未转义的 `&`、`locale` 后缀、包名是否真在
Fedora 里）、`spec` 注释里有没有百分号、`reinas-update` 能不能编译、
shellcheck、bash 语法，以及两组守护：

- **调试账号是否默认关闭**（D-007）
- **版本锁定链路是否完整**（D-008）

本地提交前先跑一次，别等 CI：

```bash
python3 scripts/check-xml.py --online kiwi/reinas.kiwi
```

### 怎么用锁定重建

`image-build.yml` 每次都会产出 `reinas-lock` artifact（保留 90 天）。
要复现某次构建：

1. 打开那次「构建镜像」运行的页面，URL 末尾的数字就是 run id
2. Actions → 锁定重建 → Run workflow
3. `lock_run_id` 填那个数字，跑

它会按锁文件装回同一批版本，最后一步**逐包比对**锁文件与实际产物，
不一致就红。

也可以把锁文件内容粘进 `lock_content` 输入，适合从别处拿到的 `.lock`。

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
│  samba、nfs、btrfs、xfs、lvm、mdadm、smartmontools  │
└────────────────────────────────────────────────────┘
```

**内核一改，Secure Boot 链就断。** `shim-x64` 里嵌的是 Fedora 的证书，它只认 Fedora 签名的 grub 和 kernel。想用自编译内核，就得走 MOK 手动导入或 Microsoft shim-review（志愿者评审 2–3 个月 + EV 证书 + HSM），不在当前规划内。

---

## SELinux

**保持 enforcing**。`config.sh` 里有 `touch /.autorelabel` 兜底，首启会自动重标签。

`sudo setenforce 0` 是所有自制发行版最经典的自杀方式：关掉之后没人再去修 policy，最后整台机器只能靠 permissive 跑着。真遇到阻拦，用 `ausearch -m avc -ts recent` 定位，写 policy 模块，不要关。

---

## 升级到下一个 Fedora

每年一次，**改六处**：

| # | 文件 | 改什么 |
|---|---|---|
| 1 | `kiwi/reinas.kiwi` | `<release-version>46</release-version>` |
| 2 | `packages/reinas-release/reinas-release.spec` | `%global fedora_release 46` |
| 3 | `packages/reinas-release/files/os-release` | `VERSION_ID` / `PLATFORM_ID` / `CPE_NAME` |
| 4 | `packages/reinas-release/files/releasever` | `46` |
| 5 | `packages/reinas-release/files/system-release-cpe` | 末段 `:46` |
| 6 | `scripts/check-xml.py` | `FEDORA_RELEASE = "46"` |

然后 `./scripts/build.sh --clean`。

**漏了第 5、6 处的后果**：`system-release-cpe` 不跟着改，CPE 会指回旧版本；
`check-xml.py` 的常量不改，`--online` 会拿旧版本的仓库元数据校验包名，
新版本里新增的包会被误判为不存在。

**不能直接 `dnf system-upgrade`**：因为你的 release 包叫 `reinas-release`，它 `Obsoletes: fedora-release`，Fedora 的升级路径不认这个。跨版本升级需要自己写迁移脚本（`dnf distro-sync` + 换 release 包），这在 0.3 之前不做。

---

## 构建成本

| 项 | 数值 |
|---|---|
| 磁盘 | 15 GB |
| 内存 | 16 GB（runner 默认） |
| CPU | 4 核 |
| 时间 | 约 6-9 分钟（CI 实测，两个架构并行各 6-9 分钟） |
| 费用 | 0 |

产物（CI 实测）：

| 文件 | 大小 | 用途 |
|---|---|---|
| `.raw.xz` | 626 MB | 解压后 dd 到磁盘 |
| `.install.iso` | 863 MB | 装机盘 |

---

## 相关文档

- [docs/decisions.md](docs/decisions.md) — 为什么选 Fedora 而非 Leap/Arch，以及被否掉的方案
- [docs/testing.md](docs/testing.md) — 怎么在 QEMU 里验证产物
- [docs/decisions-panel.md](docs/decisions-panel.md) — 面板相关决策（从 D-009 起）
- [docs/image-size.md](docs/image-size.md) — 863 MB 是怎么来的，还能不能更小
- [docs/kiwi-pitfalls.md](docs/kiwi-pitfalls.md) — kiwi 构建的坑
