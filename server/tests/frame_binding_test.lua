--- 职责：验证固定Lua5.4.7 Binding的资源所有权、帧调用、非法输入和Checkpoint恢复。
--- 输入：已发布BMAP、独立lesson_frame_native.so；失败断言立即退出。
--- 运行：server目录 ./third_party/skynet/3rd/lua/lua tests/frame_binding_test.lua。
package.cpath = "./build/frame_sync/?.so;" .. package.cpath
local native = require "lesson_frame_native"
local config = require "config.frame_sync"
assert(native.preload(config.map_path, config.airnav_path,
                      require "config.unit_profiles",
                      require "config.navigation_profiles", config.skills))
local first = assert(native.open(1001))
local second = assert(native.open(1001))
local initial = assert(first:save())
assert(initial == second:save())
assert(first:step_frame(1,
{
    { seat_id = 1, unit_instance_id = 1001, x = 1, z = 0, skill = 0 },
}))
assert(first:save() ~= second:save())
local bad, err = first:step_frame(2,
{
    { seat_id = 1, unit_instance_id = 1001, x = 9, z = 0, skill = 0 },
})
assert(bad == nil and err and err.code)
local stable = assert(first:save())
local restored, restore_err = first:restore(stable .. "x")
assert(restored == nil and restore_err and restore_err.code)
assert(first:save() == stable)
assert(first:restore(initial))
assert(first:save() == initial)
assert(first:close())
assert(first:close())
local failed = first:save()
assert(failed == nil)
assert(second:close())
print("FRAME_BINDING_OK")
