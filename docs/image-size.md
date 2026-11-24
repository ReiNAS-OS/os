# 镜像体积分析

**结论先说**：863 MB 的 `.install.iso` 基本压不动了。压缩算法已经接近通用
无损压缩的极限，再优化最多省 1–2%。想显著变小只能改分发形态，不能靠调参。

这份记录是为了避免以后有人再重复做一轮「换个压缩参数能省多少」的实验。

---

## 一、ISO 里到底是什么

实测拆解（run 45405607192，`.install.iso` 863 MB）：

```
863 MB  ISO
 ├─ 637 MB  REINAS_RAW.SQUASHFS     74%   ← 主要成分
 │    └─ 8.0 GB  ReiNAS.raw         稀疏镜像，真数据 5.9 GB
 │         └─ 2M legacy + 512M UEFI + 1024M /boot + 6652M root
 ├─  82 MB  BOOT/X86_64/LOADER/INITRD     装机环境 initrd
 ├─  82 MB  INITRD.SYSTEM_IMAGE           被装系统的 initrd
 ├─  18 MB  BOOT/X86_64/LOADER/LINUX      内核
 ├─  20 MB  EFI 程序（shim/grub，x64 与 ia32 各一份）
 └─  24 MB  其余
```

**关键事实**：squashfs 里只有 **3 个 inode**。它不是把文件系统树展开后压缩，
而是把一个已经做好的 8 GB raw 镜像**整个当文件**塞进去压。所以压缩的对象
是「镜像文件的字节」，不是「一堆小文件」。

---

## 二、8 GB 是虚拟尺寸

```
逻辑大小   8192 MB
真数据     5888 MB   71.9%
稀疏空洞   2304 MB   28.1%  从未写入
```

用 `SEEK_DATA`/`SEEK_HOLE` 能找到 11 段真实数据区。镜像 format 是 raw，
所以声明 8 GB 但只有写过的部分占盘。

**空洞压缩后几乎不占空间**——实测：

```
512 MB 全零数据 → xz -9 压到 77 KB（约 1:6800）
```

所以 637 MB 对应的是 5.9 GB 真数据，**压缩比 9.24:1**；不是 8 GB 的逻辑比
12.86:1。

---

## 三、压缩参数已经到顶

用真实系统数据做样本（145 MB，94% 非零，取自 root 分区密集区）。用稀疏
样本测会得到完全错误的结论——见下面「踩过的坑」。

| 参数 | 压缩后 | 耗时 | 相对现状 |
|---|---|---|---|
| **xz dict=1M**（squashfs 当前） | **106.7 MB** | 4.1 s | 基准 |
| xz -9e dict=64M | 105.8 MB | 37 s | 省 0.8%，慢 9 倍 |
| zstd -19 | 106.8 MB | 10.7 s | 反而大 0.1% |
| zstd --ultra -22 | 105.1 MB | 20.8 s | 省 1.5%，慢 5 倍 |

**没有任何一组能带来有意义的收益。** 按 637 MB 换算，最好情况省 9.6 MB。

当前 squashfs 参数（`unsquashfs -s` 实测）：

```
Compression        xz
Dictionary size    1048576 (1 MB)
Block size         1048576 (1 MB)
Filters selected   x86（BCJ 过滤器）
```

kiwi 在 `kiwi/filesystem/squashfs.py` 里调 mksquashfs 时只传 `-comp <类型>`
和 `-b 1M`，**字典大小没暴露**。想改只能通过 `<fscreateoptions>` 传
`create_options`，但如上表，改了也没用。

---

## 四、想显著变小只有三条路

| 方向 | 能省 | 代价 |
|---|---|---|
| 只发 `.raw.xz`，不发 ISO | **237 MB** | 用户要自己 `dd`，没有安装向导 |
| 砍包 | 100–150 MB | 已明确不砍（`kernel-modules-extra` 等全保留） |
| 换 erofs / 别的算法 | ≈ 0 | 兼容性和收益都不划算 |

**237 MB 这个数字是「装机环境的成本」**：ISO 里的两份 initrd（164 MB）+
内核（18 MB）+ EFI 程序（20 MB）+ ISO 文件系统开销。

### 推荐做法：两个制品都发

`.raw.xz`（626 MB）现在已经在产出了，不需要改任何构建逻辑：

- 会 `dd` 的人 → 下 `.raw.xz`，省 237 MB
- 要安装向导的人 → 下 `.install.iso`

---

## 五、分区大小的实际占用

| 分区 | 声明 | 实际占用 | 说明 |
|---|---|---|---|
| p1 `p.legacy` | 2 MB | 2 MB | BIOS 兼容引导区 |
| p2 `p.UEFI` | 512 MB | **18.7 MB** | FAT16，65536 簇里用了 2390 个 |
| p3 `p.lxboot` | 1024 MB | — | 内核 + initramfs |
| p4 `p.lxroot` | 6652 MB | — | btrfs 根（含 4 个子卷） |

**ESP 512 MB 是浪费**，实际只用 18.7 MB（3.7%）。降到 300 MB 甚至 128 MB
都够。

⚠️ **但改 ESP 不会让 ISO 变小**：ESP 空白区在镜像里是空洞，压缩后几乎为 0。
改它的价值是分区表更合理，不是为了省体积。

### UEFI 与 /boot 的分工

两个独立分区，不是一回事：

| 分区 | 文件系统 | 装什么 |
|---|---|---|
| p2 `p.UEFI`（ESP） | FAT16 | shim、grub、mok 管理器——UEFI 固件只认 FAT |
| p3 `p.lxboot` | ext4 | `vmlinuz`、`initramfs-*.img`——grub 从这里读内核 |

启动链实测：

```
UEFI 固件
  → HD(2,GPT,...)/\EFI\fedora\shimx64.efi
    → grubx64.efi
      → /boot/vmlinuz-7.3.4-300.fc45.x86_64
```

`p1` 那个 2 MB 的 legacy 分区是 BIOS 兼容区，不是主引导路径。

---

## 六、踩过的坑

### 用稀疏样本测压缩率会得到错误结论

第一次测时取了镜像前 200 MB 做样本，得出「dict 1M → 64M 能省 64%」的
结论。实际那份样本 **91% 是全零**（正好落在稀疏空洞里），压缩的全是零。

换成 94% 非零的真实数据重测，收益从 64% 掉到 0.8%。

**测压缩率必须确认样本的非零比例**，否则测的是「压零」不是「压数据」。

### 不要用 `-append` 给 GRUB 引导的系统传内核参数

`qemu-system-x86_64 -append` 只在 `-kernel` 直接引导时生效。走 GRUB/BLS
时它被忽略，必须改 grub.cfg 或在 GRUB 命令行编辑。

### macOS 上没有 ISO 和 ext4 工具

`isoinfo`、`xorriso`、`debugfs`、`e2ls` 都没有。分析 ISO 用 Python 解析
ISO9660 结构（PVD 在扇区 16，root dir 记录在偏移 156），分析 ext4 用
`SEEK_DATA`/`SEEK_HOLE` 找真实数据区。

squashfs 需要 `brew install squashfs`。
