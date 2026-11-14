#!/usr/bin/env bash
# 琅琊小篆 · 用户级安装（无需 root，装到 ~/.local）
#
#   ./install.sh             安装／升级
#   ./install.sh --uninstall 卸载
#
# 前提：系统已装 fcitx5（5.1 及以上）。拼音内核 libime、词典与语言模型、
# 标点／简繁模块：系统已有（如装了 fcitx5-chinese-addons）则直接复用，
# 缺失时取包内 bundle/ 补齐——不复制、不遮蔽系统已有的任何文件。
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
B="$HERE/bundle"
PREFIX="$HOME/.local"
LIBDIR="$PREFIX/lib/fcitx5"
SHARE="${XDG_DATA_HOME:-$PREFIX/share}"
CONF="${XDG_CONFIG_HOME:-$HOME/.config}"
ENVD="$CONF/environment.d/langya-fcitx5.conf"
MANIFEST="$SHARE/fcitx5/langya/installed-files.list"

uninstall() {
    if [[ -f "$MANIFEST" ]]; then
        while IFS= read -r f; do [[ -n "$f" ]] && rm -f "$f"; done < "$MANIFEST"
        rm -f "$MANIFEST"
        rmdir "$SHARE/fcitx5/langya" 2>/dev/null || true
        echo "已卸载琅琊小篆（重新登录后生效）"
    else
        echo "未找到安装清单，可能未安装"
    fi
}
[[ "${1:-}" == "--uninstall" ]] && { uninstall; exit 0; }

# ── 探测系统 fcitx5 ──
SYSADDON=""
for d in /usr/lib64/fcitx5 /usr/lib/x86_64-linux-gnu/fcitx5 /usr/lib/fcitx5 \
         /usr/local/lib64/fcitx5 /usr/local/lib/fcitx5; do
    [[ -f "$d/libkeyboard.so" || -f "$d/libclassicui.so" ]] && { SYSADDON="$d"; break; }
done
if [[ -z "$SYSADDON" ]]; then
    echo "未检测到 fcitx5：请先用系统包管理器安装 fcitx5" >&2
    exit 1
fi
SYSSHARE="$(cd "$SYSADDON/../.." && pwd)/share"
[[ -d "$SYSSHARE/fcitx5" ]] || SYSSHARE=/usr/share

[[ -f "$MANIFEST" ]] && uninstall >/dev/null
files=()
put() { install -Dm"$1" "$2" "$3"; files+=("$3"); }
note() { echo "  · $*"; }

# ── 琅琊本体 ──
put 755 "$HERE/lib/fcitx5/langya.so"                 "$LIBDIR/langya.so"
put 644 "$HERE/share/fcitx5/addon/langya.conf"       "$SHARE/fcitx5/addon/langya.conf"
put 644 "$HERE/share/fcitx5/inputmethod/langya.conf" "$SHARE/fcitx5/inputmethod/langya.conf"
put 644 "$HERE/share/fcitx5/langya/langya.map"       "$SHARE/fcitx5/langya/langya.map"
put 644 "$HERE/share/icons/hicolor/scalable/apps/langya.svg" \
        "$SHARE/icons/hicolor/scalable/apps/langya.svg"

# ── libime 库（引擎 RUNPATH=$ORIGIN，缺失时放同目录）──
if ldconfig -p 2>/dev/null | grep -q 'libIMEPinyin.so.0 '; then
    note "系统已有 libime，复用"
else
    for so in "$B"/lib/*; do put 755 "$so" "$LIBDIR/$(basename "$so")"; done
    note "补齐 libime 库"
fi

# ── 拼音词典 sc.dict（XDG Data 查找）──
if [[ -f /usr/share/libime/sc.dict || -f /usr/local/share/libime/sc.dict ]]; then
    note "系统已有拼音词典，复用"
else
    put 644 "$B/libime/sc.dict" "$SHARE/libime/sc.dict"
    note "补齐拼音词典 sc.dict"
fi

# ── 语言模型 zh_CN.lm（libime 按 LIBIME_MODEL_DIRS／编译期目录查找）──
MODELDIR=""
for d in /usr/lib64/libime /usr/lib/x86_64-linux-gnu/libime /usr/lib/libime; do
    [[ -f "$d/zh_CN.lm" ]] && { MODELDIR="$d"; break; }
done
EXTRA_ENV=""
if [[ -n "$MODELDIR" ]]; then
    note "系统已有语言模型，复用"
else
    put 644 "$B/libime/zh_CN.lm"         "$SHARE/libime/zh_CN.lm"
    put 644 "$B/libime/zh_CN.lm.predict" "$SHARE/libime/zh_CN.lm.predict"
    EXTRA_ENV="LIBIME_MODEL_DIRS=$SHARE/libime"
    note "补齐语言模型 zh_CN.lm"
fi

# ── punctuation（必需）与 chttrans（可选，需系统 OpenCC）──
for m in punctuation chttrans; do
    if [[ -f "$SYSADDON/lib$m.so" ]]; then
        note "系统已有 $m 模块，复用"; continue
    fi
    if ldd "$B/addon/lib$m.so" | grep -q "not found"; then
        note "跳过 $m 模块（缺依赖：$(ldd "$B/addon/lib$m.so" | awk '/not found/{print $1}' | xargs)）"
        continue
    fi
    put 755 "$B/addon/lib$m.so" "$LIBDIR/lib$m.so"
    for dep in "$B"/addon/libboost_* "$B"/addon/libbz2*; do   # 模块 RUNPATH=$ORIGIN
        [[ -f "$LIBDIR/$(basename "$dep")" ]] || put 755 "$dep" "$LIBDIR/$(basename "$dep")"
    done
    dst="$SHARE/fcitx5/addon/$m.conf"
    mkdir -p "$(dirname "$dst")"
    if [[ $m == chttrans ]]; then
        # 剥离 notifications 可选依赖（单独装时不存在，等待会卡住）；随启动加载
        sed -e '/^\[Addon\/OptionalDependencies\]/,/^$/{/notifications/d}' \
            -e 's/OnDemand=True/OnDemand=False/' "$B/share/fcitx5/addon/$m.conf" > "$dst"
        files+=("$dst")
    else
        put 644 "$B/share/fcitx5/addon/$m.conf" "$dst"
    fi
    for f in "$B/share/fcitx5/$m"/*; do
        put 644 "$f" "$SHARE/fcitx5/$m/$(basename "$f")"
    done
    note "补齐 $m 模块"
done

# ── 简繁档位（港繁 s2hk）：用户已有配置则不覆盖 ──
if [[ ! -f "$CONF/fcitx5/conf/chttrans.conf" ]]; then
    put 644 "$HERE/config/chttrans.conf" "$CONF/fcitx5/conf/chttrans.conf"
fi

# ── 环境变量：fcitx5 默认不搜 ~/.local/lib/fcitx5（重新登录生效）──
mkdir -p "$(dirname "$ENVD")"
{ echo "FCITX_ADDON_DIRS=$LIBDIR:$SYSADDON"; [[ -n "$EXTRA_ENV" ]] && echo "$EXTRA_ENV"; } > "$ENVD"
files+=("$ENVD")

if ldd "$LIBDIR/langya.so" | grep -q "not found"; then
    echo "警告：引擎仍有未满足的依赖：" >&2
    ldd "$LIBDIR/langya.so" | grep "not found" >&2
fi

printf '%s\n' "${files[@]}" > "$MANIFEST"
gtk-update-icon-cache -q -t "$SHARE/icons/hicolor" 2>/dev/null || true
cat <<EOF
✓ 琅琊小篆 $(cat "$HERE/VERSION")（$(cat "$HERE/COMMIT")）已安装到 $PREFIX
  1. 注销并重新登录（使环境变量生效）
  2. 系统设置 → 输入法 → 添加「琅琊小篆」
  显示小篆需安装说文小篆字体：
  https://github.com/xiaoshihou514/xiaozhuan_unicode_fonts/releases/latest
EOF
