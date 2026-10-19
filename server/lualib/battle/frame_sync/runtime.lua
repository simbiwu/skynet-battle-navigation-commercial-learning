--- 职责：单场帧同步 no-yield Core Adapter；收集玩家输入并提交完整权威帧。
--- 边界：宿主 Battle Runtime；不依赖 Skynet/网络/墙钟。
--- ownership：独占 Native Engine；Worker 必须在销毁 Battle 时调用 close。
--- 输入/输出：席位输入 -> 帧记录/规范化 Checkpoint；失败返回稳定 code。
--- 不负责：用户认证、fd、Cluster、定时器、Battle 进程持久化恢复。
local frame_native = require "lesson_frame_native"
local M = {}

local MAX_SEATS = 1
local MAX_MISSING_HOLD = 6 -- 100ms；连续缺输入后改为中立方向。

---@class FrameInput
---@field frame integer 目标权威帧号；由Server验证Deadline。
---@field x integer -1,0,1。
---@field z integer -1,0,1。
---@field skill integer 0,1,2,3；缺输入永不继承技能。

---@class FrameRuntime
---@field engine userdata 独占 Native Engine；显式关闭。
---@field frame integer 已完成的权威帧号。
---@field winner integer 0运行、1玩家胜、2敌方胜、3平局。
---@field seats integer[] 固定值[1]。
---@field seat_unit_instance_ids table<integer,integer> seat_id -> 本席位可控单位实例ID。
---@field pending table<integer,table<integer,FrameInput>> 未来窗口的席位输入。
---@field last_input table<integer,FrameInput> 各席位上一正式方向。
---@field missing table<integer,integer> 各席位连续缺输入次数。
---@field records table[] 只含正式采用输入，不含伪造的客户端State。
---@field window integer 未来最大有效帧窗口。
---@field max_frames integer 帧日志/对战寿命上限。

--- FNV32 是状态分歧诊断值，不是认证Hash。
---@param bytes string Native规范化Checkpoint副本。
---@return integer hash 32位无符号整数。
function M.hash(bytes)
    local value = 2166136261
    for index = 1, #bytes do
        value = ((value ~ bytes:byte(index)) * 16777619) & 0xffffffff
    end
    return value
end

--- 读取固定小端的格式版本/帧号/胜负；调用前已验证Native生成状态。
local function read_header(bytes)
    local version, frame, winner = string.unpack("<I4I4I4", bytes)
    assert(version == 3, "STATE_VERSION") -- 当前规范化格式为Checkpoint V3。
    return frame, winner
end

local function valid_input(input)
    if type(input) ~= "table" then return false end
    local f, x, z, skill = input.frame, input.x, input.z, input.skill
    return math.type(f) == "integer" and f >= 1 and
        math.type(x) == "integer" and x >= -1 and x <= 1 and
        math.type(z) == "integer" and z >= -1 and z <= 1 and
        math.type(skill) == "integer" and skill >= 0 and skill <= 3
end

local function copy_input(input)
    return { frame = input.frame, x = input.x, z = input.z, skill = input.skill }
end

--- 创建独占Runtime；Native预载MapRegistry。失败清理临时Engine。
---@param frame_runtime_config table {map_id,window,max_frames,seat_unit_instance_ids} 由Worker显式传入。
---@return FrameRuntime|nil runtime 成功实例，失败为nil。
---@return table|nil err 稳定错误Record。
function M.create(frame_runtime_config)
    assert(frame_runtime_config.window >= 1 and frame_runtime_config.window <= 32)
    assert(frame_runtime_config.max_frames > 0)
    assert(#frame_runtime_config.seat_unit_instance_ids == MAX_SEATS)

    local engine, open_err = frame_native.open(frame_runtime_config.map_id)
    if not engine then return nil, open_err or { code = "NATIVE_OPEN" } end

    local checkpoint, save_err = engine:save()
    if not checkpoint then
        engine:close()
        return nil, save_err or { code = "CHECKPOINT" }
    end

    local frame, winner = read_header(checkpoint)
    assert(frame == 0 and winner == 0, "BATTLE_INITIAL_STATE")

    local runtime =
    {
        engine     = engine,
        initial    = checkpoint,
        frame      = frame,
        winner     = winner,
        seats      = { 1 },
        seat_unit_instance_ids = { [1] = frame_runtime_config.seat_unit_instance_ids[1] },
        pending    = {},
        last_input = { [1] = { x = 0, z = 0 } },
        missing    = { [1] = 0 },
        records    = {},
        window     = frame_runtime_config.window,
        max_frames = frame_runtime_config.max_frames,
    }
    return runtime
end

--- 某席位提交未来输入；Worker已校验传输身份和该帧实际Deadline。
--- 复制输入避免跨消息保留调用方临时table；不yield、不执行Native。
---@param runtime FrameRuntime 当前Battle owner。
---@param seat_id integer 服务端绑定席位，不允许读取客户端自填席位。
---@param input FrameInput 网络已解析且不持有外部buffer的值record。
---@return string code OK/LATE/INPUT_WINDOW/CONFLICT/BAD_INPUT/FINISHED。
function M.accept(runtime, seat_id, input)
    if not runtime.seat_unit_instance_ids[seat_id] then return "NO_SEAT" end
    if not valid_input(input) then return "BAD_INPUT" end
    if runtime.winner ~= 0 then return "FINISHED" end
    if input.frame <= runtime.frame then return "LATE" end
    if input.frame > runtime.frame + runtime.window then return "INPUT_WINDOW" end

    local slot = runtime.pending[input.frame]
    if not slot then
        slot = {}
        runtime.pending[input.frame] = slot
    end

    local previous = slot[seat_id]
    if previous then
        local same = previous.x == input.x and previous.z == input.z and
                     previous.skill == input.skill
        return same and "OK" or "CONFLICT"
    end

    slot[seat_id] = copy_input(input)
    return "OK"
end

--- 提取一帧全部席位输入，缺输入方向最多保持六帧（100ms），技能立即清零。
--- 此函数不修改runtime，避免Native执行失败时last_input和missing先变更。
local function prepare_frame(runtime, frame)
    local slot = runtime.pending[frame] or {}
    local adopted, next_last, next_missing, records = {}, {}, {}, {}

    for _, seat_id in ipairs(runtime.seats) do
        local source = slot[seat_id]
        local supplied = source ~= nil
        local missing = supplied and 0 or runtime.missing[seat_id] + 1
        local hold = missing <= MAX_MISSING_HOLD
        local last = runtime.last_input[seat_id]
        local input = source or
        {
            frame = frame,
            x = hold and last.x or 0,
            z = hold and last.z or 0,
            skill = 0,
        }
        local final = copy_input(input)
        next_last[seat_id] = { x = final.x, z = final.z }
        next_missing[seat_id] = missing

        adopted[#adopted + 1] =
        {
            seat_id = seat_id,
            unit_instance_id = runtime.seat_unit_instance_ids[seat_id],
            x = final.x,
            z = final.z,
            skill = final.skill,
        }
        records[#records + 1] =
        {
            seat_id = seat_id,
            input = final,
            supplied = supplied,
        }
    end
    return adopted, records, next_last, next_missing
end

--- 提交完整权威帧；Native失败则Worker终止本Battle，不能继续半帧模拟。
---@param runtime FrameRuntime 当前Battle owner。
---@return table|nil record 本帧正式记录。
---@return table|nil err 稳定错误记录。
function M.step(runtime)
    if runtime.winner ~= 0 then return nil, { code = "FINISHED" } end
    if runtime.frame >= runtime.max_frames then return nil, { code = "FRAME_LIMIT" } end

    local frame = runtime.frame + 1
    local inputs, players, next_last, next_missing = prepare_frame(runtime, frame)
    local ok, step_err = runtime.engine:step_frame(frame, inputs)
    if not ok then return nil, step_err or { code = "NATIVE_STEP" } end

    local state, save_err = runtime.engine:save()
    if not state then return nil, save_err or { code = "CHECKPOINT" } end
    local confirmed, winner = read_header(state)
    if confirmed ~= frame then return nil, { code = "FRAME_SEQUENCE" } end

    runtime.frame = frame
    runtime.winner = winner
    runtime.last_input = next_last
    runtime.missing = next_missing
    runtime.pending[frame] = nil

    local record = { frame = frame, players = players, hash = M.hash(state) }
    runtime.records[#runtime.records + 1] = record
    return record
end

--- 断线或同一席位恢复后丢弃它尚未采用的旧代数未来输入。
--- 不修改已完成FrameRecord。
---@param runtime FrameRuntime 当前Battle owner。
---@param seat_id integer 恢复/断线的原席位。
function M.clear_seat_pending(runtime, seat_id)
    for frame, slot in pairs(runtime.pending) do
        slot[seat_id] = nil
        if next(slot) == nil then runtime.pending[frame] = nil end
    end
    runtime.last_input[seat_id] = { x = 0, z = 0 }
    runtime.missing[seat_id] = MAX_MISSING_HOLD
end

--- 显式释放Native，GC仅兜底；调用后Runtime不得再执行step。
---@param runtime FrameRuntime 当前Battle owner。
function M.close(runtime)
    if runtime.engine then
        runtime.engine:close()
        runtime.engine = nil
    end
end

return M
