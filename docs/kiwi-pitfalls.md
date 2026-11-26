# kiwi 构建的坑

从 `AGENTS.md` 挪过来的长尾细节。AGENTS.md 只留最容易踩的几条，其余在这里。

---

## 描述文件的四类静态错误

这四类都是「构建跑到很晚才炸」，`scripts/check-xml.py` 会提前拦住：

1. **XML 注释里不能有连续减号** — `--disable-plugin` 这类参数写进注释就炸。
   踩过四次。
2. **`<locale>` 不能带 `.UTF-8` 后缀** — 只认 `en_US`，写 `en_US.UTF-8` 报
   `RELAXNG_ERR_INTEREXTRA: Extra element locale`。
3. **`<packages>` 上不能有 `arch` 属性** — 只能写 `type` / `patternType` /
   `profiles`。`arch` 要写具体的 `<package>` 上。报
   `RELAXNG_ERR_INVALIDATTR: Invalid attribute arch for element packages`。
4. **包名必须真实存在** — 用 `--online` 校验。漏包和拼错以前要等构建跑到最末尾
   才暴露，白等十几分钟。

### 另外三类 `check-xml.py` 也查

5. **未转义的 `&`** — URL 里的查询串必须写成 `&amp;`。
6. **整体可解析性** — XML 本身不合法时直接报错退出，不再往下查。
7. **结构最小断言** — 根元素是 `<image>`、有 `name`、有 `<profile>`、
   带 `profiles`/`arch` 的 `<preferences>` 必须有 `<type>`。

`<packages type="image">` 没设 `patternType="onlyRequired"` 只打提示不报错。

---

## 包必须按 `type` 分三段写

```xml
<packages type="bootstrap">  <!-- 最小引导集，只放 filesystem -->
<packages type="image">      <!-- 装进磁盘镜像 -->
<packages type="iso">        <!-- 只装进 .install.iso 的构建环境 -->
```

`type="iso"` 段容易被整段忘掉。`grub2-efi-*-cdboot` 就在里面，缺了 ISO 的 UEFI
引导是空的。对照 Fedora 官方 `components/boot.xml` 逐项比对。

### bootstrap 只放 filesystem

曾经试过加 `glibc` / `bash` / `coreutils` / `rpm` / `setup`，全部失败。rpm 维护者
pmatilai 在 rpm#3691 的结论是这个早期集合极其脆弱，加包会破坏 rpm 本来能算出的
顺序。

但有一条例外要注意：RPM 的 `%pre` scriptlet 用 `/bin/sh` 执行，而 Fedora 的 `sh`
由 bash 提供。历史上缺 bash 会让 `crypto-policies` 这类带 `%pre` 的包以 exit 127
失败，而错误信息完全指不到真正原因（依赖环：crypto-policies → /bin/sh → bash →
glibc → ...）。当前配置走官方单包写法，这个问题由 rpm 的拓扑排序兜住。

---

## 本地 rpm 仓库必须在 `kiwi/rpms/`

kiwi 只把 `--description` 指向的目录当仓库源，rpm 放别处看不到。描述文件里用
`this://./rpms` 引用，且必须 `createrepo_c` 生成元数据——只有 rpm 文件会报：

```
Failed to download metadata (baseurl: "file:///description/rpms/")
```

不能用 `127.0.0.1:8888` 的 HTTP 服务，构建箱有独立网络命名空间。

---

## `root/` overlay 的实际行为

`kiwi/` 目录下的 `root/` 是 kiwi 的 overlay 树：包装完之后整个目录按路径覆盖进
镜像。曾经三个空目录（`etc/issue.d`、`etc/NetworkManager/dispatcher.d`、
`etc/systemd/system`）被删过，因为空目录不进 git、clone 下来不存在：

- `/etc/NetworkManager/dispatcher.d` ← `NetworkManager` 包提供
- `/etc/systemd/system` ← `systemd` 包提供
- `/etc/issue.d` ← 曾经靠 `config.sh` 里 `mkdir -p`

**现在 `kiwi/root/` 里只有一个文件**：`etc/issue.d/10-reinas.issue`。登录字标
带 200 多段 ANSI 码（2.9 KB），内联进 `config.sh` 会把它顶到提交钩子的 20 KB
上限；放进 overlay 后它是普通文本文件，改配色直接编辑、`git diff` 能看清改了
什么。`config.sh` 只校验它在、设权限，并把 `@REINAS_URL@` 换成当前 IP。

⚠️ 这个文件的 ANSI 颜色必须是**真实 ESC 字节**（0x1B），不是字面的 `\033`。
用 `cat -v` 看，出现 `^[[` 才是对的；写成字面 `\033` 会原样显示成乱码。

真要用 overlay 时新建即可，kiwi 会自动识别。注意 `kiwi/` 根下的 `*.kiwi` 会被
kiwi glob 排序取第一个当描述文件，所以**别把其它文件放进 `kiwi/` 根目录**，
要覆盖进镜像就放 `root/` 下。

---

## `<packages type="delete">` 在 config.sh **之后**执行

这是最容易搞反的顺序。仓库里观察到的实际顺序（CI 构建日志）：

```
08:04:14  Calling config.sh script
08:04:15  Processing SELinux file security contexts
08:04:17  Uninstalling system packages (chroot)
08:04:17  Creating system image
```

kiwi 的 schema 注释也写明：`delete` packages are uninstalled **after the
preparation phase is done**。

**后果**：`config.sh` 里 touch 出来的文件，如果同名项写进了 `<packages
type="delete">`，会被随后的删除阶段抹掉。当前描述文件里删的是
`/etc/machine-id` 和 `/var/lib/systemd/random-seed`，而 `config.sh` 第 22-23 行
正好 `rm -f` + `touch /etc/machine-id`。

**待验证**：`<packages type="delete">` 里放 `<file>` 是否真的会被执行（kiwi
的文档对 `type="delete"` 只描述了「卸载包」，`<file>` 的删除语义没有明确说明）。
镜像启动后用 `ls -l /etc/machine-id` 确认：文件存在且为空 → 删除没生效；
文件不存在 → 删除生效，config.sh 的 touch 被覆盖。见 `docs/testing.md`
第 6 节。

---

## `type="uninstall"` 会带走依赖它的包

`<packages type="uninstall">` 走的是包管理器卸载，**会连同依赖链一起清掉**。
所以「image 段装 A，uninstall 段卸 B」时，如果 A 依赖 B，A 也留不下来。

实例：`NetworkManager-bluetooth` 依赖 `bluez`，而 `bluez` 在 uninstall 段。
结果这个包从来没进过镜像。曾经描述文件 87 个包、锁文件只有 86 个，缺的就是它。
现在这行已删除，原位置留了注释说明不要加回来。

**自查方法**：`build.sh --lock-out` 生成的锁文件会列出「描述里有但没装上」的包：

```
⚠️ 描述文件里列了但没装上（可能是 glob 或被 uninstall 移除）：
   NetworkManager-bluetooth
```

看到这个提示就去查 uninstall 段。正常情况应该一个都不缺。

---

## btrfs 下 `rootflags` 会在内核参数里出现两次

`btrfs_root_is_subvolume="true"` + `btrfs_set_default_volume="false"` 时，
最终 BLS 条目的 `options` 行长这样：

```
options root=UUID=... ro rootflags=subvol=root  quiet console=tty0 console=ttyS0,115200n8 rootflags=subvol=root
```

`rootflags=subvol=root` 出现了两次。原因是 kiwi 两次都加：

1. `kiwi/builder/disk.py` 直接往 boot options 里追加一次
2. 同一个值又被塞进 `GRUB_CMDLINE_LINUX_DEFAULT`，BLS 生成时再带一次

而 `kiwi/bootloader/config/grub2.py` 里剥离 `root=` 的正则只管 `root=`，
不管 `rootflags=`：

```python
grub_final_cmdline = re.sub(
    r'(^root=[^\s]+)|( root=[^\s]+)', '', self.cmdline
).strip()
```

**影响**：无。内核把重复的 `rootflags=` 当同名参数处理，后一个覆盖前一个，
两者值相同。系统能正常挂载根并启动到登录提示（实测）。

**不要试图在 `fsmountoptions` 里去掉它** —— 那里本来就没有 `subvol`，加了反而
多一份。这是 kiwi 的行为，不要打补丁（见本文末一节）。

---

## 环境陷阱

- **`config.sh` 在 chroot 里跑，`systemctl enable` 可能非零退出。** kiwi 用
  `set -e` 跑它，一条失败就整体中止。**每条都要 `|| true`。**
- **`grub2-editenv` 在容器 overlay 上会失败**（拿不到真实块设备）：
  `failed to get canonical path of 'overlay'`。直接写 1024 字节的 grubenv 块。
- **`dracut` 的 `No '/dev/log' or 'logger'` 是 warning 不是错误**，退出码 0。
  曾被这条误导过两轮。
- **`Extended attributes not supported for target`** 是 fuse 文件系统的警告，
  不影响产物。
- **`Running fallback setup for shim secure boot efi image`** 是正常路径，
  不是错误。

---

## RPM spec 注释里不能出现百分号

RPM 会把注释里的 `%` 当宏展开，报 `Macro XXX has empty body`。踩过两次。
`static-check.yml` 有一步专门查这个。

---

## 为什么 kiwi 的行为和官方描述不一致时，先改自己

D-006 里记着：过程中给 kiwi 打过 5 处源码补丁，事后验证全部无效——官方描述不加
任何补丁也能推进到同一位置。补丁只让构建多跑十分钟。

**遇到 kiwi 行为异常，先对照 Fedora 官方描述文件，而不是改 kiwi 源码。**
