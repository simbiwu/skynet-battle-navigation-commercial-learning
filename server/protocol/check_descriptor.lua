-- 职责：验证 Server descriptor 能加载且包含第一课必需的三种消息。
-- 边界：离线 Build Check；不启动 Skynet，不执行地图查询。
-- 输入/输出：descriptor 文件路径 -> 断言或 PROTO_DESCRIPTOR_OK。
local pb = require "pb"

local path = assert(arg[1], "usage: lua check_descriptor.lua descriptor.pb")
local data = assert(io.open(path, "rb")):read("*a")
assert(pb.load(data))

assert(pb.type(".battle.navigation.v1.Envelope"))
assert(pb.type(".battle.navigation.v1.QueryCellRequest"))
assert(pb.type(".battle.navigation.v1.QueryCellResponse"))
print("PROTO_DESCRIPTOR_OK")
