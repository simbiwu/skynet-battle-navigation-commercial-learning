-- 职责：验证一个课程 FileDescriptorSet 只包含共享 Envelope 与本课程协议。
-- 边界：离线 Build Check；不启动 Skynet，不读取 Gateway 配置。
-- 输入：descriptor 文件路径和课程 profile；失败通过 assert 返回非零。
local pb = require "pb"

local path = assert(arg[1], "usage: lua check_descriptor.lua descriptor.pb profile")
local profile = assert(arg[2], "usage: lua check_descriptor.lua descriptor.pb profile")
local stream = assert(io.open(path, "rb"))
local data = stream:read("*a")
stream:close()
assert(pb.load(data), "descriptor load failed: " .. path)

-- 所有课程只共享这个传输信封；课程命令编号和业务类型各自独立。
assert(pb.type(".battle.transport.v1.Envelope"), "descriptor missing shared Envelope")

-- 每个 profile 都列举至少两个本课类型和其它三个 profile 的代表类型。
-- 新增业务消息无需在此穷举，但必须在 expected 中保留验证协议边界的代表合同。
local contracts = {
    lesson_01 = {
        command = 1001,
        expected = { ".battle.lesson_01.navigation.v1.QueryCellRequest",
                     ".battle.lesson_01.navigation.v1.QueryCellResponse",
                     ".battle.lesson_01.navigation.v1.WorldPosition" },
        excluded = { ".battle.lesson_02.navigation.v1.QueryCellRequest",
                     ".battle.lesson_03.frame_sync.v1.FrameJoinRequest",
                     ".battle.lesson_03.state_sync.v1.StateJoinRequest" },
    },
    lesson_02 = {
        command = 1001,
        expected = { ".battle.lesson_02.navigation.v1.QueryCellRequest",
                     ".battle.lesson_02.navigation.v1.RunAutoBattleRequest",
                     ".battle.lesson_02.navigation.v1.RunAutoBattleResponse" },
        excluded = { ".battle.lesson_01.navigation.v1.QueryCellRequest",
                     ".battle.lesson_03.frame_sync.v1.FrameJoinRequest",
                     ".battle.lesson_03.state_sync.v1.StateJoinRequest" },
    },
    lesson_03_frame_sync = {
        command = 1101,
        expected = { ".battle.lesson_03.frame_sync.v1.FrameJoinRequest",
                     ".battle.lesson_03.frame_sync.v1.FramePushResponse",
                     ".battle.lesson_03.frame_sync.v1.FrameReplay" },
        excluded = { ".battle.lesson_01.navigation.v1.QueryCellRequest",
                     ".battle.lesson_02.navigation.v1.QueryCellRequest",
                     ".battle.lesson_03.state_sync.v1.StateJoinRequest" },
    },
    lesson_03_state_sync = {
        command = 1201,
        expected = { ".battle.lesson_03.state_sync.v1.StateJoinRequest",
                     ".battle.lesson_03.state_sync.v1.StatePushResponse",
                     ".battle.lesson_03.state_sync.v1.WorldPosition" },
        excluded = { ".battle.lesson_01.navigation.v1.QueryCellRequest",
                     ".battle.lesson_02.navigation.v1.QueryCellRequest",
                     ".battle.lesson_03.frame_sync.v1.FrameJoinRequest" },
    },
}
local contract = assert(contracts[profile], "unknown descriptor profile: " .. profile)
for _, name in ipairs(contract.expected) do
    assert(pb.type(name), "descriptor missing " .. name)
end
for _, name in ipairs(contract.excluded) do
    assert(not pb.type(name), "descriptor unexpectedly includes " .. name)
end

-- Envelope 编解码确认课程 command 使用共享传输头，body 使用字段 3。
local envelope = ".battle.transport.v1.Envelope"
local original = { protocol_version = 4, command = contract.command, body = "profile-check" }
local encoded = assert(pb.encode(envelope, original))
local decoded = assert(pb.decode(envelope, encoded))
assert(decoded.protocol_version == original.protocol_version)
assert(decoded.command == original.command)
assert(decoded.body == original.body)
-- Protobuf length-delimited tag 26 is field 3; field 4 would use tag 34.
-- Inspect exact bytes as well as round-trip values so an accidentally shifted body field fails.
local body_tag = string.char(26, #original.body) .. original.body
local old_body_tag = string.char(34, #original.body) .. original.body
assert(encoded:find(body_tag, 1, true), "Envelope.body must use field 3")
assert(not encoded:find(old_body_tag, 1, true), "Envelope.body must not use field 4")
print(string.upper(profile) .. "_DESCRIPTOR_OK")
