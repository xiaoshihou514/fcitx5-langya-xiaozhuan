#!/usr/bin/env python3
"""生成桌面图标：透明底、单个「篆」字 SVG、占满整格、暗黑自适应。

从源 SVG 抠 path_seal_zhuan 及其原始 transform 链（不烘焙坐标——
该路径含 V/H 命令且链上带负 scale，烘焙会上下颠倒），viewBox 由
512px 渲染的 alpha 像素 bbox 反推。产出一份：
  icons/scalable/apps/langya.svg（hicolor）
暗色自适应用 Breeze 同款「current-color-scheme」样式表：path 填
currentColor、class=ColorScheme-Text，KDE 按当前配色把文字色注入，
亮/暗主题一份通吃；非 KDE 渲染器取默认深灰 #232629。
（旧方案另装 breeze-dark/scalable/apps 白字版，但 breeze-dark 的
index.theme 未登记 scalable/apps 目录，永远查不到，暗色下仍取黑字。）

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

    def make_svg() -> str:
        return (f'<svg xmlns="http://www.w3.org/2000/svg" '
                f'viewBox="{bx0:.2f} {by0:.2f} {bx1-bx0:.2f} {by1-by0:.2f}">'
                f'<style type="text/css" id="current-color-scheme">'
                f'.ColorScheme-Text {{ color: #232629; }}</style>'
                f'<g transform="{chain}">'
                f'<path class="ColorScheme-Text" fill="currentColor" '
                f'd="{d_clean}"/></g></svg>')

    icons = HERE.parent / "icons"
    out = icons / "scalable" / "apps" / "langya.svg"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(make_svg(), encoding="utf-8")
    print(f"✓ {out}（{out.stat().st_size} 字节）")

    # 安装到用户 hicolor；清理旧 PNG 与旧 breeze-dark 白字版
    home_icons = Path.home() / ".local/share/icons"
    dst = home_icons / "hicolor" / "scalable" / "apps" / "langya.svg"
    dst.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(["cp", str(out), str(dst)], check=True)
    for old in [*home_icons.glob("*x*/apps/langya.png"),
                *home_icons.glob("**/breeze-dark/scalable/apps/langya.svg")]:
        old.unlink()
    print("✓ 已安装到 hicolor（亮/暗配色由 KDE 自动着色）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
