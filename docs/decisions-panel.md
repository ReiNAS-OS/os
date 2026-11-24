# 面板相关决策

这份文件接 `decisions.md`。D-001 到 D-008 在那边（基底、镜像类型、Secure Boot、
构建环境、账号、版本锁定），从 D-009 起拆到这里，因为 `decisions.md` 已经接近
提交钩子的 20 KB 上限。

---

## D-009：不装 Cockpit，面板自己写

**日期**：2026-11-24
**状态**：已决定

### 背景

镜像原本装了 Cockpit 全套（`cockpit` / `-storaged` / `-networkmanager` /
`-podman` / `-selinux` / `-packagekit` + `udisks2` + `podman`），
`cockpit.socket` 开机启用，防火墙开 9090，登录提示也指向它。

但 ReiNAS 的规划是**自己的 NAS 面板**（`panel/` 仓库），不做 Cockpit 的皮。

### 决策

**从镜像移除 Cockpit 全套和 podman，面板作为 systemd 服务直接跑在宿主上。**

移除的包和体积：

| 包 | 体积 | 理由 |
|---|---|---|
| `cockpit` + 5 个插件 | 3.9 MB | 被自有面板取代 |
| `udisks2` + `udisks2-btrfs` | 0.8 MB | 只是 `cockpit-storaged` 的后端 |
| `podman` | **16.5 MB** | 面板跑宿主，不需要容器运行时 |

同时移除非 NAS 的包（合计再省约 6.9 MB）：

| 包 | 理由 |
|---|---|
| `grub2-efi-ia32` + modules | 32 位 UEFI，现代 NAS 用不到 |
| `vim-enhanced` → `vim-minimal` | 保留 `vi` 应急（0.9 MB），砍掉语法高亮和插件 |
| `tmux` / `htop` | 开发工具，不是 NAS 功能 |
| `wget2-wget` | 有 `curl` 就够 |
| `systemd-oomd-defaults` | 桌面场景的 OOM 策略 |
| `langpacks-en` | `glibc-langpack-en` 已提供 |

**保留的（按「和 NAS 相关就不动」的规则）**：`xfsprogs`、`lvm2`、`mdadm`、
`kernel-modules-extra`、`samba`、`nfs-utils`、所有 `btrfs-progs` 相关、
所有 grub x64 相关。

显式包从 86 个降到 70 个。

### 为什么不留着当救援通道

考虑过保留 Cockpit 不启用、只在出问题时手动 start。否掉的理由：

1. **它每 6 个月跟着 Fedora 大版本变**，插件 API 会改，等于白养一个要跟进的依赖
2. **和自有面板功能完全重叠**（存储、网络、SELinux），两套界面同时操作同一批
   配置容易打架
3. 真出问题时 **SSH + 系统日志** 够用，不需要 Web 界面

### 代价（明确接受）

**面板做出来之前，镜像里没有任何 Web 管理界面。** 这段时间只能靠：

- SSH（`--root-password` 构建，或注入公钥）
- 物理控制台 / IPMI

登录提示里的 `Web panel: https://<ip>:5090` 是**占位**——5090 是规划端口，
服务还不存在，现在访问会连不上。

### 面板要做的事

面板就绪时需要同步两处：

1. `kiwi/config.sh` 的防火墙段加 `--add-port=5090/tcp`
2. 面板自己的 systemd unit 加进镜像（`<packages type="image">` 的 `<file>`
   或做成 RPM）

如果面板要用 `udisks2` 管盘（它提供标准 storaged D-Bus API），把它加回来。
