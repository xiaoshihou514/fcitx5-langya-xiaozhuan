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
                   path.join(inc, "LibIME"),
                   path.join(inc, "Fcitx5", "Core"),
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

    -- 安装全部手动接管（on_install 替换内建安装，避免默认落到 lib/）
    on_install(function (target)
        import("core.base.option")
        local installdir = option.get("installdir") or "/usr/local"
        local confroot = path.join(target:autogendir(), "conf")
        os.mkdir(path.join(installdir, libdir, "fcitx5"))
        os.cp(target:targetfile(),
              path.join(installdir, libdir, "fcitx5", "langya.so"))
        os.mkdir(path.join(installdir, confdir))
        os.cp(path.join(confroot, confdir) .. "/.",
              path.join(installdir, confdir) .. "/")
        os.cp(path.join(os.projectdir(), "icons", "."),
              path.join(installdir, "share", "icons", "hicolor"))
        if os.isfile("data/langya.map") then
            os.mkdir(path.join(installdir, confdir, "langya"))
            os.cp("data/langya.map",
                  path.join(installdir, confdir, "langya", "langya.map"))
        else
            print("提示：缺 data/langya.map。"
                .. "请先运行 xmake export-char-map")
        end
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

-- 生成 data/langya.tsv（封裝 tools/export_data.py，需 uv 与 ../zhuan）
task("export-data")
    set_category("langya")
    on_run(function ()
        if not os.isdir("../zhuan") then
            raise("未找到 ../zhuan（zhuan 项目应与 langya 同级，"
                .. "提供 seal.db 查表链环境）")
        end
        os.execv("uv", {"run", "--project", "../zhuan",
                        "python", "tools/export_data.py"})
    end)
    set_menu {
        usage = "xmake export-data",
        description = "生成词典 data/langya.tsv（先跑 download-dict）",
    }

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

includes("tests/xmake.lua")
includes("android/xmake.lua")
