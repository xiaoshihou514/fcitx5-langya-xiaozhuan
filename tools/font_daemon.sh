#!/usr/bin/env bash
# 字体掉落守护：轮询 theme_webview symlink，检测到回退即自动恢复。
#
# 根因（已破案）：configuration change（转屏/分屏/深色切换）触发
# framework 重新校验主题字体的 rights——无授权即回退默认。
# 恢复动作：强杀主题 app → 深链打开字体列表 → input 点应用。
#
# 用法（电脑连着手机时）：bash tools/font_daemon.sh [&]
set -uo pipefail
OK_LINK='/data/system/theme/fonts/Roboto-Regular.ttf'
FONT_TAB='theme://zhuti.xiaomi.com/themeActivity/'
LOG=/tmp/font_daemon.log

healthy() {
    [ "$(adb shell readlink \
        /data/system/fonts/theme_webview/Roboto-Regular.ttf 2>/dev/null \
        | tr -d '\r')" = "$OK_LINK" ]
}

restore() {
    echo "[$(date '+%m-%d %H:%M:%S')] 检测到掉落，自动恢复…" >> "$LOG"
    adb shell am force-stop com.android.thememanager
    sleep 1
    adb shell am start -d "$FONT_TAB" >/dev/null 2>&1
    sleep 4                       # 等列表加载
    # 「我的」标签在底栏右二（1080x2400 级分辨率典型坐标；失败时
    # 可用 uiautomator dump 校准——见 README 排障节）
    adb shell input tap 915 2320
    sleep 2
    # 字体条目（列表第二区）；命中详情后点「应用」按钮
    adb shell input tap 610 980
    sleep 2
    adb shell input tap 540 2190
    sleep 3
    if healthy; then
        echo "[$(date '+%m-%d %H:%M:%S')] ✓ 自动恢复成功" >> "$LOG"
    else
        echo "[$(date '+%m-%d %H:%M:%S')] ✗ 自动恢复未生效（界面坐标" \
             "可能不符，手动应用一次后校准 tools/font_daemon.sh）" >> "$LOG"
    fi
}

echo "[$(date '+%m-%d %H:%M:%S')] 守护启动（10s 轮询）" >> "$LOG"
while true; do
    healthy || restore
    sleep 10
done
