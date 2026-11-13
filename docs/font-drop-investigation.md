# 字体掉落调查档案

状态：**未破案**（2026-10-25）。取证监控运行中（tools/font_watch.sh），
自然掉落时自动抓全量 logcat + dumpsys 到 /tmp/font_forensics/。

## 案发记录

| 时间 | 现场特征 | 伴随事件 |
|---|---|---|
| 10-25 15:48 | symlink 回退、字体清空 | 用户禁用主题应用组件后 |
| 10-25 18:02 | symlink 回退（18:02:17.438）、字体清空 | B站全屏视频转屏（18:02:16 configuration_changed 0x20000100 含 theme 位）；同秒 am_kill 风暴（19 个后台进程被杀）；**thememanager 本体未死** |

## 已实测排除的假设

- **configuration change 类**：font_scale 抖动、深浅模式（cmd uimode night）、
  物理转屏（真机横竖）、软件转屏（user_rotation/cmd window user-rotation，
  桌面竖屏锁挡住未真转）——均不掉，themeChanged 计数不动（11）
- **内存压力**：B 站全屏视频 3 分钟 + 监控 30 轮——不掉
- **条目重建**：两次掉落 .mrm 补丁均完好（区别于更早的条目重建型掉补丁）

## 现场事实

- 主题 app（com.android.thememanager）以 **system_theme uid** 运行，
  与 /data/system/theme/、theme_webview/ 属主同 uid
- 掉落动作（改 symlink + 删字体）只能由 system_theme 域执行
- themeChanged 计数（dumpsys window overrideConfig）在掉落时应 bump
  （18:02 的 config diff 含 0x20000000 theme 位）——复现实验中计数纹丝不动
- 恢复方式：强杀 thememanager → 点应用（补丁仍有效）

## 下一步

1. **取证监控**等自然掉落（判据：symlink 回退或 themeChanged 增长），
   拿到案发毫秒级日志后定位执行进程与调用链
2. 候选深挖：
   - `ThemeOtaUpdateReceiver`（exported receiver，OTA 检查时机？）
   - 主题商店 com.miui.themestore 后台任务
   - miui.theme 系统服务的定期校验（dumpsys miuifont 空输出，服务在
     但无 dump；考虑 dumpsys --help / binder trace）
   - **rights 伪造路线**：.mra 结构分析（mtz 内 MILanPro 样本）+
     miui.drm 验签算法逆向（boot classpath，jar 在 vdex 中未提取）
3. Shizuku 路线（已装 app，daemon 未拉起）：掉落自动恢复的执行体

## 环节绕过审计（2026-10-26 夜，全链逆向后）

真凶链：CYCLE_CHECK 精确自续期闹钟（system，非 DrmBroadcast 路径）
→ ThemeReceiver（system_server 动态注册）→ ValidateThemeTask
→ 递归校验 /data/system/theme/ → resetDefault 删文件+广播回退。

| 环节 | 审计结果 |
|---|---|
| 0 闹钟 | ❌ dumpsys alarm 无 CHECK_TIME_UP 项；实际驱动者是 miui.intent.action.CYCLE_CHECK（ELAPSED_WAKEUP 精确闹钟、repeatInterval=0 自续期、system 持有）。cmd alarm 仅 set-time/set-timezone，无删除能力 |
| 1 广播投递 | ❌ system_server 内动态注册 receiver，无 manifest 组件可 pm disable |
| 2 任务启动 | ❌ mIsValidating 防重入，无外部控制点 |
| 3 目录遍历 | ❌ 白名单为编译常量（rights/.runtime/wallpaper 等 14 项），fonts/ 必遍历。FIFO/循环 symlink 可卡死遍历（listFiles/getSHA1 阻塞→mIsValidating 永锁→后续校验全拒）但创建需 system_theme 域写权，应用流程只拷普通文件 |
| 4b RSA 验签 | ❌ 标准 JCA SHA1withRSA + e=65537（C 线结案，无小米私钥不可伪造）|
| 4c hash 匹配 | ❌ SHA1 碰撞不可行；rights 免疫位仅对 MILanPro 原内容成立（换其内容=非小篆）|
| 5 resetDefault | ❌ ThemeFileUtils.remove（system 侧直接删）+ 显式广播 ACTION_CLEAR_THEME_RUNTIME_DATA 给主题 app 清 runtime |

理论残留（不推荐）：
- XXE 卡死：rights 注入通道未验证成立（真机 rights/ 恒空，mtz 携带
  .mra 未被拷入）；且卡死的是 system_server 共享 AsyncTask 串行池，
  副作用不可控（可能拖垮系统其他 AsyncTask 用户）。
- 竞态 abort：校验中删文件可令 getSHA1 抛异常中止整轮——但无法
  控制校验时机，无同步入口。

结论：非 root 全环节封死。根治=KernelSU 后 hook
DrmManager.isLegal 返回 true（或禁 CYCLE_CHECK 闹钟）。
