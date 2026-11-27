# 账号相关决策

这份文件接 `decisions.md`。D-007 原本在那边，因为它已经接近提交钩子的
20 KB 上限，搬到独立文件——账号策略还会继续演进（面板初始化、SSH 公钥
分发、多用户），值得单独一份。

`decisions.md` 里保留 D-007 的编号占位和一句指路。

---

## D-007：root 密码用显式开关，默认关闭

**日期**：2026-11-24
**状态**：已决定

### 背景

0.1.0 之前的状态是：`root` 和 `reinas` 都 `passwd -l` 锁定，SSH 是
`PasswordAuthentication no`，而 `<users>` 段里一个用户都没有。结果是镜像
能构建、能启动，但**装完没有任何人能登录**——只能 `rd.break` 或单步救援改
`/etc/shadow`。验证阶段没法做。

需要一个「开发时能进、发布时进不去」的机制。

### 决策

**一个开关，默认关。开的时候作用于 `root`。**

```bash
./scripts/build.sh                      # 关（生产形态，root 锁定）
./scripts/build.sh --root-password      # 开，root 密码 123456
./scripts/build.sh --root-password=xxx  # 开，自定义密码
```

CI 里对应 `workflow_dispatch` 的 `root_password` 输入，留空即关闭。

### 为什么是 root，不是预置的普通账号

最初做的是 `reinas` 账号。后来改成 root，原因：

- 开发验证要在系统里做一堆特权操作（`df -h /`、`getenforce`、
  `systemctl is-enabled`、`btrfs subvolume list`），root 省掉 `sudo` 这一层
- 少一个变量：开发构建和生产的差别只有「root 有没有密码」这一条

### 后续修订：镜像不再预置 reinas 账号

**2026-11-27 起，镜像里连 `reinas` 账号也不再创建。**

原来的设计里有一个 `reinas` 应急账号（`useradd -m -G wheel`，密码始终
`passwd -l`），用意是留给最终用户做控制台救援。

但它和面板的初始化流程冲突：**新机器开箱就有一个非 root 账号存在**，
「有没有初始化过」这件事就没法用「有没有可登录用户」来判断，而且那个
账号是死号（登不进去），留着只增加解释成本。

现在的形态：

| | 生产构建 | 开发构建 |
|---|---|---|
| `root` | 锁定密码，SSH 仅公钥 | 有密码（`--root-password`） |
| 普通用户 | **无** | **无** |

第一个普通账号由面板初始化流程创建（`POST /api/v1/setup/user`，走
`useradd -m -G wheel -s /bin/bash`），创建者拿到 sudo 权限。也就是说
**Web 面板、SSH、控制台共用同一套 Linux 凭据**，没有第二套账号体系。

代价：生产镜像装完仍然只能靠 SSH 公钥或物理控制台进入——这一点和之前
一样，只是少了一个永远锁着的账号。

### 实现链路

```
build.sh --root-password
  └─ 写 kiwi/root.conf（一行明文密码；关闭时是空文件）
       └─ reinas.kiwi 的 <file name="root.conf" target="/etc/reinas/root.conf">
            └─ config.sh 用 read 读它
                 ├─ 有密码 → chpasswd root:<pw>
                 │           + 写 20-reinas-root.conf：
                 │               PermitRootLogin yes
                 │               PasswordAuthentication yes
                 │           + 写 /etc/reinas/BUILD-HAS-ROOT-PASSWORD 标记
                 └─ 无密码 → passwd -d root / passwd -l root（锁定）
```

**为什么必须写那个 drop-in**：`config.sh` 里的 `10-reinas.conf` 默认是

```
PermitRootLogin prohibit-password
PasswordAuthentication no
```

两行都挡住 root 密码登录 —— `prohibit-password` 只允许公钥，而
`PasswordAuthentication no` 连密码通道都关了。只设密码是登不进去的，
必须同时覆盖这两项。

三个设计选择，都是踩过的：

1. **用 `read` 不用 `source`。** 密码里带 `$` `` ` `` `"` `\` 时，`source`
   会把它当 shell 代码展开。实测 `a$b`c"d\e` 用 `source` 读出来是空的。
2. **关闭时写空文件，不写 `VAR=""`。** `[ -s file ]` 判断比解析一行 shell
   赋值难出错。
3. **两个分支都 `rm -f /etc/reinas/root.conf`。** 明文密码不能留在交付镜像里。

### 生产形态的真实含义

关闭时镜像里**没有任何已知口令**：

- `root` 锁定密码
- `reinas` 锁定密码，在 `wheel` 组
- SSH 只认公钥，但镜像里也没有预置公钥

所以当前的关闭态是「安全但进不去」，不是「安全且能进」。真正要能进，还缺
一条合法的初始凭据通道（首启向导 / ISO 装机时建账号 / 注入公钥）。这是
后续的事，在它做完之前**`--root-password` 是唯一能登录的路**。

### 强制约束

`static-check.yml` 里有两步守着，改动时会被拦：

- `确认 root 密码默认关闭` —— 检查 `<file>` 条目在、`[ -n "$ROOT_PASSWORD" ]`
  守卫在、`rm -f root.conf` 在、`passwd -l root` 在、`root.conf` 没入库
- `检查 root 密码开关的实际行为` —— 真跑一遍开关逻辑，验空文件 / 密码内容 /
  元字符不展开 / 换行被拒

`kiwi/root.conf` 在 `.gitignore` 里，且可能含明文密码，绝不入库。

---

