# Upstream PR draft (fcitx5-android)

> Status: draft, not submitted. Submit only if the project owner
> approves. Base branch: main (patch written against 0.1.3,
> commit 048f581c). Patch file in this repo:
> `langya/android/patches/0001-datamanager-cold-boot-plugin-scan.patch`
> (applies cleanly to 048f581c; rebuilt host app compiles).

---

## Title

DataManager: keep still-installed plugins across cold-boot scan misses

## Body

### Problem

On cold boot fcitx5-android starts before the user unlocks the device
(direct boot). At that point `PackageManager.queryIntentActivities()`
may not resolve plugin activities yet, so `DataManager.detectPlugins()`
returns an empty (or partial) plugin set. `sync()` then treats every
installed plugin as uninstalled: the merged data hierarchy is rebuilt
without the plugin's files, the diff deletes the plugin's addon/input
method configs and data from the fcitx data directory, and the new
(without-plugin) descriptor is persisted. The plugin's addons then fail
to load — the input method disappears from the list until the user
re-adds it.

This is a long-standing report; see issue #410 ("插件重启后消失",
plugin disappears after reboot). A user in that thread confirmed it
hits *all* plugin-provided input methods on affected devices while
built-in ones are unaffected, which matches the mechanism above.
Third-party plugin authors (e.g. fcitx5-android-plugin-langya) hit the
same bug in the field.

### Root cause

`detectPlugins()` relies solely on an intent-query to enumerate
plugins. That query is not reliable at direct-boot time on some
devices, and `sync()` performs destructive cleanup based on the
unreliable result.

### Fix

Persist the set of loaded plugin package names to device-protected
storage (`known-plugins.txt` next to the data descriptor) after each
successful sync. In `detectPlugins()`, union the intent query result
with the known packages that are still installed (verified via
`PackageManager.getPackageInfo`). A plugin whose package was really
uninstalled fails that check and is still cleaned up, so uninstall
behavior is unchanged; a plugin that is merely missed by the cold-boot
query is detected through its package context as before.

### Reproduction steps

1. Install fcitx5-android 0.1.3 plus any dynamic plugin APK (e.g.
   plugin.unikey or a third-party plugin) on a device where the issue
   reproduces (reported on EMUI/HarmonyOS and Android 9; timing
   dependent — slow unlock / heavy boot improves reproducibility).
2. Enable the plugin's input method, verify it works.
3. Reboot the device and unlock.
4. Observe: the plugin input method has disappeared from the input
   method list / plugin page shows load failure; logs show
   `Detected plugin packages:` without the plugin package, followed by
   file deletions in `sync()`.
5. With this patch: the same boot logs show the plugin package in
   `Detected plugin packages:` (recovered from `known-plugins.txt`),
   the plugin data survives, and the input method still works without
   re-adding.

### Notes

- The known-packages file lives in the same device-protected data
  directory as the rest of fcitx data, so it is available in direct
  boot.
- `getPackageInfo` is only used as an existence check; plugin assets
  are still read through `createPackageContext`, exactly as before.
- Open to alternative shapes (e.g. deferring destructive cleanup until
  after unlock); happy to rework.

### Testing

- Rebuilt `:app` with the patch (assembleRelease, arm64-v8a):
  successful.
- Verified the patch does not change behavior on a warm, successful
  scan: detected set is identical (query result ∪ installed known
  packages), descriptor diff and cleanup only proceed for packages
  that no longer exist.
- Field verification checklist used on a real device (langya plugin):
  reboot → logcat `Detected plugin packages` contains the plugin →
  addon loads, input method survives, no re-add needed.

---
（中文说明，供主人决策参考，不进 PR）

补丁共 65 行，仅改 app 模块的 DataManager.kt：新增 known-plugins.txt
持久记录＋扫描结果并集。风险低（真卸载行为不变），收益是所有第三方
插件作者与用户都受益。若主人同意提交，我可以 fork 后开 PR 并在
issue #410 下附链。
