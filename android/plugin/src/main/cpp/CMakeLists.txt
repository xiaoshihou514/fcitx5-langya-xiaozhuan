cmake_minimum_required(VERSION 3.18)

project(fcitx5-android-plugin-langya VERSION ${VERSION_NAME})

# For reproducible build
add_link_options("LINKER:--hash-style=gnu,--build-id=none")

# prefab dependency
find_package(fcitx5 REQUIRED CONFIG)
get_target_property(FCITX5_CMAKE_MODULES fcitx5::cmake INTERFACE_INCLUDE_DIRECTORIES)
set(CMAKE_MODULE_PATH ${FCITX5_CMAKE_MODULES} ${CMAKE_MODULE_PATH})

find_package(ECM MODULE)
find_package(Fcitx5Core MODULE)

# 引擎核心与数据由 scripts/sync.sh 从 ../../langya 同步到本目录
# （core/ 与 data/，勿手动修改）
add_subdirectory(core)
