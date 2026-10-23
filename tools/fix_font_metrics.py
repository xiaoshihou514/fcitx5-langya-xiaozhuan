#!/usr/bin/env python3
"""修正 shuowen-seal 字体的度量（真机反馈：字格偏小、间距观感差）。

病灶（实测 shuowen-seal-CCZ.ttf，upem=2048）：
  - advance 均值 65.5% em —— 内嵌 CID 字体继承的窄步进，汉字应为全角
  - 墨迹高度均值 74.7% em —— 常规汉字字体约 88%
  - 行高度量（ascent/descent）未校准

修复（对 SVG 管线的中间 TTF 逐字形，产出中文名 OTF）：
  1. 墨迹高度归一 96% em、宽度封顶 98%（横扁字防爆格），等比缩放，
     水平居中 0.5em，垂直放入 [baseline-0.10em, baseline+0.86em] 框
  2. advance 统一 100% em（全角），lsb 同步新 bbox
  3. hhea/OS/2 垂直度量：ascent 0.86em / descent -0.10em / lineGap 0
  4. 经 build_fonts.ttf_to_otf 转 CFF，输出中文文件名 OTF，
     name 表全中文（仅 PostScript 名按规范保留 ASCII），
     中间 TTF 删除——交付物只有中文名 OTF

用法：uv run --project ../zhuan python tools/fix_font_metrics.py
"""
from __future__ import annotations

import sys
from pathlib import Path

LANGYA = Path(__file__).resolve().parent.parent
ZHAN = LANGYA.parent / "zhuan"
sys.path.insert(0, str(ZHAN))

from fontTools.pens.transformPen import TransformPen  # noqa: E402
from fontTools.pens.ttGlyphPen import TTGlyphPen  # noqa: E402
from fontTools.ttLib import TTFont  # noqa: E402

# 真机/桌面二轮调参：墨迹加大至 0.94，整体下移对齐主流中文字体
# 的实际墨迹框（思源类约 [-0.10, +0.84]），消除"底大空隙、字偏小"
INK_H = 0.96   # 目标墨迹高度 / em（三轮：留白再收紧）
INK_W = 0.98   # 目标墨迹宽度上限 / em（横扁字按宽约束，
               # 否则「一」等被高度归一撑爆全角步进）
TOP = 0.86     # 墨迹顶 / em（baseline 之上）
BOT = -0.10    # 墨迹底 / em（baseline 之下）
# 槽位 → 中文家族名（SLOT_ZH 一致）
ZH_NAMES = {
    "CCZ": "说文小篆-陈昌治本",
    "QJZ": "说文小篆-徐锴本",
    "DYC": "说文小篆-段玉裁本",
    "THX": "说文小篆-藤花树本",
}
PS_NAMES = {  # PostScript 名仅限 ASCII（规范要求）
    "CCZ": "ShuowenSeal-ChenChangzhi",
    "QJZ": "ShuowenSeal-XuKai",
    "DYC": "ShuowenSeal-DuanYucai",
    "THX": "ShuowenSeal-TengHuaShu",
}


def fix_ttf(path: Path) -> None:
    f = TTFont(str(path), recalcBBoxes=False)
    upem = f["head"].unitsPerEm
    glyf = f["glyf"]
    glyph_set = f.getGlyphSet()
    hmtx = f["hmtx"]
    target_h = INK_H * upem
    target_w = INK_W * upem
    n_scaled = n_full = 0
    for name in f.getGlyphOrder():
        g = glyf[name]
        if getattr(g, "numberOfContours", 0) == 0:
            # 空字形也统一全角步进
            hmtx[name] = (upem, hmtx[name][1])
            n_full += 1
            continue
        h = g.yMax - g.yMin
        w = g.xMax - g.xMin
        if h <= 0 or w <= 0:
            continue
        # 高度归一为主、宽度封顶（横扁字如「一」不撑爆步进）
        s = min(target_h / h, target_w / w)
        if abs(s - 1.0) > 0.01:
            n_scaled += 1
        # 缩放后水平居中于 0.5em，垂直顶对齐 TOP、底随高度
        new_w = w * s
        tx = 0.5 * upem - new_w / 2 - g.xMin * s
        ty = TOP * upem - g.yMax * s
        pen = TTGlyphPen(glyph_set)
        tpen = TransformPen(pen, (s, 0, 0, s, tx, ty))
        glyph_set[name].draw(tpen)
        glyf[name] = pen.glyph()
        # 重新计算 bbox（TTGlyphPen 产物不带坐标缓存）
        ng = glyf[name]
        ng.recalcBounds(f)
        hmtx[name] = (upem, ng.xMin)
        n_full += 1
    # 垂直度量与行高
    f["hhea"].ascent = int(TOP * upem)
    f["hhea"].descent = int(BOT * upem)
    f["hhea"].lineGap = 0
    os2 = f["OS/2"]
    os2.sTypoAscender = int(TOP * upem)
    os2.sTypoDescender = int(BOT * upem)
    os2.sTypoLineGap = 0
    os2.usWinAscent = int(TOP * upem)
    os2.usWinDescent = int(-BOT * upem)
    # 修后 head/字形的 bbox 缓存
    f.save(str(path) + ".fixed")
    fixed = TTFont(str(path) + ".fixed", recalcBBoxes=False)
    fixed["head"] = f["head"]  # 保持
    fixed.save(str(path))
    Path(str(path) + ".fixed").unlink()
    print(f"  {path.name}: 缩放 {n_scaled} 字形，全角步进 {n_full}")


def set_chinese_names(font, zh: str, ps: str) -> None:
    """name 表全中文（Windows 平台 UCS-2，简中/英文语言位同名）；
    仅 nameID 6（PostScript）按规范保留 ASCII。"""
    name = font["name"]
    name.names = []
    for nid, val in [(1, zh), (2, "常规"), (3, zh), (4, zh)]:
        name.setName(val, nid, 3, 1, 0x409)
        name.setName(val, nid, 3, 1, 0x804)
    name.setName(ps, 6, 3, 1, 0x409)


def main() -> int:
    import build_fonts  # zhuan 项目：ttf_to_otf

    for slot in ZH_NAMES:
        src = ZHAN / f"shuowen-seal-{slot}.ttf"
        if not src.exists():
            print(f"  跳过缺失的 {src.name}")
            continue
        print(f"修复 {src.name} …")
        fix_ttf(src)
        otf = build_fonts.ttf_to_otf(src)
        from fontTools.ttLib import TTFont as _F
        font = _F(str(otf))
        set_chinese_names(font, ZH_NAMES[slot], PS_NAMES[slot])
        dest = ZHAN / f"{ZH_NAMES[slot]}.otf"
        font.save(str(dest))
        font.close()
        src.unlink()   # 中间 TTF 不交付
        otf.unlink()   # 旧英文名 OTF
        print(f"  → {dest.name}")
    print("完成：四款中文名 OTF（中间 TTF 已清理）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
