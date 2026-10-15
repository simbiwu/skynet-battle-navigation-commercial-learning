-- 职责：由 proto CommandId 和 Request/Response 消息生成的 FlyWow Gateway command registry。
-- 边界：Build Artifact；运行时只读加载，不手工注册 command。
-- 输入/输出：CommandId + 可选 XxxRequest/XxxResponse -> Envelope command 映射。
-- 生命周期：协议生成后随 Server 产物发布；Gateway 启动时加载并校验。
-- 不负责：不实现业务 handler、不读取 Socket、不动态解析 .proto。
local command_ids =
    {
        STATE_CAST = 1203,
        STATE_INPUT = 1202,
        STATE_JOIN = 1201,
        STATE_LEAVE = 1207,
        STATE_PUSH = 1204,
        STATE_RECOVER = 1205,
        STATE_REPLAY = 1208,
        STATE_RESYNC = 1206,
    }
return
{
    envelope_type = ".battle.transport.v1.Envelope",
    command_ids   = command_ids,
    commands      =
    {
        [command_ids.STATE_JOIN] =
        {
            name          = "StateJoin",
            request_type  = ".battle.lesson_03.state_sync.v1.StateJoinRequest",
            response_type = ".battle.lesson_03.state_sync.v1.StateJoinResponse",
        },
        [command_ids.STATE_INPUT] =
        {
            name          = "StateInput",
            request_type  = ".battle.lesson_03.state_sync.v1.StateInputRequest",
            response_type = ".battle.lesson_03.state_sync.v1.StateInputResponse",
        },
        [command_ids.STATE_CAST] =
        {
            name          = "StateCast",
            request_type  = ".battle.lesson_03.state_sync.v1.StateCastRequest",
            response_type = ".battle.lesson_03.state_sync.v1.StateCastResponse",
        },
        [command_ids.STATE_PUSH] =
        {
            name          = "StatePush",
            request_type  = nil,
            response_type = ".battle.lesson_03.state_sync.v1.StatePushResponse",
        },
        [command_ids.STATE_RECOVER] =
        {
            name          = "StateRecover",
            request_type  = ".battle.lesson_03.state_sync.v1.StateRecoverRequest",
            response_type = ".battle.lesson_03.state_sync.v1.StateRecoverResponse",
        },
        [command_ids.STATE_RESYNC] =
        {
            name          = "StateResync",
            request_type  = ".battle.lesson_03.state_sync.v1.StateResyncRequest",
            response_type = ".battle.lesson_03.state_sync.v1.StateResyncResponse",
        },
        [command_ids.STATE_LEAVE] =
        {
            name          = "StateLeave",
            request_type  = ".battle.lesson_03.state_sync.v1.StateLeaveRequest",
            response_type = ".battle.lesson_03.state_sync.v1.StateLeaveResponse",
        },
        [command_ids.STATE_REPLAY] =
        {
            name          = "StateReplay",
            request_type  = ".battle.lesson_03.state_sync.v1.StateReplayRequest",
            response_type = ".battle.lesson_03.state_sync.v1.StateReplayResponse",
        },
    },
}
