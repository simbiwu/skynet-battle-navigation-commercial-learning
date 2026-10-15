# 协议源与生成物

shared/protocol/ 是协议源和已验证生成物的边界。课程 1、课程 2、课程 3 帧同步、课程 3 状态同步分别按独立项目维护自己的 package、命令枚举和业务消息；只有传输头 wire_header.proto 中的 battle.transport.v1.Envelope 共用；所有课程客户端、descriptor 与 Registry 都同步使用当前版本，不保留历史字段兼容。

## 源文件布局

- wire_header.proto：所有课程唯一共用的 battle.transport.v1.Envelope。它只包含 protocol_version=1、command=2 和 body=3。
- lesson_01/navigation.proto：第一课导航查询的 CommandId、位置类型和消息。
- lesson_02/navigation.proto：第二课导航查询与自动战斗的 CommandId、位置类型和消息。
- lesson_03/frame_sync.proto：第三课帧同步自己的命令编号和消息。
- lesson_03/state_sync.proto：第三课状态同步自己的命令编号、位置类型和消息。
- VERSIONS.env：固定 protoc 与 protobuf Runtime 版本。
- generated/server/：各课程独立的 FileDescriptorSet、二进制 SHA-256 和输入源 SHA-256。
- generated/unity/：Windows Unity C# 生成文件的逐文件 SHA-256。

各课程使用独立 package，方便所有课程客户端类型同时存在于同一 Unity 程序集中。业务 schema 不 import 其它课程 schema；生成 Server descriptor 时将 wire_header.proto 和当前课程 schema 放进同一份 FileDescriptorSet。--include_imports 的职责是让当前课程 descriptor 自包含地携带需要的类型，不代表 Gateway 加载其它课程协议。

## 协议构建入口

每个入口只生成一个课程的 .pb、hash sidecar 和 protocol_registry_*.lua；入口内部带有路径推导、版本检查、输入验证、生成顺序和失败语义的中文注释。

命令（每次只运行需要的那一课）：

    bash server/protocol/build_protocol_lesson_01.sh
    bash server/protocol/build_protocol_lesson_02.sh
    bash server/protocol/build_protocol_lesson_03_frame_sync.sh
    bash server/protocol/build_protocol_lesson_03_state_sync.sh

例如修改帧同步协议只运行第三课帧同步入口，不会生成或覆盖导航、自动战斗或状态同步文件。Server 启动脚本只消费已经构建的 descriptor 与 Registry，不会在 run_server.sh 中发现或批量生成协议。

descriptor 输出名分别为 lesson_01.pb、lesson_02.pb、lesson_03_frame_sync.pb、lesson_03_state_sync.pb。Registry 分别名为 protocol_registry_lesson_01.lua、protocol_registry_lesson_02.lua、protocol_registry_lesson_03_frame_sync.lua、protocol_registry_lesson_03_state_sync.lua。

## Unity C# 生成

在 Windows PowerShell 执行：

    .\shared\protocol\build_unity_cs.ps1

脚本中的 $protocolInputs 是唯一课程文件清单。输出分别放进 Scripts/Protocol/Shared/、Lesson01/、Lesson02/、Lesson03FrameSync/ 和 Lesson03StateSync/，不会因两个课程都有 Navigation.cs 而相互覆盖。Unity Editor 管理新文件的 .meta。

协议修改后，应使用对应课程的 WSL Server 构建入口和 Windows Unity C# 入口分别生成、验证双方产物。不要从课程 1 协议构建流程生成课程 2/3 文件，也不要手工编辑 .pb、Registry 或生成的 C#。
