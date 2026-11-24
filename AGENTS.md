# ReiNAS OS

基于 Fedora 45 的 NAS 发行版，用 kiwi 构建。产出两个制品：`.raw`（dd 到磁盘）和
`.install.iso`（装机盘）。

仓库：https://github.com/ReiNAS-OS/os　　默认分支 `main`

## 快速上手

```bash
sudo ./scripts/build.sh              # 完整构建（生产形态，无已知口令）
sudo ./scripts/build.sh --debug-password  # 调试构建：reinas / 123456
sudo ./scripts/build.sh --rpm-only   # 只编译 reinas-release
./scripts/build.sh --list-boxes      # 看可用构建箱
python3 scripts/check-xml.py --online kiwi/reinas.kiwi   # 描述文件校验
```

构建需要完整 Linux 宿主（KVM + loop + udev）。**macOS 和 Docker 容器都不行**，
原因见 `docs/decisions.md` D-006。CI 用 GitHub Actions 的 `ubuntu-latest`。

**调试账号默认关闭**（D-007）。不开开关构建出来的镜像没有任何口令、SSH 只认
公钥、镜像里也没预置公钥 —— 装完进不去。验证阶段必须加 `--debug-password`。
开关打开产出的镜像不要对外发布。

## 目录

```
kiwi/reinas.kiwi    镜像描述，唯一入口。改包、改分区、改引导都在这里
kiwi/config.sh      镜像内 chroot 配置：身份、账号、服务、防火墙、SELinux
packages/           自建 RPM（reinas-release 替代 fedora-release）
scripts/build.sh    构建入口（--debug-password 开关在这里）
scripts/check-xml.py 描述文件静态检查
docs/decisions.md   技术决策记录，改架构前先读
docs/testing.md     QEMU 验证流程
```

## CI 命名约定

workflow **文件名保持英文**（`build-image.yml` / `validate.yml`），
**显示名和每个 step 的 name 用中文**：

```yaml
name: 构建镜像
jobs:
  build:
    name: 构建 ReiNAS 镜像
    steps:
      - name: 检出代码
      - name: 检查宿主环境
```

新加 workflow 或 step 时照这个来。artifact 名（`reinas-raw` 之类）保持英文，
它们是机器读的。

## 这个项目特有的坑

### kiwi 描述文件有四类错误，构建要跑到很晚才暴露

`scripts/check-xml.py` 会查前四类，提交前跑一次，别等 CI：

1. **XML 注释里不能有连续减号** — `--disable-plugin` 这类参数写进注释就炸。
   踩过四次。
2. **`<locale>` 不能带 `.UTF-8` 后缀** — 只认 `en_US`，写 `en_US.UTF-8` 报
   `RELAXNG_ERR_INTEREXTRA: Extra element locale`。
3. **`<packages>` 上不能有 `arch` 属性** — 只能写 `type` / `patternType` / `profiles`。
   `arch` 要写具体的 `<package>` 上。报
   `RELAXNG_ERR_INVALIDATTR: Invalid attribute arch for element packages`。
4. **包名必须真实存在** — 用 `--online` 校验。漏包和拼错以前要等构建跑到最末尾
   才暴露，白等十几分钟。

### 包必须按 `type` 分三段写，漏一段就缺东西

```xml
<packages type="bootstrap">  <!-- 最小引导集，只放 filesystem -->
<packages type="image">      <!-- 装进磁盘镜像 -->
<packages type="iso">        <!-- 只装进 .install.iso 的构建环境 -->
```

`type="iso"` 段容易被整段忘掉。`grub2-efi-*-cdboot` 就在里面，缺了 ISO 的 UEFI
引导是空的。对照 Fedora 官方 `components/boot.xml` 逐项比对。

### 本地 rpm 仓库必须放在 `kiwi/rpms/`

boxbuild 只共享 description 和 target-dir 两个目录，仓库放别处构建箱看不到。
描述文件里用 `this://./rpms` 引用，且必须 `createrepo_c` 生成元数据——只有 rpm
文件会报 `Failed to download metadata`。

### 内核和 grub 必须用 Fedora 已签名的原件

`shim-x64` / `grub2-efi-x64` / `kernel` 一旦替换成自编译版本，Secure Boot 链就断。
详见 D-003。

### 构建系统的环境陷阱

- `config.sh` 在 chroot 里跑，`systemctl enable` 可能非零退出，而 kiwi 用 `set -e`
  跑它，一条失败就整体中止。**每条都要 `|| true`。**
- `grub2-editenv` 在容器 overlay 上会失败（拿不到真实块设备）。直接写 1024 字节
  的 grubenv 块。
- `dracut` 的 `No '/dev/log' or 'logger'` 是 **warning 不是错误**，退出码 0。
  曾被这条误导过两轮。

### RPM spec 注释里不能出现百分号

RPM 会把注释里的 `%` 当宏展开，报 `Macro XXX has empty body`。踩过两次。

## 提交规则

- 提交被钩子拒了，照报错把文件拆小再提交，不要绕过。
- 写新函数、新规则前，先搜项目里有没有现成的。
- 改架构、换工具链之前先读 `docs/decisions.md`，那里记录了哪些方案已经被否掉
  以及为什么——避免重复走弯路。
