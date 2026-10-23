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
    dest = HERE.parent / "data" / "langya.map"
    dest.write_text("\n".join(out_lines) + "\n", encoding="utf-8")
    print(f"映射 {len(out_lines)} 字（未收 {miss}），→ {dest}"
          f"（{dest.stat().st_size // 1024} KiB）", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
