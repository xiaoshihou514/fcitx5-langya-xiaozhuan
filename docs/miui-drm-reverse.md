# MIUI 主题 DRM 完整逆向（C 线结案）

目标：伪造 rights 授权文件（.mra），使字体校验永久通过（治本不掉落）。
结论：**密码学上不可行**——但完整格式与验证逻辑已摸清，归档如下。

## 材料与方法

- `miui-framework.jar`（/system_ext/framework/，boot classpath 真身）
  → jadx 反编译 → `miui/drm/DrmManager.java`（559 行）、`miui/util/RSAUtilsCompat.java`
- `MILanProVF.mtz` 的 `rights/*.mra` 样本

## .mra 文件格式（rights 文件）

XML，root 元素：
- 属性 `O_EX_ID_CATEGORY` 对应名 = **签名的十六进制串**
- 子节点序列化（Transformer 输出）= **被签名的 contentPart**
- 内容字段（XPath 解析）：
  - `assets`：授权内容的 SHA1 列表（逗号分隔，多个资产）
  - `imeis`：设备 VAID 绑定列表（**可为空；含 "-1" 视为不限**）
  - `startTime`/`endTime`：时间窗（**endTime=0 = 永久**）

## 验证链（DrmManager.isLegal）

```
isLegal(context, hash/contentFile, rightsFile)
  1. rightsFile 不存在 → RIGHT_FILE_NOT_EXISTS（掉落场景即此）
  2. parseRightsFile → isRightsFileLegal：
     RSA SHA1withRSA 验签（公钥硬编码，e=10001，2048 位 m）
     ——RSAUtilsCompat 用标准 JCA Signature.getInstance("SHA1withRSA")
       （教科书验签的可伪造攻击面：Bleichenbacher e=3 / padding
       不严格——标准实现+e=65537 全部不适用）
  3. ro.assets 包含内容 SHA1 → 否则 ASSET_NOT_MATCH
  4. imeis 空 → 跳过；含 -1 → 过；否则须匹配本机 VAID
  5. endTime=0 → 永久；>0 → 检查当前时间窗
  → DRM_SUCCESS
```

## 结论与推论

1. **伪造 .mra 不可行**：无小米私钥则造不出合法签名；无签名则
   parseRightsFile 返回 null → RIGHT_OBJECT_IS_NULL，不可能 SUCCESS。
2. 小米自家 rights 是「永久 + 不限设备」宽松格式——安全性 100% 依赖
   签名本身。
3. **掉落判定依据确认**：字体内容 SHA1 不在任何合法签名 rights 的
   assets 列表 → 判非法 → system 侧回退（我们带 MILanPro 的 .mra
   也掉，因 hash 不匹配，与逆向结论自洽）。
4. rights 解析有 mRightsCache（按文件 lastModified 缓存）。

## 剩余路线

- **A（取证 v5，运行中）**：掉落执行者（system 侧）若用另一套更简单的
  校验（存在性/别的标志位），仍有机会；第四次掉落将抓到执行进程日志。
- 终极后备：root（KernelSU + hook isLegal 一行返回 true）。

*2026-10-26*
