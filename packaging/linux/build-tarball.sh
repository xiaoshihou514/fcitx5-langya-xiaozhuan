#!/usr/bin/env bash
# 构建桌面便携包：langya-<ver>-linux-x86_64.tar.gz
#
# 在 Ubuntu 24.04（fcitx5 5.1.7）上编译：fcitx5 5.x ABI 向后兼容，
# 老版本头文件编出的插件可在更新的发行版 fcitx5 5.1+ 上加载。
# 包内：琅琊自身（引擎 .so、注册配置、映射表、图标）＋安装脚本，
# 另附 bundle/（libime 库与词典/语言模型、punctuation、chttrans 模块）——
# 很多用户只装 Rime 不装 fcitx5-chinese-addons，安装脚本仅在系统缺失时
# 才取用 bundle，系统已有则不复制、不遮蔽。
#
# 用法（仓库根）：packaging/linux/build-tarball.sh [版本号]
# 依赖（Debian/Ubuntu）：见 .github/workflows/nightly.yml 的 apt 列表
set -euo pipefail
cd "$(dirname "$0")/../.."
VER="${1:-dev}"
NAME="langya-${VER}-linux-x86_64"
OUT="dist/${NAME}"

rm -rf build-pkg "dist/${NAME}" "dist/${NAME}.tar.gz"
cmake -B build-pkg -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr \
      -DCMAKE_INSTALL_LIBDIR=lib
cmake --build build-pkg -j"$(nproc)"
DESTDIR="$PWD/build-pkg/root" cmake --install build-pkg

R=build-pkg/root/usr
mkdir -p "$OUT"
install -Dm755 "$(find "$R" -name langya.so | head -1)" "$OUT/lib/fcitx5/langya.so"
# RUNPATH=$ORIGIN：系统缺 libime 时，安装脚本把 bundle 里的 libIME*.so 放同目录
patchelf --set-rpath '$ORIGIN' "$OUT/lib/fcitx5/langya.so"
install -Dm644 "$R/share/fcitx5/addon/langya.conf"       "$OUT/share/fcitx5/addon/langya.conf"
install -Dm644 "$R/share/fcitx5/inputmethod/langya.conf" "$OUT/share/fcitx5/inputmethod/langya.conf"
install -Dm644 data/langya.map                           "$OUT/share/fcitx5/langya/langya.map"
install -Dm644 icons/scalable/apps/langya.svg            "$OUT/share/icons/hicolor/scalable/apps/langya.svg"
install -Dm644 core/chttrans.conf                        "$OUT/config/chttrans.conf"
install -Dm755 packaging/linux/install.sh                "$OUT/install.sh"
install -Dm644 LICENSE                                   "$OUT/LICENSE"
# ── bundle：取自构建机（Ubuntu 24.04）系统包 ──
A=/usr/lib/x86_64-linux-gnu
B="$OUT/bundle"
for so in libIMECore.so.0 libIMEPinyin.so.0; do
    install -Dm755 "$(readlink -f "$A/$so")" "$B/lib/$so"
done
for m in punctuation chttrans; do
    install -Dm755 "$A/fcitx5/lib$m.so" "$B/addon/lib$m.so"
    patchelf --set-rpath '$ORIGIN' "$B/addon/lib$m.so"
    install -Dm644 "/usr/share/fcitx5/addon/$m.conf" "$B/share/fcitx5/addon/$m.conf"
done
# 两模块依赖的 boost_iostreams（版本随发行版变，各家 soname 不同）一并附带
bio=$(ldd "$A/fcitx5/libpunctuation.so" | awk '/boost_iostreams/{print $3}')
install -Dm755 "$(readlink -f "$bio")" "$B/addon/$(basename "$bio")"
patchelf --set-rpath '$ORIGIN' "$B/addon/$(basename "$bio")"
# Debian 系 soname 为 libbz2.so.1.0（Fedora/Arch 为 libbz2.so.1），附带一份
bz=$(ldd "$bio" | awk '/libbz2/{print $3}')
install -Dm755 "$(readlink -f "$bz")" "$B/addon/$(basename "$bz")"
cp -r /usr/share/fcitx5/punctuation /usr/share/fcitx5/chttrans "$B/share/fcitx5/"
install -Dm644 /usr/share/libime/sc.dict "$B/libime/sc.dict"
install -Dm644 "$A/libime/zh_CN.lm"         "$B/libime/zh_CN.lm"
install -Dm644 "$A/libime/zh_CN.lm.predict" "$B/libime/zh_CN.lm.predict"

git rev-parse --short HEAD > "$OUT/COMMIT" 2>/dev/null || echo unknown > "$OUT/COMMIT"
echo "$VER" > "$OUT/VERSION"

tar -C dist -czf "dist/${NAME}.tar.gz" "$NAME"
echo "dist/${NAME}.tar.gz"
