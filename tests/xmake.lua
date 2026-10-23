-- 引擎集成测试（无图形界面，借 fcitx5 官方 testfrontend 注入按键）。
--
-- 用法：xmake engine-test
-- 环境变量：
--   FCITX_ROOT        含 fcitx5 运行时与开发头文件的前缀（默认
--                     /tmp/fcitx5root，xmake.lua 布置 langya 三件套进去）
--   FCITX5_TESTING_INC 含 testing/testfrontend/testfrontend_public.h 的
--                     fcitx5 源码目录（默认 android/ 宿主树）
--   LANGYA_SO         覆盖被测引擎（默认本构建产物）

-- 测试驱动：依赖外部 fcitx5 头文件与宿主树的 testfrontend 公共头，
-- 不在默认构建集内（xmake build engine_test 单独触发）
target("engine_test")
    set_kind("binary")
    set_default(false)
    add_files("engine_test.cpp")
    on_load(function (target)
        local root = os.getenv("FCITX_ROOT") or "/tmp/fcitx5root"
        local testing = os.getenv("FCITX5_TESTING_INC")
            or path.join(os.projectdir(), "android", "build",
                         "fcitx5-android", "lib", "fcitx5", "src",
                         "main", "cpp", "fcitx5")
        local incdir = path.join(root, "usr", "include", "Fcitx5")
        target:add("includedirs", path.join(incdir, "Core"),
                   path.join(incdir, "Utils"),
                   path.join(incdir, "Config"),
                   path.join(testing, "testing", "testfrontend"))
        local inc = path.join(root, "usr", "include")
        target:add("includedirs", inc, path.join(inc, "boost"),
                   path.join(inc, "LibIME"))
        target:add("linkdirs", path.join(root, "usr", "lib64"))
        target:add("links", "Fcitx5Core", "Fcitx5Config", "Fcitx5Utils",
                   "IMECore", "IMEPinyin")
    end)

task("engine-test")
    set_category("langya")
    on_run(function ()
        local root = os.getenv("FCITX_ROOT") or "/tmp/fcitx5root"
        local libdir = path.join(root, "usr", "lib64")
        local fcitxdir = path.join(root, "usr", "share", "fcitx5")

        -- 1) 构建引擎与测试驱动
        os.execv("xmake", {"build", "-y", "langya"})
        os.execv("xmake", {"build", "-y", "engine_test"})

        -- 2) 布置 langya 三件套（OnDemand 改随启动加载：fcitx5 5.1.23
        --    测试环境下惰性加载路径不触发；产品配置不受影响）
        local so = os.getenv("LANGYA_SO")
            or path.join(os.projectdir(), "build", "linux", "x86_64",
                         "release", "langya.so")
        os.mkdir(path.join(root, "usr", "lib64", "fcitx5"))
        os.cp(so, path.join(root, "usr", "lib64", "fcitx5", "langya.so"))
        os.mkdir(path.join(fcitxdir, "langya"))
        -- conf 由 langya 目标的 before_build 渲染，autogendir 含
        -- plat/arch/mode，用 glob 定位
        local gens = path.join(os.projectdir(), "build", ".gens", "langya")
        local function read_conf(rel)
            local files = os.files(path.join(gens, "**", rel))
            assert(files and files[1], "conf 未生成：" .. rel)
            table.sort(files)
            return io.readfile(files[1])
        end
        local conf = read_conf(path.join("share", "fcitx5", "addon",
                                         "langya.conf"))
        -- 注意：gsub 返回 (串, 计数) 两个值，须先取首值再传 writefile；
        -- Lua 的 ^ 是串首而非行首，行首匹配用 "\n" 前缀
        local relaxed = conf:gsub("\nOnDemand=True", "\nOnDemand=False")
        io.writefile(path.join(fcitxdir, "addon", "langya.conf"), relaxed)
        io.writefile(path.join(fcitxdir, "inputmethod", "langya.conf"),
                     read_conf(path.join("share", "fcitx5", "inputmethod",
                                         "langya.conf")))
        os.cp(path.join(os.projectdir(), "data", "langya.map"),
              path.join(fcitxdir, "langya", "langya.map"))
        -- libime 数据（zh_CN.lm resolver 需 Data 路径下的副本）
        os.mkdir(path.join(fcitxdir, "..", "libime"))
        local lm = path.join(root, "usr", "lib64", "libime",
                             "zh_CN.lm")
        if os.isfile(lm) then
            os.cp(lm, path.join(fcitxdir, "..", "libime", "zh_CN.lm"))
            os.cp(lm .. ".predict",
                  path.join(fcitxdir, "..", "libime",
                            "zh_CN.lm.predict"))
        end

        -- 3) 运行（fcitx 经 LD_LIBRARY_PATH 找本地 libFcitx5*）
        local envs = {LD_LIBRARY_PATH = libdir}
        os.execv(path.join(os.projectdir(), "build", "linux", "x86_64",
                           "release", "engine_test"),
                 {}, {envs = envs})
    end)
    set_menu {
        usage = "xmake engine-test",
        description = "构建并在真实 fcitx5 运行时中运行引擎集成测试",
    }
