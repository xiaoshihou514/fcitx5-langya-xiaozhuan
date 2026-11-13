#!/usr/bin/env python3
"""生成桌面图标：透明底、单个「篆」字 SVG、占满整格、暗黑自适应。

从源 SVG 抠 path_seal_zhuan 及其原始 transform 链（不烘焙坐标——
该路径含 V/H 命令且链上带负 scale，烘焙会上下颠倒），viewBox 由
512px 渲染的 alpha 像素 bbox 反推。产出两份：
  icons/scalable/apps/langya.svg          黑字（hicolor，浅色主题）
  icons/breeze-dark/scalable/apps/...     白字（breeze-dark，暗色主题）
KDE 暗色模式的图标主题即 breeze-dark，QIcon 自动取白色版，无需检测。

用法：uv run --project ../zhuan python tools/make_desktop_icon.py
"""
from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

import xml.etree.ElementTree as ET
import numpy as np
from PIL import Image

HERE = Path(__file__).resolve().parent
SRC = HERE.parent.parent / "ic_launcher_legacy_zhuan.svg"
SVG_NS = "{http://www.w3.org/2000/svg}"
INK = "{http://www.inkscape.org/namespaces/inkscape}label"


def main() -> int:
    root = ET.parse(SRC).getroot()

    # 抠 path_seal_zhuan 与祖先 transform 链（从外到内）
    target = None

    def walk(el, transforms):
        nonlocal target
        if target is not None:
            return
        if el.tag == f"{SVG_NS}path":
            if el.get("id") == "path_seal_zhuan":
                own = el.get("transform", "")
                target = (el.get("d"), transforms + ([own] if own else []))
            return
        t = el.get("transform", "")
        for c in el:
            walk(c, transforms + ([t] if t else []))

    for layer in root.findall(f"{SVG_NS}g"):
        if layer.get(INK, "") == "csslayer":
            t = layer.get("transform", "")
            for c in layer:
                walk(c, [t] if t else [])

    assert target, "未找到篆字路径 path_seal_zhuan"
    d, transforms = target
    d_clean = re.sub(r"\s+", " ", d)
    chain = " ".join(transforms)

    # 试渲染取像素 bbox（alpha 通道），viewBox 紧贴字迹
    raw = (f'<svg xmlns="http://www.w3.org/2000/svg" '
           f'viewBox="0 0 50.8 50.8">'
           f'<g transform="{chain}"><path fill="#000" d="{d_clean}"/></g></svg>')
    work = Path("/tmp/langya-desktop-icon")
    work.mkdir(exist_ok=True)
    (work / "raw.svg").write_text(raw, encoding="utf-8")
    subprocess.run(["inkscape", str(work / "raw.svg"), "-w", "512", "-h",
                    "512", "-o", str(work / "raw.png")], check=True)
    a = np.array(Image.open(work / "raw.png").convert("RGBA"))[..., 3]
    ys, xs = np.where(a > 8)
    assert len(xs), "渲染为空"
    bx0, bx1 = xs.min() / 512 * 50.8, xs.max() / 512 * 50.8
    by0, by1 = ys.min() / 512 * 50.8, ys.max() / 512 * 50.8
    print(f"像素 bbox x[{bx0:.2f},{bx1:.2f}] y[{by0:.2f},{by1:.2f}]")

    def make_svg(fill: str) -> str:
        return (f'<svg xmlns="http://www.w3.org/2000/svg" '
                f'viewBox="{bx0:.2f} {by0:.2f} {bx1-bx0:.2f} {by1-by0:.2f}">'
                f'<g transform="{chain}">'
                f'<path fill="{fill}" d="{d_clean}"/></g></svg>')

    icons = HERE.parent / "icons"
    black = icons / "scalable" / "apps" / "langya.svg"
    black.parent.mkdir(parents=True, exist_ok=True)
    black.write_text(make_svg("#000"), encoding="utf-8")
    print(f"✓ {black}（黑，{black.stat().st_size} 字节）")
    white = icons / "breeze-dark" / "scalable" / "apps" / "langya.svg"
    white.parent.mkdir(parents=True, exist_ok=True)
    white.write_text(make_svg("#fff"), encoding="utf-8")
    print(f"✓ {white}（白，{white.stat().st_size} 字节）")

    # 安装：hicolor=黑，breeze-dark=白；清理旧 PNG
    home_icons = Path.home() / ".local/share/icons"
    for sub, src in (("hicolor", black), ("breeze-dark", white)):
        dst = home_icons / sub / "scalable" / "apps" / "langya.svg"
        dst.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(["cp", str(src), str(dst)], check=True)
    for old in home_icons.glob("*x*/apps/langya.png"):
        old.unlink()
    subprocess.run(["fc-cache", "-f"], capture_output=True)
    print("✓ 已安装黑(hicolor)+白(breeze-dark)并刷新缓存")
    print("  暗色模式由 breeze-dark 主题自动取白版，无需运行时检测")
    return 0


if __name__ == "__main__":
    sys.exit(main())
