#!/usr/bin/env python3
"""构建 HyperOS/MIUI 字体主题包（mtz）：MiSans + 說文小篆合并。

背景：HyperOS 3 无 root 无法改系统字体回退链；用户可从主题壁纸导入
本地 mtz。MIUI 字体主题机制 = fonts/Roboto-Regular.ttf 全局替换，故
以手机自带 MiSansVF 为底、仅注入 U+3D000–3FC3F 小篆区字形——日常
文字零观感差异，小篆码点正常显示。

完整结构（对照系统自带 MILanProVF.mtz，缺一不可，否则导入器解析
半途失败、不生成 .mrm 元数据——真机踩过）：
  description.xml   完整字段（title/author/fontWeight 等）
  fonts/Roboto-Regular.ttf   合并字体
  preview/preview_fonts_{0,1,2}.jpg + preview_fonts_small_0.png
  rights/*.mra      空目录亦可（参考包携带）

用法：
  # 1) 依赖：手机已连 adb（拉 MiSansVF 与参考 mtz）
  # 2) 中间产物经 git 恢复（f609776dd 的 SVG 管线 TTF）+ 度量修复
  uv run --project ../zhuan python tools/build_mtz.py [--out DIR]

产物：<out>/说文小篆.mtz（推到手机 Download 由用户导入）
"""
from __future__ import annotations

import argparse
import shutil
import subprocess
import sys
import zipfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
LANGYA = HERE.parent
ZHAN = LANGYA.parent / "zhuan"
sys.path.insert(0, str(ZHAN))

SVG_PIPELINE_COMMIT = "f609776dd"          # 正确字形的基线提交
CCZ = ZHAN / "shuowen-seal-CCZ.ttf"
LO, HI = 0x3D000, 0x3FC3F

WORK = Path("/tmp/miztu")


def sh(*cmd: str, cwd: Path | None = None) -> None:
    subprocess.run(cmd, check=True, cwd=cwd)


def adb(*args: str) -> str:
    return subprocess.run(("adb", *args), check=True,
                          capture_output=True, text=True).stdout


def prepare_inputs() -> dict[str, Path]:
    """拉取手机端材料 + 恢复小篆基线 TTF（度量修复后）。"""
    WORK.mkdir(parents=True, exist_ok=True)
    base = WORK / "MiSansVF.ttf"
    if not base.exists():
        adb("pull", "/product/fonts/MiSansVF.ttf", str(base))
        print(f"拉取 {base.name} {base.stat().st_size} 字节")

    ref = WORK / "MILanProVF.mtz"
    if not ref.exists():
        adb("pull", "/system/media/theme/MILanProVF.mtz", str(ref))
        print(f"拉取参考包 {ref.name}")

    raw = WORK / "seal-raw.ttf"
    if not raw.exists():
        data = subprocess.run(
            ("git", "-C", str(LANGYA.parent.parent), "show",
             f"{SVG_PIPELINE_COMMIT}:小篆/zhuan/shuowen-seal-CCZ.ttf"),
            check=True, capture_output=True).stdout
        raw.write_bytes(data)
    return {"base": base, "ref": ref, "raw": raw}


def fix_metrics(ttf: Path) -> None:
    """SVG 管线 TTF 的度量归一（与 fix_font_metrics.py 同参数）。"""
    from fontTools.pens.transformPen import TransformPen
    from fontTools.pens.ttGlyphPen import TTGlyphPen
    from fontTools.ttLib import TTFont

    INK_H, TOP = 0.96, 0.86
    f = TTFont(str(ttf), recalcBBoxes=False)
    upem = f["head"].unitsPerEm
    glyf, hmtx = f["glyf"], f["hmtx"]
    glyph_set = f.getGlyphSet()
    n = 0
    for name in f.getGlyphOrder():
        g = glyf[name]
        if getattr(g, "numberOfContours", 0) == 0:
            hmtx[name] = (upem, hmtx[name][1])
            continue
        h, w = g.yMax - g.yMin, g.xMax - g.xMin
        if h <= 0 or w <= 0:
            continue
        s = min(INK_H * upem / h, 0.98 * upem / w)
        tx = 0.5 * upem - w * s / 2 - g.xMin * s
        ty = TOP * upem - g.yMax * s
        pen = TTGlyphPen(glyph_set)
        glyph_set[name].draw(TransformPen(pen, (s, 0, 0, s, tx, ty)))
        glyf[name] = pen.glyph()
        glyf[name].recalcBounds(f)
        hmtx[name] = (upem, glyf[name].xMin)
        n += 1
    f.save(str(ttf))
    print(f"度量修复：{n} 字形")


def merge(base: Path, seal: Path, out: Path) -> int:
    """MiSansVF 底 + 小篆区注入（仅 U+3D000–3FC3F 的 cmap 层）。"""
    from fontTools.ttLib import TTFont
    from fontTools.ttLib.tables._c_m_a_p import CmapSubtable
    from fontTools.pens.transformPen import TransformPen
    from fontTools.pens.ttGlyphPen import TTGlyphPen

    b = TTFont(str(base), recalcBBoxes=False)
    s = TTFont(str(seal), recalcBBoxes=False)
    upem_b = b["head"].unitsPerEm
    upem_s = s["head"].unitsPerEm
    targets = {cp: n for cp, n in s.getBestCmap().items() if LO <= cp <= HI}
    order = b.getGlyphOrder()
    existing = set(order)
    glyf, hmtx = b["glyf"], b["hmtx"]
    sg, sh_ = s["glyf"], s["hmtx"]
    glyph_set = s.getGlyphSet()
    INK_H, TOP = 0.96, 0.86
    added = {}
    for cp, sname in targets.items():
        g0 = sg[sname]
        if getattr(g0, "numberOfContours", 0) == 0:
            continue
        name = f"seal{cp:X}"
        if name in existing:
            continue
        h, w = g0.yMax - g0.yMin, g0.xMax - g0.xMin
        sc = min(INK_H * upem_b / h, 0.98 * upem_b / w)
        tx = 0.5 * upem_b - w * sc / 2 - g0.xMin * sc
        ty = TOP * upem_b - g0.yMax * sc
        pen = TTGlyphPen(glyph_set)
        glyph_set[sname].draw(TransformPen(pen, (sc, 0, 0, sc, tx, ty)))
        order.append(name)
        existing.add(name)
        glyf[name] = pen.glyph()
        glyf[name].recalcBounds(b)
        hmtx[name] = (upem_b, glyf[name].xMin)
        added[cp] = name
    b.setGlyphOrder(order)
    best = b.getBestCmap()
    best.update(added)
    sub = CmapSubtable.newSubtable(12)
    sub.platformID, sub.platEncID, sub.language = 3, 10, 0
    sub.cmap = best
    b["cmap"].tables = [sub]
    b["cmap"].tableVersion = 0
    b.save(str(out))
    print(f"合并 {len(added)} 小篆码位 → {out.name}")
    return len(added)


def render_previews(merged: Path) -> dict[str, Path]:
    from PIL import Image, ImageDraw, ImageFont
    sys.path.insert(0, str(ZHAN))
    from zhuan import ZhuanConverter
    cv = ZhuanConverter()
    seal = "".join(chr(cv.lookup(c).seal_cp) for c in "说文小篆")
    out = {}
    fb = ImageFont.truetype(str(merged), 300)
    fm = ImageFont.truetype(str(merged), 110)
    im = Image.new("RGB", (1080, 1080), (245, 243, 238))
    ImageDraw.Draw(im).text((540, 540), seal, fill=(40, 40, 40), font=fb,
                            anchor="mm")
    p0 = WORK / "p0.jpg"
    im.save(p0, quality=88)
    out["preview/preview_fonts_0.jpg"] = p0
    im = Image.new("RGB", (1080, 1080), "white")
    d = ImageDraw.Draw(im)
    d.text((540, 280), "说文小篆", fill="black",
           font=ImageFont.truetype(str(merged), 150), anchor="mm")
    d.text((540, 720), seal, fill="black", font=fm, anchor="mm")
    p1 = WORK / "p1.jpg"
    im.save(p1, quality=88)
    out["preview/preview_fonts_1.jpg"] = p1
    im = Image.new("RGB", (1080, 1080), (30, 32, 34))
    long_seal = "".join(
        chr(cv.lookup(c).seal_cp) if cv.lookup(c) else c
        for c in "琅琊小篆說文解字")
    ImageDraw.Draw(im).text((540, 540), long_seal[:4] + "\n" + long_seal[4:],
                            fill=(230, 226, 220), font=fm, anchor="mm")
    p2 = WORK / "p2.jpg"
    im.save(p2, quality=88)
    out["preview/preview_fonts_2.jpg"] = p2
    small = WORK / "p_small.png"
    Image.open(p0).resize((360, 360)).save(small)
    out["preview/preview_fonts_small_0.png"] = small
    return out


def build_description(ref: Path) -> str:
    """以参考包 description.xml 为模板，仅替换标识字段。"""
    import re
    with zipfile.ZipFile(ref) as z:
        text = z.read("description.xml").decode("utf-8")
    text = text.replace("<title>小米兰亭Pro</title>", "<title>说文小篆</title>")
    text = text.replace("<author>小米主题</author>", "<author>琅琊</author>")
    text = text.replace("<designer>小米主题</designer>", "<designer>琅琊</designer>")
    # 参考包携全部字重（VF 轴保留），合并字体同为 VF，保持不动
    return text


def pack(merged: Path, ref: Path, out: Path) -> None:
    previews = render_previews(merged)
    desc = build_description(ref)
    (WORK / "description.xml").write_text(desc, encoding="utf-8")
    with zipfile.ZipFile(out, "w", zipfile.ZIP_STORED) as z:
        z.write(WORK / "description.xml", "description.xml")
        z.write(merged, "fonts/Roboto-Regular.ttf")
        for arc, path in previews.items():
            z.write(path, arc)
        # rights 参考结构（mra 为版权描述，复用占位）
        with zipfile.ZipFile(ref) as r:
            for n in r.namelist():
                if n.startswith("rights/"):
                    z.writestr(n, r.read(n))
    print(f"打包 → {out}（{out.stat().st_size} 字节）")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", type=Path, default=WORK / "说文小篆.mtz")
    args = ap.parse_args()
    inputs = prepare_inputs()
    seal = WORK / "seal-fixed.ttf"
    if not seal.exists():
        shutil.copy(inputs["raw"], seal)
        fix_metrics(seal)
    merged = WORK / "merged.ttf"
    if not merged.exists():
        merge(inputs["base"], seal, merged)
    pack(merged, inputs["ref"], args.out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
