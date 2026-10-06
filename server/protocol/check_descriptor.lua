--- 职责：验证 Server descriptor 消息表和 Envelope 请求关联字段合同。
-- 边界：离线 Build Check；不启动 Skynet，不执行地图查询。
-- 输入/输出：descriptor 文件路径 -> 断言或 PROTO_DESCRIPTOR_OK。
local pb = require "pb"

local path = assert(arg[1], "usage: lua check_descriptor.lua descriptor.pb")
local data = assert(io.open(path, "rb")):read("*a")
assert(pb.load(data))

assert(pb.type(".battle.navigation.v1.Envelope"))
assert(pb.type(".battle.navigation.v1.QueryCellRequest"))
assert(pb.type(".battle.navigation.v1.QueryCellResponse"))
local envelope_type = ".battle.navigation.v1.Envelope"
local original =
{
    protocol_version = 3,
    command = 1002,
    request_id = 0x12345678,
    body = "descriptor-contract",
}
local encoded = assert(pb.encode(envelope_type, original))
local decoded = assert(pb.decode(envelope_type, encoded))
assert(decoded.protocol_version == original.protocol_version)
assert(decoded.command == original.command)
assert(decoded.request_id == original.request_id,
    "Envelope.request_id must be uint64 field 3")
assert(decoded.body == original.body, "Envelope.body must be bytes field 4")
print("PROTO_DESCRIPTOR_OK")
