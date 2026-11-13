# 琅琊项目独立审核报告

审核员：glyph-auditor（独立审核，只读）　日期：2026-11-13　任务：task-38
基线：langya 仓库 HEAD `419da46`（含 task-37 的 Android 链接修复）。
方法：逐行通读与行为探针结合。探针用 fcitx5 官方 testfrontend 在真实 fcitx5 运行时中注入按键，记录每个按键「吞」还是「放行」、上屏了什么、面板显示什么；被测引擎是用 HEAD 源码构建的 `build/cmake/core/langya.so`（18:34）。探针程序只在临时目录编译运行，源码见附录甲，可原样复现。行号一律指 HEAD。

落地分工（按任务约定）：desktop-lead 负责落地，涉及 core/ 的修复由 mobile-lead 交叉审查；涉及 zhuan 查表链的数据问题归 font-lead（与字体审计 G1 同一根因）。

## 一、结论摘要

| 级别 | 编号 | 问题 | 证据 |
|---|---|---|---|
| **阻断** | D1 | 映射表错映：楷化模式下输入「二」上屏「上」，「光」上屏「水」，「亲／親」上屏「榛」，「煙」上屏「完」，「關」上屏「寡」，「滚」上屏「玄」…… | `data/langya.map` 实查；zhuan 查表链 `-d` 命中路径 |
| **阻断** | K1 | 数字或英文字母之后的「.」「,」被吞：3.14 → 314，1,000 → 1000 | 探针 P1、P1b、P13 |
| **严重** | K2 | 组字中按标点，只上屏候选、标点丢失（nihao, → 你好）。文档和测试把这当成「拼音行为」，但实际上拼音并不这样处理 | 探针 P2；对照上游 PinyinEngine::handlePunc |
| **严重** | K3 | 选择只覆盖部分拼音的候选后，剩余拼音被丢弃（nihaoma 选「你好」，「吗」消失） | 探针 P3 |
| **严重** | K4 | 标点候选窗状态机：窗口打开时按字母会被暗中吞掉；按 Esc 或退格会漏给应用，窗口却不关；失焦后窗口仍残留；残留状态还会吃掉下一次按键 | 探针 Q1–Q5 |
| **严重** | K5 | 组字中失焦时，fcitx 把客户端预编辑（楷化文本）提交给应用：小篆模式下应用收到的是楷化字 | 探针 Q6 |
| **严重** | K6 | 隐私：每次按键的拼音和每次上屏的原文都以 INFO 级写入 journal 或 logcat（fcitx 默认级别就是 Info） | `langyaengine.cpp:515-516`、`:530-531` |
| **严重** | B1 | 港繁简繁配置从未生效：`chttrans.conf` 用了不存在的 `[OpenCC]` 分组，安装位置也不是 chttrans 读取配置的目录 | 对照 chttrans 配置定义与 `readAsIni` 源码 |
| **严重** | B2 | `xmake install` 改写会话级 `FCITX_ADDON_DIRS`（写死 `/usr/lib64/fcitx5`），并复制模块与 libime 去遮蔽系统版本；卸载不彻底 | `xmake.lua:162-205`、`:257-292` |
| 轻微 | — | 共 18 项：按键边界、加载失败处理、依赖声明、测试有效性、构建脚本与文档不符等 | 第三节 |
| 建议 | — | 共 7 项：Android 链接可以彻底去掉、无 SONAME 陷阱的门禁、插件重复打包 libime 等 | 第四节 |

**task-37 的 Android 链接修复**：DT_NEEDED 已正确，实测为 `libpunctuation.so`，不再含构建机绝对路径，修复有效。不过审核发现这条链接**本来就不需要**：langya.so 没有从 libpunctuation 导入任何一个符号（实测 0/176）。另外注释说插件 APK 也打包了同名库副本，与实际 APK 内容不符。详见第四节 A1，以及同类陷阱的普查结果 A2。

## 二、阻断与严重问题明细

### D1【阻断】映射表错映：常用字输出成另一个字

- **现象**：`data/langya.map` 的楷化列和小篆列都来自 zhuan 查表链，其中有成批的语义错误。楷化模式下：

  | 输入 | 上屏（楷化） | 小篆码点 | 查表链命中路径（`zhuan -d`） |
  |---|---|---|---|
  | 二 | 上 | U+3D008 | 变体链 二→上（「二」是「上」的古文） |
  | 光 | 水 | U+3EF5E | 变体链 光→𬺧→水 |
  | 亲、親 | 榛 | U+3DFE5 | 变体链 親→亲→榛 |
  | 煙 | 完 | U+3E4CB | 变体链 煙→完 |
  | 關 | 寡 | U+3E4E7 | 变体链 關→寡 |
  | 詳（繁体） | 翔 | U+3DA3D | 变体链 詳→翔（简体「详」反而正确，输出 詳） |
  | 壹 | 一 | U+3D000 | 变体链 壹→一 |
  | 面 | 麪 | U+3DF63 | 变体链 面→麵→麪 |
  | 滚 | 玄 | U+3DB5D | 变体链 滚→𬺤→玄 |
  | 难 | 鳥 | U+3DAB3 | 說文正形「难」 |

- **范围**：字体审计（`fonts/audit/字形审核报告.md` G1）列出的 107 条疑似错映，`langya.map` **107 条全部原样存在**。另外，GB2312 一级字中楷化输出与原字不同的有 1,219 条，其中大部分是正常的简→繁转换。随机抽 80 条（种子 38），发现 2 条明显错误（滚→玄、难→鳥），按比例估计约有 30 条明显错误；还有一批可以商榷的说文本字替换（尸→屍、研→揅、欢→懽）。
- **复现**：`grep -P '^(二|光|亲|煙)\t' data/langya.map`；`cd ../zhuan && .venv/bin/python -m zhuan -d "二光亲煙關滚难"`。
- **成因**：zhuan 查表链让变体链优先于字头本字，并允许多跳语义漂移；`tools/export_char_map.py:45-50` 照单全收，**没有任何回归校验**。
- **建议**：① 根因修在 zhuan（与字体审计 G1 合并处理，由 font-lead 负责）：字头本字优先，变体链排除 `sw_gw`（古文从属）关系并限制跳数；② `export_char_map.py` 增加常用字黄金表校验（至少覆盖上表各字及 GB2312 一级高频字），校验不过就拒绝写出；③ 在测试中新增「楷化模式输入二／光／亲」等回归用例（见第五节）。

### K1【阻断】数字或英文字母之后的句点、逗号被吞

- **现象（探针 P1、P1b、P13）**：

  ```
  3[放行] period[吞] 1[放行] 4[放行]   → 应用实际收到 314
  1[放行] comma[吞] 0 0 0[放行]        → 1000
  A[放行] period[吞]                   → A
  ```
- **成因**：punctuation 模块有个默认开启的选项「HalfWidthPuncAfterLetterOrNumber」：在字母或数字之后，`pushPunctuationV2` 对 `.` `,` 返回空串，意思是「不转换，交给应用输出半角」。但 `langyaengine.cpp:303` 在调用 `pushPunctuationV2` **之前**就已经 `filterAndAccept()`，`:308-310` 发现结果为空后什么也不上屏，按键就这样丢了。上游 PinyinEngine 的做法是只有拿到非空标点才吞键，否则放行。
- **建议**：先调用 `pushPunctuationV2`，结果非空才 `filterAndAccept` 并上屏；结果为空就 `return false` 放行。增加回归用例「3.14」「1,000」。

### K2【严重】组字中按标点：标点被吞，而文档说这是「拼音行为」

- **现象（探针 P2）**：`n i h a o comma` 只上屏「你好」，逗号消失，用户每个词之后都要再按一次标点。
- **对照上游**：fcitx5-chinese-addons `PinyinEngine::handlePunc` 先选中高亮候选；如果选完后上下文已经清空（整句已上屏），就**接着输出标点**；只有部分选择、上下文仍有残留时才吞键。所以 `docs/desktop/agent.md:30`、`:126` 与 `tests/engine_test.cpp:221-224` 所写的「组字吞键＝拼音行为」**与事实不符**，测试 10 把错误行为固化成了期望。
- **成因**：`langyaengine.cpp:280-292` 组字分支选完候选后一律 `filterAndAccept` 并返回。
- **建议**：选完候选后如果 `ctx.userInput()` 已经为空，继续走下面的非组字标点流程；同步修正文档和测试 10，期望改为「𿕾，」。

### K3【严重】选部分候选后，剩余拼音被丢弃

- **现象（探针 P3）**：输入 `nihaoma`，候选为「你好吗／你好／拟好／你／拟」。选第 2 项「你好」后只上屏「你好」，面板清空，「ma」不见了。
- **成因**：`LangyaCandidateWord::select`（`:116-120`）调用 `commitEntry`（`:521-532`），直接整段上屏并 `ctx.clear()`，没有使用 libime 的 `PinyinContext::select(idx)` 和「部分选择后继续组字」的机制。顺带后果：`updateUI` 里 `selectedSentence()`（`:484`）永远为空。
- **建议**：照上游的做法：候选持有索引，`select` 时调用 `ctx.select(idx)`；如果 `ctx.selected()` 为真（整句完成），就把 `selectedSentence()` 转换后上屏，并调用 `ctx.learn()`；否则刷新界面继续组字。

### K4【严重】标点候选窗（多映射键，例如 `[`）状态机缺陷

探针结果（每个场景使用全新的输入上下文）：

| 场景 | 按键结果 | 上屏 | 之后面板 |
|---|---|---|---|
| Q1 `[` 后打 `n i` | 全部吞 | 莫名其妙地上屏「in」或什么都没有 | 拼音被暗中放进隐藏的组字缓冲，界面上看不到 |
| Q2 `[` 后按 Escape | **Escape 放行给应用** | 无 | 标点窗口**仍然开着** |
| Q3 `[` 后按退格 | **退格放行**（删掉应用里的一个字） | 无 | 标点窗口仍然开着 |
| Q4 `[` 后失焦再聚焦，打 `wo` | 吞 | 无 | **仍显示标点候选**，「wo」不可见 |
| Q5 `[` → Esc → 再按 `[` | 第二个 `[` 被吞 | 无 | 空：残留的标点模式吃掉了这次按键 |

- **成因**：
  1. `keyEvent` 的分支顺序：退格、Esc、空格、数字、字母都在 `handlePunc`（`:452`）之前处理，所以 `:257-270` 的「标点模式下其他键一律退出」实际上只对标点类按键生效；
  2. `:404-419` 不在组字状态时，退格和 Esc 直接 `return`，不吞也不退出标点模式；
  3. `updateUI` 在标点模式下直接返回（`:470-472`），因此 `reset()`（`:236-241`）清不掉标点窗口；`activate()`（`:219-234`）也不复位 `puncMode`。
- **建议**：`keyEvent` 开头先处理 `puncMode`：数字或空格选择，Esc 或退格关闭窗口并吞键，其他键先关闭窗口再按普通流程处理；`reset()` 和 `activate()` 都要清掉 `puncMode`、`puncCandidates` 并重置面板。

### K5【严重】失焦时提交的是楷化预览，不是当前模式的文本

- **现象（探针 Q6，小篆模式）**：输入 `w o` 后失焦，应用收到「我」（楷化字），而不是「𿕾」。
- **成因**：`:484-491` 客户端预编辑固定写成 `convert(sentence, false)`（楷化）。fcitx 核心在失焦时会把客户端预编辑原样提交（`instance.cpp` 中 FocusOut 观察者调用 `clientPreedit().toStringForCommit()`；客户端自己负责提交的情况也一样）。
- **建议**：二选一：① 客户端预编辑按当前模式转换（小篆模式就显示小篆）；② 给预编辑文本加上 `TextFormatFlag::DontCommit`，并在 `deactivate` 里按当前模式自行提交（或丢弃，保持与配置一致）。

### K6【严重】隐私：按键与上屏原文写入系统日志

- `:515-516` 每次按键都记录 `琅琊查表 <拼音> 命中 N`；`:530-531` 每次上屏都记录 `琅琊上屏 <原文> → <输出>`。两处都是 `FCITX_INFO`。fcitx 的日志类别默认级别就是 Info（`log.h:61`），fcitx5-android 非详细模式下的规则也只是 `notimedate`，不会降低级别。结果是桌面 journal、手机 logcat 和 bug 报告里都会留下用户输入的全部文字。
- **建议**：改为 `FCITX_DEBUG`，或者干脆删除；激活、模式切换这类不含输入内容的日志可以保留。

### B1【严重】港繁简繁配置从未生效

- **事实一**：chttrans 的配置定义中，`OpenCCS2TProfile`、`OpenCCT2SProfile`、`Hotkey` 都是**顶层键**（见上游 `chttrans.h:46-65`，审核用该模块的 `getConfig()` 导出也确认是顶层）。`core/chttrans.conf:2-7` 和 `xmake.lua:190-197` 生成的用户配置都把它们写在 `[OpenCC]` 分组下，fcitx 读到后会忽略；`Hotkey` 是列表，正确写法应为 `[Hotkey]` 下的 `0=…`。
- **事实二**：chttrans 用 `readAsIni(config_, "conf/chttrans.conf")` 读配置，默认的路径类型是 **PkgConfig**（`iniparser.cpp:161-162`），也就是 `FCITX_CONFIG_HOME` 加上 `FCITX_CONFIG_DIRS`（或 `XDG_CONFIG_DIRS/fcitx5`）。而 `core/CMakeLists.txt:104-106` 把文件装到 `${FCITX_INSTALL_PKGDATADIR}/conf`，属于 PkgData。桌面（`/usr/share/fcitx5/conf`）和 Android 插件资源（`usr/share/fcitx5/conf`）都**不在读取路径上**。
- **结论**：文档宣称的「简→港繁 s2hk／港繁→简 hk2s」在三条安装路线上都没有生效，实际用的一直是 OpenCC 默认配置（标准繁体）。
- **建议**：改成顶层键写法。桌面安装到 `/etc/xdg/fcitx5/conf/`，或者文档改为提示用户自行设置；Android 需要确认宿主是否支持插件下发 PkgConfig，不支持就在插件配置页提示，或改由引擎在激活时通过 chttrans 的配置接口设置。不要再写一份不会被读取的文件。

### B2【严重】xmake 用户级安装会破坏或遮蔽系统 fcitx5，且卸载不彻底

- `xmake.lua:201-205` 写入 `~/.config/environment.d/langya-fcitx5.conf`，内容为 `FCITX_ADDON_DIRS=~/.local/lib/fcitx5:/usr/lib64/fcitx5`。这会**整体替换** fcitx5 编译时内置的模块目录。在 Debian/Ubuntu（`/usr/lib/x86_64-linux-gnu/fcitx5`）、Arch（`/usr/lib/fcitx5`）上，重新登录后系统的全部模块（拼音、界面、前端）都会消失，fcitx5 直接不可用。
- `:106-116`、`:162-186` 把**构建前缀**（RPM 解包得到的 fcitx5 5.1.23）里的 `libIMECore`、`libIMEPinyin`、`libchttrans.so`、`libpunctuation.so` 复制进 `~/.local/lib/fcitx5`，再加上 `$ORIGIN` RPATH（`:52-54`）。由于 `~/.local` 排在前面，这些副本会**遮蔽系统的同名模块**，系统 fcitx5 版本一旦不同，就有 ABI 不兼容甚至崩溃的风险；同时 `~/.local/share/fcitx5/addon/chttrans.conf`（被改成 OnDemand=False 并剥掉了依赖）也会遮蔽系统配置，影响用户正在用的 fcitx5 拼音。
- `:188-197` 无条件覆盖用户的 `~/.config/fcitx5/conf/chttrans.conf`。
- `uninstall`（`:257-292`）**不会清理**复制进去的 libchttrans、libpunctuation、两个模块的 addon conf、图标、`~/.config/fcitx5/conf/chttrans.conf`，所以卸载后系统的拼音和简繁转换仍然处在被遮蔽、被改写的状态。
- **建议**：用户级安装不要覆盖 `FCITX_ADDON_DIRS`；如果确实需要，就把系统目录作为后备追加，并用 `pkg-config --variable=libdir Fcitx5Core` 探测实际路径。不要复制系统里已有的模块和 libime（先探测，系统有就不装）；不要覆盖用户配置（已存在就跳过并给出提示）；安装时记录清单，卸载时按清单逐项删除。

## 三、轻微问题

| 编号 | 位置 | 问题 | 建议 |
|---|---|---|---|
| L1 | `langyaengine.cpp:281-292`（经 `keySymToUnicode`） | 组字中按回车会上屏首选候选，不是上屏原始字母（上游拼音的行为是上屏拼音串），用户没法「回车输出英文」（探针 P4） | 回车上屏 `ctx.userInput()` 原文 |
| L2 | 同上 | 组字中按 Shift+字母、Delete、Tab：上屏候选，同时按键被吞（P8、P11）；Home、End 被吞，没有任何效果（P14） | 明确各键语义：大写字母要么并入输入，要么上屏后放行；Delete、Home、End 用于移动组字光标 |
| L3 | `:275` | 没有排除小键盘：小键盘小数点在非组字状态下会转成「。」（P9），上游会跳过小键盘键 | 加 `!event.key().isKeyPad()` |
| L4 | `:32-58` | CharMap 加载不校验码点范围和 UTF-8：越界码点会让 `UCS4ToUTF8` 输出空串，该字在上屏时静默消失；首列为多字时只取首字；文件打不开与内容为空无法区分 | 校验码点在 U+3D000–3FC3F 内、首列恰好一个字，加载结果写进日志统计 |
| L5 | `:207-211` | 找不到映射表时只记一条错误日志，引擎静默退化成「普通拼音」，用户不知道为什么没有小篆 | 状态区或候选窗给出一次性提示 |
| L6 | `:184-197` | 词典加载抛出的异常没有捕获。`LANGYA_LIBIME_DICT` 指错或 sc.dict 损坏时，构造函数抛异常，addon 加载失败，被 fcitx 标记为「启动时禁用」（正是移动端那类症状） | try/catch 后降级并给出提示 |
| L7 | `:172-175` 对照 `:200-206` | 语言模型的实际加载走 libime 自己的解析器（`LIBIME_MODEL_DIRS` 或编译期目录），缺失检测却用 `StandardPaths` 的 Data 路径，两者可能一个说有、一个说没有 | 检测直接复用解析器的结果（判断返回指针是否为空） |
| L8 | `langya-addon.conf.in:19-20` | punctuation 是**硬依赖**：用户在 fcitx5 配置里禁用标点模块后，整个琅琊无法加载。引擎在 `:295-297` 已经能处理模块缺失 | 改为可选依赖 |
| L9 | `langyaengine.h:120-125` | 成员声明顺序是 `factory_` 在前、`ime_` 在后，析构时 PinyinIME 先于各 LangyaState（其中的 PinyinContext）销毁；初始化列表顺序与声明不一致（会触发 -Wreorder）。现有析构路径经核对不会解引用，但很脆弱 | 照上游的顺序，把 `ime_` 声明在 `factory_` 之前 |
| L10 | `:327-338` | 每次切换模式都写 `sealByDefault`，配置界面里「默认输出小篆」实际变成了「上次的模式」；`setConfig`（`:540-543`）也不刷新已有上下文的模式 | 文档写清楚这个语义，或拆成两个选项 |
| L11 | `langyaengine.h:67`、`:521-532` | `puncCandidates` 写了但从不读取；`commitEntry` 的 `miss` 参数与内部第二次转换重复 | 清理 |
| L12 | 文档 `docs/desktop/agent.md:18`、`:95-96`，`docs/mobile/agent.md:147` | 声称候选窗会提示「說文未收」，代码里**没有实现**；`:27-28` 与 mobile `:82` 的字体名 `shuowen-seal-*.ttf` 已经过时（现在是「说文小篆-*.otf」）；`:30` 和 `:126` 的「组字吞键＝拼音行为」有误（见 K2） | 实现该提示或删掉这段描述；更新字体名 |
| L13 | `tests/engine_test.cpp:146-253` | 17 个行为用例全是 `check(true, …)`，计数是装饰性的，「23 项通过」的数字不反映真实结果（真正的判定靠 testfrontend 的期望断言，失败就中止整个进程，后面的用例都不跑，也不会打印汇总） | 每个用例单独判定，失败不中止，汇总真实通过数 |
| L14 | 同上 | 没有断言 `sendKeyEvent` 的返回值（按键是吞还是放行），所以「按键泄漏给应用」这一整类回归（K1、K4、L1）测不出来 | 对吞键和放行的预期逐键断言 |
| L15 | 同上 `:157-169` | 「持久化」用例只验证了内存：测试环境的 `FCITX_CONFIG_HOME=/Invalid/Path`，`safeSaveAsIni` 静默失败，从未验证写盘后重启能读回 | 用临时配置目录加两次 Instance 验证；顺带断言写盘返回值 |
| L16 | 同上 | 所有场景共用一个输入上下文，前一个用例的残留状态（例如 K4 的标点模式）会串到后一个用例，导致失败归属不清 | 每个用例新建一个上下文 |
| L17 | `xmake.lua:65-75` | 桌面 xmake 构建必须依赖 `FCITX_ROOT` 前缀（默认 `/tmp/fcitx5root`）提供 LibIME 和 punctuation 头文件；系统安装 fcitx5-devel 时这些头不在默认搜索路径上，编译失败。这与文档「系统装可省」不符 | 用 pkg-config 或 CMake 包探测 LibIME 和 punctuation，前缀只作为后备 |
| L18 | `android/xmake.lua:247-253` 对照 `:277-278`；`:102-113`；`:56-62` | ① `GRADLE_USER_HOME` 默认是 `android/build/gradle-home`，命令行 `-Dgradle.user.home` 默认却是 `/tmp/gradle-home`，两处自相矛盾；② `git apply --check` 失败一律当作「已经套用」而跳过，补丁失效时会静默缺失冷启动修复；③ 缺映射表时只打印提示，仍会打出一个没有映射表的 APK | ① 统一用同一个变量；② 先用 `git apply --reverse --check` 区分「已套用」与「不适用」，不适用就报错；③ 缺映射表时直接失败 |

数据管线（`tools/export_char_map.py`）另有几处：luna 缓存缺失时字符集静默缩小（`:30-40`）；写文件不是原子操作（`:51-52`）；产物里没有记录 zhuan 的版本或提交，无法追溯；`download-dict` 下载的 `essay.txt` 根本没有用到。建议：缓存缺失直接报错；写临时文件后再替换；在映射表头部或旁边的文件里记录 zhuan 提交哈希和生成时间；删掉多余的下载。版本号在 `CMakeLists.txt:2`、`xmake.lua:27`、`:32` 三处重复；Android 侧 conf 的 `Version` 取的是宿主的 `VERSION_NAME`（0.1.3），与桌面的 0.1.0 不一致（`android/plugin/src/main/cpp/CMakeLists.txt:3`）。

## 四、构建双轨与 Android 链接（task-37）健壮性

| 编号 | 发现 | 证据 | 建议 |
|---|---|---|---|
| A1 | **libpunctuation 链接本来就不需要。** 对 langya.so 的 176 个未定义动态符号与 libpunctuation 的导出符号求交集，结果为 **0**：IPunctuation 的调用都通过 addon 名字动态分派，链接期不依赖任何符号。桌面的 `Fcitx5::Module::Punctuation` 也只是提供头文件的接口目标，桌面 langya.so 的 NEEDED 里本来就没有它 | `llvm-nm -D` 求交集；桌面 `readelf -d build/cmake/core/langya.so` | Android 分支只取 `INTERFACE_INCLUDE_DIRECTORIES`，**删掉** `-Wl,-l:libpunctuation.so` 和 `target_link_directories`。这样运行时就完全不依赖宿主库的名字，同类陷阱也随之消失 |
| A1′ | `core/CMakeLists.txt:29-31` 注释说「宿主 APK 与本插件 APK 均打包同名库副本」，**与事实不符**：插件 APK 中只有 `langya.so`、`libIMECore.so`、`libIMEPinyin.so`，没有 libpunctuation.so；现在之所以能运行，靠的是宿主 APK 自带的那一份 | `unzip -l` 插件 release APK | 修正注释（如果按 A1 处理，就整段删除） |
| A2 | **系统性陷阱普查**：宿主 prefab 中 fcitx 模块库**全部没有 SONAME**，共 13 个：chttrans、clipboard、fullwidth、imselector、luaaddonloader、pinyin、pinyinhelper、punctuation、quickphrase、scel2org5、spell、table、unicode；只有 Fcitx5Core/Config/Utils 与 IMECore/IMEPinyin/IMETable 有 SONAME。以后只要有人直接链接其中任何一个导入目标（比如为 chttrans 加接口），task-37 的问题就会原样复发 | `llvm-readelf -d` 逐个检查 | `build-android` 构建后增加门禁：用 `llvm-readelf -d` 检查 langya.so 的 NEEDED，不允许含 `/`，并与白名单（Fcitx5Core/Config/Utils、IMECore/IMEPinyin、libc++_shared、libc/libm/libdl）比对，不符就失败 |
| A3 | 插件 APK 带了 `libIMECore.so`、`libIMEPinyin.so`（约 1.8MB），宿主 APK 里有同名同版本的库。宿主只把插件库目录加进 `FCITX_ADDON_DIRS` 供按绝对路径 dlopen，DT_NEEDED 会在宿主进程的命名空间里解析到宿主那一份，所以插件的副本推断不会被用到。jyutping 插件就排除了 `libIMECore.so`、`libpunctuation.so` | 插件 `build.gradle.kts:42-44` 对照 jyutping 的同名文件；宿主 `Fcitx.kt:429-435` | 照 jyutping 的做法在 `excludes` 里加上 `**/libIME*.so`。改之前先在真机上用 `/proc/<pid>/maps` 确认实际映射的是哪个路径 |
| A4 | 双轨差异：CMake 不写 RPATH，xmake 写 `$ORIGIN`（`:52-54`）；CMake 安装 chttrans.conf 到 PkgData（无效，见 B1），xmake 写用户配置（覆盖用户设置，见 B2）；xmake 会复制 libime 和模块，CMake 不会 | 第二、三节 | 把 CMake 定为唯一正式安装路线，xmake 只用于开发和测试，不再提供用户级安装；或者让两者的安装行为对齐，并都改正 B1、B2 |

## 五、测试覆盖面评估

文档描述的用户路径与现有用例对照（✓＝已覆盖，✗＝缺失，⚠＝用例固化了错误行为）：

| 用户路径（文档或常识） | 现状 | 需要新增或修改的回归 |
|---|---|---|
| 拼音→候选→空格上屏（小篆/楷化） | ✓ | — |
| 楷化模式常用字语义（二、光、亲……） | ✗ | 「楷化：二→二、光→光、亲→親」（D1） |
| 数字或字母后的「.」「,」 | ✗ | 「3.14」「1,000」「A.」放行（K1） |
| 组字中按标点 | ⚠ 测试 10 期望吞掉逗号 | 改为期望「𿕾，」（K2） |
| 部分候选选择后继续组字 | ✗ | nihaoma 选「你好」后继续选「吗」（K3） |
| 多映射标点 `[` 候选窗 | ✗ | 数字选择、Esc 关闭（吞键）、字母、退格、失焦（K4） |
| 失焦时组字的处理 | ✗ | 小篆模式失焦后提交的文本（K5） |
| Esc 清空组字 | ✗ | Esc 后面板为空，且 Esc 被吞 |
| 回车行为 | ✗ | 回车上屏原文（L1） |
| 翻页 `-`、`=`、PageUp，方向键 Left/Up | 部分（只测了 PageDown、Right） | 补上其余几个键 |
| Ctrl+Shift+S 在 NumLock/CapsLock 下 | ✗（核对 fcitx 的 `Key::normalize` 后确认实际可用） | 补用例防止回归 |
| 状态区「篆/楷」按钮 | ✗ | 触发按钮后模式切换并持久化 |
| 持久化写盘与重启读回 | ⚠ 只测了内存 | 见 L15 |
| 简繁转换（chttrans）实际效果 | ✗（只测了能加载） | 港繁配置生效（B1） |
| 缺映射表、缺词典、缺语言模型时的降级 | ✗ | 引擎能加载、不抛异常、有提示（L5、L6） |
| 按键吞放断言 | ✗（返回值被忽略） | 每个用例都断言（L14） |

另外，候选顺序类用例（ni+2→拟，ni 第 7 项＝尼）依赖语言模型的版本，升级 libime 数据时会误报，建议改为断言集合成员，或者固定语言模型的版本。

## 六、修复优先级建议

1. **数据**：D1（与字体审计 G1 一起在 zhuan 修，导出时加黄金表校验，然后重新导出 `langya.map` 并同步到 Android）；
2. **键处理**：K1、K2、K3、K4、K5 一次性重构 `keyEvent`、`handlePunc` 和提交路径，对齐上游 PinyinEngine 的语义，同时把第五节的回归用例补齐（先写用例，确认失败，再修）；
3. **隐私**：K6，日志降级，改动很小，建议立刻做；
4. **安装**：B1、B2，然后是 A1、A2 的门禁；
5. 其余轻微项和建议项。

## 附录甲：行为探针（复现方式）

在任意临时目录编译，链接本地 fcitx5 前缀即可，不改仓库内任何文件。核心代码如下：每个场景新建一个输入上下文，记录每个按键吞还是放行、上屏内容和面板状态。

```cpp
// g++ -std=c++20 probe.cpp -o probe -I$R/usr/include/Fcitx5/{Core,Utils,Config} \
//   -I<宿主树>/lib/fcitx5/src/main/cpp/fcitx5/testing/testfrontend -I$R/usr/include \
//   -L$R/usr/lib64 -lFcitx5Core -lFcitx5Config -lFcitx5Utils
// 运行：FCITX_ROOT=$R LD_LIBRARY_PATH=$R/usr/lib64 ./probe
//（R=langya/build/env/fcitx5root；把待测 langya.so 放进 /tmp/probe/addon 并排在 addon 目录首位）
setupTestingEnvironmentPath("", {"/tmp/probe/addon", root/"usr/lib64/fcitx5"},
    {root/"usr/share", root/"usr/share/fcitx5", root/"usr/share/fcitx5/testing"});
// --disable=all --enable=langya,testfrontend,punctuation,chttrans
auto w = instance.watchEvent(EventType::InputContextCommitString,
    EventWatcherPhase::PreInputMethod,
    [&](Event &e){ commits.push_back(static_cast<CommitStringEvent&>(e).text()); });
bool filtered = tf->call<ITestFrontend::sendKeyEvent>(uuid, Key("period"), false);
// 场景：P1 "3.14"、P1b "1,000"、P2 "nihao,"、P3 nihaoma 选「你好」、P4 wo+Return、
//       P8 wo+A、P9 KP_Decimal、P11 wo+Delete、P13 A+.、P14 wo+Home+space、
//       Q1–Q5 [ 后各种按键、Q6 wo 后 focusOut()/focusIn()
```

探针原始输出摘录：

```
P1  3[放行] period[吞] 1[放行] 4[放行]    上屏：（无）
P2  n i h a o[吞] comma[吞]               上屏：「你好」
P3  nihaoma（你好吗/你好/拟好/你/拟）选「你好」  上屏：「你好」  选后面板：空
Q2  bracketleft[吞] Escape[放行]          面板：【/「/『/❲/［/[ 仍在
Q6  w o[吞] → focusOut：上屏「我」（当时为小篆模式）
```
