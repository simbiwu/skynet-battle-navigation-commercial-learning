# 状态同步客户端仅预测本地移动；通过FlyWow公开目标复用地图和地面移动规则。
# 最低 CMake 版本用于支持本文件使用的 target 与测试配置语法。
cmake_minimum_required(VERSION 3.16)
project(state_navigation LANGUAGES CXX)

# 预测库与 Server 使用同一 C++17 标准；关闭编译器扩展以减少平台差异。
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

# 本目录后续可注册 Native 回归测试，测试通过 CTest 统一发现和运行。
enable_testing()

# 引入 FlyWow Navigation 源码目录中的 CMakeLists.txt；第二个参数是本工程下的独立构建子目录。
# 该目录会定义 FlyWow::Navigation 公开目标，供状态同步预测库复用地图读取和移动规则。
add_subdirectory("../../third_party/skynet-flywow/navigation/native" "flywow_navigation")

# 输出供 Unity P/Invoke 加载的共享库；状态同步只在客户端本地预测，不接管 Server 权威结果。
add_library(state_navigation SHARED state_navigation.cpp)
# PRIVATE 表示 Navigation 只作为此 DLL 的实现依赖，不向 DLL 的下游链接者继续传播。
target_link_libraries(state_navigation PRIVATE FlyWow::Navigation)
# 警告选项按编译器区分；MSVC 需要异常/UTF-8 选项，GCC/Clang 使用常见警告集合。
if(MSVC)
    target_compile_options(state_navigation PRIVATE /W4 /EHsc /utf-8)
else()
    target_compile_options(state_navigation PRIVATE -Wall -Wextra -Wpedantic)
endif()
