-- xmake 构建（与 CMakeLists.txt / core/CMakeLists.txt 保持同步）
--
-- 覆盖范围：Linux 桌面侧（引擎 .so、注册配置、词典安装）。
-- Android 端不走 xmake——它必须经 android/ 宿主树的 CMake prefab
-- 链路构建（见 android/README.md）。
--
-- 同步要点（改 core/ 时两处一起改）：
--   * 源文件列表（core/*.cpp，3 个）
--   * 语言标准 C99/C++20（无编译器扩展）、-Wall -Wextra
--   * 可见性 -fvisibility=hidden(-inlines-hidden)、
--     链接 -Wl,--no-undefined -Wl,--as-needed
--   * 产物名 langya.so（无 lib 前缀，与 conf 的 Library=langya 对应）
--   * 安装布局：lib64/fcitx5、share/fcitx5/{addon,inputmethod,langya}
--
-- 与 CMake 的已知差异：未设置安装 RPATH（发行版打包由 ldconfig/包
-- 管理处理；CMake 侧按 Fcitx5CompilerSettings 写入 INSTALL_RPATH）。
--
-- 用法：
--   export PKG_CONFIG_PATH=<fcitx5 前缀的 pkgconfig 目录>  # 系统装可省
--   xmake f -m release -y
--   xmake
--   xmake install -o <prefix>          # 布局同 cmake --install
--
-- 注：模板渲染与安装逻辑写在脚本作用域内（before_build /
-- on_install），其中才挂载完整 io 模块；项目顶层作用域受限。
set_project("fcitx5-langya")
set_version("0.1.0")
set_languages("c99", "c++20")
set_warnings("all", "extra")

-- 与 CMakeLists.txt 的 project(... VERSION 0.1.0) 同步（conf 模板用）
local VERSION = "0.1.0"

-- fcitx5 核心依赖：pkg-config 定位 Fcitx5Core.pc（fcitx5-devel 自带）。
-- 不用 xmake 的 cmake:: 包：其探测器不继承 shell 环境，
-- pkg-config 路线在任何装了 fcitx5-devel 的机器上开箱即用。

-- 安装布局：x86_64 用 lib64（对齐 GNUInstallDirs），可用 FCITX_LIBDIR 覆盖
local libdir = os.getenv("FCITX_LIBDIR") or (is_arch("x86_64") and "lib64" or "lib")
local confdir = "share/fcitx5"

target("langya")
    set_kind("shared")
    -- 无 lib 前缀：fcitx5 按 conf 的 Library=langya 定位 langya.so
    set_prefixname("")
    add_files("core/langyaengine.cpp", "core/addonfactory.cpp")
    add_includedirs("core")
    -- 对齐 Fcitx5CompilerSettings.cmake
    add_cxxflags("-fvisibility=hidden", "-fvisibility-inlines-hidden",
                 {force = true})
    add_ldflags("-Wl,--no-undefined", "-Wl,--as-needed", {force = true})
    -- $ORIGIN RPATH：与 libIME*.so 同目录即可运行（用户级安装免
    -- LD_LIBRARY_PATH；须防 shell 展开，经 linker script 参数传入）
    add_shflags([[-Wl,-rpath,$ORIGIN]], {force = true})
    on_load(function (target)
        import("lib.detect.find_package")
        local pkg = find_package("Fcitx5Core")
        if not pkg then
            raise("未找到 Fcitx5Core（pkg-config）；"
                .. "系统请安装 fcitx5-devel，或设置 PKG_CONFIG_PATH")
        end
        target:add(pkg)
        -- libime 拼音内核（与 Fcitx5Core 同前缀；Fedora 布局
        -- include/LibIME，链接 IMECore+IMEPinyin）
        local root = os.getenv("FCITX_ROOT") or "/tmp/fcitx5root"
        local inc = path.join(root, "usr", "include")
        target:add("includedirs", inc, path.join(inc, "boost"),
                   path.join(inc, "Fcitx5", "Module"),
                   path.join(inc, "Fcitx5", "Module", "fcitx-module",
                             "punctuation"),
                   path.join(inc, "LibIME"),
                   path.join(inc, "Fcitx5", "Core"),
                   path.join(inc, "Fcitx5", "Config"),
                   path.join(inc, "Fcitx5", "Utils"))
        target:add("linkdirs", path.join(root, "usr", "lib64"))
        target:add("links", "IMECore", "IMEPinyin")
    end)
    -- 渲染 conf 模板（@PROJECT_VERSION@ → 版本号），镜像出安装树
    before_build(function (target)
        local out = path.join(target:autogendir(), "conf")
        local confs = {
            {"core/langya-addon.conf.in", "addon/langya.conf"},
            {"core/langya.conf.in",       "inputmethod/langya.conf"},
        }
        for _, c in ipairs(confs) do
            local dst = path.join(out, confdir, c[2])
            os.mkdir(path.directory(dst))
            local text = io.readfile(c[1]):gsub("@PROJECT_VERSION@", VERSION)
            io.writefile(dst, text)
        end
    end)

    -- 用户级 XDG 安装（xmake install，无 -o 时装 ~/.local）：
    --   ~/.local/lib/fcitx5/{langya.so, libIME*.so}   引擎+libime（RPATH 免配置）
    --   ~/.local/share/fcitx5/{addon,inputmethod,langya}/  注册与映射
    --   ~/.local/share/libime/                        拼音词典/语言模型
    --   ~/.config/environment.d/langya-fcitx5.conf    addon 搜索路径（重登录生效）
    on_install(function (target)
        import("core.base.option")
        local home = os.getenv("HOME")
        local inst = option.get("installdir")
            or path.join(home, ".local")
        local confroot = path.join(target:autogendir(), "conf")
        local root = os.getenv("FCITX_ROOT") or "/tmp/fcitx5root"

        -- B2：探测系统 fcitx5 安装（pkg-config，回退常见前缀）。
        -- 系统已提供的模块、库、数据一律不复制、不遮蔽
        local sysprefix = nil
        local out = os.iorunv("pkg-config",
                              {"--variable=prefix", "Fcitx5Core"})
        if out then
            sysprefix = (out:gsub("[\r\n]", ""))
        end
        if not sysprefix or sysprefix == "" then
            for _, cand in ipairs({"/usr", "/usr/local"}) do
                if os.isfile(path.join(cand, "lib64", "fcitx5",
                                       "libclassicui.so"))
                    or os.isfile(path.join(cand, "lib", "fcitx5",
                                           "libclassicui.so")) then
                    sysprefix = cand
                    break
                end
            end
        end
        local syslibaddon = nil   -- 系统模块目录（lib*/fcitx5）
        local sysshare = nil      -- 系统数据目录（share/fcitx5）
        if sysprefix and sysprefix ~= "" then
            -- 目录判断用「目录内探针文件」（xmake os.isdir 语义不可靠，
            -- 复验⑤：os.isfile 判目录恒 false 导致模块仍被复制遮蔽）
            syslibaddon = (os.isfile(path.join(sysprefix, "lib64", "fcitx5",
                                               "libclassicui.so"))
                and path.join(sysprefix, "lib64", "fcitx5"))
                or (os.isfile(path.join(sysprefix, "lib", "fcitx5",
                                        "libclassicui.so"))
                and path.join(sysprefix, "lib", "fcitx5"))
            sysshare = path.join(sysprefix, "share", "fcitx5")
        end

        -- 安装清单：卸载按清单逐项删除，不留遮蔽残骸（B2）
        local manifest = {}

        local function install_file(src, dst)
            os.cp(src, dst)
            table.insert(manifest, dst)
        end

        -- 引擎与 libime 同目录（$ORIGIN 互相可见）
        local libdir_ = path.join(inst, "lib", "fcitx5")
        os.mkdir(libdir_)
        install_file(target:targetfile(), path.join(libdir_, "langya.so"))
        -- libime 核心：系统（含发行版 libime 包）已提供则不复制
        if sysprefix and os.isfile(path.join(sysprefix, "lib64",
                                             "libIMECore.so.0")) then
            print("系统已提供 libIME，跳过复制（不遮蔽）")
        else
            for _, so in ipairs(os.files(path.join(root, "usr", "lib64",
                                                   "libIMECore.so*"))) do
                install_file(so, libdir_)
            end
            for _, so in ipairs(os.files(path.join(root, "usr", "lib64",
                                                   "libIMEPinyin.so*"))) do
                install_file(so, libdir_)
            end
        end

        -- fcitx5 注册文件与琅琊映射
        local share = path.join(inst, "share")
        os.mkdir(path.join(share, "fcitx5", "addon"))
        os.mkdir(path.join(share, "fcitx5", "inputmethod"))
        os.mkdir(path.join(share, "fcitx5", "langya"))
        install_file(path.join(confroot, confdir, "addon", "langya.conf"),
                     path.join(share, "fcitx5", "addon"))
        install_file(path.join(confroot, confdir, "inputmethod",
                               "langya.conf"),
                     path.join(share, "fcitx5", "inputmethod"))
        os.cp(path.join(os.projectdir(), "icons", "."),
              path.join(share, "icons", "hicolor"))
        if os.isfile("data/langya.map") then
            install_file("data/langya.map",
                         path.join(share, "fcitx5", "langya",
                                   "langya.map"))
        else
            print("提示：缺 data/langya.map，请先运行 xmake export-char-map")
        end

        -- libime 数据（sc.dict + zh_CN.lm），XDG Data 路径。
        -- 系统已提供（发行版 libime / libime-data）则不复制；
        -- 缺语言模型时引擎会退化为无词频排序（task-16），显式报缺
        local syshasdict = os.isfile("/usr/share/libime/sc.dict")
            or (sysshare and os.isfile(path.join(sysshare, "..", "libime",
                                                 "sc.dict")))
        os.mkdir(path.join(share, "libime"))
        if syshasdict then
            print("系统已提供 libime 词典数据，跳过复制（不遮蔽）")
        elseif os.isfile(path.join(root, "usr", "share", "libime",
                                   "sc.dict")) then
            install_file(path.join(root, "usr", "share", "libime",
                                   "sc.dict"),
                         path.join(share, "libime"))
        else
            print("警告：缺 sc.dict（拼音词典），候选将不可用；"
                .. "请先运行 tools/setup_fcitx5root.sh")
        end
        local lm = path.join(root, "usr", "lib64", "libime")
        if os.isfile("/usr/lib64/libime/zh_CN.lm")
            or os.isfile("/usr/share/libime/zh_CN.lm") then
            print("系统已提供 zh_CN.lm，跳过复制（不遮蔽）")
        elseif os.isfile(path.join(lm, "zh_CN.lm")) then
            for _, f in ipairs(os.files(path.join(lm, "zh_CN.lm*"))) do
                install_file(f, path.join(share, "libime"))
            end
        else
            print("警告：缺 zh_CN.lm（语言模型），单字候选将失去"
                .. "词频排序（生僻字居前）；请先运行 "
                .. "tools/setup_fcitx5root.sh")
        end

        -- chttrans／punctuation 模块：琅琊的依赖，系统已提供则不复制
        for _, mod in ipairs({"chttrans", "punctuation"}) do
            local so = path.join(root, "usr", "lib64", "fcitx5",
                                 "lib" .. mod .. ".so")
            if syslibaddon and os.isfile(path.join(syslibaddon,
                                                   "lib" .. mod .. ".so")) then
                print("系统已提供 lib" .. mod .. "，跳过复制（不遮蔽）")
            elseif os.isfile(so) then
                install_file(so, libdir_)
            else
                print("提示：缺 lib" .. mod .. ".so，跳过该模块")
                goto continue
            end
            local conf = path.join(root, "usr", "share", "fcitx5",
                                   "addon", mod .. ".conf")
            if sysshare and os.isfile(path.join(sysshare, "addon",
                                                mod .. ".conf")) then
                print("系统已提供 " .. mod .. " addon 配置，跳过（不遮蔽）")
                goto continue
            end
            if mod == "chttrans" then
                -- 两处适配：1) 剥离 notifications 可选依赖（桌面
                -- 永不加载，等待会卡死）；2) OnDemand→False 随
                -- fcitx5 启动加载（OnDemand 拉起在部分环境死结）
                local nl = string.char(10)
                local pat = "%[Addon/OptionalDependencies%]"
                    .. "%s*" .. nl .. "+0=notifications[%s" .. nl .. "]*"
                local dst = path.join(share, "fcitx5", "addon",
                                      "chttrans.conf")
                local t = io.readfile(conf):gsub(pat, "")
                    :gsub("OnDemand=True", "OnDemand=False")
                io.writefile(dst, t)
                table.insert(manifest, dst)
            else
                install_file(conf, path.join(share, "fcitx5", "addon"))
            end
            ::continue::
        end

        -- 用户级配置：简→繁用香港标准（s2hk），繁→简用 hk2s。
        -- 键必须为顶层（chttrans 配置定义即顶层键，分组写法会被忽略，
        -- B1）；Hotkey 为列表项须经 [Hotkey] 枚举。已有用户配置时
        -- 不覆盖（B2：不得改写用户正在用的档位），仅提示
        local confdir = path.join(home, ".config", "fcitx5", "conf")
        os.mkdir(confdir)
        local usercht = path.join(confdir, "chttrans.conf")
        if os.isfile(usercht) then
            print("提示：已存在用户 chttrans 配置（" .. usercht
                .. "），未覆盖；港繁档位请按需手工调整")
        else
            io.writefile(usercht,
                         "# 简繁转换（OpenCC）：香港繁体标准（琅琊写入）\n"
                         .. "OpenCCS2TProfile=s2hk.json\n"
                         .. "OpenCCT2SProfile=hk2s.json\n"
                         .. "\n[Hotkey]\n0=Control+Shift+F\n")
            table.insert(manifest, usercht)
        end

        -- addon 搜索路径（fcitx5 不默认搜 ~/.local/lib/fcitx5）：
        -- environment.d 对 systemd 用户会话生效（KDE Wayland 需重新登录）。
        -- B2：不写死系统模块目录——用 pkg-config 探测的系统目录作后备，
        -- 探测不到时给常见路径全集，绝不截断系统既有目录
        local envd = path.join(home, ".config", "environment.d")
        os.mkdir(envd)
        local sysdirs = {}
        if syslibaddon then
            table.insert(sysdirs, syslibaddon)
        end
        table.insert(sysdirs, "/usr/lib64/fcitx5")
        table.insert(sysdirs, "/usr/lib/x86_64-linux-gnu/fcitx5")
        table.insert(sysdirs, "/usr/lib/fcitx5")
        local envdfile = path.join(envd, "langya-fcitx5.conf")
        io.writefile(envdfile,
                     "FCITX_ADDON_DIRS=" .. libdir_ .. ":"
                         .. table.concat(sysdirs, ":") .. "\n")
        table.insert(manifest, envdfile)
        -- 写安装清单（卸载按清单逐项删除）
        io.writefile(path.join(share, "fcitx5", "langya",
                               "installed-files.list"),
                     table.concat(manifest, "\n") .. "\n")
        local msg = [[✓ 用户级安装完成 → %s
  立即生效：export FCITX_ADDON_DIRS=%s && fcitx5 -r
  重登录后：environment.d 自动生效
  添加输入法：系统设置→键盘→输入法→添加「琅琊小篆」]]
        print(msg:format(inst, libdir_))
    end)

-- ── 数据管线任务 ─────────────────────────────────────────

-- 下载 Rime 词频与词典数据（LGPL-3.0）到 tools/cache/
task("download-dict")
    set_category("langya")
    on_run(function ()
        -- 锁定 commit 保证可复现（两仓库均无 tag，锁 master HEAD）
        local files = {
            {"https://raw.githubusercontent.com/rime/rime-luna-pinyin/56b934b099dfbeab842320f13aa8b461a6ab3e42/luna_pinyin.dict.yaml",
             "luna_pinyin.dict.yaml"},
            {"https://raw.githubusercontent.com/rime/rime-essay/054920de4f54c9e5994276a96a4fc2a35cb51aa3/essay.txt",
             "essay.txt"},
        }
        os.mkdir("tools/cache")
        for _, f in ipairs(files) do
            local dst = path.join("tools/cache", f[2])
            if os.isfile(dst) and os.filesize(dst) > 0 then
                print("已有缓存：%s", dst)
            else
                print("下载 %s …", f[1])
                os.tryrm(dst)
                os.runv("curl", {"-fL", f[1], "-o", dst})
                print("已下载：%s（%d 字节）", dst, os.filesize(dst))
            end
        end
    end)
    set_menu {
        usage = "xmake download-dict",
        description = "下载 Rime 词典与词频数据到 tools/cache/",
    }

-- 导出 data/langya.map（封裝 tools/export_char_map.py，需 uv 与 ../zhuan）
task("export-char-map")
    set_category("langya")
    on_run(function ()
        os.execv("uv", {"run", "--project", "../zhuan",
                        "python", "tools/export_char_map.py"})
    end)
    set_menu {
        usage = "xmake export-char-map",
        description = "导出 data/langya.map（汉字→小篆码点/楷化字）",
    }

-- 卸载用户级安装（xmake uninstall）
task("uninstall")
    set_category("langya")
    on_run(function ()
        local home = os.getenv("HOME")
        local manifest = path.join(home, ".local/share/fcitx5/langya",
                                   "installed-files.list")
        if os.isfile(manifest) then
            for _, line in ipairs(io.lines(manifest)) do
                if line ~= "" and os.exists(line) then
                    os.tryrm(line)
                    print("已删 %s", line)
                end
            end
            os.tryrm(manifest)
        else
            print("未找到安装清单，按旧版固定路径清理")
            local files = {
                path.join(home, ".local/lib/fcitx5/langya.so"),
                path.join(home, ".local/share/fcitx5/addon/langya.conf"),
                path.join(home, ".local/share/fcitx5/inputmethod/langya.conf"),
                path.join(home, ".local/share/fcitx5/langya/langya.map"),
                path.join(home, ".config/environment.d/langya-fcitx5.conf"),
            }
            for _, f in ipairs(files) do
                if os.isfile(f) then
                    os.tryrm(f)
                    print("已删 %s", f)
                end
            end
            for _, f in ipairs(os.files(path.join(home, ".local/lib/fcitx5",
                                                  "libIME*.so*"))) do
                os.tryrm(f)
                print("已删 %s", f)
            end
            for _, f in ipairs({"sc.dict", "zh_CN.lm", "zh_CN.lm.predict"}) do
                local p2 = path.join(home, ".local/share/libime", f)
                if os.isfile(p2) then
                    os.tryrm(p2)
                    print("已删 %s", p2)
                end
            end
        end
        print("完成。输入法列表里的「琅琊小篆」请在系统设置中手动移除；"
            .. "系统自身模块与配置未受本次安装影响")
    end)
    set_menu {
        usage = "xmake uninstall",
        description = "卸载用户级琅琊安装（~/.local 布局，按清单清理）",
    }

includes("tests/xmake.lua")
includes("android/xmake.lua")
