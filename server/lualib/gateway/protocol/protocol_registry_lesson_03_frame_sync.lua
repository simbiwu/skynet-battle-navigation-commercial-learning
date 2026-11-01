-- 职责：由 proto CommandId 和 Request/Response 消息生成的 FlyWow Gateway command registry。
-- 边界：Build Artifact；运行时只读加载，不手工注册 command。
-- 输入/输出：CommandId + 可选 XxxRequest/XxxResponse -> Envelope command 映射。
-- 生命周期：协议生成后随 Server 产物发布；Gateway 启动时加载并校验。
-- 不负责：不实现业务 handler、不读取 Socket、不动态解析 .proto。
local command_ids =
{
    FRAME_INPUT = 1102, -- 宿主可用此名称引用 proto 中分配的稳定命令号。
    FRAME_JOIN = 1101, -- 宿主可用此名称引用 proto 中分配的稳定命令号。
    FRAME_LEAVE = 1105, -- 宿主可用此名称引用 proto 中分配的稳定命令号。
    FRAME_PUSH = 1103, -- 宿主可用此名称引用 proto 中分配的稳定命令号。
    FRAME_RECOVER = 1104, -- 宿主可用此名称引用 proto 中分配的稳定命令号。
    FRAME_REPLAY = 1106, -- 宿主可用此名称引用 proto 中分配的稳定命令号。
}
return
{
    envelope_type = ".battle.transport.v1.Envelope", -- lua-protobuf 解码和编码外层 Envelope 时使用。
    command_ids   = command_ids, -- 宿主业务代码按协议枚举名称引用命令号。
    commands      = -- Gateway 按 Envelope.command 选择消息类型。
    {
        [1101] = -- ID 来自 proto CommandId，作为 commands 的唯一查询键。
        {
            request_type  = ".battle.lesson_03.frame_sync.v1.FrameJoinRequest", -- Gateway 用于解码该命令的入站 Request；nil 表示客户端不能发送此命令。
            response_type = ".battle.lesson_03.frame_sync.v1.FrameJoinResponse", -- Gateway 用于编码该命令的服务端 Response；nil 表示该命令没有响应消息。
        },
        [1102] = -- ID 来自 proto CommandId，作为 commands 的唯一查询键。
        {
            request_type  = ".battle.lesson_03.frame_sync.v1.FrameInputRequest", -- Gateway 用于解码该命令的入站 Request；nil 表示客户端不能发送此命令。
            response_type = nil, -- Gateway 用于编码该命令的服务端 Response；nil 表示该命令没有响应消息。
        },
        [1103] = -- ID 来自 proto CommandId，作为 commands 的唯一查询键。
        {
            request_type  = nil, -- Gateway 用于解码该命令的入站 Request；nil 表示客户端不能发送此命令。
            response_type = ".battle.lesson_03.frame_sync.v1.FramePushResponse", -- Gateway 用于编码该命令的服务端 Response；nil 表示该命令没有响应消息。
        },
        [1104] = -- ID 来自 proto CommandId，作为 commands 的唯一查询键。
        {
            request_type  = ".battle.lesson_03.frame_sync.v1.FrameRecoverRequest", -- Gateway 用于解码该命令的入站 Request；nil 表示客户端不能发送此命令。
            response_type = ".battle.lesson_03.frame_sync.v1.FrameRecoverResponse", -- Gateway 用于编码该命令的服务端 Response；nil 表示该命令没有响应消息。
        },
        [1105] = -- ID 来自 proto CommandId，作为 commands 的唯一查询键。
        {
            request_type  = ".battle.lesson_03.frame_sync.v1.FrameLeaveRequest", -- Gateway 用于解码该命令的入站 Request；nil 表示客户端不能发送此命令。
            response_type = ".battle.lesson_03.frame_sync.v1.FrameLeaveResponse", -- Gateway 用于编码该命令的服务端 Response；nil 表示该命令没有响应消息。
        },
        [1106] = -- ID 来自 proto CommandId，作为 commands 的唯一查询键。
        {
            request_type  = ".battle.lesson_03.frame_sync.v1.FrameReplayRequest", -- Gateway 用于解码该命令的入站 Request；nil 表示客户端不能发送此命令。
            response_type = ".battle.lesson_03.frame_sync.v1.FrameReplayResponse", -- Gateway 用于编码该命令的服务端 Response；nil 表示该命令没有响应消息。
        },
    },
}
