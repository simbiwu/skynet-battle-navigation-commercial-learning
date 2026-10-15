-- 职责：由 proto CommandId 和 Request/Response 消息生成的 FlyWow Gateway command registry。
-- 边界：Build Artifact；运行时只读加载，不手工注册 command。
-- 输入/输出：CommandId + 可选 XxxRequest/XxxResponse -> Envelope command 映射。
-- 生命周期：协议生成后随 Server 产物发布；Gateway 启动时加载并校验。
-- 不负责：不实现业务 handler、不读取 Socket、不动态解析 .proto。
local command_ids =
    {
        QUERY_CELL = 1001,
    }
return
{
    envelope_type = ".battle.transport.v1.Envelope",
    command_ids   = command_ids,
    commands      =
    {
        [command_ids.QUERY_CELL] =
        {
            name          = "QueryCell",
            request_type  = ".battle.lesson_01.navigation.v1.QueryCellRequest",
            response_type = ".battle.lesson_01.navigation.v1.QueryCellResponse",
        },
    },
}
