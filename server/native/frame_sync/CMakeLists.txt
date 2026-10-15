# 职责：把宿主帧同步Core分别构建成Windows Unity DLL与Linux Lua Native依赖。
# 边界：课程宿主只链接固定FlyWow submodule公开的FlyWow::Navigation目标，不枚举导航实现源码。
# 输入/输出：宿主frame_core与Binding源码 -> frame_core, lesson_frame_native, frame_test。
# 不负责：重复枚举FlyWow内部CPP、生成规则源码Hash、修改Skynet源码。
cmake_minimum_required(VERSION 3.16)
project(lesson_frame LANGUAGES CXX)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

# CMAKE_CURRENT_SOURCE_DIR 是 CMake 自动变量，值为当前文件所在源码目录：
# 这里是 server/native/frame_sync。向上两级到 server/，再定位 FlyWow 子模块。
set(FLYWOW "${CMAKE_CURRENT_SOURCE_DIR}/../../third_party/skynet-flywow")

# add_subdirectory(<源码目录>, <构建目录>) 会读取源码目录内的 CMakeLists.txt。
# 第一个路径必须包含 CMakeLists.txt；执行它后，FlyWow::Navigation 目标才可供本文件使用。
# 第二个路径位于 CMAKE_CURRENT_BINARY_DIR（由 cmake -B 指定）下，只放生成文件和中间产物。
# 加载构建定义会注册 FlyWow 目标，但此处还没有把它链接到 frame_core。
add_subdirectory("${FLYWOW}/navigation/native"
                 "${CMAKE_CURRENT_BINARY_DIR}/flywow_navigation")

# Core 同时供原生测试程序和 Lua Binding 链接，保持两条入口使用同一实现。
add_library(frame_core SHARED frame_core.cpp)
# 这里的目录是 server/native/frame_sync，包含 frame_core.h 等宿主头文件。
# PUBLIC 让 frame_core 自己和链接它的下游目标（frame_test、Lua 模块）都继承此搜索路径。
target_include_directories(frame_core PUBLIC "${CMAKE_CURRENT_SOURCE_DIR}")

# FlyWow::Navigation 是 FlyWow CMakeLists.txt 中 flywow_navigation_core STATIC 目标的别名。
# FlyWow 的 .cpp 由该独立目标编译，再把需要的目标代码链接进 frame_core；
# 它们没有被追加到 frame_core 的源码列表中。
# PUBLIC 表示下游使用者（frame_test、Lua 模块）继承此链接依赖，也继承 FlyWow 公开的头文件目录。
target_link_libraries(frame_core PUBLIC FlyWow::Navigation)
if(MSVC)
    target_compile_options(frame_core PRIVATE /W4 /permissive- /EHsc /utf-8)
else()
    target_compile_options(frame_core PRIVATE -Wall -Wextra -Wpedantic)
endif()

add_executable(frame_test frame_test.cpp)
target_link_libraries(frame_test PRIVATE frame_core)
if(MSVC)
    target_compile_options(frame_test PRIVATE /UNDEBUG /utf-8)
else()
    target_compile_options(frame_test PRIVATE -UNDEBUG)
endif()

enable_testing()
# 使用仓库发布格式的真实 BMAP 资产验证 Native Core 的集成入口。
add_test(NAME frame_native
         COMMAND frame_test "${CMAKE_CURRENT_SOURCE_DIR}/../../../shared/navigation/battle_1001/battle_1001.bmap")

# option 最后的 ON 是 CMake 默认值；配置命令传入 -DLESSON_FRAME_LUA=... 时会覆盖它。
# Skynet Server 需要 Lua Binding，因此构建脚本默认传 ON；Windows Unity DLL 构建应传 OFF。
option(LESSON_FRAME_LUA "构建Skynet Lua 5.4.7 Binding；Windows Unity构建时设OFF" ON)
if(LESSON_FRAME_LUA)
    # Binding 必须使用项目固定版本 Skynet 自带的 Lua 头文件，避免 Lua ABI 不匹配。
    set(SKYNET_LUA_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../third_party/skynet/3rd/lua")
    add_subdirectory("${FLYWOW}/lua-binding"
                     "${CMAKE_CURRENT_BINARY_DIR}/flywow_lua_binding" EXCLUDE_FROM_ALL)
    # Lua 按模块名查找 lesson_frame_native.so；MODULE 目标需要去掉默认 lib 前缀。
    add_library(lesson_frame_native MODULE frame_binding.cpp)
    # frame_core 与 flywow_lua_binding 都公开了各自头文件目录；链接目标会自动传递搜索路径，
    # 因此这里不再重复写 target_include_directories。
    target_link_libraries(lesson_frame_native PRIVATE frame_core flywow_lua_binding)
    # set_target_properties(<目标> PROPERTIES <属性> <值>...) 按“属性/值”配对设置 CMake 目标属性。
    # PREFIX "" 将 lesson_frame_native.so 文件名前缀设为空，Lua 的 require 名称不含 lib。
    # BUILD_RPATH 是构建目录产物的运行时依赖搜索路径；$ORIGIN 是 ELF 加载器标记，表示当前 .so 所在目录。
    # 因此加载本模块时能从旁边找到 libframe_core.so；若以后安装到其它目录，再按安装布局设置 INSTALL_RPATH。
    set_target_properties(lesson_frame_native PROPERTIES
                          PREFIX "" BUILD_RPATH "$ORIGIN")
endif()
