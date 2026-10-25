#!/usr/bin/env bash
# 主题 .mrm 元数据 DRM 免检补丁（HyperOS 3 逆向成果）。
#
# 原理（反编译 com.android.thememanager ThemeHelper.g → DrmService.q）：
#   DRM 校验在 contentPath 以 /system 开头时直接放行：
#     if (new File(contentPath).getAbsolutePath().startsWith("/system"))
#         return DRM_SUCCESS;
#   File.getAbsolutePath() 不解析 ".."，而实际文件 IO 由内核解析——
#   注入 "/system/../sdcard/..." 路径遍历：DRM 以为内容在 /system，
#   应用层实际读取我们的 .mrc 字体。
#
# 用法：bash tools/patch_mrm.sh [localId]   # 默认最新的 ec98f9a5…
# 前置：字体 mtz 已导入（.mrc/.mrm 已生成），手机已连 adb。
# 恢复：adb shell "cp /sdcard/Download/ec98.mrm.bak <mrm路径>"
set -euo pipefail
BASE='/sdcard/Android/data/com.android.thememanager/files/MIUI/theme/.data'
ID="${1:-ec98f9a5-947b-42fb-af4e-86ad3d77a949}"
M="$BASE/meta/fonts/$ID.mrm"

adb shell "test -f '$M' && cp '$M' '/sdcard/Download/$ID.mrm.bak'"
# 只替换顶层 contentPath（第一处 null）
adb shell "toybox sed -i '0,/\"contentPath\": null/s|\"contentPath\": null|\"contentPath\": \"/system/../$BASE/content/fonts/$ID.mrc\"|' '$M'"
echo "已补丁：$M"
adb shell "grep -m1 -o '\"contentPath\": \"[^\"]*\"' '$M'"
echo "备份：/sdcard/Download/$ID.mrm.bak"
echo "下一步：主题壁纸 → 我的字体 → 说文小篆 → 应用；观察 logcat 'check rights isLegal'"
