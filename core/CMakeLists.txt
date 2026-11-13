# 琅琊（Langya）说文小篆输入法 — 引擎核心
#
# 本目录同时被两个工程引用，请勿引入平台特定逻辑：
#   - Linux 桌面版：../CMakeLists.txt（fcitx5 引擎插件）
#   - Android 版：android/plugin/src/main/cpp/CMakeLists.txt
#     （由 xmake sync-android 将本目录与 ../data 同步进去）
find_package(Fcitx5Core 5.1 REQUIRED)

add_library(langya SHARED
    langyaengine.cpp
    addonfactory.cpp
)
target_link_libraries(langya PRIVATE Fcitx5::Core)

# libime 拼音内核：Android 走宿主 prefab（jyutping 同款），
# Linux 走系统安装（Fedora: libime-devel；需与 Fcitx5Core 同前缀）
if(ANDROID)
    # punctuation 模块（fcitx5-chinese-addons，jyutping 同款）
    find_package(fcitx5-chinese-addons REQUIRED CONFIG)
    get_target_property(FCITX5_CHINESE_ADDONS_CMAKE_MODULES
                        fcitx5-chinese-addons::cmake
                        INTERFACE_INCLUDE_DIRECTORIES)
    set(CMAKE_MODULE_PATH
        ${FCITX5_CHINESE_ADDONS_CMAKE_MODULES} ${CMAKE_MODULE_PATH})
    find_package(Fcitx5ModulePunctuation MODULE)
    # punctuation 的 prefab 产物不带 SONAME，直接链接导入目标会把
    # IMPORTED_LOCATION 的构建机绝对路径写进 DT_NEEDED，真机上
    # dlopen 必败（附加组件每次启动加载失败，呈「禁用」状）。
    # 改为按文件名名义链接：DT_NEEDED 记为 libpunctuation.so，
    # 运行时由 Android 动态链接器在宿主/插件库目录解析
    # （宿主 APK 与本插件 APK 均打包同名库副本）。
    get_target_property(_punct_loc Fcitx5::Module::Punctuation
                        IMPORTED_LOCATION)
    if(NOT _punct_loc)
        message(FATAL_ERROR "未取得 libpunctuation.so 位置，无法安全链接")
    endif()
    list(GET _punct_loc 0 _punct_loc_first)
    get_filename_component(_punct_dir "${_punct_loc_first}" DIRECTORY)
    get_target_property(_punct_inc Fcitx5::Module::Punctuation
                        INTERFACE_INCLUDE_DIRECTORIES)
    target_include_directories(langya PRIVATE ${_punct_inc})
    target_link_directories(langya PRIVATE "${_punct_dir}")
    target_link_options(langya PRIVATE "-Wl,-l:libpunctuation.so")

    find_package(libime REQUIRED CONFIG)
    get_target_property(LIBIME_CMAKE_MODULES libime::cmake
                        INTERFACE_INCLUDE_DIRECTORIES)
    set(CMAKE_MODULE_PATH ${LIBIME_CMAKE_MODULES} ${CMAKE_MODULE_PATH})
    # libime 头依赖 boost（jyutping 同款 prebuilt boost）
    list(APPEND CMAKE_FIND_ROOT_PATH
         "${PREBUILT_DIR}/boost/${ANDROID_ABI}/lib/cmake")
    find_package(Boost 1.87.0 REQUIRED COMPONENTS iostreams CONFIG)
    target_link_libraries(langya PRIVATE Boost::boost Boost::iostreams)
    find_package(LibIMEPinyin MODULE)
    target_link_libraries(langya PRIVATE LibIME::Pinyin)
else()
    find_package(LibIMEPinyin REQUIRED)
    target_link_libraries(langya PRIVATE LibIME::Pinyin)
    # punctuation 模块头（zh_CN 标点表与配对引号；引擎 activate 依赖该模块）。
    # 桌面发行包提供 CONFIG 包（fcitx5-chinese-addons-devel，Fedora 布局
    # lib64/cmake/Fcitx5ModulePunctuation）；Android 分支上方走宿主树
    # Find 模块，两条路径互不影响。
    find_package(Fcitx5ModulePunctuation CONFIG REQUIRED)
    target_link_libraries(langya PRIVATE Fcitx5::Module::Punctuation)
endif()
# fcitx5 master 头文件使用 std::ranges/std::span（C++20）
target_compile_features(langya PRIVATE cxx_std_20)
set_target_properties(langya PROPERTIES PREFIX "")

# 桌面图标（hicolor 主题，输入法列表/托盘用）
install(DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/../icons/"
        DESTINATION "${CMAKE_INSTALL_DATADIR}/icons/hicolor")

# 数据文件：汉字→小篆/楷化映射（tools/export_char_map.py 生成；
# 拼音词典/语言模型用宿主自带的 libime 数据，不重复打包）
if(ANDROID)
    install(FILES "${CMAKE_CURRENT_SOURCE_DIR}/../data/langya.map"
            DESTINATION "${FCITX_INSTALL_PKGDATADIR}/langya"
            COMPONENT prebuilt-assets)
else()
    install(FILES "${CMAKE_CURRENT_SOURCE_DIR}/../data/langya.map"
            DESTINATION "${FCITX_INSTALL_PKGDATADIR}/langya")
    # 桌面版：安装引擎本体（Android 由 externalNativeBuild 经 jniLibs 打包）
    install(TARGETS langya DESTINATION "${FCITX_INSTALL_LIBDIR}/fcitx5")
endif()

# addon 注册文件与输入法条目（@PROJECT_VERSION@ 在两端均由 project() 提供）。
# COMPONENT config：fcitx5-android 的 fcitx-component 插件按该组件收取
# addon/inputmethod 配置并打进插件 APK（Linux 侧组件名无副作用）。
configure_file("${CMAKE_CURRENT_SOURCE_DIR}/langya-addon.conf.in"
               "${CMAKE_CURRENT_BINARY_DIR}/langya-addon.conf" @ONLY)
configure_file("${CMAKE_CURRENT_SOURCE_DIR}/langya.conf.in"
               "${CMAKE_CURRENT_BINARY_DIR}/langya-im.conf" @ONLY)
install(FILES "${CMAKE_CURRENT_BINARY_DIR}/langya-addon.conf"
        DESTINATION "${FCITX_INSTALL_PKGDATADIR}/addon"
        RENAME langya.conf
        COMPONENT config)
install(FILES "${CMAKE_CURRENT_BINARY_DIR}/langya-im.conf"
        DESTINATION "${FCITX_INSTALL_PKGDATADIR}/inputmethod"
        RENAME langya.conf
        COMPONENT config)
# 简繁转换配置（chttrans 模块以 PkgConfig 类型 readAsIni("conf/chttrans.conf")
# 读取，即配置主目录而非 PkgData；B1）。系统级安装写入 /etc/xdg/fcitx5/conf/
#（FCITX_CONFIG_DIRS 之一，会被读取）；用户有同名配置时以用户为准。
# Android 宿主无法下发 PkgConfig 文件，该配置在插件内不可达——
# 不随 config 组件打包（APK 不再有读不到的死文件），Android 侧
# 简繁档位维持 OpenCC 默认（标准繁体）。
install(FILES "${CMAKE_CURRENT_SOURCE_DIR}/chttrans.conf"
        DESTINATION "/etc/xdg/fcitx5/conf"
        COMPONENT config)
