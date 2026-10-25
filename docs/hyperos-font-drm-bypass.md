# 在自己的手机上装一块字体：HyperOS 3 主题 DRM 逆向记

> 「为什么官方主题本地导入也没法应用字体，这不合理呀」——用户这句话，是整场战役的转折点。
>
> 这篇文章记录如何在一台**无 root** 的小米 HyperOS 3 手机上，装上一块自制的「说文小篆」字体。全程只用 adb 和一台电脑，最终以一个 30 字节的 JSON 字段注入攻破了小米的主题 DRM。

## 0x00 背景：一块没有字体的文字

我在做一个fcitx5-android 的拼音输入法插件「琅琊」——打拼音，上屏《說文解字》小篆。它依赖 Unicode 18.0 新增的小篆区块（U+3D000–3FC3F，11,328 个码位）：码位是权威标准，但**手机上没有任何字体包含这些字形**，于是上屏的内容长这样：

```
□□□□，□□□□□
```

我自己造了字体（从 Unicode 官方码表 PDF 提取四家篆体轮廓，另文再表），问题只剩一个：怎么让手机认识它？这是一台小米，HyperOS 3.0，**不解锁 BL，不 root**。

## 0x01 排雷：把所有正路走一遍

先说结论——正路全是死的，而且每条都是亲手验证的死，不是猜的。

**① MIUI 字体主题包（.mtz）**。HyperOS 的主题壁纸 app 支持导入本地 mtz，字体包的机制是 `fonts/Roboto-Regular.ttf` 全局替换。我把字体做成「MiSans 为底 + 仅注入 U+3D000 小篆区」的合并字体打了包——日常文字零观感差异，小篆码点正常显示。第一次导入：无反应。拆开系统自带的 `MILanProVF.mtz` 对照，补齐 `description.xml` 全部字段、四张预览图、rights 目录后，导入终于走通（`.data/meta/fonts/` 下生成了 `.mrm` 元数据）——但点「应用」，毫无动静。

**② 官方包对照实验**。把系统自带的官方字体包推回去导入，同样无法应用。这排除了「我们包做得不对」的假设：**问题在应用环节本身**。

**③ 直写主题目录**。逆向已知字体生效点是 `/data/system/fonts/theme_webview/`（一个 symlink 链）。目录 DAC 权限 777，满心欢喜 `mv` 进去——SELinux `Enforcing` 拒绝，shell 域对 `theme_data_file` 没有任何写权限。`cp`/`mv`/`rm`/`ln` 全试，全灭。

**④ RRO overlay**。系统内置的字体切换（如 Noto Serif）走的是标准 AOSP 机制：`category="android.theme.customization.font"` 的 overlay APK 覆盖 framework 的 `config_bodyFontFamily` 字符串。我依样画了一个 8KB 的 overlay，安装被 PackageManager 拒绝：

```
Overlay ... and target android signed with different certificates,
and the overlay lacks <overlay android:targetName>
```

拆 framework-res 一看，`config_bodyFontFamily` **没有 overlayable 声明**——按 AOSP 安全模型，无 overlayable 声明的资源只允许平台签名覆盖。预置字体包是平台签名的，我不是。死。

**⑤ 开源界现状**。SonderIcons（GPL-3.0，HyperOS 免 root 主题修改的标杆）README 明写「HyperOS 3 不支持：主题目录已锁、Theme backup 需向小米请求权限」；zfont3 闭源；maxikin 走 KernelSU——都要 root。

至此，用户的直觉「不合理」得到了证实：**HyperOS 3 把字体应用限制在主题商店在线渠道和系统预置两条路上，本地导入的包无论出身，一概不给应用的资格**。字体是小米主题商店的付费品类，这是商业决策。

但是——我的手机，我的字体。

## 0x02 下钻：53MB 的主题 app

反编译 `com.android.thememanager`（jadx，53MB，1.5 万个类）。目标很明确：找到「应用」按钮的执行路径，看判断条件长什么样。

顺着 `LocalFontProviderManager.toq()` → `ThemeHelper.g()` 摸到了 DRM 闸门：

```java
// ThemeHelper.g —— 所有资源应用的必经之路
DrmManager.DrmResult result = ResourceRightsHelper.k(...); // miui.drm 校验
if (result == DRM_SUCCESS) {
    ThemeApplyUtils.s(...);   // 真正的应用
    return;
}
// rights 文件缺失/不匹配 → 尝试在线补购（需要商店商品身份）→ 失败
status = 97;                   // 静默失败，无任何 UI 提示
```

这解释了全部现象：本地包没有 rights 授权文件，在线补购又没有商品 ID，于是「应用」点了等于没点。**官方包本地导入也一样死**——rights 不在本地，身份不在服务端。

关键在校验函数 `DrmService.q()`，逐行读它的时候，三个连续的提前返回跳了出来：

```java
if (TextUtils.isEmpty(contentPath))      return DRM_SUCCESS;  // ① 空
if (new File(contentPath).getAbsolutePath()
        .startsWith("/system"))          return DRM_SUCCESS;  // ② 系统路径
if (rightsPath == null)                  return DRM_SUCCESS;  // ③ 无 rights 定义
// ...以上都不满足，才走到
return DrmManager.isLegal(app, sha1(contentPath), rightsFile);
```

`DRM_SUCCESS` 三连——免检通道就写在光天化日之下。①和③没用：内容为空/未定义 rights 的资源没法用。但 **②**：

> 只要 contentPath 以 `/system` 开头，直接放行。

而它的判断方式是——

```java
new File(path).getAbsolutePath().startsWith("/system")
```

**`getAbsolutePath()` 不解析 `..`**。Java 的 `File` 只有 `getCanonicalPath()` 才做路径规范化，`getAbsolutePath()` 是纯字符串拼接。也就是说：

```java
new File("/system/../sdcard/Download/font.ttf").getAbsolutePath()
// → "/system/../sdcard/Download/font.ttf"
// startsWith("/system") == true  ✓ DRM 放行
```

而后续真正读文件的代码把路径交给内核，内核老老实实解析 `..`，读到的就是 `/sdcard/Download/font.ttf`。

经典的 check-without-normalize。DRM 检查的是一条路径，应用读取的是另一条。

## 0x03 注入：一个 30 字节的补丁

剩下的问题是：contentPath 从哪来、能不能改。

它存在 `.mrm` 元数据文件里（JSON）——而 `.mrm` 位于：

```
/sdcard/Android/data/com.android.thememanager/files/MIUI/theme/.data/meta/fonts/<uuid>.mrm
```

在 sdcard 上。`ls -Z` 看权限：`-rw-rw---- system_theme ext_data_rw`。而 adb shell 的补充组里恰好有 `ext_data_rw`——**组写权限，可改**。

于是补丁就一行（sed 版）：

```bash
toybox sed -i 's|"contentPath": null|"contentPath": "/system/../sdcard/.../fonts/<uuid>.mrc"|' <mrm>
```

把 contentPath 从 `null`（运行时自动构造为 sdcard 标准路径，不免税）改成 `/system/../sdcard/.../<uuid>.mrc`（实际指向同一个文件，但 DRM 眼里它在 `/system` 下）。

## 0x04 两次空枪

补丁打完，让用户点应用——日志显示校验照旧。空枪两发，各有一个教训：

**第一枪：应用动作会重建条目。** 首次点「应用」失败后，主题 app 把资源条目整个重建了：uuid 从 `ec98f9a5` 变成 `1d8d9044`，旧 `.mrm` 删除。我的补丁打在了已经不存在的条目上。

**第二枪：内存缓存。** 补丁打对文件后，应用列表的数据依然来自 `MemoryDataManager` 的进程内存缓存，不会重读 `.mrm`。**必须强杀主题 app 进程**，让资源从磁盘重新加载。

两个坑都填上（patch 新 uuid + `am force-stop`），第三枪：

```
I theme   : check rights isLegal: 小米兰亭Pro,34cbc671...,null
I OnlineResourceDetailPre: result is: DRM_SUCCESS        ← 闸门开了
E APP-AVTT: illegal theme component found: .../fonts/Roboto-Regular.ttf
           hash:34cbc671 DRM_ERROR_UNKNOWN               ← 事后校验报警
```

`DRM_SUCCESS`！应用流程完整执行。事后那行 `APP-AVTT` 报警（应用完成后的自检）看着吓人，但它**只记日志，不回滚**——落盘为证：

```
/data/system/theme/fonts/Roboto-Regular.ttf  30779780 字节（我们的合并字体）
MI_Theme_VF.ttf -> Roboto-Regular.ttf        （系统自动挂的全套字重 symlink）
Miui-Regular.ttf -> Roboto-Regular.ttf
Roboto-Bold.ttf  -> Roboto-Regular.ttf
...
/data/system/fonts/theme_webview/Roboto-Regular.ttf -> /data/system/theme/fonts/Roboto-Regular.ttf
```

MIUI 不仅把字体装了进去，还自动为所有字重（Miui-Light 到 Roboto-Black，17 个）创建了指向它的符号链接，并把 WebView 字体链一并切换。重启手机，一切生效：日常文字依旧是 MiSans 的样子，小篆码点正常显示。

```bash
adb shell ls /data/system/theme/fonts/   # 你现在是系统字体了
```

## 0x05 复盘

**攻击面总览**：

```
应用按钮
  └─ ThemeHelper.g
       ├─ DrmService.q ──── contentPath.startsWith("/system") ──→ DRM_SUCCESS ← 命中
       │                    （getAbsolutePath 不解析 ".."）
       └─ ApplyThemeTask ── 写 /data/system/theme/fonts/（system_theme 域）
                            .mrm 在 sdcard（ext_data_rw 组可写）← 注入点
```

**攻防双方的失误清单**：

| 层 | 失误 |
|---|---|
| DRM 判断 | 用 `getAbsolutePath()` 而非 `getCanonicalPath()` 校验路径前缀 |
| 元数据存储 | `.mrm`（含 contentPath 字段）放在 shell 可写的 sdcard 分区 |
| 缓存设计 | 应用流程重建条目却让旧元数据残留，反而给了观察窗口 |

修复其实只要一行——把 `startsWith` 的判断对象换成 `getCanonicalPath()`。小米大概率会修，届时这条路关闭，但方法论不变：**找到「检查用路径 A、使用用路径 B」的每一处接缝**。

**为什么写这篇**。整个过程里最动人的不是漏洞，是那个用户直觉——「官方主题也装不上，这不合理」。商业公司把「不合理」做成了设计，而逆向工程就是把这个不合理一寸寸拆开看哪里是坚固的墙、哪里是画上去的门。这扇门是画上去的。

## 附：工具链

全部产物在 [langya 仓库](../README.md)：

- `tools/build_mtz.py` —— 合并字体 + 完整 mtz 打包（一条命令）
- `tools/patch_mrm.sh` —— DRM 免检补丁（参数化 uuid，自动备份）
- `tools/make_misans_merge.py` —— MiSans + 小篆区合并（root 方案的 maxikin 配套）

*2026-10-24*
