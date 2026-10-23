#!/usr/bin/env python3
"""生成琅琊输入法词典 data/langya.tsv。

数据源与合成策略：
  1. rime luna_pinyin.dict.yaml（LGPL-3.0）
     - 单字段：字 → 拼音码（多音字多行，带相对频率标注 N%）
     - 词组段：生僻词 → 码（直接收录，权重 0 排桶尾）
  2. rime essay.txt 八股文词频表（LGPL-3.0）：常用词组只有「词→权重」
     没有拼音码（Rime 构建时按字音合成），此处同样合成：
     词码 = 每字主音码拼接（主音 = 相对频率最高的码，无标注视作 100%）
  3. zhuan 项目的 seal.db 查表链（别名 → 本字 → 变体闭包 → 說文對位
     → OpenCC 简繁 → 借聲符）：每个汉字 → (小篆码点, 楷化字)

显示层：词头经 OpenCC 转简体作 src（原词繁体仅用于查表）。
說文未收的字按原字回退并打 miss 标记（候选窗口显示「說文未收」）。

输出 TSV（制表符分隔，UTF-8，6 列，同拼音桶按权重降序）：
  拼音（无空格连打）\t 原词 \t 小篆输出 \t 楷化输出 \t 权重 \t 标记

用法（在 langya/ 下）：
  ./tools/download_dict.sh
  uv run --project ../zhuan python tools/export_data.py
"""
from __future__ import annotations

import argparse
import sys
from collections import defaultdict
from pathlib import Path

HERE = Path(__file__).resolve().parent
LANGYA = HERE.parent
sys.path.insert(0, str(LANGYA.parent / "zhuan"))

DEFAULT_DICT = HERE / "cache" / "luna_pinyin.dict.yaml"
DEFAULT_ESSAY = HERE / "cache" / "essay.txt"
DEFAULT_OUT = LANGYA / "data" / "langya.tsv"

VALID_CODE = __import__("re").compile(r"^[a-z]+( [a-z]+)*$")


def is_hanzi(word: str) -> bool:
    return bool(word) and all(
        "\u3400" <= c <= "\u9fff" or "\U00020000" <= c <= "\U0002ffff"
        for c in word)


def parse_luna(path: Path):
    """返回 (单字: 字→[(码, 相对频率)]，词组: [(词, 码)])。"""
    char_codes: dict[str, list[tuple[str, int]]] = defaultdict(list)
    word_entries: list[tuple[str, str]] = []
    in_body = False
    for line in path.read_text(encoding="utf-8").splitlines():
        if not in_body:
            if line.strip() == "...":
                in_body = True
            continue
        if not line or line.startswith("#"):
            continue
        cols = line.split("\t")
        if len(cols) < 2:
            continue
        word, code = cols[0], cols[1].strip().lower()
        if not is_hanzi(word) or not VALID_CODE.match(code):
            continue
        # 可选第三列：多音字的相对频率标注（"0%"/"100%"）
        freq = 100
        if len(cols) > 2 and cols[2].endswith("%"):
            try:
                freq = int(cols[2][:-1])
            except ValueError:
                pass
        if len(word) == 1:
            char_codes[word].append((code, freq))
        else:
            word_entries.append((word, code))
    return char_codes, word_entries


def parse_essay(path: Path) -> dict[str, int]:
    weights = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        cols = line.split("\t")
        if len(cols) != 2:
            continue
        try:
            weights[cols[0]] = int(cols[1])
        except ValueError:
            continue
    return weights


def main() -> int:
    ap = argparse.ArgumentParser(description="生成琅琊输入法词典")
    ap.add_argument("--dict", type=Path, default=DEFAULT_DICT)
    ap.add_argument("--essay", type=Path, default=DEFAULT_ESSAY)
    ap.add_argument("--out", type=Path, default=DEFAULT_OUT)
    ap.add_argument("--min-word-weight", type=int, default=100,
                    help="essay 词组收录的最低权重")
    ap.add_argument("--max-per-pinyin", type=int, default=30,
                    help="同一拼音桶保留的最大候选数")
    args = ap.parse_args()

    for p in (args.dict, args.essay):
        if not p.exists():
            sys.exit(f"缺数据文件 {p}，先运行 tools/download_dict.sh")

    import opencc  # zhuan 环境内
    from zhuan import ZhuanConverter  # noqa: E402

    t2s = opencc.OpenCC("t2s")
    cv = ZhuanConverter()
    cache: dict[str, tuple[str, str] | None] = {}  # 字 → (小篆, 楷化) | None

    def convert_char(ch: str) -> tuple[str, str] | None:
        if ch not in cache:
            m = cv.lookup(ch)
            if m is None:
                cache[ch] = None
            else:
                seal = chr(m.seal_cp)
                kai = m.kaishu_char if m.kaishu_char else ch
                cache[ch] = (seal, kai)
        return cache[ch]

    char_codes, word_entries = parse_luna(args.dict)
    weights = parse_essay(args.essay)
    # 主音码：相对频率最高（同分取先出现）
    main_code = {c: max(codes, key=lambda t: t[1])[0]
                 for c, codes in char_codes.items()}
    print(f"luna 单字 {len(char_codes)}，luna 词组 {len(word_entries)}，"
          f"essay 词 {len(weights)}", file=sys.stderr)

    def synth_code(word: str) -> str | None:
        parts = []
        for ch in word:
            code = main_code.get(ch)
            if code is None:
                return None
            parts.append(code)
        return "".join(parts)

    # 收录集合：(码, 繁体词) → 权重
    entries: dict[tuple[str, str], int] = {}
    # 1) essay 词组（合成码）
    n_synth = 0
    for word, weight in weights.items():
        if len(word) < 2 or not is_hanzi(word):
            continue
        if weight < args.min_word_weight:
            continue
        code = synth_code(word)
        if code is None:
            continue
        key = (code, word)
        if key not in entries or entries[key] < weight:
            entries[key] = weight
        n_synth += 1
    # 2) essay 单字（真实多码全收）
    for word, weight in weights.items():
        if len(word) == 1 and is_hanzi(word):
            for code, _freq in char_codes.get(word, []):
                key = (code, word)
                if key not in entries or entries[key] < weight:
                    entries[key] = weight
    # 3) luna 词组段（生僻词，权重 0）
    for word, code in word_entries:
        entries.setdefault((code, word), 0)
    # 4) luna 单字（未进 essay 的字补录，权重 0）
    for ch, codes in char_codes.items():
        for code, _freq in codes:
            entries.setdefault((code, ch), 0)
    print(f"合成 essay 词组 {n_synth}，总收录 {len(entries)} 条",
          file=sys.stderr)

    buckets: dict[str, list[tuple[int, str, str, str, bool]]] = defaultdict(list)
    miss_chars: set[str] = set()
    n_miss = 0
    for (code, word), weight in entries.items():
        src = t2s.convert(word)
        seal_parts, kai_parts = [], []
        miss = False
        for ch in word:  # 用繁体原词查表（链路对繁体最优）
            r = convert_char(ch)
            if r is None:
                miss = True
                miss_chars.add(ch)
                seal_parts.append(ch)
                kai_parts.append(ch)
            else:
                seal_parts.append(r[0])
                kai_parts.append(r[1])
        if miss:
            n_miss += 1
        buckets[code].append((weight, src, "".join(seal_parts),
                              "".join(kai_parts), miss))

    out_lines: list[str] = []
    for key in sorted(buckets):
        seen: set[str] = set()
        ranked = sorted(enumerate(buckets[key]),
                        key=lambda t: (-t[1][0], t[0]))
        for _i, (weight, src, seal, kai, miss) in ranked[: args.max_per_pinyin]:
            if src in seen:
                continue
            seen.add(src)
            flag = "miss" if miss else ""
            out_lines.append(
                f"{key}\t{src}\t{seal}\t{kai}\t{weight}\t{flag}")

    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text("\n".join(out_lines) + "\n", encoding="utf-8")

    total_chars = len(cache)
    hit_chars = sum(1 for v in cache.values() if v)
    print(f"输出 {args.out}（{args.out.stat().st_size // 1024} KiB）："
          f"拼音键 {len(buckets)} 个，候选项 {len(out_lines)}，"
          f"含未收回退 {n_miss} 条", file=sys.stderr)
    print(f"用字覆盖 {hit_chars}/{total_chars}"
          f"（{100.0 * hit_chars / max(1, total_chars):.1f}%）", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
