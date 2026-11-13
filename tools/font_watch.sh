#!/usr/bin/env bash
# 字体掉落取证 v6 —— 仅「好→坏翻转」触发一次，杜绝重复取证。
# 事件定义：symlink 从 OK 变为非 OK（真掉落）。themeChanged 计数
# 变化只随日志记录不触发（恢复动作也会 bump，会误报）。
# 产物：仓库 forensics/（持久）。用法：bash tools/font_watch.sh &
set -uo pipefail
OK='/data/system/theme/fonts/Roboto-Regular.ttf'
DIR=/home/xiaoshihou/Playground/void/小篆/langya/forensics
LOG=$DIR/watch.log
mkdir -p "$DIR"

link() { adb shell readlink \
    /data/system/fonts/theme_webview/Roboto-Regular.ttf 2>/dev/null | tr -d '\r'; }
tc() { adb shell "dumpsys window 2>/dev/null | grep -ao 'themeChanged=[0-9]*' \
        | head -1 | cut -d= -f2" 2>/dev/null | tr -d '\r'; }

prev=$(link)
echo "[$(date '+%m-%d %H:%M:%S')] v6 启动 基线=${prev##*/} tc=$(tc)" >> "$LOG"

while true; do
    sleep 15
    c=$(link) || continue
    if [ "$prev" = "$OK" ] && [ "$c" != "$OK" ]; then
        ts=$(date '+%m-%d_%H-%M-%S')
        echo "[$ts] ✗✗✗ 掉落！好→坏翻转，开始取证" >> "$LOG"
        adb logcat -d -b main,system,events,crash > "$DIR/logcat_$ts.txt" 2>/dev/null
        for svc in activity services window meminfo package; do
            adb shell dumpsys $svc > "$DIR/dumpsys_${svc}_$ts.txt" 2>/dev/null
        done
        adb shell "ls -la /data/system/theme/ /data/system/theme/fonts/ /data/system/fonts/theme_webview/ /data/system/theme/.runtime/ 2>&1" > "$DIR/theme_dirs_$ts.txt" 2>/dev/null
        echo "[$ts] 取证完成（此后不再重复取证，恢复后重新武装）" >> "$LOG"
    elif [ "$prev" != "$OK" ] && [ "$c" = "$OK" ]; then
        echo "[$(date '+%m-%d %H:%M:%S')] ✓ 已恢复（重新武装）tc=$(tc)" >> "$LOG"
    fi
    prev=$c
done
