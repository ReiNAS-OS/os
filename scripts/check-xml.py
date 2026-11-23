#!/usr/bin/env python3
"""
kiwi 描述的 XML 静态检查。

存在的理由：XML 规范禁止注释里出现连续两个减号，而 shell 命令行参数
（比如 --disable-plugin）天然带它。这个错误踩过四次，每次都不是
校验能直接指出来的，所以固化成脚本。
"""
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path


def check(path: Path) -> int:
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

    return report(errs)


def report(errs) -> int:
    if errs:
        print("XML 检查发现问题：")
        for e in errs:
            print(f"  ✗ {e}")
        return 1
    print("  ✓ 通过")
    return 0


if __name__ == "__main__":
    targets = [Path(p) for p in (sys.argv[1:] or ["kiwi/reinas.kiwi"])]
    rc = 0
    for t in targets:
        if not t.exists():
            print(f"  ✗ 文件不存在: {t}")
            rc = 1
            continue
        print(f"检查 {t}")
        rc |= check(t)
    sys.exit(rc)
