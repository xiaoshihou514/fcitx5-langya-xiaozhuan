#!/usr/bin/env bash
# 重建 /tmp/fcitx5root —— 本地 fcitx5 运行时/开发前缀（无 root）。
# /tmp 重启即清，此脚本可重复运行（幂等）。
# 产出：头文件、libFcitx5*、libIME*、addon 运行库、cmake/pkgconfig、
#       libime 数据（zh_CN.lm 来自 RPM；sc.dict 从手机宿主 APK 提取）
set -euo pipefail
ROOT=/tmp/fcitx5root
RPM=/tmp/fcitx5rpm
mkdir -p "$ROOT" "$RPM"

need() { rpm -q --whatprovides "$1" >/dev/null 2>&1 || rpm -q "$1" >/dev/null 2>&1; }

echo "── 下载 RPM（若缓存缺失）──"
cd "$RPM"
for spec in fcitx5-libs fcitx5-devel fcitx5 fcitx5-data \
            extra-cmake-modules libime libime-devel boost-devel; do
    # 仅当解包目标缺关键文件时下载
    if ! ls "$ROOT/usr/lib64/libFcitx5Core.so" >/dev/null 2>&1 \
       || ! ls "$ROOT/usr/lib64/libIMECore.so" >/dev/null 2>&1 \
       || ! ls "$ROOT/usr/share/fcitx5/addon/classicui.conf" >/dev/null 2>&1 \
       || ! ls "$ROOT/usr/include/LibIME" >/dev/null 2>&1 \
       || ! ls "$ROOT/usr/include/boost" >/dev/null 2>&1; then
        dnf download --destdir . "$spec" 2>/dev/null | tail -1 || true
    fi
done
ls *.rpm >/dev/null 2>&1 || { echo "无 RPM 可解包"; exit 1; }

echo "── 解包到 $ROOT/usr ──"
for r in *.rpm; do
    rpm2cpio "$r" | cpio -idm --quiet -D "$ROOT" 2>/dev/null || \
    (cd "$ROOT" && rpm2cpio "$RPM/$r" | cpio -idm --quiet) || true
done

echo "── 修补绝对路径（RPM 内置 /usr → 本前缀）──"
# pkgconfig：libdir/includedir 常为绝对路径
for pc in "$ROOT/usr/lib64/pkgconfig/"*.pc; do
    [ -f "$pc" ] || continue
    sed -i "s|^prefix=/usr$|prefix=$ROOT/usr|; \
             s|^libdir=/usr/lib64|libdir=\${prefix}/lib64|; \
             s|^includedir=/usr/include|includedir=\${prefix}/include|; \
             s|^libdir=/usr/lib\$|libdir=\${prefix}/lib|" "$pc"
done
# cmake 导入目标里的绝对路径
grep -rl '"/usr/include\|"/usr/lib64' "$ROOT/usr/lib64/cmake/" 2>/dev/null | \
    while read -r f; do sed -i "s|\"/usr/|\"$ROOT/usr/|g" "$f"; done
# libime 的 zh_CN.lm 归位（rpm 装在 lib64/libime）
mkdir -p "$ROOT/usr/share/libime"
cp -n "$ROOT"/usr/lib64/libime/zh_CN.lm* "$ROOT/usr/share/libime/" 2>/dev/null || true

echo "── sc.dict（宿主 APK 提取）──"
if [ ! -s "$ROOT/usr/share/libime/sc.dict" ]; then
    APK=$(mktemp -u /tmp/host.XXXX.apk)
    p=$(adb shell pm path org.fcitx.fcitx5.android 2>/dev/null \
        | head -1 | sed 's/package://' | tr -d '\r')
    if [ -n "$p" ]; then
        adb pull "$p" "$APK" >/dev/null 2>&1
        unzip -o -j "$APK" 'assets/usr/share/libime/sc.dict' \
            -d "$ROOT/usr/share/libime/" >/dev/null
        rm -f "$APK"
        echo "  sc.dict 已从手机提取"
    else
        echo "  ⚠ 手机未连接，跳过 sc.dict（engine-test 需它）"
    fi
fi

echo "── 验证 ──"
export PKG_CONFIG_PATH="$ROOT/usr/lib64/pkgconfig"
pkg-config --modversion Fcitx5Core Fcitx5Utils
ls "$ROOT/usr/lib64/libIMECore.so" "$ROOT/usr/share/libime/sc.dict" \
   "$ROOT/usr/share/libime/zh_CN.lm" >/dev/null && echo "✓ fcitx5root 就绪"
