# langya/android — 琅琊·说文小篆输入法（fcitx5-android 插件）

[fcitx5-android](https://github.com/fcitx5-android/fcitx5-android) 的原生
引擎插件：拼音输入，上屏《說文解字》小篆（Unicode 18.0 小篆区
U+3D000–3FC3F）或楷化字，Ctrl+Shift+S 切换（移动端建议在实体键盘场景
使用；虚拟键盘下的切换入口见路线图）。

引擎核心与 Linux 桌面版（仓库根的 `core/`）共享同一份 C++ 代码，
本目录只维护 Android 插件外壳与构建脚本。

## 工作方式

fcitx5-android 的插件必须是**其源码树内的 gradle 模块**（依赖宿主的
build-logic 约定插件与 `:lib:fcitx5` prefab 原生库），因此本仓库不直接
产出 APK，而是：

```
xmake setup-android（仓库根运行）
  ├─ 浅克隆 fcitx5-android（锁定 PINNED_REF=官方 0.1.3）
  ├─ 递归子模块（fcitx5/prebuilt/libime＋kenlm，由 gitlink 锁定）
  ├─ plugin/ + {core,data} → …/plugin/langya
  └─ settings.gradle.kts 注册 include(":plugin:langya")
```

**可复现**：宿主树默认检出官方发行版提交（0.1.3-0-g048f581c），
子模块随该提交的 gitlink 锁定；词典数据源亦按 commit 锁定（见
根目录 xmake.lua 的 download-dict）。插件 APK 与手机上官方宿主
版本一致即可直接安装使用。

之后在宿主树内用 gradle 构建插件 APK，与宿主 App（**同版本**，插件
apiVersion 0.1 需与宿主匹配）一起安装。

## 环境要求

- Android SDK Platform & Build-Tools 35
- Android NDK（side-by-side）25＋、CMake 3.22.1（构建时按宿主要求自动安装）
- KDE extra-cmake-modules（ECM）：系统包安装，或设
  `ECM_DIR=<ECM 的 cmake 目录>`（宿主的 fcitx5 原生库配置需要）
- JDK 17＋（注意：GraalVM 的 jlink 无法处理 android 平台包，
  需用标准 JDK，如 Temurin 21）、git
- 构建词典需要：`../../zhuan`（seal.db 查表链，uv 环境）
- 注：若全局 gradle 镜像（如 aliyun）缺失新版构件，可用
  `-Dgradle.user.home=<干净目录>` 绕开 `~/.gradle/init.gradle`

## 构建

全部经 xmake（含克隆/子模块/构建），无需手敲 gradle：

```bash
# 仓库根执行
xmake download-dict && xmake export-data   # 1) 词典数据（锁 commit）
xmake setup-android                        # 2) 宿主树（锁官方 0.1.3）
xmake build-android                        # 3) 插件 APK（默认 arm64-v8a）

# 迭代：改了 core/ 或词典后
xmake sync-android && xmake build-android

# 环境变量（均有默认）：
#   LANGYA_ABI=arm64-v8a|armeabi-v7a|x86_64|x86   目标 ABI
#   LANGYA_REF=<分支/标签/SHA>   覆盖宿主版本（默认 PINNED_REF）
#   LANGYA_GRADLE_HOME=<目录>    gradle 依赖缓存（默认 /tmp/gradle-home）
```

产物：APK 路径由 `xmake build-android` 直接打印。

已在本机验证（2026-10）：官方 0.1.3 对应树构建成功（单 ABI 约
3 分钟、增量 18 秒），APK 内含
`lib/<abi>/langya.so`、`assets/usr/share/fcitx5/{addon,inputmethod}/langya.conf`
与词典 `assets/usr/share/fcitx5/langya/langya.tsv`。

## 安装与启用

1. 安装 fcitx5-android 宿主 App（官方发行版或自建，版本须与克隆的宿主树一致）
2. 安装插件 APK
3. 宿主 App → 插件管理 → 启用「琅琊小篆」
4. 添加输入法「琅琊小篆」，即可拼音打字上屏小篆/楷化字

> 小篆字形显示：目标应用需有小篆字体。可安装 zhuan 项目生成的
> `shuowen-seal-*.ttf`（覆盖通行字）或 Noto Serif Seal；无字体时
> 小篆码点显示为方框，但码点本身是标准数据。

## 目录结构

```
langya/android/
├── xmake.lua                    # setup/sync/build-android 任务（PINNED_REF 锁版本）
├── plugin/                      # 插件模块（同步进宿主树 plugin/langya）
│   ├── build.gradle.kts         # 约定插件 + native-app + fcitx-component
│   ├── licenses/libraries/      # 第三方组件许可清单
│   └── src/main/
│       ├── AndroidManifest.xml
│       ├── cpp/CMakeLists.txt   # prefab fcitx5 → add_subdirectory(core)
│       └── res/                 # plugin.xml（apiVersion 0.1）＋图标
└── README.md
```

## 与 Linux 版的差异

| | langya（Linux） | langya/android |
|---|---|---|
| 构建系统 | 独立 CMake 工程 | fcitx5-android 树内 gradle 模块 |
| fcitx5 依赖 | 系统包（CONFIG） | 宿主 prefab（MODULE） |
| 引擎 .so | `install` 到 lib/fcitx5 | externalNativeBuild → jniLibs |
| 词典数据 | install 到 share/fcitx5/langya | prebuilt-assets 打进 APK |

## 已知边界与路线图

- 真机验证待做：本机 qemu-headless 模拟器稳定段错误（图形栈崩溃，
  与插件无关），暂无法在模拟器上联调；引擎逻辑已在 Linux 端以
  fcitx5 testfrontend 集成测试覆盖（见 ../langya/tests）
- 词组拼音由单字主音合成，多音字词（如「重庆」）可能错音
- 词典为内存 TSV（约 13 MiB / 28 万条），启动加载与内存占用待优化
  （v2 计划：libime 式二进制格式＋按需分页）
- 說文未收的现代常用字（你、这等）按原字回退上屏，候选标注「說文未收」
- 虚拟键盘下的模式切换 UI（宿主无实体键 Ctrl+Shift+S）
- 简繁词头经 OpenCC 转换，个别异形词显示待打磨

## 许可

- 插件代码：MIT
- 词典数据：rime-luna-pinyin 与 rime-essay（LGPL-3.0）派生；
  小篆映射源自 Unicode UCD（SealSources.txt）与維基文庫《說文解字》
  转录（CC BY-SA 4.0）的派生索引，分发时需携带相应署名
