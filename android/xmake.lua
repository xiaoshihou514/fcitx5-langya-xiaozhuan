-- fcitx5-android 宿主树管理任务（替代原 scripts/setup.sh 与 sync.sh）。
--
-- 用法：
--   xmake setup-android    初始化宿主树（克隆＋递归子模块＋挂载＋注册）
--   xmake sync-android     增量同步插件模块/引擎核心/词典到宿主树
--   xmake build-android    构建插件 APK（gradle 封装，内存友好默认值）
-- 环境变量：
--   LANGYA_HOST_DIR  宿主树位置（默认按 PINNED_REF 命名于 android/build/）
--   LANGYA_REF       覆盖检出的分支/标签/SHA（默认锁定 PINNED_REF）
--   LANGYA_ABI       目标 ABI（默认 arm64-v8a）
--
-- 可复现性：默认检出官方发行版提交（见 PINNED_REF），宿主树内嵌的
-- fcitx5/libime 等由该提交的 gitlink 锁定；插件须与手机上宿主版本一致。

-- 官方 fcitx5-android 0.1.3（git describe: 0.1.3-0-g048f581c）
local PINNED_REF = "048f581c652367567b8ee5c28c5163b805288895"
--
-- 注：同步逻辑写在 on_run 脚本作用域内（完整 os 模块只在脚本作用域
-- 挂载；项目顶层闭包只有限 os）。

local function host_dir()
    -- 仅用受限 os 支持的 getenv/isdir，可在顶层安全调用
    return os.getenv("LANGYA_HOST_DIR")
        or path.join(os.projectdir(), "android", "build",
                     "fcitx5-android-0.1.3")
end

task("sync-android")
    set_category("langya")
    on_run(function ()
        local host = host_dir()
        if not os.isdir(path.join(host, ".git")) then
            raise("宿主树 " .. host .. " 不存在，先运行 xmake setup-android")
        end
        local core = path.join(os.projectdir(), "core")
        if not os.isdir(core) then
            raise("未找到 core/（引擎核心应位于仓库根）")
        end

        local dest = path.join(host, "plugin", "langya")
        os.mkdir(dest)
        -- 1) 插件模块骨架：合并复制（保留宿主树内 gradle/cmake 增量产物）
        os.cp(path.join(os.projectdir(), "android", "plugin", "."), dest)
        -- 2) 引擎核心：镜像同步（先清空再复制，等价 rsync --delete）
        local core_dest = path.join(dest, "src", "main", "cpp", "core")
        os.tryrm(core_dest)
        os.cp(path.join(core, "."), core_dest)
        -- 复制后统一 touch：os.cp 保留源 mtime，若早于上次构建，
        -- gradle/cmake 增量会跳过重编（真机踩过：APK 里是旧 .so）
        os.execv("bash",
                 {"-c", "find '" .. core_dest
                  .. "' \\( -name '*.cpp' -o -name '*.h' \\) -exec touch {} +"})
        -- 3) 词典
        local map = path.join(os.projectdir(), "data", "langya.map")
        os.mkdir(path.join(dest, "src", "main", "cpp", "data"))
        if os.isfile(map) then
            os.cp(map, path.join(dest, "src", "main", "cpp", "data",
                                 "langya.map"))
        else
            print("提示：缺 data/langya.map，映射未同步。"
                .. "请先运行 xmake export-char-map")
        end
        print("已同步 → %s", dest)
    end)
    set_menu {
        usage = "xmake sync-android",
        description = "同步插件模块/引擎核心/词典到 fcitx5-android 宿主树",
    }

task("setup-android")
    set_category("langya")
    on_run(function ()
        local host = host_dir()
        local ref = os.getenv("LANGYA_REF") or PINNED_REF
        if not os.isdir(path.join(host, ".git")) then
            print("克隆 fcitx5-android（%s）…", ref)
            os.mkdir(path.directory(host))
            os.execv("git", {"clone", "--no-checkout",
                             "https://github.com/fcitx5-android/fcitx5-android.git",
                             host})
            -- 分支/标签/SHA 统一经 fetch+checkout（SHA 对齐官方发行版）
            os.execv("git", {"-C", host, "fetch", "--depth", "1",
                             "origin", ref})
            os.execv("git", {"-C", host, "checkout", "FETCH_HEAD"})
        end
        -- 构建插件所需子模块（fcitx5 本体 / prebuilt / libime）
        print("初始化子模块（fcitx5 / prebuilt / libime）…")
        -- --recursive：libime 内嵌 kenlm 等二级子模块一并锁定
        os.execv("git", {"-C", host, "submodule", "update", "--init",
                         "--recursive", "--depth", "1",
                         "lib/fcitx5/src/main/cpp/fcitx5",
                         "lib/fcitx5/src/main/cpp/prebuilt",
                         "lib/libime/src/main/cpp/libime"})
        -- 同步（与 sync-android 相同的脚本作用域逻辑）
        local core = path.join(os.projectdir(), "core")
        -- 宿主树补丁：冷启动时 PackageManager 可能还解析不到插件活动
        -- （fcitx 先于用户解锁启动），仅靠意图查询会把已安装插件当卸载
        -- 处理、误清插件数据，附加组件随之被禁用（上游 issue #410）。
        -- 补丁让插件扫描并入已装载插件的持久记录（仍在安装即保留）。
        local patch = path.join(os.projectdir(), "android", "patches",
                                "0001-datamanager-cold-boot-plugin-scan.patch")
        if os.isfile(patch) then
            local fresh = true
            try {
                function () os.execv("git", {"-C", host, "apply", "--check", patch}) end,
                catch { function (errs) fresh = false end }
            }
            if fresh then
                os.execv("git", {"-C", host, "apply", patch})
                print("已套用宿主补丁：冷启动插件扫描保护")
            else
                print("宿主补丁已套用或不再适用，跳过")
            end
        end
        local dest = path.join(host, "plugin", "langya")
        os.mkdir(dest)
        os.cp(path.join(os.projectdir(), "android", "plugin", "."), dest)
        local core_dest = path.join(dest, "src", "main", "cpp", "core")
        os.tryrm(core_dest)
        os.cp(path.join(core, "."), core_dest)
        -- 复制后统一 touch：os.cp 保留源 mtime，若早于上次构建，
        -- gradle/cmake 增量会跳过重编（真机踩过：APK 里是旧 .so）
        os.execv("bash",
                 {"-c", "find '" .. core_dest
                  .. "' \\( -name '*.cpp' -o -name '*.h' \\) -exec touch {} +"})
        local map = path.join(os.projectdir(), "data", "langya.map")
        os.mkdir(path.join(dest, "src", "main", "cpp", "data"))
        if os.isfile(map) then
            os.cp(map, path.join(dest, "src", "main", "cpp", "data",
                                 "langya.map"))
        end
        -- 注册 gradle 模块
        local settings = path.join(host, "settings.gradle.kts")
        local text = io.readfile(settings)
        if not text:find(":plugin:langya", 1, true) then
            io.writefile(settings,
                         text .. "\ninclude(\":plugin:langya\")\n")
            print("已在 settings.gradle.kts 注册 :plugin:langya")
        else
            print("settings.gradle.kts 已包含 :plugin:langya")
        end
        print("已同步 → %s", dest)
        print("后续步骤（需要 Android SDK、NDK、CMake；构建插件 APK）：")
        print("  cd %s", host)
        print("  ./gradlew :plugin:langya:assembleDebug")
        print("  产物：plugin/langya/build/outputs/apk/debug/*.apk，")
        print("  与宿主 App（同版本）一同安装，插件管理中启用琅琊小篆")
    end)
    set_menu {
        usage = "xmake setup-android",
        description = "初始化 fcitx5-android 宿主树并挂载琅琊插件模块",
    }

task("build-android")
    set_category("langya")
    on_run(function ()
        local host = host_dir()
        if not os.isdir(path.join(host, ".git")) then
            raise("宿主树 " .. host .. " 不存在，先运行 xmake setup-android")
        end
        local abi = os.getenv("LANGYA_ABI") or "arm64-v8a"
        -- 默认 release：debug 版 action 带 .debug 后缀，正式宿主
        -- （包可见性查询）发现不了插件
        local buildType = os.getenv("LANGYA_BUILD_TYPE") or "release"

        -- GraalVM 的 jlink 处理不了 android 平台包：非标准 JDK 时提示
        local ver = os.iorunv("bash",
            {"-c", "java -version 2>&1 | head -1"}) or ""
        if ver:lower():find("graal") then
            print("警告：当前 Java 为 GraalVM，jlink 不兼容 android "
                .. "平台包；若构建失败请 JAVA_HOME 指向标准 JDK 21")
        end

        -- Android SDK：环境变量 → 常见安装位置探测（宿主 gradle 需要）
        local sdk = os.getenv("ANDROID_HOME")
        if not sdk or sdk == "" then
            local home = os.getenv("HOME") or ""
            for _, cand in ipairs({
                    path.join(home, "Applications", "android-studio-sdk"),
                    path.join(home, "Android", "Sdk"),
                    "/opt/android-sdk", "/usr/lib/android-sdk"}) do
                if os.isdir(path.join(cand, "platforms")) then
                    sdk = cand
                    break
                end
            end
        end
        if not sdk or sdk == "" then
            raise("未找到 Android SDK：请设 ANDROID_HOME，或安装在 "
                .. "~/Applications/android-studio-sdk、~/Android/Sdk 等常见位置")
        end
        print("Android SDK：%s", sdk)

        -- ECM（KDE extra-cmake-modules，宿主 fcitx5 配置需要）：
        -- 环境变量 → 系统安装 → 本地前缀 android/build/ecm-root（持久，
        -- 不受 /tmp 清空影响）→ 均无则自动下载安装（extra-cmake-modules
        -- 5.116.0，源 https://download.kde.org/stable/frameworks/5.116/）
        local ecm = os.getenv("ECM_DIR")
        if not ecm or ecm == "" then
            local ecmroot = path.join(os.projectdir(), "android", "build",
                                      "ecm-root")
            for _, cand in ipairs({"/usr/share/ECM/cmake",
                                   path.join(ecmroot, "share", "ECM", "cmake"),
                                   path.join(ecmroot, "usr", "share", "ECM",
                                             "cmake")}) do
                if os.isfile(path.join(cand, "ECMConfig.cmake")) then
                    ecm = cand
                    break
                end
            end
            if not ecm then
                print("未找到系统 ECM，自动安装 extra-cmake-modules "
                    .. "5.116.0 → %s", ecmroot)
                local srcdir = path.join(os.projectdir(), "android", "build",
                                         "src", "ecm")
                os.mkdir(srcdir)
                local tgz = path.join(srcdir,
                    "extra-cmake-modules-5.116.0.tar.xz")
                if not os.isfile(tgz) then
                    os.execv("bash", {"-c",
                        "curl -fsSLo '" .. tgz
                        .. "' https://download.kde.org/stable/frameworks/"
                        .. "5.116/extra-cmake-modules-5.116.0.tar.xz"})
                end
                os.execv("bash", {"-c",
                    "cd '" .. srcdir .. "' && tar xf "
                    .. "extra-cmake-modules-5.116.0.tar.xz"})
                local verdir = path.join(srcdir,
                                         "extra-cmake-modules-5.116.0")
                os.execv("cmake", {"-S", verdir,
                                   "-B", path.join(verdir, "build"),
                                   "-DCMAKE_INSTALL_PREFIX=" .. ecmroot,
                                   "-DBUILD_TESTING=OFF"})
                os.execv("cmake", {"--install", path.join(verdir, "build")})
                ecm = path.join(ecmroot, "share", "ECM", "cmake")
            end
        end
        if not ecm or ecm == "" then
            raise("缺 ECM（extra-cmake-modules）：请系统安装并重试，"
                .. "或设 ECM_DIR 指向其 cmake 目录")
        end
        print("ECM：%s", ecm)

        -- gradle 缓存：默认放 android/build/gradle-home（持久）。默认的
        -- /tmp/gradle-home 会被 /tmp 清空策略抹掉；~/.gradle 在部分机器
        -- 只读。gradlew 发行包缓存也经 GRADLE_USER_HOME 一并改道。
        local ghome = os.getenv("LANGYA_GRADLE_HOME") or path.join(
            os.projectdir(), "android", "build", "gradle-home")

        local envs = {
            ECM_DIR = ecm,
            ANDROID_HOME = sdk,
            GRADLE_USER_HOME = ghome,
            CMAKE_BUILD_PARALLEL_LEVEL = "4",
        }
        -- release 需签名：默认复用 SDK 调试密钥（插件加载不校验签名，
        -- 仅供本地安装；正式分发请设 SIGN_KEY_FILE 换自己的密钥）
        if buildType == "release" and not os.getenv("SIGN_KEY_FILE") then
            local ks = path.join(os.getenv("HOME") or "", ".android",
                                 "debug.keystore")
            if os.isfile(ks) then
                envs.SIGN_KEY_FILE = ks
                envs.SIGN_KEY_PWD = "android"
                envs.SIGN_KEY_ALIAS = "androiddebugkey"
                print("签名：复用 SDK 调试密钥 %s", ks)
            else
                raise("release 构建需签名：生成或指定 keystore"
                    .. "（SIGN_KEY_FILE/PWD/ALIAS），或创建 ~/.android/"
                    .. "debug.keystore")
            end
        end

        os.execv(path.join(host, "gradlew"),
                 {":plugin:langya:assemble" .. buildType, "--no-daemon",
                  "-Dorg.gradle.workers.max=2",
                  "-Dkotlin.daemon.jvm.options=-Xmx1024m",
                  "-Dgradle.user.home=" ..
                      (os.getenv("LANGYA_GRADLE_HOME") or "/tmp/gradle-home"),
                  "-Pandroid.injected.build.abi=" .. abi,
                  "-Pandroid.injected.testOnly=false"},
                 {curdir = host, envs = envs})

        -- 产物定位（单 ABI 注入时落在 intermediates/apk）
        local base = path.join(host, "plugin", "langya", "build")
        for _, d in ipairs({"outputs/apk/" .. buildType,
                            "intermediates/apk/" .. buildType}) do
            local apks = os.files(path.join(base, d, "*" .. abi .. "*.apk"))
            if apks and apks[1] then
                for _, f in ipairs(apks) do
                    print("APK：%s", f)
                end
                return
            end
        end
        raise("未找到 " .. abi .. " 的 APK 产物")
    end)
    set_menu {
        usage = "xmake build-android",
        description = "构建插件 APK（默认 release/arm64-v8a；"
            .. "LANGYA_BUILD_TYPE/LANGYA_ABI/SIGN_KEY_* 可覆盖）",
    }
