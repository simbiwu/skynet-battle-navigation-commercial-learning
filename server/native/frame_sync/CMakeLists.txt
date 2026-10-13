# 职责：把宿主帧同步Core分别构建成Windows Unity DLL与Linux Lua Native依赖。
# 边界：课程宿主只链接固定FlyWow submodule公开的FlyWow::Navigation目标，不枚举导航实现源码。
# 输入/输出：宿主frame_core与Binding源码 -> frame_core, lesson_frame_native, frame_test。
# 不负责：重复枚举FlyWow内部CPP、生成规则源码Hash、修改Skynet源码。
cmake_minimum_required(VERSION 3.16)
project(lesson_frame LANGUAGES CXX)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

set(FLYWOW "${CMAKE_CURRENT_SOURCE_DIR}/../../third_party/skynet-flywow")
add_subdirectory("${FLYWOW}/navigation/native"
                 "${CMAKE_CURRENT_BINARY_DIR}/flywow_navigation")

add_library(frame_core SHARED frame_core.cpp)
target_include_directories(frame_core PUBLIC "${CMAKE_CURRENT_SOURCE_DIR}")
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
add_test(NAME frame_native
         COMMAND frame_test "${CMAKE_CURRENT_SOURCE_DIR}/../../../shared/navigation/battle_1001/battle_1001.bmap")

option(LESSON_FRAME_LUA "构建Skynet Lua 5.4.7 Binding；Windows Unity构建时设OFF" ON)
if(LESSON_FRAME_LUA)
    set(SKYNET_LUA_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../third_party/skynet/3rd/lua")
    add_subdirectory("${FLYWOW}/lua-binding"
                     "${CMAKE_CURRENT_BINARY_DIR}/flywow_lua_binding" EXCLUDE_FROM_ALL)
    add_library(lesson_frame_native MODULE frame_binding.cpp)
    target_include_directories(lesson_frame_native PRIVATE
                               "${SKYNET_LUA_DIR}" "${FLYWOW}/lua-binding")
    target_link_libraries(lesson_frame_native PRIVATE frame_core flywow_lua_binding)
    set_target_properties(lesson_frame_native PROPERTIES
                          PREFIX "" BUILD_RPATH "$ORIGIN")
endif()
