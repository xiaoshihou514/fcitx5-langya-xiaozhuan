#!/usr/bin/env python3
"""合并 MiSansVF + 小篆 U+3D000 区字形 → MIUI 字体 mtz。

机制：MIUI/HyperOS 字体包以 fonts/Roboto-Regular.ttf 全局替换；
故底为系统 MiSansVF（日常文字不变），仅注入小篆区码位字形——
U+3D000–3FC3F 之外的小篆 cmap 层（隸定/通行字映射）不导入，
避免全局文字变篆书。
"""
from fontTools.ttLib import TTFont
from pathlib import Path
import zipfile

BASE = "/tmp/miztu/MiSansVF.ttf"
SEAL = "/tmp/miztu/seal-fixed.ttf"
OUT_TTF = "/tmp/miztu/merged.ttf"
OUT_MTZ = "/tmp/miztu/说文小篆.mtz"
LO, HI = 0x3D000, 0x3FC3F

base = TTFont(BASE, recalcBBoxes=False)
seal = TTFont(SEAL, recalcBBoxes=False)

seal_cmap = seal.getBestCmap()
targets = {cp: name for cp, name in seal_cmap.items() if LO <= cp <= HI}
print(f"注入 {len(targets)} 个小篆码位（U+{LO:X}–U+{HI:X}）")

base_order = base.getGlyphOrder()
existing = set(base_order)
glyf = base["glyf"]
hmtx = base["hmtx"]
seal_glyf = seal["glyf"]
seal_hmtx = seal["hmtx"]
upem_s = seal["head"].unitsPerEm
upem_b = base["head"].unitsPerEm
# upem 不同（2048 vs 1000）：按 MiSans 框重设——高度 96%em，
# 顶对齐 0.86em（与 fix_font_metrics 同参数，按目标 upem 换算）
from fontTools.pens.transformPen import TransformPen
from fontTools.pens.ttGlyphPen import TTGlyphPen
INK_H, TOP = 0.96, 0.86
glyph_set = seal.getGlyphSet()

def rescale(name):
    g = seal_glyf[name]
    h = g.yMax - g.yMin
    w = g.xMax - g.xMin
    if h <= 0 or w <= 0:
        return None
    target_h = INK_H * upem_b
    target_w = 0.98 * upem_b
    s = min(target_h / h, target_w / w)
    tx = 0.5 * upem_b - w * s / 2 - g.xMin * s
    ty = TOP * upem_b - g.yMax * s
    pen = TTGlyphPen(glyph_set)
    glyph_set[name].draw(TransformPen(pen, (s, 0, 0, s, tx, ty)))
    return pen.glyph()

added = {}
for cp, sname in targets.items():
    g0 = seal_glyf[sname]
    if getattr(g0, "numberOfContours", 0) == 0 and not hasattr(g0, "components"):
        continue
    newname = f"seal{cp:X}"
    if newname in existing:
        continue
    g = rescale(sname)
    if g is None:
        continue
    base_order.append(newname)
    existing.add(newname)
    glyf[newname] = g
    glyf[newname].recalcBounds(base)
    hmtx[newname] = (upem_b, glyf[newname].xMin)
    added[cp] = newname

base.setGlyphOrder(base_order)

# cmap：改 format12（或 4）主表；直接用 TTFont 的 cmap API 重建
from fontTools.ttLib.tables._c_m_a_p import CmapSubtable
best = base.getBestCmap()  # 原映射
best.update(added)
sub12 = CmapSubtable.newSubtable(12)
sub12.platformID, sub12.platEncID, sub12.language = 3, 10, 0
sub12.cmap = best
cmap = base["cmap"]
cmap.tables = [sub12]
cmap.tableVersion = 0
base.save(OUT_TTF)
print(f"合并完成 → {OUT_TTF}")

# 打 mtz
desc = """<?xml version="1.0" encoding="UTF-8" standalone="no"?>
<theme>
    <version>1.00</version>
    <uiVersion>8</uiVersion>
    <author>Langya</author>
    <designer>Langya</designer>
    <title>说文小篆</title>
    <description>MiSans + 說文解字小篆（U+3D000 区）</description>
    <fontWeight>400</fontWeight>
</theme>
"""
Path("/tmp/miztu/description.xml").write_text(desc, encoding="utf-8")
with zipfile.ZipFile(OUT_MTZ, "w", zipfile.ZIP_STORED) as z:
    z.write("/tmp/miztu/description.xml", "description.xml")
    z.write(OUT_TTF, "fonts/Roboto-Regular.ttf")
print(f"打包 → {OUT_MTZ}")
