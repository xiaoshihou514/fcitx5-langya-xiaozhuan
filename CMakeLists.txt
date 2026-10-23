cmake_minimum_required(VERSION 3.21)
project(fcitx5-langya VERSION 0.1.0 LANGUAGES CXX)

# 依赖 fcitx5 核心（Fedora: fcitx5-devel；Debian: fcitx5-modules-dev）
find_package(Fcitx5Core 5.1 REQUIRED)
include("${FCITX_INSTALL_CMAKECONFIG_DIR}/Fcitx5Utils/Fcitx5CompilerSettings.cmake")
include(GNUInstallDirs)

add_subdirectory(core)
