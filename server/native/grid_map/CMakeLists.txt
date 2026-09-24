# 职责：构建 grid_map_core 和第一课 Native 单元测试。
# 边界：Server Native Build；不下载依赖，不构建 Skynet 本体。
# 输入/输出：本目录 C++ 源码 -> 静态库、测试可执行文件和 CTest 用例。
cmake_minimum_required(VERSION 3.16)
project(battle_grid_map LANGUAGES CXX C)

set(CMAKE_CXX_STANDARD 14)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

add_library(grid_map_core STATIC
    src/bmap_reader.cpp
    src/grid_map.cpp
    src/map_registry.cpp
    src/nav_result.cpp
)
# grid_map_core 也会被链接进 Lua 动态模块，因此其目标文件必须可用于共享库。
set_target_properties(grid_map_core PROPERTIES POSITION_INDEPENDENT_CODE ON)

target_include_directories(grid_map_core PUBLIC include)
target_compile_options(grid_map_core PRIVATE -Wall -Wextra -Wpedantic)

add_executable(grid_map_test tests/grid_map_test.cpp)
target_link_libraries(grid_map_test PRIVATE grid_map_core pthread)

enable_testing()
add_test(NAME grid_map_test COMMAND grid_map_test)
