# ReiNAS OS

基于 Fedora 45 的 NAS 发行版，用 kiwi 构建。产出两个制品：`.raw`（dd 到磁盘）和
`.install.iso`（装机盘）。

仓库：https://github.com/ReiNAS-OS/os　　默认分支 `main`

## 快速上手

```bash
sudo ./scripts/build.sh                   # 完整构建（生产形态，无已知口令）
sudo ./scripts/build.sh --root-password   # 开发构建：root / 123456
sudo ./scripts/build.sh --rpm-only        # 只编译 reinas-release
python3 scripts/check-xml.py --online kiwi/reinas.kiwi   # 描述文件校验
```

构建需要完整 Linux 宿主（KVM + loop + udev）。**macOS 和 Docker 容器都不行**，
原因见 `docs/decisions.md` D-006。CI 用 GitHub Actions 的 `ubuntu-latest`。

**root 密码默认关闭**（D-007）。不开开关构建出来的镜像没有任何口令、SSH 只认
公钥、镜像里也没预置公钥 —— 装完进不去。开发阶段必须加 `--root-password`。
开关打开产出的镜像不要对外发布。

**版本默认跟最新**（D-008）。每次构建吃仓库最新包，不可复现。CI 会导出
`out/*.lock` 分发，复现用 `--lock <file>`。锁文件不入库、CI 不提交代码。

## 目录

```
kiwi/reinas.kiwi      镜像描述，唯一入口。改包、改分区、改引导都在这里
kiwi/config.sh        镜像内 chroot 配置：身份、账号、服务、防火墙、SELinux
packages/             自建 RPM（reinas-release 替代 fedora-release）
scripts/build.sh      构建入口（--root-password / --lock 开关在这里）
scripts/check-xml.py  描述文件静态检查
scripts/smoke.sh      镜像内冒烟测试
docs/decisions.md     技术决策记录，改架构前先读
docs/kiwi-pitfalls.md kiwi 构建的坑：描述文件错误、执行顺序、环境陷阱
docs/image-size.md    镜像体积构成与压缩参数的实测结论
docs/testing.md       QEMU 验证流程
```

## 提交前先跑

```bash
python3 scripts/check-xml.py --online kiwi/reinas.kiwi
```

`static-check.yml` 跑的就是这一套，别等 CI 才发现。

## 这个项目特有的坑

完整清单在 `docs/kiwi-pitfalls.md`。最容易踩的四条：

1. **kiwi 描述文件的错误要跑到很晚才暴露。** 注释里的连续减号、`<locale>` 带
   `.UTF-8` 后缀、`<packages>` 上写 `arch`、包名拼错——都用 `check-xml.py`
   提前拦住。
2. **`<packages type="delete">` 在 `config.sh` 之后执行。** config.sh 里 touch
   的文件，同名项写进 delete 段就会被随后抹掉。
3. **包必须按 `bootstrap` / `image` / `iso` 分三段写。** `type="iso"` 段最容易
   整段忘掉，缺了它 ISO 的 UEFI 引导是空的。
4. **内核和 grub 必须用 Fedora 已签名原件。** `shim-x64` / `grub2-efi-x64` /
   `kernel` 一旦替换成自编译版本，Secure Boot 链就断。详见 D-003。

## CI 命名约定

workflow 文件名保持英文（`image-build.yml` / `static-check.yml`），显示名、作业名、
每个 step 的 `name` 用中文。artifact 名保持英文，它们是机器读的。

## 提交规则

- 提交被钩子拒了，照报错把文件拆小再提交，不要绕过。上限 20 KB（约 5000 token）。
- 写新函数、新规则前，先搜项目里有没有现成的。
- 改架构、换工具链之前先读 `docs/decisions.md`，那里记录了哪些方案已经被否掉
  以及为什么——避免重复走弯路。
