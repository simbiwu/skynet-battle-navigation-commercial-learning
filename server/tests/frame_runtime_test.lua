--- 职责：不用Skynet的单人帧输入收集、复制隔离、幂等/冲突/缺输入测试。
--- 输入：已准备的BMAP和lesson_frame_native；输出FRAME_RUNTIME_OK或抛错。
--- 用法：server/目录执行 ./third_party/skynet/3rd/lua/lua tests/frame_runtime_test.lua。
package.path = "./lualib/?.lua;./lualib/?/init.lua;" .. package.path
package.cpath = "./build/frame_sync/?.so;" .. package.cpath
local native = require "lesson_frame_native"
local core = require "battle.frame_sync.runtime"
local config = require "config.frame_sync"
assert(native.preload(config.map_path, config.airnav_path,
                      require "config.unit_profiles",
                      require "config.navigation_profiles", config.skills))
local runtime = assert(core.create({ map_id = 1001, window = 8, max_frames = 10800,
                                     seat_unit_instance_ids = { 1001 } }))
local first = { frame = 1, x = 1, z = 0, skill = 0 }
assert(core.accept(runtime, 1, first) == "OK")
first.x = -1 -- 证明Runtime保存了值的拷贝，不是网络table地址。
assert(core.accept(runtime, 1, { frame = 1, x = 1, z = 0, skill = 0 }) == "OK")
assert(core.accept(runtime, 1, first) == "CONFLICT")
local record = assert(core.step(runtime))
assert(record.frame == 1 and #record.players == 1)
assert(record.players[1].supplied)
assert(record.players[1].input.x == 1)
assert(core.accept(runtime, 1, { frame = 1, x = 0, z = 0, skill = 0 }) == "LATE")
assert(core.accept(runtime, 1, { frame = 11, x = 0, z = 0, skill = 0 }) == "INPUT_WINDOW")
local missing = assert(core.step(runtime))
assert(not missing.players[1].supplied)
assert(missing.players[1].input.x == 1)
assert(missing.players[1].input.skill == 0)
assert(core.step(runtime) and core.step(runtime))
local stopped
for _ = 1, 4 do stopped = assert(core.step(runtime)) end
assert(stopped.players[1].input.x == 0)
core.close(runtime)
print("FRAME_RUNTIME_OK")
