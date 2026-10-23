#!/usr/bin/env python3
"""从 ic_launcher_legacy_zhuan.svg 生成琅琊 Android 自适应图标。

设计（源 SVG，viewBox 50.8×50.8）：
  - 灰键盘底板（#696969）＋两排按键与空格（#c5c5c5）
  - 白色盾形键盘轮廓（#ffffff）＋黑描边轮廓（#020000）
  - 小篆「篆」字（#020000）
  - 渐变阴影层丢弃（Android vector 不支持渐变填充，非主体）

输出：
  - android/plugin/src/main/res/drawable/ic_launcher_foreground.xml
    （108dp viewport，内容缩放进 66dp 安全区）
  - /tmp/langya-icon/preview_fg.svg｜preview_full.svg（对比/导 PNG 用）

用法：python3 tools/make_android_icon.py <源SVG路径>
依赖：仅标准库；渲染 PNG 另用 inkscape。
"""
from __future__ import annotations

import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

NS = {"svg": "http://www.w3.org/2000/svg"}
INK_LABEL = "{http://www.inkscape.org/namespaces/inkscape}label"
CANVAS = 50.8          # 源 viewBox 尺寸
VIEWPORT = 108.0       # 自适应图标 viewport
SAFE = 66.0            # 前景安全区直径

# 组变换（从源 SVG 逐层提取）
M_KBD = (0.79581705, 0.0, 0.0, 0.79581705, -17.574121, -17.349325)
M_CSS = (0.50131088, 0.0, 0.0, 0.50131088, 8.4220116, -115.7035)
M_ROW1 = (1.0, 0.0, 0.0, 1.0, 0.03001099, 0.14636307)
M_SEAL = (0.029029, 0.0, 0.0, -0.029029, 4.3296, 283.4655)


def mul(m1, m2):
    """m1∘m2：先施加 m2 再施加 m1（SVG matrix 语义）。"""
    a1, b1, c1, d1, e1, f1 = m1
    a2, b2, c2, d2, e2, f2 = m2
    return (a1 * a2 + c1 * b2, b1 * a2 + d1 * b2,
            a1 * c2 + c1 * d2, b1 * c2 + d1 * d2,
            a1 * e2 + c1 * f2 + e1, b1 * e2 + d1 * f2 + f1)


def apply(m, x, y):
    a, b, c, d, e, f = m
    return a * x + c * y + e, b * x + d * y + f


# 画布映射：内容缩放进安全区并居中
S = SAFE / CANVAS
T_OFF = (VIEWPORT - SAFE) / 2.0
C = (S, 0.0, 0.0, S, T_OFF, T_OFF)


# ── SVG path 解析与仿射烘焙 ──────────────────────────────
TOKEN = re.compile(r"([MmLlHhVvCcSsQqTtAaZz])|(-?\d*\.?\d+(?:e[-+]?\d+)?)",
                   re.ASCII)


def parse_path(d):
    out = []
    pos = []
    for m in TOKEN.finditer(d):
        g1, g2 = m.group(1), m.group(2)
        if g1:
            if pos:
                out.append(pos)
            pos = [g1]
        else:
            pos.append(float(g2))
    if pos:
        out.append(pos)
    return out


def fmt(v):
    s = f"{v:.2f}"
    return s.rstrip("0").rstrip(".") if "." in s else s


def transform_path(d, m):
    """烘焙仿射进路径数据，统一输出绝对命令（M/L/H/V/Q/C/A/Z）。

    仅支持均匀缩放（|a|==|d|），arc 半径同乘比例。相对命令（含
    M/L 的隐式重复与 T/S 的反射控制点）一律化为绝对形式。
    """
    a, b, c, dd, e, f = m
    assert abs(abs(a) - abs(dd)) < 1e-9, "仅支持均匀缩放"
    scale = abs(a)
    assert b == 0 and c == 0 or abs(a) == abs(dd), "不支持旋转/剪切"

    def pt(x, y):
        return a * x + c * y + e, b * x + dd * y + f

    def f2(p):
        return f"{p[0]:.2f} {p[1]:.2f}"

    out = []
    cx = cy = sx = sy = 0.0
    prev_ctrl = None  # Q/T/C/S 的反射控制点（原坐标系）

    for cmd in parse_path(d):
        op_raw, args = cmd[0], cmd[1:]
        op = op_raw.upper()
        rel = op_raw.islower()
        i = 0
        while True:
            if op == "M":
                if i + 2 > len(args):
                    break
                x, y = args[i], args[i + 1]
                i += 2
                if rel and out:
                    x += cx
                    y += cy
                sx, sy = x, y
                out.append("M " + f2(pt(x, y)))
                cx, cy = x, y
                prev_ctrl = None
                # 后续隐式 L，相对性与 M 保持一致（m 后是隐式 l）
                op = "L"
                continue
            if op == "L":
                if i + 2 > len(args):
                    break
                x, y = args[i], args[i + 1]
                i += 2
                if rel:
                    x += cx
                    y += cy
                out.append("L " + f2(pt(x, y)))
                cx, cy = x, y
                prev_ctrl = None
                continue
            if op == "H":
                if i + 1 > len(args):
                    break
                x = args[i] + (cx if rel else 0)
                i += 1
                out.append("H " + f"{pt(x, cy)[0]:.2f}")
                cx = x
                prev_ctrl = None
                continue
            if op == "V":
                if i + 1 > len(args):
                    break
                y = args[i] + (cy if rel else 0)
                i += 1
                out.append("V " + f"{pt(cx, y)[1]:.2f}")
                cy = y
                prev_ctrl = None
                continue
            if op in ("Q", "T"):
                if op == "Q":
                    if i + 4 > len(args):
                        break
                    x1, y1, x, y = args[i:i + 4]
                    i += 4
                    if rel:
                        x1 += cx; y1 += cy; x += cx; y += cy
                else:
                    if i + 2 > len(args):
                        break
                    x, y = args[i], args[i + 1]
                    i += 2
                    if rel:
                        x += cx; y += cy
                    if prev_ctrl:
                        x1 = 2 * cx - prev_ctrl[0]
                        y1 = 2 * cy - prev_ctrl[1]
                    else:
                        x1, y1 = cx, cy
                out.append("Q " + f2(pt(x1, y1)) + " " + f2(pt(x, y)))
                prev_ctrl = (x1, y1)
                cx, cy = x, y
                continue
            if op in ("C", "S"):
                if op == "C":
                    if i + 6 > len(args):
                        break
                    x1, y1, x2, y2, x, y = args[i:i + 6]
                    i += 6
                    if rel:
                        for k in range(6):
                            pass
                        x1 += cx; y1 += cy; x2 += cx; y2 += cy
                        x += cx; y += cy
                else:
                    if i + 4 > len(args):
                        break
                    x2, y2, x, y = args[i:i + 4]
                    i += 4
                    if rel:
                        x2 += cx; y2 += cy; x += cx; y += cy
                    if prev_ctrl:
                        x1 = 2 * cx - prev_ctrl[0]
                        y1 = 2 * cy - prev_ctrl[1]
                    else:
                        x1, y1 = cx, cy
                out.append("C " + f2(pt(x1, y1)) + " " + f2(pt(x2, y2))
                           + " " + f2(pt(x, y)))
                prev_ctrl = (x2, y2)
                cx, cy = x, y
                continue
            if op == "A":
                if i + 7 > len(args):
                    break
                rx, ry, rot, laf, sf, x, y = args[i:i + 7]
                i += 7
                if rel:
                    x += cx; y += cy
                out.append(f"A {rx * scale:.2f} {ry * scale:.2f} "
                           f"{rot:.2f} {int(laf)} {int(sf)} "
                           + f2(pt(x, y)))
                cx, cy = x, y
                prev_ctrl = None
                continue
            if op == "Z":
                out.append("Z")
                cx, cy = sx, sy
                prev_ctrl = None
                break
            break
    return " ".join(out)


NUM = r"[-+]?[0-9.]+(?:[eE][-+]?[0-9]+)?"


def parse_transform(text):
    """支持函数串联：translate(...) scale(...) 等复合变换。"""
    t = text.strip()
    total = (1, 0, 0, 1, 0, 0)
    while t:
        m = re.match(rf"translate\(({NUM})(?:[ ,]+({NUM}))?\)\s*", t)
        if m:
            tm = (1, 0, 0, 1, float(m.group(1)), float(m.group(2) or 0))
        else:
            m = re.match(rf"scale\(({NUM})(?:[ ,]+({NUM}))?\)\s*", t)
            if m:
                sx = float(m.group(1))
                sy = float(m.group(2) or m.group(1))
                tm = (sx, 0, 0, sy, 0, 0)
            else:
                m = re.match(rf"matrix\(({NUM})[ ,]+({NUM})[ ,]+({NUM})"
                             rf"[ ,]+({NUM})[ ,]+({NUM})[ ,]+({NUM})\)\s*",
                             t)
                if m:
                    tm = tuple(float(g) for g in m.groups())
                else:
                    raise ValueError(f"不支持的变换 {text}")
        total = mul(total, tm)
        t = t[m.end():]
    return total


def style_fill(el, inherited):
    st = el.get("style", "")
    m = re.search(r"(?:^|;)\s*fill:\s*(#[0-9a-fA-F]+)", st)
    return m.group(1) if m else inherited


def collect(el, matrix, fill, items):
    tag = el.tag.split("}")[-1]
    if el.get("display") == "none" or el.get(INK_LABEL, "").startswith(
            "DEBUG"):
        return
    if el.get("transform"):
        matrix = mul(matrix, parse_transform(el.get("transform")))
    fill = style_fill(el, fill)
    if tag == "path" and el.get("d"):
        items.append((el.get("d"), fill, matrix))
    for child in el:
        collect(child, matrix, fill, items)


def main():
    src = Path(sys.argv[1] if len(sys.argv) > 1 else
               "../ic_launcher_legacy_zhuan.svg")
    root = ET.parse(src).getroot()

    items = []
    for layer in root.findall("svg:g", NS):
        label = layer.get(INK_LABEL, "")
        if label == "kbd":
            for child in layer:
                collect(child, M_KBD, "#000000", items)
        elif label == "csslayer":
            for child in layer:
                collect(child, M_CSS, "#ffffff", items)
        # 阴影层（无 label 的渐变路径）与 DEBUG 组跳过

    # 篆字的附加变换在 collect 中经 transform 处理（g867 内的 path）

    paths = []
    for d, fill, m in items:
        td = transform_path(d, mul(C, m))
        paths.append((td, fill))

    # 输出 vector drawable
    body = []
    for td, fill in paths:
        body.append(f'    <path\n'
                    f'        android:fillColor="{fill}"\n'
                    f'        android:pathData="{td}" />')
    xml = ('<?xml version="1.0" encoding="utf-8"?>\n'
           '<!-- 由 tools/make_android_icon.py 从 ic_launcher_legacy_zhuan.svg 生成，勿手改 -->\n'
           '<vector xmlns:android="http://schemas.android.com/apk/res/android"\n'
           '    android:width="108dp"\n'
           '    android:height="108dp"\n'
           '    android:viewportWidth="108"\n'
           '    android:viewportHeight="108">\n'
           + "\n".join(body) + "\n</vector>\n")

    out = Path(__file__).resolve().parent.parent / (
        "android/plugin/src/main/res/drawable/ic_launcher_foreground.xml")
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(xml, encoding="utf-8")
    print(f"生成 {out}（{len(paths)} 条路径）")

    # 预览 SVG（对比与导 PNG）
    prev = Path("/tmp/langya-icon")
    prev.mkdir(parents=True, exist_ok=True)
    def svg_doc(bg):
        rects = (f'<rect width="108" height="108" fill="{bg}"/>'
                 if bg else "")
        body2 = "".join(f'<path fill="{f}" d="{d}"/>' for d, f in paths)
        return (f'<svg xmlns="http://www.w3.org/2000/svg" '
                f'viewBox="0 0 108 108" width="432" height="432">'
                f"{rects}{body2}</svg>")
    (prev / "preview_fg.svg").write_text(svg_doc(None), encoding="utf-8")
    (prev / "preview_full.svg").write_text(svg_doc("#37474F"),
                                           encoding="utf-8")
    print(f"预览：{prev}/preview_fg.svg（透明底）与 preview_full.svg")


if __name__ == "__main__":
    main()
