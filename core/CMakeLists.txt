# 琅琊（Langya）说文小篆输入法 — 引擎核心
#
# 本目录同时被两个工程引用，请勿引入平台特定逻辑：
#   - Linux 桌面版：../CMakeLists.txt（fcitx5 引擎插件）
#   - Android 版：android/plugin/src/main/cpp/CMakeLists.txt
#     （由 android/scripts/sync.sh 将本目录与 ../data 同步进去）
find_package(Fcitx5Core 5.1 REQUIRED)

add_library(langya SHARED
    langyaengine.cpp
    addonfactory.cpp
)
target_link_libraries(langya PRIVATE Fcitx5::Core)

# libime 拼音内核：Android 走宿主 prefab（jyutping 同款），
# Linux 走系统安装（Fedora: libime-devel；需与 Fcitx5Core 同前缀）
if(ANDROID)
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
