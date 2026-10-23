# langya — 琅琊·说文小篆输入法（Linux fcitx5 引擎插件）

拼音输入，上屏《說文解字》小篆：基于 Unicode 18.0 小篆区（U+3D000–3FC3F，
11,328 码位），由 [zhuan](../zhuan) 项目的查表链完成「现代汉字 → 小篆码点 /
楷化字」转换。

## 特性

- 拼音连打，候选显示原词，**空格/数字上屏**
- 两种输出模式，**Ctrl+Shift+S 随时切换**：
  - 小篆模式：上屏小篆区码点（显示需装小篆字体，如本项目生成的
    `shuowen-seal-*.ttf` 或 Noto Serif Seal）
  - 楷化模式：上屏說文隸定字（常规 CJK 区，任何字体可显示）
- 候选注释给出楷化对照（說文正形与通行字不同时）
- 单一数据文件 `langya.tsv`，内存查询，无外部服务

## 构建（Linux）

依赖：CMake ≥ 3.21、C++20 编译器、fcitx5 开发包
（Fedora：`fcitx5-devel`；Debian：`fcitx5-modules-dev`）。
也可以用 xmake（见下文），两者产物等价。

```bash
# 1) 生成词典数据（依赖 zhuan 项目环境与 seal.db）
xmake download-dict && xmake export-data

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
| `langya.so` | `${prefix}/lib/fcitx5/` |
| addon 注册 | `${prefix}/share/fcitx5/addon/langya.conf` |
| 输入法条目 | `${prefix}/share/fcitx5/inputmethod/langya.conf` |
| 词典 | `${prefix}/share/fcitx5/langya/langya.tsv` |

### xmake（备选，与 CMake 同步）

`xmake.lua` 覆盖 Linux 桌面侧同一套产物（依赖经 pkg-config 定位
`Fcitx5Core.pc`；Android 仍走 `android/` 宿主树 CMake）：

```bash
export PKG_CONFIG_PATH=<fcitx5 前缀>/lib64/pkgconfig   # 系统装可省
xmake f -m release -y && xmake
xmake install -o <prefix>            # 布局同 cmake --install
```

集成测试可用任意构建产物（`LANGYA_SO` 覆盖被测引擎）：

```bash
LANGYA_SO=build/linux/x86_64/release/langya.so xmake engine-test
```

## 数据管线

```
rime luna_pinyin.dict.yaml ──┐ 单字段（多音字带相对频率）
rime essay.txt ──────────────┤ 词频表 → 常用词组按每字主音合成拼音码
                             ├─→ tools/export_data.py ─→ data/langya.tsv
zhuan/seal.db 查表链 ────────┘      (拼音, 原词, 小篆输出, 楷化输出, 权重, 标记)
```

- 词库：[rime-luna-pinyin](https://github.com/rime/rime-luna-pinyin) 与
  [rime-essay](https://github.com/rime/rime-essay)（均 LGPL-3.0）。
  luna 词表自带码（单字＋生僻词组）；常用词组频度在 essay，拼音码由
  每字主音（相对频率最高的读音）合成——多音字词可能错音，属已知边界
- 转换：逐字跑 zhuan 完整查询链（别名 → 本字 → 变体闭包 → 說文對位 →
  OpenCC 简繁 → 借聲符）；詞頭经 OpenCC 转简体作显示层
- 說文未收的现代字（你、这等）：按原字回退并打 miss 标记，
  候选窗口显示「說文未收」，不影响上屏

## 目录结构

```
langya/
├── CMakeLists.txt          # Linux 工程入口
├── core/                   # 引擎核心（与 Android 版共享，勿放平台代码）
│   ├── langyaengine.*      # 输入法引擎（键处理/候选/模式切换）
│   ├── langyadict.*        # 词典加载与查询
│   ├── addonfactory.cpp    # addon 工厂
│   ├── langya-addon.conf.in# addon 注册模板
│   └── langya.conf.in      # 输入法条目模板
├── xmake.lua               # xmake 构建（与 CMake 同步，Linux 侧）
├── data/                   # 生成的词典（xmake export-data 产出）
├── tools/                  # 数据管线（export_data.py，入口见 xmake 任务）
└── README.md
```

## 测试

`tests/` 是引擎集成测试：借 fcitx5 官方 testing 设施（testfrontend）
注入真实按键事件，在完整 fcitx5 运行时内验证「拼音 → 候选 → 上屏」、
双模式切换、数字选词与退格。

```bash
# 需先完成数据生成；FCITX_ROOT 为含 fcitx5 运行时与开发头文件的
# 前缀（任务会构建、布置 langya 三件套并运行）
xmake engine-test
```

当前 9 项全部通过（fcitx5 5.1.23）：
wo→𿕾（我）、模式切换→我、zhongguo→𽄙𾇓（中國）、ni+2→呢（未收回退）、
woh+退格→𿕾。

## Android 版

见 [android/](android)——同一份 `core/` 构建的 fcitx5-android 插件。

## 许可

- 代码：MIT（见 LICENSE）
- 词典数据：rime-luna-pinyin 为 LGPL-3.0；转换映射源自 Unicode UCD
  （SealSources.txt，Unicode 授权）与維基文庫《說文解字》转录
  （CC BY-SA 4.0）的派生索引，分发时需携带相应署名
