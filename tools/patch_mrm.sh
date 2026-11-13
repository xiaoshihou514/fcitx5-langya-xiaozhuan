#!/usr/bin/env bash
# 主题 .mrm DRM 免检补丁 v2 —— 自动发现活动条目 + 状态诊断。
#
# 用法：
#   bash tools/patch_mrm.sh          # 自动找最新 .mrm 打补丁
#   bash tools/patch_mrm.sh status   # 诊断字体链路状态（不改动）
#
# 背景：每次「应用」动作会重建条目（新 uuid、干净 .mrm），补丁失效
# （真机反复掉补丁的根因）。v2 自动定位当前条目；配合 apply 提示。
set -euo pipefail
BASE='/sdcard/Android/data/com.android.thememanager/files/MIUI/theme/.data'

# 找最新 .mrm（排除预置 b004d74e）
find_active() {
    adb shell "ls -t '$BASE/meta/fonts/'" | tr -d '\r' \
        | grep -v '^b004d74e' | head -1 | sed 's/\.mrm$//'
}

status() {
    local id
    id=$(find_active)
    echo "── 活动条目：$id"
    adb shell "grep -m1 -o '\"contentPath\": \"[^\"]*\"' \
        '$BASE/meta/fonts/$id.mrm'" 2>/dev/null \
        || echo "contentPath: null（未打补丁）"
    echo "── 字体落位："
    adb shell "ls -la /data/system/theme/fonts/Roboto-Regular.ttf \
        /data/system/fonts/theme_webview/Roboto-Regular.ttf 2>&1" | head -4
    echo "── 是否需要应用：看上面两行是否齐全＋symlink 指向"
}

patch() {
    local id m c
    id=$(find_active)
    m="$BASE/meta/fonts/$id.mrm"
    c="$BASE/content/fonts/$id.mrc"
    echo "补丁对象：$id"
    adb shell "test -f '$c'" || { echo "✗ 对应 .mrc 不存在"; exit 1; }
    adb shell "cp '$m' '/sdcard/Download/$id.mrm.bak'" 2>/dev/null || true
    # 若已有 contentPath（重建前的补丁残留），先还原 null 再打（幂等）
    adb shell "toybox sed -i 's|\"contentPath\": \"[^\"]*\"|\"contentPath\": null|' '$m'"
    adb shell "toybox sed -i 's|\"contentPath\": null|\"contentPath\": \"/system/../$c\"|' '$m'"
    adb shell "grep -m1 -o '\"contentPath\": \"[^\"]*\"' '$m'"
    adb shell am force-stop com.android.thememanager
    echo "✓ 已补丁并强杀主题 app"
    echo "→ 手机上重新打开主题壁纸，对「说文小篆」点「应用」"
}

case "${1:-patch}" in
    status) status ;;
    patch)  patch ;;
esac
