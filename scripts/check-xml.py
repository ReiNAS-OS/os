#!/usr/bin/env python3
"""
kiwi 描述的 XML 静态检查。

存在的理由：XML 规范禁止注释里出现连续两个减号，而 shell 命令行参数
（比如 shell 的连续减号选项）天然带它。这个错误踩过四次，每次都不是
校验能直接指出来的，所以固化成脚本。
"""
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path


def check(path: Path, online: bool = False) -> int:
    src = path.read_text(encoding="utf-8")
    errs = []

    # 1. 注释内的连续减号
    for m in re.finditer(r"<!--.*?-->", src, re.S):
        if "--" in m.group(0)[4:-3]:
            line = src[: m.start()].count("\n") + 1
            snippet = next(
                (l.strip() for l in m.group(0).splitlines() if "--" in l), ""
            )
            errs.append(f"{path}:{line}: 注释内含连续减号 → {snippet[:80]}")

    # 2. 未转义的 &
    for i, line in enumerate(src.split("\n"), 1):
        if "&" in line and not re.search(
            r"&(amp|lt|gt|quot|apos|#\d+|#x[0-9a-fA-F]+);", line
        ):
            errs.append(f"{path}:{i}: 含未转义的 & → {line.strip()[:80]}")

    # 3. 整体可解析性
    try:
        root = ET.fromstring(src)
    except ET.ParseError as e:
        errs.append(f"{path}: XML 解析失败 → {e}")
        # 6. 包名对 Fedora 仓库的真实性校验（需要联网，失败时跳过）
    errs.extend(check_packages_exist(path, root, online))

    return report(errs)

    # 4. kiwi 结构的最小断言
    if root.tag != "image":
        errs.append(f"{path}: 根元素应为 <image>，实际 <{root.tag}>")
    if not root.get("name"):
        errs.append(f"{path}: <image> 缺少 name 属性")
    if not root.findall("./profiles/profile"):
        errs.append(f"{path}: 没有定义 profile")

    # 第一个 <preferences> 通常只放全局属性（version/packagemanager/locale...），
    # 不带 <type>；带 profiles 或 arch 的才必须有 <type>。
    for pref in root.findall("./preferences"):
        is_global = pref.get("profiles") is None and pref.get("arch") is None
        t = pref.find("type")
        if t is None:
            if not is_global:
                errs.append(
                    f"{path}: 带 profiles/arch 的 <preferences> 缺少 <type>"
                )
            continue
        if not t.get("image"):
            errs.append(f"{path}: <type> 缺少 image 属性")
        # locale 不能带 .UTF-8 之类的后缀，kiwi 的 schema 只认 en_US 形式
        loc = pref.find("locale")
        if loc is not None and loc.text and "." in loc.text:
            errs.append(
                f"{path}: <locale>{loc.text}</locale> 非法，"
                f"应为 {loc.text.split('.')[0]}（不能带 .UTF-8 后缀）"
            )

    # 5. patternType 提醒（数量会翻倍，属于性能/体积问题而非错误）
    img_pkgs = root.findall('.//packages[@type="image"]')
    for p in img_pkgs:
        if p.get("patternType") != "onlyRequired":
            print(
                f"  提示: {path} 的 <packages type=\"image\"> 没设 "
                f"patternType=\"onlyRequired\"，weak deps 会被装进镜像"
            )

    # 6. 包名对 Fedora 仓库的真实性校验（需要联网，失败时跳过）
    errs.extend(check_packages_exist(path, root, online))

    return report(errs)


# Fedora 主版本与元数据地址
FEDORA_RELEASE = "45"
REPOMD = (
    f"https://mirror.rackspace.com/fedora/releases/{FEDORA_RELEASE}"
    "/Everything/x86_64/os/repodata/repomd.xml"
)


def _fetch_available_packages() -> set:
    """下载 Fedora 的 primary 元数据，返回可用包名集合。"""
    import urllib.request
    import zlib

    repomd = urllib.request.urlopen(REPOMD, timeout=60).read().decode()
    base = REPOMD.rsplit("/repodata/", 1)[0]

    # Fedora 的 primary 元数据默认是 .zst。优先找 .gz，避免依赖 zstandard；
    # 只有 .zst 时才需要第三方模块。
    gz = re.search(r'href="([^"]*primary\.xml\.gz)"', repomd)
    zst = re.search(r'href="([^"]*primary\.xml\.zst)"', repomd)

    if gz:
        raw = urllib.request.urlopen(f"{base}/{gz.group(1)}", timeout=180).read()
        data = zlib.decompress(raw, 16 + zlib.MAX_WBITS)
    elif zst:
        try:
            import zstandard
        except ImportError:
            raise RuntimeError("元数据只有 .zst 格式，需要 pip install zstandard")
        raw = urllib.request.urlopen(f"{base}/{zst.group(1)}", timeout=180).read()
        data = zstandard.ZstdDecompressor().decompress(raw, max_output_size=300_000_000)
    else:
        raise RuntimeError("repomd 里找不到 primary 元数据")

    names = set()
    for m in re.finditer(rb'<package type="rpm">(.*?)</package>', data, re.S):
        b = m.group(1)
        n = re.search(rb"<name>(.*?)</name>", b).group(1).decode()
        a = re.search(rb"<arch>(.*?)</arch>", b).group(1).decode()
        if a in ("x86_64", "noarch"):
            names.add(n)
    return names


def check_packages_exist(path: Path, root, online: bool) -> list:
    """校验描述文件里的包名在 Fedora 里真实存在。

    这是本项目最常犯的错误：漏包（少写 dracut-network）或拼错包名，
    都要等到构建跑到最末尾才暴露，白等十几分钟。这里提前拦住。

    自建包（reinas-release）和 glob（iwl* 之类）跳过。
    """
    if not online:
        return []

    self_built = {"reinas-release"}
    try:
        avail = _fetch_available_packages()
    except Exception as e:
        print(f"  提示: 跳过包名校验（{e}）")
        return []

    bad = []
    for sec in root.findall(".//packages"):
        sec_type = sec.get("type")
        for pkg in sec.findall("package"):
            name = pkg.get("name")
            if not name or name in self_built:
                continue
            if any(c in name for c in "*?["):
                continue
            if name not in avail:
                bad.append(f"{path}: [{sec_type}] 包名不存在: {name}")
    return bad


def report(errs) -> int:
    if errs:
        print("XML 检查发现问题：")
        for e in errs:
            print(f"  ✗ {e}")
        return 1
    print("  ✓ 通过")
    return 0


if __name__ == "__main__":
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    online = "--online" in sys.argv
    targets = [Path(p) for p in (args or ["kiwi/reinas.kiwi"])]
    rc = 0
    for t in targets:
        if not t.exists():
            print(f"  ✗ 文件不存在: {t}")
            rc = 1
            continue
        print(f"检查 {t}" + ("（含包名校验）" if online else ""))
        rc |= check(t, online)
    sys.exit(rc)
