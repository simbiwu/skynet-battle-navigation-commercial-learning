--- 职责：不用Skynet的单人帧输入收集、复制隔离、幂等/冲突/缺输入测试。
--- 输入：已准备的BMAP和lesson_frame_native；输出FRAME_RUNTIME_OK或抛错。
--- 用法：server/目录执行 ./third_party/skynet/3rd/lua/lua tests/frame_runtime_test.lua。
package.path = "./lualib/?.lua;./lualib/?/init.lua;" .. package.path
package.cpath = "./build/frame_sync/?.so;" .. package.cpath
local frame_native = require "lesson_frame_native"
local frame_sync_runtime = require "battle.frame_sync.runtime"
local frame_sync_config = require "config.frame_sync"
assert(frame_native.preload(frame_sync_config.map_path, frame_sync_config.airnav_path,
                      require "config.unit_profiles",
                      require "config.navigation_profiles", frame_sync_config.skills))
local runtime = assert(frame_sync_runtime.create({ map_id = 1001, window = 8, max_frames = 10800,
                                     seat_unit_instance_ids = { 1001 } }))
local first = { frame = 1, x = 1, z = 0, skill = 0 }
assert(frame_sync_runtime.accept(runtime, 1, first) == "OK")
first.x = -1 -- 证明Runtime保存了值的拷贝，不是网络table地址。
assert(frame_sync_runtime.accept(runtime, 1, { frame = 1, x = 1, z = 0, skill = 0 }) == "OK")
assert(frame_sync_runtime.accept(runtime, 1, first) == "CONFLICT")
local record = assert(frame_sync_runtime.step(runtime))
assert(record.frame == 1 and #record.players == 1)
assert(record.players[1].supplied)
assert(record.players[1].input.x == 1)
assert(frame_sync_runtime.accept(runtime, 1, { frame = 1, x = 0, z = 0, skill = 0 }) == "LATE")
assert(frame_sync_runtime.accept(runtime, 1, { frame = 11, x = 0, z = 0, skill = 0 }) == "INPUT_WINDOW")
local missing = assert(frame_sync_runtime.step(runtime))
assert(not missing.players[1].supplied)
assert(missing.players[1].input.x == 1)
assert(missing.players[1].input.skill == 0)
assert(frame_sync_runtime.step(runtime) and frame_sync_runtime.step(runtime))
local stopped
for _ = 1, 4 do stopped = assert(frame_sync_runtime.step(runtime)) end
assert(stopped.players[1].input.x == 0)
frame_sync_runtime.close(runtime)
print("FRAME_RUNTIME_OK")
