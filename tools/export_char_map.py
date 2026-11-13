#!/usr/bin/env python3
"""导出全字映射 data/langya.map：汉字 → (小篆码点, 楷化字)。

供 C++ 引擎选词后逐字转换（查表链在导出时预跑，运行时零依赖）。
字符集：rime 单字表（luna 全部读音字）∪ seal_char 的 mcjk。
格式：汉字\tseal_hex\tkai（UTF-8 TSV；未收字不输出，引擎回退原字）
"""
from __future__ import annotations

import sqlite3
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent.parent / "zhuan"))

from zhuan import ZhuanConverter  # noqa: E402


def main() -> int:
    cv = ZhuanConverter()
    # 字符集：seal.db 直接给的全量 + luna 单字表兜底
    chars: set[str] = set()
    con = sqlite3.connect(HERE.parent.parent / "zhuan" / "seal.db")
    for (mc,) in con.execute(
            "SELECT mcjk_char FROM seal_char WHERE mcjk_char IS NOT NULL"):
        chars.add(mc)
    for (ch,) in con.execute("SELECT char FROM aliases"):
        chars.add(ch)
    dict_yaml = HERE / "cache" / "luna_pinyin.dict.yaml"
    if dict_yaml.exists():
        in_body = False
        for line in dict_yaml.read_text(encoding="utf-8").splitlines():
            if not in_body:
                if line.strip() == "...":
                    in_body = True
                continue
            word = line.split("\t")[0]
            if len(word) == 1:
                chars.add(word)

    out_lines = []
    miss = 0
    for ch in sorted(chars):
        m = cv.lookup(ch)
        if m is None:
            miss += 1
            continue
        kai = m.kaishu_char or ch
        out_lines.append(f"{ch}\t{m.seal_cp:X}\t{kai}")
    # 应用覆盖（白名单机制）：改写指定字的码位
    overrides_pre = {"亲": 0x3E8DB}
    for i, line in enumerate(out_lines):
        ch = line.split("\t")[0]
        if ch in overrides_pre:
            cols = line.split("\t")
            cols[1] = f"{overrides_pre[ch]:X}"
            out_lines[i] = "\t".join(cols)

    dest = HERE.parent / "data" / "langya.map"
    dest.write_text("\n".join(out_lines) + "\n", encoding="utf-8")
    print(f"映射 {len(out_lines)} 字（未收 {miss}），→ {dest}"
          f"（{dest.stat().st_size // 1024} KiB）", file=sys.stderr)

    # ── 常用字黄金表门禁（审计 D1 建议）────────────────────────
    # 期望值人工核对自 U3D000.pdf 码表（与 fonts/data/黄金映射.tsv
    # 同源），防止 zhuan 查表链回归再次污染词典（变体链曾优先于
    # 字头本字，导致 二→上、光→水 等）。不匹配即导出失败。
    # 「难→3DAB3 鳥」：說文「難，鳥也」，鸟形即本义正形（lead 裁定
    # 保留并白名单豁免，用户感知差异已文档注明）；
    # 「滚」：後起字，說文未收——正确行为为「說文未收」回退
    # （font-lead 已核实变体边 滚→𬺤→玄 系数据残留错误并删除，
    # modern_map 重导后滚不再映射）；黄金表按未收断言。
    # 「他/她」：人工裁定 3F834。
    golden = {
        "一": 0x3D000, "二": 0x3F850, "三": 0x3D066,
        "上": 0x3D008, "下": 0x3D011,
        "光": 0x3ED49, "白": 0x3E657, "無": 0x3F590,
        "草": 0x3D304, "煙": 0x3ED2C, "關": 0x3F2CA,
        "親": 0x3E8DB, "詳": 0x3D6B6, "壹": 0x3EDE2,
        "面": 0x3E9A7, "永": 0x3F188, "龍": 0x3F268,
        "水": 0x3EF5E, "山": 0x3EA5A, "木": 0x3DFA9,
        "人": 0x3E66C, "舌": 0x3D429,
        "的": 0x3E300,   # 說文正形「旳」
        "难": 0x3DAB3,   # 說文「難，鳥也」，本义正形（裁定保留）
        "滚": "",        # 說文未收：必须回退（不得映射任何码位）
        "他": 0x3F834,   # 人工裁定
        "她": 0x3F834,   # 人工裁定
    }

    gold_bad = []
    table = {}
    for line in out_lines:
        cols = line.split("\t")
        table[cols[0]] = cols[1]
    for ch, want in golden.items():
        got = table.get(ch)
        if want == "":
            if got is not None:
                gold_bad.append(
                    f"{ch}: 說文未收字不得映射（实际 U+{got}）")
            continue
        if got is None:
            gold_bad.append(f"{ch}: 查表链未收（期望 U+{want:X}）")
        elif int(got, 16) != want:
            gold_bad.append(f"{ch}: 得 U+{got} 期望 U+{want:X}")
    if gold_bad:
        print("黄金表门禁失败（查表链回归？）：", file=sys.stderr)
        for b in gold_bad:
            print(f"  ✗ {b}", file=sys.stderr)
        dest.unlink(missing_ok=True)
        return 1
    print(f"黄金表门禁通过（{len(golden)} 字）", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
