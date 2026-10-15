-- 职责：由 proto CommandId 和 Request/Response 消息生成的 FlyWow Gateway command registry。
-- 边界：Build Artifact；运行时只读加载，不手工注册 command。
-- 输入/输出：CommandId + 可选 XxxRequest/XxxResponse -> Envelope command 映射。
-- 生命周期：协议生成后随 Server 产物发布；Gateway 启动时加载并校验。
-- 不负责：不实现业务 handler、不读取 Socket、不动态解析 .proto。
local command_ids =
    {
        FRAME_INPUT = 1102,
        FRAME_JOIN = 1101,
        FRAME_LEAVE = 1105,
        FRAME_PUSH = 1103,
        FRAME_RECOVER = 1104,
        FRAME_REPLAY = 1106,
    }
return
{
    envelope_type = ".battle.transport.v1.Envelope",
    command_ids   = command_ids,
    commands      =
    {
        [command_ids.FRAME_JOIN] =
        {
            name          = "FrameJoin",
            request_type  = ".battle.lesson_03.frame_sync.v1.FrameJoinRequest",
            response_type = ".battle.lesson_03.frame_sync.v1.FrameJoinResponse",
        },
        [command_ids.FRAME_INPUT] =
        {
            name          = "FrameInput",
            request_type  = ".battle.lesson_03.frame_sync.v1.FrameInputRequest",
            response_type = nil,
        },
        [command_ids.FRAME_PUSH] =
        {
            name          = "FramePush",
            request_type  = nil,
            response_type = ".battle.lesson_03.frame_sync.v1.FramePushResponse",
        },
        [command_ids.FRAME_RECOVER] =
        {
            name          = "FrameRecover",
            request_type  = ".battle.lesson_03.frame_sync.v1.FrameRecoverRequest",
            response_type = ".battle.lesson_03.frame_sync.v1.FrameRecoverResponse",
        },
        [command_ids.FRAME_LEAVE] =
        {
            name          = "FrameLeave",
            request_type  = ".battle.lesson_03.frame_sync.v1.FrameLeaveRequest",
            response_type = ".battle.lesson_03.frame_sync.v1.FrameLeaveResponse",
        },
        [command_ids.FRAME_REPLAY] =
        {
            name          = "FrameReplay",
            request_type  = ".battle.lesson_03.frame_sync.v1.FrameReplayRequest",
            response_type = ".battle.lesson_03.frame_sync.v1.FrameReplayResponse",
        },
    },
}
