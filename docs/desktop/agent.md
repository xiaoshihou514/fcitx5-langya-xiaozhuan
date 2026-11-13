# langya — 琅琊·说文小篆输入法（Linux fcitx5 引擎插件）

拼音输入，上屏《說文解字》小篆：基于 Unicode 18.0 小篆区（U+3D000–3FC3F，
11,328 码位），由 [zhuan](../../../zhuan) 项目的查表链完成「现代汉字 → 小篆码点 /
楷化字」转换。

## 架构

```
按键 ──→ LangyaEngine（core/langyaengine.cpp）
           │
           ├─ 拼音层：libime PinyinIME（fcitx5 拼音同款内核）
           │    简拼/全拼/词组/模糊匹配、整句解码均由 libime 完成，
           │    词典与语言模型用宿主自带的 sc.dict + zh_CN.lm，零数据重复
           │
           ├─ 转换层：CharMap（data/langya.map，15,376 行）
           │    候选词逐字查表 → 小篆码点（U+3D000–3FC3F）或楷化字；
           │    說文未收字回退原字，候选窗口提示「說文未收」
           │
           └─ 模块依赖：punctuation（中文标点，zh_CN 表，与拼音共用）、
                chttrans（简繁转换，简→港繁 s2hk / 港繁→简 hk2s）
```

- 行为与 fcitx5 拼音一致：空格/数字上屏、翻页（PageUp/Down、-/=/+）、
  方向键移动高亮、退格改键、组字中其余键吞掉防泄入应用
- 两种输出模式，**Ctrl+Shift+S 随时切换**（选择写入配置，重启保持）：
  - 小篆模式：上屏小篆区码点（显示需装小篆字体，如本项目生成的
    `shuowen-seal-*.ttf` 或 Noto Serif Seal）
  - 楷化模式：上屏說文隸定字（常规 CJK 区，任何字体可显示）
- 标点：组字中按标点＝选当前候选并吞键（拼音行为）；非组字走
  punctuation 模块 zh_CN 表（多映射键如 `[` 弹候选窗）
- 单一数据文件 `langya.map`，内存查询，无外部服务

## 构建（Linux）

依赖：CMake ≥ 3.21、C++20 编译器、fcitx5 开发包（Fedora：
`fcitx5-devel`）与 fcitx5-chinese-addons-devel（punctuation 模块头）、
libime-devel、boost-devel。

```bash
# 1) 生成映射数据（依赖 zhuan 项目环境与 seal.db）
xmake export-char-map        # → data/langya.map

# 2) 构建
cmake -B build -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr
cmake --build build
sudo cmake --install build

# 3) 重启输入法后，在 fcitx5 配置中添加「琅琊小篆」
fcitx5 -rd
```

安装产物：

| 文件 | 位置 |
|---|---|
| `langya.so` | `${prefix}/lib64/fcitx5/` |
| addon 注册 | `${prefix}/share/fcitx5/addon/langya.conf` |
| 输入法条目 | `${prefix}/share/fcitx5/inputmethod/langya.conf` |
| 映射表 | `${prefix}/share/fcitx5/langya/langya.map` |
| chttrans 配置 | `${prefix}/share/fcitx5/conf/chttrans.conf` |

### xmake（备选，与 CMake 同步）

`xmake.lua` 覆盖 Linux 桌面侧同一套产物（依赖经 pkg-config 定位
`Fcitx5Core.pc`；Android 仍走 `android/` 宿主树 CMake）：

```bash
export PKG_CONFIG_PATH=<fcitx5 前缀>/lib64/pkgconfig   # 系统装可省
xmake f -m release -y && xmake
xmake install -o <prefix>            # 布局同 cmake --install
```

> **已知环境坑**：工作区路径含非 ASCII 字符（如本仓库上层目录「小篆」）时，
> `pkg-config` 输出会对路径做转义，xmake 的 `find_package` 解析后
> 会丢失 `Fcitx5Config/Fcitx5Utils` 的包含目录，导致编译报
> `fcitx-config/configuration.h` 找不到。此时改用上文的 CMake 路线，
> 或将 fcitx5 开发前缀放在纯 ASCII 路径（如 `/tmp/fcitx5root`，可用
> `tools/setup_fcitx5root.sh` 从 RPM 解包，见下文测试一节），或直接
> 系统级安装 fcitx5-devel（包管理装到 /usr，路径纯 ASCII，不受影响）。

## 数据管线

```
zhuan/seal.db 查表链 ──────────┐ 字符集：seal_char 全量 ∪ luna 单字表
rime luna_pinyin.dict.yaml ────┤
                               ├─→ tools/export_char_map.py ─→ data/langya.map
                               │    （汉字 ⇥ 小篆码点 ⇥ 楷化字，UTF-8 TSV）
xmake download-dict ───────────┘ 锁定 commit 下载 luna 词表到 tools/cache/
```

- `langya.map` 是唯一词典产物：转换在导出时预跑（zhuan 完整查询链：
  别名 → 本字 → 变体闭包 → 說文對位 → OpenCC 简繁 → 借聲符），
  运行时零依赖
- 說文未收的现代字（你、这等）不进 map，引擎按原字回退，
  候选窗口显示「說文未收」，不影响上屏
- 与 Android 插件打包同一份 `langya.map`（APK 内路径
  `assets/usr/share/fcitx5/langya/langya.map`），两端口径一致；
  改动 core/ 或映射表后，在仓库根运行 `xmake sync-android` 增量同步
  （core/ → 宿主树 plugin/langya/src/main/cpp/core 镜像，映射表经
  data/ 目录随插件模块打进 APK），再 `xmake build-android` 重编

## 目录结构

```
langya/
├── CMakeLists.txt           # Linux 工程入口
├── core/                    # 引擎核心（与 Android 版共享，勿放平台代码）
│   ├── langyaengine.*       # 输入法引擎（键处理/候选/模式切换/CharMap）
│   ├── addonfactory.cpp     # addon 工厂
│   ├── chttrans.conf        # 简繁转换配置（OpenCC 港繁档位）
│   ├── langya-addon.conf.in # addon 注册模板
│   └── langya.conf.in       # 输入法条目模板
├── xmake.lua                # xmake 构建（与 CMake 同步，Linux 侧）
├── data/                    # 生成的映射（xmake export-char-map 产出）
├── tools/                   # 数据管线与字体运维脚本（入口见 xmake 任务）
├── tests/                   # 引擎集成测试（xmake engine-test）
└── android/                 # fcitx5-android 插件（见 docs/mobile/agent.md）
```

## 测试

`tests/` 是引擎集成测试：借 fcitx5 官方 testing 设施（testfrontend）
注入真实按键事件，在完整 fcitx5 运行时内端到端验证 23 项：
「拼音 → 候选 → 上屏」、双模式切换与持久化、数字选词、翻页保持高亮位、
NumLock 组字回归、标点转换（组字吞键与 zh_CN 表）、退格改键，以及
常用单字排序回归（yi 首选「一」、de 首选「的」、ma 首选「吗」——
守护 libime 语言模型缺失时不回退为生僻字排序，见 task-16 修复）。

```bash
# 无系统级 fcitx5-devel 时，先解包本地前缀（幂等；含标点表、sc.dict
# 等运行数据，从 android 宿主树 assets 回退补齐）：
tools/setup_fcitx5root.sh
export FCITX_ROOT=/tmp/fcitx5root
export PKG_CONFIG_PATH=$FCITX_ROOT/usr/lib64/pkgconfig

# 构建 langya 与测试驱动，布置三件套后运行（LANGYA_SO 可覆盖被测引擎）：
xmake engine-test
```

当前 23 项全部通过（fcitx5 5.1.23），样例覆盖：
wo→𿕾（我）、模式切换→我、重新激活保持模式、zhongguo→𽄙𾇓（中國）、
ni+2→拟、NumLock 下 wo→𿕾、ni+PageDown+1→呢（未收回退）、
翻页保持高亮位、方向键浏览、标点（，。「、）与 woh+退格→𿕾。

## Android 版

见 [android/](../../android/)——同一份 `core/` 构建的 fcitx5-android 插件，
打包同一份 `data/langya.map`。

## 许可

- 代码：MIT（见 LICENSE）
- 映射数据：转换映射源自 Unicode UCD（SealSources.txt，Unicode 授权）
  与維基文庫《說文解字》转录（CC BY-SA 4.0）的派生索引，分发时需携带
  相应署名；libime 运行数据（sc.dict、zh_CN.lm）来自宿主，不随本项目分发
