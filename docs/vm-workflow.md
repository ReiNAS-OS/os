# QEMU 操作手册

`scripts/vm.sh` 的日常用法、以及验证登录界面时的取证手段。

这份文档只管「怎么操作虚机」。镜像本身该验什么、验到什么程度，见
[testing.md](testing.md)；kiwi 构建期的问题见 [kiwi-pitfalls.md](kiwi-pitfalls.md)。

---

## 三个启动模式，别选错

| | `vm.sh boot`（`-nographic`） | `vm.sh gui`（cocoa 窗口） | `vm.sh dev`（开发） |
|---|---|---|---|
| 看得到 | 只有串口文字 | 真实 VGA 画面 | 只有串口文字 |
| 字标颜色/渐变 | ❌ 日志里是转义字节 | ✅ | ❌ |
| 字体、块字符是否画得出来 | ❌ | ✅ | ❌ |
| 脚本化抓屏 | 不行 | ✅ monitor socket | 不行 |
| 串口可写（能敲命令） | ✅ | ❌ 单向 | ✅ socket |
| 源码同步 | ❌ | ❌ | ✅ rsync 到本地盘 |
| 适合 | 看内核日志、跑命令 | **验证登录界面长相** | **改代码看效果** |

登录字标、16 色渐变、块字符这些只有 VGA 上才看得出对错 —— 串口日志里它们是
`M-^VM-^R` 这样的转义字节，肉眼没法判断。**改登录界面后必须用 `gui` 验收。**

`gui` 会额外做三件事：

- 挂 QEMU monitor 到 `.vm/<arch>/logs/monitor.sock`（抓屏、模拟按键）
- 串口并行写 `.vm/<arch>/logs/serial.log`（回看整段启动过程比截图快）
- 加 `virtio-gpu-pci` + USB 键盘鼠标（不加 `usb-kbd` 时窗口里收不到按键）

⚠️ **`gui` 的串口不能输入。** 它用的是 `-serial file:`，单向；monitor 的
`sendkey` 注入的是 USB 键盘，只作用于 VGA 的 tty，对着串口登录提示发没有任何
反应。要脚本化敲命令用 `dev`，或者参考 `vm-install.sh` 的 chardev socket 写法。

---

## 开发模式：改代码立刻在虚机里看到

```bash
./scripts/vm.sh dev      # 终端 A：起虚机，转发 5090（面板）和 5099（SSH）
./scripts/vm.sh key      # 一次性：把宿主公钥装进虚机
./scripts/vm.sh sync     # 终端 B：fswatch 监听源码，rsync 进虚机本地盘
```

虚机里第一次要装 bun（**镜像本身不带，这是开发环境不是产物形态**）：

```bash
dnf install -y unzip
curl -fsSL https://bun.sh/install | bash

cd /root/reinas && bun install
cd /root/reinas/apps/cli && bun --watch src/main.ts serve --dev
```

宿主打开 `http://127.0.0.1:5090` 就是虚机里的页面。改宿主 `.tsx` → fswatch
触发 rsync → 重启虚机里的 dev server（`systemd-run` 托管）→ 刷新浏览器即见
新内容。改一次约 3-6 秒。

往串口敲命令（脚本化，不依赖 SSH）：

```bash
printf '%s\r' '此处填命令' | nc -U -w 3 .vm/aarch64/logs/console.sock
```

### 为什么用 rsync 而不是共享文件夹

**共享文件系统不投递 inotify 事件**，dev server 的 watch 在挂载目录上不触发，
热更新等于没有。实测和查证过的：

| 方案 | inotify |
|---|---|
| QEMU 9p | ❌ mtime 能传播，但 `inotifywait` 一条事件都收不到 |
| VirtualBox vboxsf | ❌ 官方 ticket #10660 标记 wontfix |
| NFS / SMB | ❌ 协议层不传 |
| **虚机本地盘**（ext4/btrfs） | ✅ 正常 |

macOS + QEMU 的组合用不了 virtiofs（QEMU 没编 `vhost-user-fs`，macOS 也没
`virtiofsd`），9p 是唯一选项，而它不行。所以源码得真正搬进虚机的本地盘。

`vm.sh sync` 做的事：`fswatch -o -l 0.3` 监听宿主目录，攒 300ms 合批后跑一次
`rsync -rlz --delete`，推到 `/root/reinas`，然后用 `systemctl restart
reinas-dev.service` 让服务重新编译。

**为什么要重启而不是靠 `--watch`**：实测 `bun --watch` 在这个环境里不可靠
——某次改动它编译了，之后再改就再也不触发，日志停在最后一条
`Bundled page in Nms` 不动。源文件、mtime、进程都确认更新了，bundle hash
也变了，但产物内容始终是旧的。查不到缓存失效条件，所以改用「同步即重启」
这个笨但确定的办法。

**为什么 rsync 用 `-rlz` 而不是 `-a`**：`-a` 隐含 `-t`（保留 mtime），会把
宿主的 mtime 原样复制到虚机，Bun 据此认为文件没变。`-rlz` 不保留时间戳，
文件落地时拿到"现在"的 mtime。

### 三个坑

**1. 必须用 Homebrew 的 rsync**

macOS 自带的 `/usr/bin/rsync` 是 openrsync（协议 2.6.9），不认
`--chmod=D755,F644` 和 `--no-owner`。会把宿主的 UID 501 和 600 权限原样带到
虚机，虚机里以 root 跑的 `bun --watch` 在这种属主下**不会触发重编译**。

`brew install rsync` 后脚本会自动挑 `/opt/homebrew/bin/rsync`（3.x）。

**2. 不要用 `bun run dev` / `turbo run dev`**

turbo 会把任务放进自己的进程组，`bun --watch` 的文件监听在那一层之下不生效
——实测改了 `.tsx`，bundle 不重新编译（日志里始终只有第一条
`Bundled page in Nms`，没有新的）。直接 `bun --watch src/main.ts serve --dev`
才正常。

**3. sshd drop-in 的命名**

`05-reinas-root.conf` 不能叫 `20-reinas-root.conf`。sshd 对同一个选项**取
第一次读到的值**，`10-reinas.conf` 里的 `PasswordAuthentication no` 排在前面
就盖住了。没有 SSH 就没有 rsync，dev 模式直接废掉。

### 为什么 dev 要单独一个子命令

「构建 → 交叉编译 105 MB → 传输 → 运行」是**验证交付物**的路子，改一行前端
就要走一遍几十秒的流程。开发要的是改完立刻看到。

而且面板的大量功能要调 Linux 命令（`lsblk`、`btrfs`、`useradd`、`/proc`），
macOS 上这些根本不存在——只能在真 Linux 里开发。

### 装 bun 用 dnf

镜像里已装 `fedora-repos` + `fedora-gpg-keys`，`dnf` 可以直接用：

```bash
dnf install -y unzip
curl -fsSL https://bun.sh/install | bash
```

bun 官方安装脚本要 `unzip`，镜像默认没有，得先装。

> 历史坑：这两个包曾经都不在镜像里 —— `reinas-release` 只 Obsolete 了
> `fedora-release-*`，没人接管 `fedora-repos`，导致装好的系统
> `dnf install` 报 `No matches found: no repositories are enabled`。
> 已在 `kiwi/reinas.kiwi` 里显式加上这两个包。**只加 `fedora-repos` 不够**，
> 少了 `fedora-gpg-keys` 会下载成功但验签失败。

---

## 怎么截图、怎么模拟按键

`gui` 会把 QEMU monitor 挂在 `.vm/<arch>/logs/monitor.sock`，串口并行写
`.vm/<arch>/logs/serial.log`（回看整段启动过程比截图快）。

`qemu` 的 monitor 是纯文本协议，用 `socat` 或 python 连上去发命令：

```bash
# 截图（输出 PPM，用 sips/magick 转 PNG）
printf 'screendump /tmp/s.ppm\n' | socat - UNIX-CONNECT:.vm/aarch64/logs/monitor.sock
sips -s format png /tmp/s.ppm --out /tmp/s.png

# 模拟按键（往虚机里打字）
printf 'sendkey r\nsendkey o\nsendkey o\nsendkey t\nsendkey ret\n' \
  | socat - UNIX-CONNECT:.vm/aarch64/logs/monitor.sock
```

没有 `socat` 时用 python，多行时更稳（每次 `sendkey` 之间留间隔，太快会丢键）：

```python
import socket, time
s = socket.socket(socket.AF_UNIX)
s.connect('.vm/aarch64/logs/monitor.sock'); time.sleep(0.3)
s.recv(65536)                       # 吃掉登录横幅
for ch in 'root':
    s.sendall(f'sendkey {ch}\n'.encode()); time.sleep(0.2)
s.sendall(b'sendkey ret\n'); time.sleep(2)
for ch in '123456':
    s.sendall(f'sendkey {ch}\n'.encode()); time.sleep(0.2)
s.sendall(b'sendkey ret\n'); time.sleep(4)
s.close()
```

**几个实测坑：**

- `sendkey` 注入的是 USB/PS2 键盘，走的是**当前活动的 tty**。装了 `usb-kbd`
  设备才收得到（`vm.sh gui` 已带）。
- 切 tty：`sendkey ctrl-alt-f1`。验证时容易切到别的 tty 然后对着一片黑截图。
- 每次 `restart getty@ttyN` 会清掉当前终端，之后的截图是黑的 —— 这不是 bug。
- 传带空格或符号的命令容易断行。要送文件进虚机，用 `vm.sh serve` + `curl`，
  别硬用 `sendkey` 一个字符一个字符敲。


镜像里没装 controller 时也能跑 `scripts/smoke.sh` 之外的检查（身份、SELinux、
分区、子卷）。要把 `smoke.sh` 或自己的二进制送进虚机，另开一个终端：

```bash
./scripts/vm.sh serve scripts/smoke.sh

# 虚机里
curl -O http://10.0.2.2:8000/smoke.sh
bash smoke.sh
```

装机（`install`）也走同一条链路，全自动，约 10 分钟：

```bash
./scripts/vm.sh install      # 40G 空盘 + install.iso → 装好的盘
BASE_IMAGE=$PWD/.vm/aarch64/install-target.raw ./scripts/vm.sh boot
```

`boot` 会给目标盘建 overlay，原盘只读，装一次可以反复起。

`10.0.2.2` 是 QEMU user 网络的网关，固定值，不用配。

**为什么不开 SSH**：镜像默认 `PasswordAuthentication no`（D-007），验证阶段的
目标就是按真机的方式用 —— 插串口等于插显示器。开 SSH 端口会把一个生产镜像里
不存在的入口带进测试环境。

---

## 手动触发构建 + 替换本地镜像

`image-build.yml` **只支持手动触发**，不挂 push（构建要跑 8-10 分钟且吃满
runner，push 触发等于每次改文档都白跑）。所以改了 `config.sh` 或 `kiwi/root/`
之后，要自己触发、等构建、再拉下来。

```bash
# 1. 确认要构建的提交已经推上去了
git push origin main
gh api "repos/ReiNAS-OS/os/actions/runs?per_page=1" --jq '.[0].head_sha'   # 应等于本地 HEAD

# 2. 触发（aarch64 有原生 runner，比 x86_64 快得多）
gh workflow run "image-build.yml" -R ReiNAS-OS/os --ref main \
  -f arch=aarch64 -f profile=Disk -f root_password=123456

# 3. 等（约 8-10 分钟）
gh run watch <RUN_ID> -R ReiNAS-OS/os --interval 30 --exit-status

# 4. 确认产物对应的就是你要的提交 —— 这一步别省
gh api "repos/ReiNAS-OS/os/actions/runs/<RUN_ID>" --jq '.head_sha'
```

拉产物时 **`gh run download` 对大文件会失败**（报 "not a valid zip file"），
走 artifact API + `curl -C -` 续传：

```bash
AID=$(gh api "repos/ReiNAS-OS/os/actions/runs/<RUN_ID>/artifacts" \
  --jq '.artifacts[] | select(.name=="ReiNAS.aarch64-0.1.0.raw.xz") | .id')

curl -sSL -C - --retry 5 --retry-all-errors \
  -H "Authorization: token $(gh auth token)" \
  -H "Accept: application/vnd.github+json" \
  "https://api.github.com/repos/ReiNAS-OS/os/actions/artifacts/$AID/zip" \
  -o /tmp/raw.bin
```

**下载下来的不是 zip，是裸 `.raw.xz`。** GitHub 对单个文件的 artifact 直接
返回文件内容。`file /tmp/raw.bin` 确认是 "XZ compressed data" 就对了，别去
`unzip`。网络断了重跑同一条命令即可续传。

替换本地镜像：

```bash
pkill -f qemu-system-aarch64                    # 必须先停 VM，否则文件被占用
xz -t /tmp/raw.bin                              # 校验
rm -f .vm/aarch64/*.raw .vm/aarch64/*.raw.xz .vm/aarch64/disk.qcow2
mv /tmp/raw.bin .vm/aarch64/ReiNAS.aarch64-0.1.0.raw.xz
xz -dk -T0 .vm/aarch64/ReiNAS.aarch64-0.1.0.raw.xz
./scripts/vm.sh gui                             # 自己建 overlay 和固件变量
```

`disk.qcow2` 必须删掉：它是盖在旧 raw 上的 overlay，留着会继续跑旧系统
（`prepare` 里虽然会比对 backing，但直接删更省事）。
