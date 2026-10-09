# 职责：在隔离目录验证第三课教程代码，并生成WSL主编辑源的帧同步实操。
# 此作者工具不部署用户Server，不修改子模块，不提交或推送。
from pathlib import Path
import runpy
import hashlib
import json
import re
import sys
import shutil
import subprocess

def run_processes():
    logs=[]; processes=[]
    try:
        for role in ['battle','gateway']:
            log=open(S/(role+'.startup.log'),'w'); logs.append(log)
            process=subprocess.Popen([str(S/'server/third_party/skynet/skynet'),'config/frame_'+role+'_process.lua'],
                cwd=S/'server',stdout=log,stderr=subprocess.STDOUT)
            processes.append(process)
            import time
            time.sleep(1)
            if process.poll() is not None: raise RuntimeError((S/(role+'.startup.log')).read_text())
        subprocess.run(['python3',str(S/'server/tests/frame_sync_integration.py')],check=True,cwd=S/'server',timeout=25)
        if '--windows-client' in sys.argv:
            subprocess.run(['/mnt/c/Program Files/dotnet/dotnet.exe',
                'G:\\simbi\\dev\\skynet-battle-navigation-commercial-learning\\.frame_verify_windows\\bin\\Debug\\net10.0\\Smoke.dll'],check=True,timeout=15)
    finally:
        for process in reversed(processes):
            process.terminate()
            try: process.wait(timeout=5)
            except subprocess.TimeoutExpired: process.kill(); process.wait()
        for log in logs: log.close()

def windows_stage():
    target=Path('/mnt/g/simbi/dev/skynet-battle-navigation-commercial-learning/.frame_verify_windows')
    target.mkdir(exist_ok=True)
    for path,code in F.items():
        if path.startswith('server/native/') or path.startswith('unity/'):
            out=target/path; out.parent.mkdir(parents=True,exist_ok=True); out.write_text(code)
    shutil.copytree(R/'server/third_party/skynet-flywow/navigation',target/'server/third_party/skynet-flywow/navigation',dirs_exist_ok=True)
    shutil.copytree(R/'shared/navigation/battle_1001',target/'shared/navigation/battle_1001',dirs_exist_ok=True)
    shutil.copytree(S/'shared/protocol/generated/unity',target/'generated',dirs_exist_ok=True)
    shutil.copy2(R/'server/third_party/skynet-flywow/gateway/clients/unity/FlyWowHandshake.cs',target/'FlyWowHandshake.cs')
    for name in ['Smoke.cs','Smoke.csproj','FrameCompile.csproj']:
        saved=R/'codex/work/lesson_03_frame_sync/validation'/name
        if saved.exists(): shutil.copy2(saved,target/name)
    print('WINDOWS_STAGE_OK')

def stage_files():
    # 隔离依赖目录：不能经由symlink修改用户源码。
    third = S/'server/third_party'
    if third.is_symlink(): third.unlink()
    third.mkdir(parents=True,exist_ok=True)
    for item in (R/'server/third_party').iterdir():
        target=third/item.name
        if target.exists(): continue
        if item.name=='skynet-flywow':
            shutil.copytree(item,target,ignore=shutil.ignore_patterns('.git','build'))
            (target/'build').symlink_to(item/'build',target_is_directory=True)
        else: target.symlink_to(item,target_is_directory=item.is_dir())
    for role in ['battle','gateway']:
        path='server/config/frame_'+role+'_process.lua'
        F[path]=F[path].replace('dofile("./config/'+role+'_process.lua")',(R/('server/config/'+role+'_process.lua')).read_text().strip())
    for path,code in F.items():
        target=S/path; target.parent.mkdir(parents=True,exist_ok=True); target.write_text(code)
    for path in ['server/config/gateway.lua','server/config/battle_process.lua','server/config/gateway_process.lua']:
        shutil.copy2(R/path,S/path)
    debug=S/'server/lualib/shared'
    if not debug.exists(): debug.symlink_to(R/'server/lualib/shared',target_is_directory=True)
    for name in ['logs','luaclib']:
        target=S/'server'/name
        if name=='logs': target.mkdir(exist_ok=True)
        elif not target.exists(): target.symlink_to(R/'server'/name,target_is_directory=True)
    target=S/'shared/navigation'
    if not target.exists(): target.symlink_to(R/'shared/navigation',target_is_directory=True)
    proto=(R/'shared/protocol/navigation_query.proto').read_text()
    enum=''.join(f'  FRAME_{name} = {1101+i};\n' for i,name in enumerate(['JOIN','INPUT','PUSH','RECOVER','LEAVE','REPLAY']))
    proto=proto.replace('  RUN_AUTO_BATTLE = 1002;','  RUN_AUTO_BATTLE = 1002;\n'+enum)
    proto+='\n'+F['shared/protocol/frame_sync_messages.proto.inc']
    (S/'shared/protocol/navigation_query.proto').write_text(proto)
    out=S/'shared/protocol/generated/server'; out.mkdir(parents=True,exist_ok=True)
    cs=S/'shared/protocol/generated/unity'; cs.mkdir(parents=True,exist_ok=True)
    py=S/'test_python'; py.mkdir(exist_ok=True)
    subprocess.run([str(R/'server/third_party/protoc-36.2/bin/protoc'),'-I'+str(S/'shared/protocol'),
        '--descriptor_set_out='+str(out/'navigation_query.pb'),'--include_imports',
        '--csharp_out='+str(cs),'--python_out='+str(py),str(S/'shared/protocol/navigation_query.proto')],check=True)
    subprocess.run(['python3',str(R/'server/third_party/skynet-flywow/gateway/tools/generate_gateway_registry.py'),
        '--proto',str(S/'shared/protocol/navigation_query.proto'),'--output',str(S/'server/lualib/gateway/protocol/navigation_registry.lua')],check=True)
    gateway=third/'skynet-flywow/gateway/service/gateway/flywow_gateway.lua'
    code=(R/'server/third_party/skynet-flywow/gateway/service/gateway/flywow_gateway.lua').read_text()
    old='        (message.connection_id > 0 and message.request_id == 0) or\n'
    assert old in code
    gateway.write_text(code.replace(old,''))
    subprocess.run(['python3',str(S/'server/scripts/lessons/prepare_frame_sync.py')],check=True,cwd=S/'server')
    luac=R/'server/third_party/skynet/3rd/lua/luac'
    for path in F:
        if path.endswith('.lua'): subprocess.run([str(luac),'-p',str(S/path)],check=True)
    print('STAGE_OK',len(F))

R = Path('/home/simbi/workspace/skynet-battle-navigation-commercial-learning')
S = Path('/tmp/flywow_frame_course_verify')
D = runpy.run_path(str(R/'codex/work/lesson_03_frame_sync/author_draft.py'))
F = {}
META = {}

def add(path, lang, why, focus, code):
    F[path] = code.strip()+'\n'
    META[path] = (lang,why,focus)

head = D['FILES'][0]['code']
cpp = D['FILES'][1]['code']
head = head.replace('const State& state() const noexcept { return state_; }', '''const State& state() const noexcept { return state_; }
    std::uint32_t mapId() const noexcept { return map_->metadata().map_id; }
    std::uint32_t mapVersion() const noexcept { return map_->metadata().map_version; }''')
head = head.replace('State state_;','State state_;\n    void stepUnchecked(Input input);')
head += '''\nextern "C" LESSON_FRAME_API std::uint32_t fs_map_id(void* handle);
extern "C" LESSON_FRAME_API const char* fs_rules_hash();
'''
cpp = cpp.replace('#include <algorithm>','#include <algorithm>\n#include <cstdlib>')
cpp = cpp.replace('void Engine::step(Input input)', '''void Engine::step(Input input)
{
    // API原子提交：任何异常恢复旧逻辑状态；临时内存失败不留下半帧。
    State before = state_;
    try { stepUnchecked(input); }
    catch (...) { state_ = std::move(before); throw; }
}
void Engine::stepUnchecked(Input input)''')
cpp = cpp.replace('if (unit.id==0 || (unit.camp!=1', 'if (unit.ready[0]>candidate.frame+24 || unit.ready[1]>candidate.frame+24 ||\n            unit.id==0 || (unit.camp!=1')
cpp = cpp.replace('if (bolt.id==0 || bolt.id>=candidate.next_bolt ||', '''const auto exists = [&](std::uint32_t id)
        {
            return std::any_of(candidate.units.begin(),candidate.units.end(),
                [&](const Unit& unit){ return unit.id==id; });
        };
        if (!exists(bolt.caster) || !exists(bolt.target) || bolt.expires<=candidate.frame ||
            bolt.expires>candidate.frame+60 || bolt.id==0 || bolt.id>=candidate.next_bolt ||''')
cpp = cpp[:cpp.index('extern "C" std::uint32_t fs_map_version')]+'''
extern "C" std::uint32_t fs_map_version(void* handle)
{
    return handle ? static_cast<lesson_frame::Engine*>(handle)->mapVersion() : 0;
}
extern "C" std::uint32_t fs_map_id(void* handle)
{
    return handle ? static_cast<lesson_frame::Engine*>(handle)->mapId() : 0;
}
extern "C" const char* fs_rules_hash() { return LESSON_FRAME_RULES_HASH; }
'''
add('server/native/frame_sync/frame_core.h','cpp','把本场逻辑状态、单步输入和可恢复ABI固定下来。','State全部字段、step/save/restore以及handle的open/close配对。',head)
add('server/native/frame_sync/frame_core.cpp','cpp','让按键意图按固定阶段产生位置、技能和伤害；两端编译同一份实现。','move的子步与取整、冷却/弹丸所有权、同帧统一伤害、候选restore和异常原子提交。',cpp)

add('server/native/frame_sync/frame_binding.cpp','cpp','让一个Skynet Worker Lua State拥有Native模拟，关闭时明确释放。','借用userdata仅存活于回调；错误以nil/error返回；close与GC各自负责什么。',r'''
// 职责：帧同步宿主Lua Binding；不持有Socket、Service handle或全局模拟对象。
// 每个userdata独占Engine；close幂等，GC兜底。调用同步不yield。
#include "frame_core.h"
#include "lua_binding.h"
#include "lua_table.h"
#include <memory>
using flywow_lua_binding::LuaBinding;
using flywow_lua_binding::LuaTable;
namespace
{
constexpr const char* kType="lesson.frame.engine";
struct Owner
{
    void* handle=nullptr;
    ~Owner() noexcept { fs_close(handle); }
};
// 封装层固定栈/引用合同：参数读取不弹栈，returnValues压结果；临时LuaTable的
// registry引用在回调退出时unref，Lua栈中的返回值继续持有对象。无longjmp错误API。
int openEngine(lua_State* state)
{
    LuaBinding lua(state);
    std::string path;
    if (!lua.readValue(1,path)) return lua.pushError();
    Owner* owner=nullptr;
    if (!lua.newUserdata(kType,owner)) return lua.pushError();
    owner->handle=fs_open(path.c_str());
    if (!owner->handle) return lua.pushError("MAP_LOAD","cannot open battle map");
    return lua.returnValues(owner);
}
int stepEngine(lua_State* state)
{
    LuaBinding lua(state);
    Owner* owner=nullptr;
    int x=0,z=0,skill=0;
    if (!lua.readUserdata(1,kType,owner) || !lua.readValue(2,x) ||
        !lua.readValue(3,z) || !lua.readValue(4,skill)) return lua.pushError();
    if (!fs_step(owner->handle,x,z,skill)) return lua.pushError("STEP_FAILED","invalid input or finished state");
    return lua.returnValues(true);
}
int saveEngine(lua_State* state)
{
    LuaBinding lua(state);
    Owner* owner=nullptr;
    if (!lua.readUserdata(1,kType,owner)) return lua.pushError();
    unsigned char buffer[16384];
    const int count=fs_save(owner->handle,buffer,sizeof(buffer));
    if (count==0) return lua.pushError("STATE_SAVE","closed engine or state overflow");
    return lua.returnValues(std::string(reinterpret_cast<char*>(buffer),count));
}
int restoreEngine(lua_State* state)
{
    LuaBinding lua(state);
    Owner* owner=nullptr;
    std::string bytes;
    if (!lua.readUserdata(1,kType,owner) || !lua.readValue(2,bytes)) return lua.pushError();
    if (!fs_restore(owner->handle,reinterpret_cast<const unsigned char*>(bytes.data()),static_cast<int>(bytes.size())))
        return lua.pushError("STATE_RESTORE","invalid or incompatible checkpoint");
    return lua.returnValues(true);
}
int closeEngine(lua_State* state)
{
    LuaBinding lua(state);
    Owner* owner=nullptr;
    if (!lua.readUserdata(1,kType,owner)) return lua.pushError();
    fs_close(owner->handle);
    owner->handle=nullptr; // GC只析构Owner一次，不再释放旧指针。
    return lua.returnValues(true);
}
int identity(lua_State* state)
{
    LuaBinding lua(state);
    Owner* owner=nullptr;
    if (!lua.readUserdata(1,kType,owner)) return lua.pushError();
    if (!owner->handle) return lua.pushError("CLOSED","engine is closed");
    return lua.returnValues(fs_map_id(owner->handle),fs_map_version(owner->handle));
}
int rulesHash(lua_State* state)
{
    LuaBinding lua(state);
    return lua.returnValues(fs_rules_hash());
}
}
extern "C" int luaopen_lesson_frame_native(lua_State* state)
{
    LuaBinding lua(state);
    LuaTable meta;
    if (!lua.registerUserdata<Owner>(kType,meta)) return lua.pushError();
    auto methods=lua.newTable();
    methods.setFunction("step",stepEngine); methods.setFunction("save",saveEngine);
    methods.setFunction("restore",restoreEngine); methods.setFunction("close",closeEngine);
    methods.setFunction("identity",identity); meta.writeValue("__index",methods);
    auto module=lua.newTable();
    module.setFunction("open",openEngine); module.setFunction("rules_hash",rulesHash);
    return lua.returnValues(module);
}
''')

add('server/native/frame_sync/frame_test.cpp','cpp','在接网络之前锁住重复运行、回滚恢复、损坏状态和异常不提交的合同。','比较规范化bytes，而不是结构体padding；Golden输出可跨Windows/Linux逐行比较。',r'''
// 职责：帧同步Native聚焦回归与跨平台Golden；不启动Server。
#include "frame_core.h"
#include "bmap_reader.h"
#include <cassert>
#include <iomanip>
#include <iostream>
#include <chrono>
std::uint32_t hashBytes(const std::string& bytes)
{
    std::uint32_t hash=2166136261u;
    for (unsigned char byte : bytes) hash=(hash^byte)*16777619u;
    return hash; // 模拟分歧诊断用FNV32，不是密码或资产完整性hash。
}
int main(int argc,char** argv)
{
    if (argc!=2) return 2;
    const auto map=flywow_navigation::BMapReader::Read(argv[1]);
    if (!map.ok()) return 3;
    lesson_frame::Engine a(map.value),b(map.value);
    const auto initial=a.save();
    for (int i=0;i<240 && a.state().winner==0;++i)
    {
        const lesson_frame::Input input{(i/30)%3-1,(i/45)%3-1,i%20==0?2:i%12==0?1:0};
        const auto before=a.save();
        a.step(input); b.step(input);
        assert(a.save()==b.save());
        b.restore(before); b.step(input);
        assert(a.save()==b.save());
        std::cout << "GOLDEN " << a.state().frame << " " << hashBytes(a.save()) << "\n";
    }
    const auto saved=a.save();
    try { a.restore(saved+"x"); assert(false); } catch (...) {}
    assert(a.save()==saved);
    try { a.step({9,0,0}); assert(false); } catch (...) {}
    assert(a.save()==saved);
    a.restore(initial);
    assert(a.save()==initial);
    std::cout << "FRAME_NATIVE_OK map=" << a.mapId() << ":" << a.mapVersion() << "\n";
}
''')

add('server/native/frame_sync/CMakeLists.txt','cmake','把同一核心编译为Linux Lua模块与Windows Unity DLL，不下载或复制FlyWow源码。','C++17、固定Lua ABI、真实子模块源码路径、rules_hash由源码内容生成。',r'''
# 职责：构建宿主Frame Core、Lua Binding和Unity Native DLL；源码来自固定子模块。
# 输入：固定FlyWow/Skynet源码；输出：frame_core DLL/so、lesson_frame_native.so和Golden。
cmake_minimum_required(VERSION 3.16)
project(lesson_frame LANGUAGES CXX)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(FLYWOW "${CMAKE_CURRENT_SOURCE_DIR}/../../third_party/skynet-flywow")
set(GRID "${FLYWOW}/navigation/native/grid_map")
file(SHA256 "${CMAKE_CURRENT_SOURCE_DIR}/frame_core.cpp" CORE_HASH)
file(SHA256 "${CMAKE_CURRENT_SOURCE_DIR}/frame_core.h" HEADER_HASH)
string(SHA256 RULES_HASH "${CORE_HASH}${HEADER_HASH}")
add_library(frame_core SHARED frame_core.cpp "${GRID}/bmap_reader.cpp" "${GRID}/grid_map.cpp" "${GRID}/nav_result.cpp")
target_include_directories(frame_core PUBLIC . "${GRID}")
target_compile_definitions(frame_core PRIVATE LESSON_FRAME_RULES_HASH="${RULES_HASH}")
if(MSVC)
    target_compile_options(frame_core PRIVATE /W4 /permissive- /EHsc /utf-8)
    set_target_properties(frame_core PROPERTIES WINDOWS_EXPORT_ALL_SYMBOLS ON)
else()
    target_compile_options(frame_core PRIVATE -Wall -Wextra -Wpedantic)
endif()
add_executable(frame_test frame_test.cpp)
target_link_libraries(frame_test PRIVATE frame_core)
if(MSVC)
    target_compile_options(frame_test PRIVATE /UNDEBUG /utf-8)
else()
    target_compile_options(frame_test PRIVATE -UNDEBUG)
endif()
option(LESSON_FRAME_LUA "构建固定Skynet Lua Binding" ON)
if(LESSON_FRAME_LUA)
    set(SKYNET_LUA_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../third_party/skynet/3rd/lua")
    add_subdirectory("${FLYWOW}/lua-binding" "${CMAKE_BINARY_DIR}/lua-binding" EXCLUDE_FROM_ALL)
    add_library(lesson_frame_native MODULE frame_binding.cpp)
    target_include_directories(lesson_frame_native PRIVATE "${SKYNET_LUA_DIR}" "${FLYWOW}/lua-binding")
    target_link_libraries(lesson_frame_native PRIVATE frame_core flywow_lua_binding)
    set_target_properties(lesson_frame_native PROPERTIES PREFIX "" BUILD_RPATH "$ORIGIN")
endif()
enable_testing()
add_test(NAME frame_native COMMAND frame_test "${CMAKE_CURRENT_SOURCE_DIR}/../../../shared/navigation/battle_1001/battle_1001.bmap")
''')

add('shared/protocol/frame_sync_messages.proto.inc','proto','在唯一协议源内增加帧同步消息；本节inc只表示待追加正文，不是第二份运行协议文件。','只有FramePushResponse的命令用于主动推送；FrameInputRequest是单向请求；checkpoint不是每帧状态广播。',r'''
// 职责：以下message追加到navigation_query.proto；CommandId另按正文局部修改。
message FrameCommand {
  uint32 frame = 1;       // 请求生效帧；必须位于Server当前帧之后的窗口内。
  sint32 x = 2;          // -1/0/1，X方向按键。
  sint32 z = 3;          // -1/0/1，Z方向按键。
  uint32 skill = 4;      // 0无施法，1近战，2逻辑火球。
}
message FrameRecord {
  FrameCommand input = 1; // 该帧被权威采用的玩家输入；AI在确定性Core内派生。
  bool supplied = 2;      // true采用玩家输入；false采用明确的缺输入规则。
  fixed32 hash = 3;       // 本帧结束的规范化状态FNV32；用于诊断分歧。
}
message FrameJoinRequest { uint32 scenario_id = 1; }
message FrameJoinResponse {
  string code = 1;          // OK/BUSY/BAD_SCENARIO/INTERNAL等稳定机器码。
  uint32 battle_id = 2;
  bytes resume_token = 3;   // 32bytes操作系统随机凭据；不能写日志。
  uint32 generation = 4;    // 重连会话代数；阻止旧连接输入写新会话。
  uint32 map_id = 5;
  uint32 map_version = 6;
  string map_hash = 7;      // 已发布BMAP SHA256。
  string rules_hash = 8;    // Native规则源码身份；跨端必须相同。
  uint32 frame = 9;
  bytes checkpoint = 10;   // 初始完整状态；正常帧只传FrameRecord。
}
message FrameInputRequest {
  uint32 battle_id = 1;
  uint32 generation = 2;
  repeated FrameCommand inputs = 3; // 最多8条；一帧只允许一个不可变输入。
}
message FramePushResponse {
  uint32 battle_id = 1;
  uint32 generation = 2;
  repeated FrameRecord records = 3; // 按帧严格连续；一正常推送当前帧。
  string code = 4;                 // OK/LATE/INPUT_WINDOW/CONFLICT/OVERLOAD/INTERNAL。
  uint32 winner = 5;               // 0进行中，1/2阵营胜利，3平局。
}
message FrameRecoverRequest { uint32 battle_id = 1; bytes resume_token = 2; }
message FrameRecoverResponse { FrameJoinResponse state = 1; }
message FrameLeaveRequest { uint32 battle_id = 1; uint32 generation = 2; }
message FrameLeaveResponse { string code = 1; }
message FrameReplayRequest { uint32 battle_id = 1; bytes resume_token = 2; uint32 offset = 3; }
message FrameReplayResponse {
  string code = 1;
  repeated FrameRecord records = 2; // 分页最多256帧；不把整场日志塞进单个帧。
  uint32 total = 3;
  FrameJoinResponse initial = 4;   // 第一页带身份/初始状态，不带恢复凭据。
}
message FrameReplay {
  uint32 format_version = 1;       // 目前1；加载时拒绝未知版本。
  FrameJoinResponse initial = 2;
  repeated FrameRecord records = 3;
}
''')

add('server/config/frame_sync.lua','lua','为本版Worker给出实际持有状态的上限和固定时间合同，不覆盖第二课config.battle。','tick与deadline、每Worker容量、输入窗口、重连保留、日志上限。',r'''
--- 职责：帧同步版运行预算；Server进程启动时固定，配置变更需重启。
--- 输入输出：无输入->纯配置；不创建Service、不读取Unity工程。
return
{
    map_path         = "../shared/navigation/battle_1001/battle_1001.bmap",
    manifest_path    = "../shared/navigation/battle_1001/battle_1001.manifest.json",
    workers          = 4,     -- Service数；不表示线程绑定。
    max_battles      = 128,   -- 每Worker同时持有的Battle；结束结果也占预算。
    tick_cs          = 5,     -- 5×10ms=50ms；Native kTickMs必须同值。
    future_window    = 8,     -- 当前帧后最多8帧输入；超窗明确拒绝。
    max_catchup      = 4,     -- 一次心跳最多补4帧；仍落后则OVERLOAD，不跳帧。
    retention_cs     = 3000,  -- 结束/断线Battle保留30秒。
    max_frames       = 3600,  -- 180秒；对应Native时限和有界Replay日志。
    input_batch      = 8,
    replay_page      = 256,
    gateway_node     = "frame_gateway",
    gateway_address  = "127.0.0.1:2537",
    battle_node      = "frame_battle",
    battle_address   = "127.0.0.1:2538",
    gateway_port     = 19021,
}
''')

add('server/lualib/battle/frame_sync/runtime.lua','lua','把输入窗口、缺输入规则和Replay归到一个Battle实例；先用纯Lua驱动验证。','Native owner、不可变帧输入、明确拒绝、帧状态hash、历史最大长度；不require Skynet。',r'''
--- 职责：一个帧同步Battle的no-yield运行时；输入->权威FrameRecord/Checkpoint。
--- Native Engine归本Runtime独占；调用方负责close；无Socket/墙钟/Skynet依赖。
local native = require "lesson_frame_native"
local M = {}

---@class FrameRuntime
---@field engine userdata 独占Native模拟；close后不再调用。
---@field frame integer 已完成权威帧。
---@field winner integer 0未结束、1/2胜方、3平局。
---@field pending table<integer,table> 尚未执行的输入，最多future_window条。
---@field records table 有界整场帧输入日志；不保留每帧完整状态。

--- 对规范化状态做32位FNV；不作安全校验，SHA256用于资产/规则身份。
---@param bytes string 本次调用借用的Native状态。
---@return integer hash unsigned32。
function M.hash(bytes)
    local value = 2166136261
    for i = 1, #bytes do value = ((value ~ bytes:byte(i)) * 16777619) & 0xffffffff end
    return value
end

--- 读取固定小端状态头；不会把Lua字符串转成可写指针。
local function header(bytes)
    local version, frame, winner = string.unpack("<I4I4I4", bytes)
    assert(version == 1, "STATE_VERSION")
    return frame, winner
end

--- 建立独占Native模拟；启动资产I/O，失败以nil/error交给Worker。
---@param options table map_path/future_window/max_frames由配置注入。
---@return FrameRuntime|nil runtime, table|nil error
function M.create(options)
    local engine, err = native.open(options.map_path)
    if not engine then return nil, err end
    local initial, save_err = engine:save()
    if not initial then engine:close(); return nil, save_err end
    return
    {
        engine        = engine,
        initial       = initial,
        frame         = 0,
        winner        = 0,
        pending       = {},
        records       = {},
        window        = options.future_window,
        max_frames    = options.max_frames,
        last_x        = 0,
        last_z        = 0,
        missing       = 0,
    }
end

--- 接受未来帧意图；重复相同输入幂等，不允许改写已接受输入。
--- 不yield、不修改正式位置；成功OK，失败稳定code。
---@param runtime FrameRuntime 当前Battle owner。
---@param input table frame/x/z/skill；函数复制字段，不保存借用table。
---@return string code
function M.accept(runtime, input)
    local f = input.frame or 0
    local x, z, skill = input.x or 0, input.z or 0, input.skill or 0
    if math.type(f) ~= "integer" or math.type(x) ~= "integer" or
        math.type(z) ~= "integer" or math.type(skill) ~= "integer" or
        x < -1 or x > 1 or z < -1 or z > 1 or skill < 0 or skill > 2 then
        return "BAD_INPUT"
    end
    if runtime.winner ~= 0 then return "FINISHED" end
    if f <= runtime.frame then return "LATE" end
    if f > runtime.frame + runtime.window then return "INPUT_WINDOW" end
    local previous = runtime.pending[f]
    if previous then
        return previous.x == x and previous.z == z and previous.skill == skill and "OK" or "CONFLICT"
    end

    runtime.pending[f] = { frame = f, x = x, z = z, skill = skill }
    return "OK"
end

--- 推进下一帧；缺输入最多保持方向两帧，技能永不沿用。
--- Native失败不返回半步结果；Worker结束该Battle并显式close。
---@param runtime FrameRuntime 当前Battle owner。
---@return table|nil record, table|nil error
function M.step(runtime)
    if runtime.winner ~= 0 then return nil, { code = "FINISHED" } end
    local frame = runtime.frame + 1
    local input = runtime.pending[frame]
    local supplied = input ~= nil
    if supplied then
        runtime.last_x, runtime.last_z = input.x, input.z
        runtime.missing = 0
    else
        runtime.missing = runtime.missing + 1
        local hold = runtime.missing <= 2
        input = { frame = frame, x = hold and runtime.last_x or 0,
                  z = hold and runtime.last_z or 0, skill = 0 }
    end
    local ok, err = runtime.engine:step(input.x, input.z, input.skill)
    if not ok then return nil, err end

    local state, save_err = runtime.engine:save()
    if not state then return nil, save_err end
    runtime.frame, runtime.winner = header(state)
    runtime.pending[frame] = nil
    local record = { input = input, supplied = supplied, hash = M.hash(state) }
    assert(#runtime.records < runtime.max_frames, "FRAME_LOG_LIMIT")
    runtime.records[#runtime.records + 1] = record
    return record
end

--- close幂等释放Native；Worker摘除索引后调用，GC不作为主释放路径。
---@param runtime FrameRuntime owner。
function M.close(runtime)
    if runtime.engine then runtime.engine:close(); runtime.engine = nil end
end
return M
''')

add('server/service/battle/frame_sync/worker.lua','lua','把纯Runtime放入长驻Worker；一个心跳按稳定Battle ID推进多场战斗。','no-yield更新、deadline/catchup、会话generation、结束保留、Core异常关闭与恢复。',r'''
--- 职责：拥有有界Battle实例并调度fixed Tick；不持有fd/codec，不让Core yield。
--- 输入：Dispatch注入handle与配置、业务命令；输出：控制响应和frame_push消息。
local skynet = require "skynet"
local core = require "battle.frame_sync.runtime"
local native = require "lesson_frame_native"
local config = require "config.frame_sync"
local meta = require "config.frame_sync_asset" -- 本课构建工具验证并生成。
local battles, order = {}, {}
local dispatcher = nil -- composition root注入，唯一结果接收者。

---@class FrameSession
---@field gateway_epoch string Gateway实例身份；回推时原样携带。
---@field connection_id integer 已握手连接；不是玩家永久身份。
---@class FrameWorkerRequest
---@field battle_id integer Dispatcher分配且不复用的Battle ID。
---@field session FrameSession 当前请求的传输身份。
---@field request table Proto已解码body；不含fd。

--- 使用操作系统熵生成32bytes凭据；I/O失败不退化为math.random。
local function token()
    local file = assert(io.open("/dev/urandom", "rb"))
    local value = file:read(32)
    file:close()
    assert(value and #value == 32, "TOKEN_IO")
    return value
end
--- 对恢复凭据做固定长度比较，避免提前退出的位置泄露。
local function token_equal(a, b)
    if type(a) ~= "string" or type(b) ~= "string" or #a ~= 32 or #b ~= 32 then return false end
    local diff = 0
    for i = 1, 32 do diff = diff | (a:byte(i) ~ b:byte(i)) end
    return diff == 0
end
--- 生成控制状态；仅加入/恢复会读取完整Native状态。
local function snapshot(battle, initial)
    local map_id, map_version = battle.core.engine:identity()
    return
    {
        code         = "OK",
        battle_id    = battle.id,
        resume_token = initial and "" or battle.token,
        generation   = battle.generation,
        map_id       = map_id,
        map_version  = map_version,
        map_hash     = meta.map_hash,
        rules_hash   = native.rules_hash(),
        frame        = initial and 0 or battle.core.frame,
        checkpoint   = initial and battle.core.initial or assert(battle.core.engine:save()),
    }
end
--- 推送目标连接；request_id=0表示无请求关联；不等待客户端收到。
local function push(battle, records, code)
    skynet.send(dispatcher, "lua", "frame_push",
    {
        session = battle.session,
        data    = { battle_id = battle.id, generation = battle.generation,
                    records = records, code = code, winner = battle.core.winner },
    })
end
--- 检查当前连接和会话代数；旧连接迟到输入不可进入新会话。
local function owns(battle, args)
    return battle and battle.generation == args.request.generation and
        battle.session.gateway_epoch == args.session.gateway_epoch and
        battle.session.connection_id == args.session.connection_id
end
--- 建立Runtime与索引；无yield，失败返回稳定错误，由上层记录诊断。
local function create(args)
    if #order >= config.max_battles then return { code = "BUSY" } end
    local credential = token() -- 先完成可能失败的I/O，避免创建Engine后泄漏。
    local runtime, err = core.create(config)
    if not runtime then return { code = err.code } end
    local map_id, map_version = runtime.engine:identity()
    if map_id ~= meta.map_id or map_version ~= meta.map_version then
        core.close(runtime); return { code = "ASSET_IDENTITY" }
    end
    local battle = { id = args.battle_id, core = runtime, token = credential, generation = 1,
                     session = args.session, due = skynet.now() + 10, disconnected = nil }
    battles[battle.id] = battle
    order[#order + 1] = battle.id
    table.sort(order)
    return snapshot(battle, false)
end
--- 恢复凭据归Battle所有；重连原子更换session并清掉旧代数未来输入。
local function recover(args)
    local battle = battles[args.battle_id]
    if not battle or not token_equal(battle.token, args.request.resume_token) then return { code = "NOT_FOUND" } end
    battle.generation = battle.generation + 1
    battle.session = args.session
    battle.disconnected = nil
    battle.core.pending = {}
    battle.core.last_x, battle.core.last_z = 0, 0
    return snapshot(battle, false)
end
--- 输入只入有界未来窗口；拒绝通过FramePush明确通知，不把send当接受。
local function inputs(args)
    local battle = battles[args.battle_id]
    if not owns(battle, args) then return end
    local batch = args.request.inputs or {}
    if #batch > config.input_batch then push(battle, {}, "INPUT_BATCH"); return end
    for _, input in ipairs(batch) do
        local code = core.accept(battle.core, input)
        if code ~= "OK" then push(battle, {}, code) end
    end
end
--- 一页Replay最多256帧；只有有效凭据才能读取，离线initial不包含凭据。
local function replay(args)
    local battle = battles[args.battle_id]
    if not battle or not token_equal(battle.token, args.request.resume_token) then return { code = "NOT_FOUND" } end
    local offset = args.request.offset or 0
    if offset > #battle.core.records then return { code = "REPLAY_OFFSET" } end
    local records = {}
    for i = offset + 1, math.min(#battle.core.records, offset + config.replay_page) do
        records[#records + 1] = battle.core.records[i]
    end
    return { code = "OK", records = records, total = #battle.core.records,
             initial = offset == 0 and snapshot(battle, true) or nil }
end
--- 标记客户端离开；释放逻辑发生在唯一心跳，避免边遍历边删order。
local function leave(args)
    local battle = battles[args.battle_id]
    if not owns(battle, args) then return { code = "NOT_FOUND" } end
    battle.remove = true
    return { code = "OK" }
end
--- Core异常只终止这一场；下一场继续，Runtime资源在删除时close。
local function advance(battle, now)
    if battle.core.winner ~= 0 or battle.failed then return end
    local count = 0
    while now >= battle.due and count < config.max_catchup do
        local ok, record, err = pcall(core.step, battle.core)
        if not ok or not record then
            battle.failed = true
            push(battle, {}, "INTERNAL")
            skynet.error("FRAME_CORE_FAILED id=", battle.id, " ", tostring(ok and err and err.code or record))
            break
        end
        battle.due = battle.due + config.tick_cs
        count = count + 1
        push(battle, { record }, "OK")
        if battle.core.winner ~= 0 then battle.finished = now; break end
    end
    if not battle.finished and not battle.failed and now >= battle.due then
        battle.failed = true
        push(battle, {}, "OVERLOAD") -- 绝不跳帧伪装实时跟上。
    end
    if battle.failed then battle.finished = now end
end
--- 一个Worker一个Timer；timeout回调无yield，order稳定；容量配置约束执行时间。
local function heartbeat()
    local now, surviving = skynet.now(), {}
    for _, id in ipairs(order) do
        local battle = battles[id]
        advance(battle, now)
        local expiry = battle.finished or battle.disconnected
        if battle.remove or (expiry and now - expiry >= config.retention_cs) then
            core.close(battle.core); battles[id] = nil
        else surviving[#surviving + 1] = id end
    end
    order = surviving
    skynet.timeout(config.tick_cs, heartbeat)
end
--- 断线通知由Dispatch转发；只摘除匹配传输会话，不改新会话。
local function disconnect(session)
    for _, id in ipairs(order) do
        local battle = battles[id]
        if battle.session.gateway_epoch == session.gateway_epoch and
            battle.session.connection_id == session.connection_id then
            battle.disconnected = skynet.now()
            battle.core.pending = {}
            battle.core.last_x, battle.core.last_z = 0, 0
        end
    end
end
skynet.start(function()
    skynet.dispatch("lua", function(session, source, command, args)
        if command == "configure" then
            assert(dispatcher == nil)
            dispatcher = assert(args.dispatcher)
            skynet.timeout(config.tick_cs, heartbeat)
            skynet.retpack(true)
            return
        end
        assert(source == dispatcher, "untrusted Worker sender")
        if command == "inputs" then inputs(args)
        elseif command == "disconnect" then disconnect(args)
        elseif command == "create" then skynet.retpack(create(args))
        elseif command == "recover" then skynet.retpack(recover(args))
        elseif command == "replay" then skynet.retpack(replay(args))
        elseif command == "leave" then skynet.retpack(leave(args))
        else error("unknown Frame Worker command: " .. tostring(command)) end
    end)
end)
''')

add('server/service/battle/frame_sync/dispatch.lua','lua','由Battle进程选择Worker并回推控制响应/权威帧；Gateway不拥有玩家归属。','稳定分片、显式Worker handles、send_data纯record边界、call yield后的回复身份。',r'''
--- 职责：帧同步Battle入口；拥有ID分配和Worker分片；不解析网络frame/Proto bytes。
--- 控制call可能yield；输入和frame_push用send，不等待客户端读包。
local skynet = require "skynet"
local cluster = require "skynet.cluster"
local config = require "config.frame_sync"
local ids = require("gateway.protocol.navigation_registry").command_ids
local workers, next_id = {}, 0

--- ID到Worker稳定映射；workers在进程存活期间固定，不允许在线重排。
local function worker(id)
    if math.type(id) ~= "integer" or id < 1 or id > 0x7fffffff then return nil end
    return workers[(id - 1) % #workers + 1]
end
--- 发回原传输会话；Gateway按epoch/id检查当前有效性，不保存fd。
---@param route table gateway_epoch/connection_id/command_id/request_id，由入站或Worker产生。
---@param response table 已验证响应body。
local function reply(route, response)
    local ok, err = pcall(cluster.send, config.gateway_node, "@frame_proxy", "send_data",
    {
        gateway_epoch = route.gateway_epoch,
        connection_id = route.connection_id,
        command_id    = route.command_id,
        request_id    = route.request_id,
        data          = response,
    })
    if not ok then skynet.error("FRAME_REPLY_FAILED ", tostring(err)) end
end
--- Join仅接受scenario_id；正式状态完全由Server构造。
local function control(route)
    local request = route.data
    local args = { battle_id = request.battle_id, request = request,
                   session = { gateway_epoch = route.gateway_epoch, connection_id = route.connection_id } }
    if route.command_id == ids.FRAME_JOIN then
        if request.scenario_id ~= 1001 then return { code = "BAD_SCENARIO" } end
        if next_id >= 0x7fffffff then return { code = "ID_EXHAUSTED" } end
        next_id = next_id + 1
        args.battle_id = next_id
        return skynet.call(worker(next_id), "lua", "create", args)
    end
    local target = worker(args.battle_id)
    if not target then return { code = "NOT_FOUND" } end
    if route.command_id == ids.FRAME_RECOVER then
        return { state = skynet.call(target, "lua", "recover", args) }
    elseif route.command_id == ids.FRAME_REPLAY then
        return skynet.call(target, "lua", "replay", args)
    elseif route.command_id == ids.FRAME_LEAVE then
        return skynet.call(target, "lua", "leave", args)
    end
    return { code = "BAD_COMMAND" }
end
--- 由Gateway Proxy转来的数据；控制yield只持有值record，不借用连接对象。
local function incoming(route)
    assert(type(route) == "table" and type(route.data) == "table")
    assert(type(route.gateway_epoch) == "string" and route.connection_id > 0 and route.request_id ~= 0)
    if route.command_id == ids.FRAME_INPUT then
        local target = worker(route.data.battle_id)
        if target then
            skynet.send(target, "lua", "inputs", { battle_id = route.data.battle_id,
                request = route.data, session = { gateway_epoch = route.gateway_epoch,
                                                 connection_id = route.connection_id } })
        end
        return
    end
    local ok, result = pcall(control, route)
    if not ok then
        skynet.error("FRAME_CONTROL_FAILED ", tostring(result))
        result = route.command_id == ids.FRAME_RECOVER and { state = { code = "INTERNAL" } } or { code = "INTERNAL" }
    end
    reply(route, result)
end
skynet.start(function()
    for i = 1, config.workers do
        workers[i] = skynet.newservice("battle/frame_sync/worker")
        assert(skynet.call(workers[i], "lua", "configure", { dispatcher = skynet.self() }))
    end
    skynet.dispatch("lua", function(_, source, command, payload)
        if command == "ready" then skynet.retpack(true)
        elseif command == "send_data" then incoming(payload)
        elseif command == "disconnect" then
            for _, handle in ipairs(workers) do skynet.send(handle, "lua", "disconnect", payload) end
        elseif command == "frame_push" then
            local trusted = false
            for _, handle in ipairs(workers) do trusted = trusted or source == handle end
            assert(trusted, "untrusted frame source")
            reply({ gateway_epoch = payload.session.gateway_epoch,
                    connection_id = payload.session.connection_id,
                    command_id = ids.FRAME_PUSH, request_id = 0 }, payload.data)
        else error("unknown Frame Dispatch command: " .. tostring(command)) end
    end)
end)
''')

add('server/service/battle/frame_sync/main.lua','lua','组装独立Battle进程入口，保持第二课入口可用。','cluster.register只对固定跨进程边界使用；子Service handles显式持有。',r'''
--- 职责：Frame Battle进程组合根；启动Dispatch并开放Cluster，失败终止启动。
local skynet = require "skynet"
local cluster = require "skynet.cluster"
local config = require "config.frame_sync"
skynet.start(function()
    local dispatch = skynet.newservice("battle/frame_sync/dispatch")
    assert(skynet.call(dispatch, "lua", "ready"))
    cluster.reload({ [config.gateway_node] = config.gateway_address,
                     [config.battle_node] = config.battle_address })
    cluster.open(config.battle_node, 64)
    cluster.register("frame_dispatch", dispatch)
    skynet.error("FRAME_BATTLE_READY address=", config.battle_address)
    skynet.exit()
end)
''')

add('server/service/gateway/frame_sync/proxy.lua','lua','接入第二课已建立的双向异步边界，只转发传输record。','Proxy持有Gateway handle，不持有Battle表；断线要送达Battle而非被吞掉。',r'''
--- 职责：帧同步Gateway/Battle异步转发；不解释FrameInput或模拟状态。
--- 输入输出：send_data record原样跨Cluster；disconnect携带实例与连接身份。
local skynet = require "skynet.manager"
local cluster = require "skynet.cluster"
local config = require "config.frame_sync"
local gateway = nil -- 组合根注入的本地Gateway handle。

---@class FrameGatewayData
---@field gateway_epoch string Gateway实例身份。
---@field connection_id integer 目标连接；0仅主动广播，帧同步使用具体连接。
---@field command_id integer 从唯一Proto生成的command。
---@field request_id integer 非0请求/响应，0主动消息。
---@field data table 已解码body；本Proxy不修改。

--- 尽力异步转发；Cluster失败由客户端控制超时/恢复收敛，不建立无限重试。
local function forward(command, payload)
    local ok, err = pcall(cluster.send, config.battle_node, "@frame_dispatch", command, payload)
    if not ok then skynet.error("FRAME_PROXY_SEND_FAILED ", tostring(err)) end
end
skynet.start(function()
    skynet.dispatch("lua", function(_, source, command, payload)
        if command == "start" then
            cluster.reload({ [config.battle_node] = config.battle_address,
                             [config.gateway_node] = config.gateway_address })
            cluster.open(config.gateway_node, 64)
            cluster.register("frame_proxy", skynet.self())
            assert(cluster.call(config.battle_node, "@frame_dispatch", "ready"))
            skynet.name(".frame_proxy", skynet.self())
            skynet.retpack(true)
        elseif command == "bind" then
            assert(gateway == nil)
            gateway = assert(payload.gateway)
            skynet.retpack(true)
        elseif command == "send_data" then
            assert(gateway and type(payload.data) == "table")
            if source == gateway then forward("send_data", payload)
            else skynet.send(gateway, "lua", "send_data", payload) end
        elseif command == "gateway_disconnect" then
            assert(source == gateway)
            forward("disconnect", payload)
        else error("unknown Frame Proxy command: " .. tostring(command)) end
    end)
end)
''')

add('server/service/gateway/frame_sync/main.lua','lua','先完成跨进程ready再监听客户端；复用现有FlyWow握手、framing与codec。','handler_service当前合同是注册名称；覆盖项直接可见；Gateway不依赖地图。',r'''
--- 职责：帧同步Gateway进程组合根；只创建Proxy/Gateway并注入依赖。
local skynet = require "skynet"
local config = require "config.frame_sync"
skynet.start(function()
    local proxy = skynet.newservice("gateway/frame_sync/proxy")
    assert(skynet.call(proxy, "lua", "start"))
    local gateway = skynet.newservice("flywow_gateway")
    assert(skynet.call(proxy, "lua", "bind", { gateway = gateway }))
    assert(skynet.call(gateway, "lua", "start",
    {
        handler_service = ".frame_proxy",
        host            = "127.0.0.1",
        port            = config.gateway_port,
        transport       = "tcp",
        protocol_version = 3, -- 新增命令为兼容扩展，已有字段/枚举不重用。
    }))
    skynet.error("FRAME_GATEWAY_READY port=", config.gateway_port)
    skynet.exit()
end)
''')

add('server/config/frame_battle_process.lua','lua','独立进程配置消费新增Native产物，不覆盖第二课启动配置。','所有相对路径以server为当前目录；共享库通过ORIGIN寻找frame_core.so。',r'''
--- 职责：Frame Battle进程启动路径；不保存Battle动态状态。
dofile("./config/battle_process.lua")
start = "battle/frame_sync/main"
logger = "./logs/frame_battle"
lua_cpath = "./build/frame_sync/?.so;" .. lua_cpath
''')
add('server/config/frame_gateway_process.lua','lua','Gateway启动时只消费接入模块和共享Proto生成物。','复用已验证路径，不让Gateway加载地图或Frame Native核心。',r'''
--- 职责：Frame Gateway进程启动配置；Gateway/Battle仍是独立OS进程。
dofile("./config/gateway_process.lua")
start = "gateway/frame_sync/main"
logger = "./logs/frame_gateway"
''')

add('server/scripts/lessons/prepare_frame_sync.py','python','在启动前验证已发布地图hash并生成资产身份配置；规则hash由Native构建绑定。','路径从脚本推导，manifest与BMAP内容一致性，源码运行时不读Unity工程。',r'''
# 职责：验证帧同步部署资产并生成静态身份配置；不启动Server，不操作Git。
# 调用：server工作目录 python3 scripts/lessons/prepare_frame_sync.py。
from pathlib import Path
import hashlib
import json
root = Path(__file__).resolve().parents[3]
asset = root / 'shared/navigation/battle_1001'
manifest = json.loads((asset/'battle_1001.manifest.json').read_text())
digest = hashlib.sha256((asset/'battle_1001.bmap').read_bytes()).hexdigest()
if digest != manifest['content_sha256']:
    raise SystemExit('MAP_HASH_MISMATCH')
target = root/'server/config/frame_sync_asset.lua'
target.write_text('--- 构建生成的已验证地图身份；不手改。\nreturn { map_id = %d, map_version = %d, map_hash = "%s" }\n' %
                  (manifest['map_id'],manifest['map_version'],digest), encoding='utf-8')
print('FRAME_ASSET_OK',digest)
''')

add('unity/BattleNavigation/Assets/BattleNavigation/client/FrameNative.cs','csharp','Unity只通过稳定C ABI推进与恢复本地模拟；不把Transform写回Server。','Native handle的唯一owner、DLL位宽、规范化状态字段顺序、资源释放。',r'''
// 职责：Unity帧同步Native调用及只读渲染状态解码；不负责Socket或Server权威。
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
namespace BattleNavigation.FrameSync
{
    public sealed class FrameNative : IDisposable
    {
        [DllImport("frame_core", CallingConvention=CallingConvention.Cdecl)] private static extern IntPtr fs_open([MarshalAs(UnmanagedType.LPUTF8Str)] string path);
        [DllImport("frame_core", CallingConvention=CallingConvention.Cdecl)] private static extern void fs_close(IntPtr handle);
        [DllImport("frame_core", CallingConvention=CallingConvention.Cdecl)] private static extern int fs_step(IntPtr handle,int x,int z,int skill);
        [DllImport("frame_core", CallingConvention=CallingConvention.Cdecl)] private static extern int fs_save(IntPtr handle,byte[] bytes,int capacity);
        [DllImport("frame_core", CallingConvention=CallingConvention.Cdecl)] private static extern int fs_restore(IntPtr handle,byte[] bytes,int count);
        [DllImport("frame_core", CallingConvention=CallingConvention.Cdecl)] private static extern uint fs_map_version(IntPtr handle);
        [DllImport("frame_core", CallingConvention=CallingConvention.Cdecl)] private static extern uint fs_map_id(IntPtr handle);
        [DllImport("frame_core", CallingConvention=CallingConvention.Cdecl)] private static extern IntPtr fs_rules_hash();
        private IntPtr handle; // 此实例独占；只在Unity主线程调用，Dispose后为0。
        public string RulesHash => Marshal.PtrToStringAnsi(fs_rules_hash());
        public uint MapId => fs_map_id(handle);
        public uint MapVersion => fs_map_version(handle);
        public FrameNative(string path)
        {
            handle=fs_open(path);
            if(handle==IntPtr.Zero) throw new InvalidDataException("MAP_LOAD");
        }
        public void Step(int x,int z,int skill)
        {
            if(fs_step(handle,x,z,skill)!=1) throw new InvalidOperationException("NATIVE_STEP");
        }
        public byte[] Save()
        {
            var buffer=new byte[16384];
            int size=fs_save(handle,buffer,buffer.Length);
            if(size<=0) throw new InvalidOperationException("NATIVE_SAVE");
            Array.Resize(ref buffer,size);
            return buffer;
        }
        public void Restore(byte[] bytes)
        {
            if(bytes==null || bytes.Length>16384 || fs_restore(handle,bytes,bytes.Length)!=1)
                throw new InvalidDataException("NATIVE_RESTORE");
        }
        public void Dispose()
        {
            var old=handle;
            handle=IntPtr.Zero;
            if(old!=IntPtr.Zero) fs_close(old);
            GC.SuppressFinalize(this);
        }
        ~FrameNative() { Dispose(); } // 异常构造/场景释放遗漏的兜底；主路径显式Dispose。
        public static uint Hash(byte[] bytes)
        {
            uint value=2166136261;
            foreach(byte b in bytes) value=unchecked((value^b)*16777619);
            return value;
        }
    }
    public sealed class FrameUnit
    {
        public uint Id,Camp,Ready1,Ready2;
        public long X,Y,Z; // 毫米；转成Unity float只发生在表现边界。
        public int Hp;
    }
    public sealed class FrameBolt
    {
        public uint Id;
        public long X,Y,Z;
    }
    public sealed class FrameState
    {
        public uint Frame,Winner;
        public readonly List<FrameUnit> Units=new List<FrameUnit>();
        public readonly List<FrameBolt> Bolts=new List<FrameBolt>();
        public static FrameState Decode(byte[] bytes)
        {
            if(bytes==null || bytes.Length>16384) throw new InvalidDataException("STATE_SIZE");
            using(var reader=new BinaryReader(new MemoryStream(bytes,false)))
            {
                if(reader.ReadUInt32()!=1) throw new InvalidDataException("STATE_VERSION");
                var state=new FrameState { Frame=reader.ReadUInt32(),Winner=reader.ReadUInt32() };
                reader.ReadUInt32(); // next_bolt属于逻辑状态，表现不使用。
                uint units=reader.ReadUInt32();
                if(units>64) throw new InvalidDataException("UNIT_LIMIT");
                for(uint i=0;i<units;i++) state.Units.Add(new FrameUnit
                {
                    Id=reader.ReadUInt32(),Camp=reader.ReadUInt32(),X=reader.ReadInt64(),
                    Y=reader.ReadInt64(),Z=reader.ReadInt64(),Hp=reader.ReadInt32(),
                    Ready1=reader.ReadUInt32(),Ready2=reader.ReadUInt32(),
                });
                uint bolts=reader.ReadUInt32();
                if(bolts>128) throw new InvalidDataException("BOLT_LIMIT");
                for(uint i=0;i<bolts;i++)
                {
                    uint id=reader.ReadUInt32();
                    reader.ReadUInt32(); reader.ReadUInt32(); reader.ReadUInt32();
                    state.Bolts.Add(new FrameBolt { Id=id,X=reader.ReadInt64(),Y=reader.ReadInt64(),Z=reader.ReadInt64() });
                }
                if(reader.BaseStream.Position!=reader.BaseStream.Length) throw new InvalidDataException("STATE_TRAILING");
                return state;
            }
        }
    }
}
''')

add('unity/BattleNavigation/Assets/BattleNavigation/client/FrameConnection.cs','csharp','让实时连接同时持续收推帧和发输入；沿用FlyWow握手与两字节framing。','读写线程独占职责、有界队列、控制请求超时、Dispose解除阻塞、禁止后台线程读Unity对象。',r'''
// 职责：单个实时TCP会话，复用FlyWow SDK握手与项目Envelope；不解释战斗模拟。
// 两后台线程只处理网络/Proto；Unity主线程从有界Push队列读取，调用方Dispose。
using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.IO;
using System.Net.Sockets;
using System.Threading;
using System.Threading.Tasks;
using Battle.Navigation.V1;
using Google.Protobuf;
using FlyWow.Gateway;
namespace BattleNavigation.FrameSync
{
    public sealed class FrameConnection : IDisposable
    {
        private sealed class Waiting
        {
            public uint Command;
            public TaskCompletionSource<Envelope> Result=new TaskCompletionSource<Envelope>(TaskCreationOptions.RunContinuationsAsynchronously);
        }
        private readonly TcpClient socket=new TcpClient();
        private NetworkStream stream;
        private readonly BlockingCollection<byte[]> outgoing=new BlockingCollection<byte[]>(128);
        private readonly BlockingCollection<FramePushResponse> pushes=new BlockingCollection<FramePushResponse>(256);
        private readonly Dictionary<ulong,Waiting> waiting=new Dictionary<ulong,Waiting>();
        private readonly object gate=new object();
        private Thread reader,writer;
        private long nextRequest;
        private int closed;
        private volatile string fault;
        public string Fault => fault;
        public int PushDepth => pushes.Count;

        public static async Task<FrameConnection> Connect(string host,int port)
        {
            var connection=new FrameConnection();
            try { await Task.Run(()=>connection.Open(host,port)); return connection; }
            catch { connection.Dispose(); throw; }
        }
        private void Open(string host,int port)
        {
            if(!socket.ConnectAsync(host,port).Wait(3000)) throw new TimeoutException("CONNECT_TIMEOUT");
            socket.NoDelay=true; // 小输入包不等待Nagle合并；TCP仍有队头阻塞。
            stream=socket.GetStream();
            stream.ReadTimeout=3000; stream.WriteTimeout=3000;
            using(var handshake=new HandshakeClient())
            {
                WriteFrame(handshake.Begin());
                WriteFrame(handshake.Respond(ReadFrame(99)));
                handshake.Complete(ReadFrame(33));
            }
            stream.ReadTimeout=10000;
            reader=new Thread(ReadLoop) { IsBackground=true,Name="FrameRead" };
            writer=new Thread(WriteLoop) { IsBackground=true,Name="FrameWrite" };
            reader.Start(); writer.Start();
        }
        private byte[] Exact(int count)
        {
            var result=new byte[count];
            int offset=0;
            while(offset<count)
            {
                int n=stream.Read(result,offset,count-offset);
                if(n==0) throw new EndOfStreamException("DISCONNECTED");
                offset+=n;
            }
            return result;
        }
        private byte[] ReadFrame(int expected=0)
        {
            var header=Exact(2);
            int size=(header[0]<<8)|header[1];
            if(size<1 || (expected!=0 && size!=expected)) throw new InvalidDataException("FRAME_LENGTH");
            return Exact(size);
        }
        private void WriteFrame(byte[] bytes)
        {
            if(bytes.Length<1 || bytes.Length>65535) throw new InvalidDataException("FRAME_SIZE");
            var frame=new byte[bytes.Length+2];
            frame[0]=(byte)(bytes.Length>>8); frame[1]=(byte)bytes.Length;
            Buffer.BlockCopy(bytes,0,frame,2,bytes.Length);
            stream.Write(frame,0,frame.Length);
        }
        private ulong Enqueue(uint command,IMessage body)
        {
            if(Volatile.Read(ref closed)!=0) throw new IOException(fault??"CLOSED");
            ulong id=checked((ulong)Interlocked.Increment(ref nextRequest));
            EnqueueEnvelope(command,body,id);
            return id;
        }
        private void EnqueueEnvelope(uint command,IMessage body,ulong id)
        {
            var bytes=new Envelope { ProtocolVersion=3,Command=command,RequestId=id,
                Body=ByteString.CopyFrom(body.ToByteArray()) }.ToByteArray();
            if(!outgoing.TryAdd(bytes)) { Fail("OUTGOING_LIMIT"); throw new IOException("OUTGOING_LIMIT"); }
        }
        public void SendInputs(FrameInputRequest body) { Enqueue((uint)CommandId.FrameInput,body); }
        public async Task<Envelope> Request(CommandId command,IMessage body)
        {
            var item=new Waiting { Command=(uint)command };
            ulong id=checked((ulong)Interlocked.Increment(ref nextRequest));
            lock(gate)
            {
                if(closed!=0) throw new IOException(fault??"CLOSED");
                if(waiting.Count>=8) throw new IOException("CONTROL_LIMIT");
                waiting.Add(id,item);
            }
            try
            {
                EnqueueEnvelope((uint)command,body,id);
                if(await Task.WhenAny(item.Result.Task,Task.Delay(3000))!=item.Result.Task)
                    throw new TimeoutException("CONTROL_TIMEOUT");
                return await item.Result.Task;
            }
            finally { lock(gate) waiting.Remove(id); }
        }
        public bool TryPush(out FramePushResponse push) { return pushes.TryTake(out push); }
        private void ReadLoop()
        {
            try
            {
                while(closed==0)
                {
                    var envelope=Envelope.Parser.ParseFrom(ReadFrame());
                    if(envelope.ProtocolVersion!=3) throw new InvalidDataException("PROTOCOL_VERSION");
                    if(envelope.RequestId==0)
                    {
                        if(envelope.Command!=(uint)CommandId.FramePush) throw new InvalidDataException("PUSH_COMMAND");
                        if(!pushes.TryAdd(FramePushResponse.Parser.ParseFrom(envelope.Body))) throw new IOException("PUSH_LIMIT");
                        continue;
                    }
                    Waiting item;
                    lock(gate) waiting.TryGetValue(envelope.RequestId,out item);
                    if(item==null) continue; // 已超时结果丢弃，不污染新请求。
                    if(item.Command!=envelope.Command) throw new InvalidDataException("RESPONSE_COMMAND");
                    item.Result.TrySetResult(envelope);
                }
            }
            catch(Exception ex) { Fail(ex.Message); }
        }
        private void WriteLoop()
        {
            try { foreach(var bytes in outgoing.GetConsumingEnumerable()) WriteFrame(bytes); }
            catch(Exception ex) { Fail(ex.Message); }
        }
        private void Fail(string code)
        {
            if(Interlocked.Exchange(ref closed,1)!=0) return;
            fault=code;
            outgoing.CompleteAdding();
            socket.Close(); // 解除read/write等待；不使用Thread.Abort。
            lock(gate)
            {
                foreach(var item in waiting.Values) item.Result.TrySetException(new IOException(code));
                waiting.Clear();
            }
        }
        public void Dispose()
        {
            Fail("CLOSED");
            if(reader!=null && reader!=Thread.CurrentThread) reader.Join(1000);
            if(writer!=null && writer!=Thread.CurrentThread) writer.Join(1000);
            // Collection可能仍被极少数退出路径借用，随此对象GC回收；Socket已同步关闭。
        }
    }
}
''')

add('unity/BattleNavigation/Assets/BattleNavigation/client/FrameBattleController.cs','csharp','让实际按键在本地预测，并根据Server确认帧恢复重演；最终可在场景里观察。','confirmed/predicted双实例、只对确认状态核对hash、窗口与GAP、重连清旧代数、回放只读输入。',r'''
// 职责：Unity输入、固定逻辑帧、预测/回滚、场景表现与回放接入；不是Server权威。
// Native实例和GameObject只由主线程使用；FrameConnection后台只传纯Proto值。
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Threading.Tasks;
using Battle.Navigation.V1;
using Google.Protobuf;
using UnityEngine;
namespace BattleNavigation.FrameSync
{
    public sealed class FrameBattleController : MonoBehaviour
    {
        public string Host="127.0.0.1";
        public int Port=19021;
        public string ReplayPath=""; // 空串在线；非空从本机回放文件读取，不连Server。
        private FrameConnection connection;
        private FrameNative confirmed,predicted;
        private FrameJoinResponse session;
        private readonly SortedDictionary<uint,FrameCommand> pending=new SortedDictionary<uint,FrameCommand>();
        private readonly Dictionary<uint,GameObject> actors=new Dictionary<uint,GameObject>();
        private readonly Dictionary<uint,GameObject> bolts=new Dictionary<uint,GameObject>();
        private FrameReplay replay;
        private int replayIndex;
        private float accumulated;
        private int queuedSkill;
        private bool ready,connecting,destroyed;
        private string status="connecting";
        private uint authorityFrame,predictedFrame,winner;
        private int rollbackCount;
        private float castPreviewUntil;
        private string MapPath => Path.Combine(Application.streamingAssetsPath,"navigation/battle_1001.bmap");

        private async void Start()
        {
            try
            {
                confirmed=new FrameNative(MapPath);
                predicted=new FrameNative(MapPath);
                if(ReplayPath.Length>0)
                {
                    if(new FileInfo(ReplayPath).Length>1024*1024) throw new InvalidDataException("REPLAY_LIMIT");
                    replay=FrameReplay.Parser.ParseFrom(File.ReadAllBytes(ReplayPath));
                    if(replay.FormatVersion!=1) throw new InvalidDataException("REPLAY_VERSION");
                    Install(replay.Initial);
                    status="offline replay";
                }
                else await Connect(false);
            }
            catch(Exception ex) { StopWith(ex.Message); }
        }
        private async Task Connect(bool resume)
        {
            connecting=true; ready=false;
            connection?.Dispose();
            var next=await FrameConnection.Connect(Host,Port);
            if(destroyed) { next.Dispose(); return; }
            connection=next;
            FrameJoinResponse state;
            if(resume)
            {
                var envelope=await connection.Request(CommandId.FrameRecover,new FrameRecoverRequest
                    { BattleId=session.BattleId,ResumeToken=session.ResumeToken });
                state=FrameRecoverResponse.Parser.ParseFrom(envelope.Body).State;
            }
            else
            {
                var envelope=await connection.Request(CommandId.FrameJoin,new FrameJoinRequest { ScenarioId=1001 });
                state=FrameJoinResponse.Parser.ParseFrom(envelope.Body);
            }
            if(destroyed) { next.Dispose(); return; }
            Install(state);
            connecting=false;
        }
        private void Install(FrameJoinResponse state)
        {
            if(state==null || state.Code!="OK") throw new IOException(state?.Code??"EMPTY_STATE");
            string mapHash;
            using(var sha=SHA256.Create()) mapHash=BitConverter.ToString(sha.ComputeHash(File.ReadAllBytes(MapPath))).Replace("-","").ToLowerInvariant();
            if(mapHash!=state.MapHash || confirmed.RulesHash!=state.RulesHash ||
                confirmed.MapId!=state.MapId || confirmed.MapVersion!=state.MapVersion) throw new InvalidDataException("ASSET_IDENTITY");
            confirmed.Restore(state.Checkpoint.ToByteArray());
            predicted.Restore(state.Checkpoint.ToByteArray());
            session=state;
            var view=FrameState.Decode(confirmed.Save());
            if(view.Frame!=state.Frame) throw new InvalidDataException("CHECKPOINT_FRAME");
            authorityFrame=predictedFrame=view.Frame; winner=view.Winner;
            pending.Clear(); accumulated=0; queuedSkill=0;
            ready=true; status="ready";
            if(replay==null && winner==0) SeedLead();
        }
        // 默认2帧=100ms输入提前量；本地在未来帧先执行，Server按deadline采用。
        private void SeedLead()
        {
            for(int i=0;i<2;i++) Predict(new FrameCommand { Frame=predictedFrame+1 });
        }
        private void Predict(FrameCommand input)
        {
            predicted.Step(input.X,input.Z,(int)input.Skill);
            predictedFrame=input.Frame;
            pending[input.Frame]=input;
        }
        private void Update()
        {
            if(!ready || connecting) return;
            try
            {
                if(replay==null)
                {
                    if(connection.Fault!=null) { StopWith(connection.Fault); return; }
                    int processed=0;
                    while(connection.TryPush(out var push))
                    {
                        if(++processed>256) throw new IOException("PUSH_BUDGET");
                        Receive(push);
                    }
                    if(Input.GetKeyDown(KeyCode.J)) { queuedSkill=1; castPreviewUntil=Time.unscaledTime+.12f; }
                    if(Input.GetKeyDown(KeyCode.K)) { queuedSkill=2; castPreviewUntil=Time.unscaledTime+.12f; }
                }
                accumulated+=Time.unscaledDeltaTime;
                int catchup=0;
                while(accumulated>=.05f && winner==0)
                {
                    if(++catchup>4) throw new IOException("CLIENT_OVERLOAD");
                    accumulated-=.05f;
                    if(replay!=null) PlaybackStep(); else LocalStep();
                }
                Render(FrameState.Decode(predicted.Save()));
            }
            catch(Exception ex) { StopWith(ex.Message); }
        }
        private void LocalStep()
        {
            if(FrameState.Decode(predicted.Save()).Winner!=0) return; // 预测结束时等待权威确认。
            if(predictedFrame-authorityFrame>=8 || pending.Count>=64) throw new IOException("PREDICTION_WINDOW");
            int x=(Input.GetKey(KeyCode.D)?1:0)-(Input.GetKey(KeyCode.A)?1:0);
            int z=(Input.GetKey(KeyCode.W)?1:0)-(Input.GetKey(KeyCode.S)?1:0);
            var input=new FrameCommand { Frame=predictedFrame+1,X=x,Z=z,Skill=(uint)queuedSkill };
            queuedSkill=0;
            Predict(input);
            connection.SendInputs(new FrameInputRequest { BattleId=session.BattleId,
                Generation=session.Generation,Inputs={ input } });
        }
        private void Receive(FramePushResponse push)
        {
            if(push.BattleId!=session.BattleId || push.Generation!=session.Generation) return;
            if(push.Code!="OK")
            {
                status=push.Code;
                if(push.Code=="OVERLOAD" || push.Code=="INTERNAL") throw new IOException(push.Code);
                return; // LATE/CONFLICT只是拒绝；正式帧仍会确认实际采用输入。
            }
            foreach(var record in push.Records)
            {
                if(record.Input.Frame<=authorityFrame) continue;
                if(record.Input.Frame!=authorityFrame+1) throw new InvalidDataException("FRAME_GAP");
                confirmed.Step(record.Input.X,record.Input.Z,(int)record.Input.Skill);
                if(FrameNative.Hash(confirmed.Save())!=record.Hash) throw new InvalidDataException("STATE_DIVERGENCE");
                authorityFrame=record.Input.Frame;
                pending.Remove(authorityFrame);
            }
            Reconcile();
            winner=push.Winner;
        }
        private void Reconcile()
        {
            var before=predicted.Save();
            uint target=Math.Max(predictedFrame,authorityFrame);
            predicted.Restore(confirmed.Save()); predictedFrame=authorityFrame;
            if(FrameState.Decode(predicted.Save()).Winner==0)
            {
                for(uint frame=authorityFrame+1;frame<=target;frame++)
                {
                    if(!pending.TryGetValue(frame,out var input)) input=new FrameCommand { Frame=frame };
                    predicted.Step(input.X,input.Z,(int)input.Skill);
                    predictedFrame=frame;
                    if(FrameState.Decode(predicted.Save()).Winner!=0) break;
                }
            }
            if(FrameNative.Hash(before)!=FrameNative.Hash(predicted.Save())) rollbackCount++;
        }
        private void PlaybackStep()
        {
            if(replayIndex>=replay.Records.Count) { winner=3; status="replay end"; return; }
            var record=replay.Records[replayIndex++];
            if(record.Input.Frame!=predictedFrame+1) throw new InvalidDataException("REPLAY_FRAME_GAP");
            predicted.Step(record.Input.X,record.Input.Z,(int)record.Input.Skill);
            if(FrameNative.Hash(predicted.Save())!=record.Hash) throw new InvalidDataException("REPLAY_DIVERGENCE");
            predictedFrame=authorityFrame=record.Input.Frame;
            winner=FrameState.Decode(predicted.Save()).Winner;
        }
        private static Vector3 World(long x,long y,long z) { return new Vector3(x/1000f,y/1000f,z/1000f); }
        private GameObject Actor(uint id,bool projectile)
        {
            var index=projectile?bolts:actors;
            if(index.TryGetValue(id,out var existing)) return existing;
            var actor=GameObject.CreatePrimitive(projectile?PrimitiveType.Sphere:PrimitiveType.Capsule);
            actor.name=(projectile?"Bolt_":"Unit_")+id;
            Destroy(actor.GetComponent<Collider>()); // 表现不驱动Native碰撞。
            actor.transform.localScale=projectile?Vector3.one*.25f:new Vector3(.4f,1,.4f);
            index.Add(id,actor);
            return actor;
        }
        private void Render(FrameState state)
        {
            foreach(var unit in state.Units)
            {
                var actor=Actor(unit.Id,false);
                actor.SetActive(unit.Hp>0);
                var goal=World(unit.X,unit.Y,unit.Z)+Vector3.up;
                // 差异较大直接贴权威预测点，小差异100ms内收敛；只改显示Transform。
                actor.transform.position=Vector3.Distance(actor.transform.position,goal)>2 ? goal :
                    Vector3.Lerp(actor.transform.position,goal,1-Mathf.Exp(-Time.unscaledDeltaTime*30));
                var color=unit.Camp==1?Color.green:Color.red;
                if(unit.Id==1001 && Time.unscaledTime<castPreviewUntil) color=Color.yellow;
                actor.GetComponent<Renderer>().material.color=color;
            }
            var present=new HashSet<uint>();
            foreach(var bolt in state.Bolts)
            {
                present.Add(bolt.Id);
                var actor=Actor(bolt.Id,true);
                actor.transform.position=World(bolt.X,bolt.Y,bolt.Z)+Vector3.up;
                actor.GetComponent<Renderer>().material.color=Color.cyan;
            }
            foreach(var id in bolts.Keys.ToArray())
                if(!present.Contains(id)) { Destroy(bolts[id]); bolts.Remove(id); }
        }
        private async void Recover()
        {
            if(connecting || session==null || replay!=null) return;
            try { await Connect(true); }
            catch(Exception ex) { connecting=false; StopWith(ex.Message); }
        }
        private async void SaveReplay()
        {
            try
            {
                if(winner==0) throw new IOException("REPLAY_REQUIRES_FINISHED");
                var file=new FrameReplay { FormatVersion=1 };
                uint offset=0,total;
                do
                {
                    var envelope=await connection.Request(CommandId.FrameReplay,new FrameReplayRequest
                        { BattleId=session.BattleId,ResumeToken=session.ResumeToken,Offset=offset });
                    var page=FrameReplayResponse.Parser.ParseFrom(envelope.Body);
                    if(page.Code!="OK") throw new IOException(page.Code);
                    if(offset==0) file.Initial=page.Initial;
                    file.Records.Add(page.Records); offset+=(uint)page.Records.Count; total=page.Total;
                    if(total>3600 || (page.Records.Count==0 && offset<total)) throw new InvalidDataException("REPLAY_PAGE");
                } while(offset<total);
                string path=Path.Combine(Application.persistentDataPath,"frame_last.pb");
                File.WriteAllBytes(path,file.ToByteArray()); status="saved "+path;
            }
            catch(Exception ex) { status=ex.Message; }
        }
        private void StopWith(string code) { ready=false; connecting=false; status=code; connection?.Dispose(); }
        private void OnGUI()
        {
            GUILayout.BeginArea(new Rect(10,10,520,250),GUI.skin.box);
            GUILayout.Label($"FrameSync {status} server={authorityFrame} predicted={predictedFrame} rollback={rollbackCount} winner={winner}");
            GUILayout.Label("WASD移动，J近战，K火球；黄闪是本地施法预备反馈，HP由权威帧确认");
            if(predicted!=null)
            {
                var view=FrameState.Decode(predicted.Save());
                foreach(var unit in view.Units) GUILayout.Label($"unit={unit.Id} hp={unit.Hp} skillReady={unit.Ready1}/{unit.Ready2}");
            }
            if(GUILayout.Button("重连 / 权威状态恢复")) Recover();
            if(GUILayout.Button("保存结束战斗输入回放")) SaveReplay();
            GUILayout.EndArea();
        }
        private void OnDestroy()
        {
            destroyed=true; ready=false;
            connection?.Dispose(); confirmed?.Dispose(); predicted?.Dispose();
            foreach(var actor in actors.Values) Destroy(actor);
            foreach(var bolt in bolts.Values) Destroy(bolt);
        }
    }
}
''')

# AI复用Lesson2已验证的A*；scratch独占，不是需要Checkpoint的逻辑事实。
# 三种技能案例：近战瞬发、立即伤害的表现弹丸、碰撞到达才伤害的逻辑弹丸。
F['server/native/frame_sync/frame_core.h']=F['server/native/frame_sync/frame_core.h'].replace('ready[2]','ready[3]').replace('skill 为0/1/2','skill 为0/1/2/3').replace('1近战，2逻辑火球','1近战，2表现弹丸，3逻辑火球')
F['server/native/frame_sync/frame_core.h']=F['server/native/frame_sync/frame_core.h'].replace('    std::uint32_t expires = 0;','    std::uint32_t expires = 0;\n    std::int32_t damage = 0; // 0仅表现；20到达目标才结算。')
p='server/native/frame_sync/frame_core.cpp'
F[p]=F[p].replace('{{900, 12, 14, false}, {9000, 24, 20, true}}','{{900, 12, 14, false}, {9000, 24, 12, true}, {9000, 24, 20, true}}')
F[p]=F[p].replace('<= 900*900 ? 1 : 2','<= 900*900 ? 1 : 3').replace('input.skill > 2','input.skill > 3')
F[p]=F[p].replace('    state_.bolts.push_back({','    if (skill_id==2) damage[index] += def.damage; // 表现飞行不会改变已经结算的伤害。\n    state_.bolts.push_back({')
F[p]=F[p].replace('state_.frame+60,unit.x','state_.frame+60,skill_id==2 ? 0 : def.damage,unit.x')
F[p]=F[p].replace('] += 20;','] += bolt.damage;')
F[p]=F[p].replace('size()*44','size()*48').replace('size()*40','size()*44')
F[p]=F[p].replace('put(out,unit.ready[1],4);','put(out,unit.ready[1],4); put(out,unit.ready[2],4);')
F[p]=F[p].replace('put(out,bolt.expires,4);','put(out,bolt.expires,4); put(out,static_cast<std::uint32_t>(bolt.damage),4);')
F[p]=F[p].replace('unit.ready[1] = static_cast<std::uint32_t>(get(bytes,offset,4));','unit.ready[1] = static_cast<std::uint32_t>(get(bytes,offset,4));\n        unit.ready[2] = static_cast<std::uint32_t>(get(bytes,offset,4));')
F[p]=F[p].replace('unit.ready[1]>candidate.frame+24 ||','unit.ready[1]>candidate.frame+24 || unit.ready[2]>candidate.frame+24 ||')
F[p]=F[p].replace('bolt.expires=static_cast<std::uint32_t>(get(bytes,offset,4));','bolt.expires=static_cast<std::uint32_t>(get(bytes,offset,4));\n        bolt.damage=static_cast<std::int32_t>(get(bytes,offset,4));')
F[p]=F[p].replace('if (!exists(bolt.caster)','if ((bolt.damage!=0 && bolt.damage!=20) || !exists(bolt.caster)')
F['shared/protocol/frame_sync_messages.proto.inc']=F['shared/protocol/frame_sync_messages.proto.inc'].replace('1近战，2逻辑火球','1近战，2表现弹丸，3逻辑火球')
p='server/lualib/battle/frame_sync/runtime.lua'
F[p]=F[p].replace('input.skill > 2','input.skill > 3').replace('skill > 2','skill > 3')
p='unity/BattleNavigation/Assets/BattleNavigation/client/FrameNative.cs'
F[p]=F[p].replace('Ready1,Ready2','Ready1,Ready2,Ready3').replace('Ready2=reader.ReadUInt32(),','Ready2=reader.ReadUInt32(),Ready3=reader.ReadUInt32(),')
F[p]=F[p].replace('reader.ReadUInt32(); reader.ReadUInt32(); reader.ReadUInt32();','reader.ReadUInt32(); reader.ReadUInt32(); reader.ReadUInt32(); reader.ReadInt32();')
p='unity/BattleNavigation/Assets/BattleNavigation/client/FrameBattleController.cs'
F[p]=F[p].replace('J/K','J/K/L').replace('if(Input.GetKeyDown(KeyCode.K))','if(Input.GetKeyDown(KeyCode.L)) { queuedSkill=3; castPreviewUntil=Time.unscaledTime+.15f; }\n                if(Input.GetKeyDown(KeyCode.K))')
# 空中单位使用独立通行规则：地图XZ边界+地表高度上方2000mm，不读取地面阻挡/clearance。
p='server/native/frame_sync/frame_core.h'
F[p]=F[p].replace('    std::uint32_t camp = 0;','    std::uint32_t camp = 0;\n    std::uint32_t move_mode = 1; // 1地面，2固定离地2000mm的空中单位。')
F[p]=F[p].replace('    void move(Unit& unit, Input input);','    void move(Unit& unit, Input input);\n    bool sampleAir(std::int64_t x, std::int64_t z, std::int64_t& y) const;')
p='server/native/frame_sync/frame_core.cpp'
F[p]=F[p].replace('bool bolt; };','bool bolt; std::uint32_t target_modes; };').replace('{{900, 12, 14, false}, {9000, 24, 12, true}, {9000, 24, 20, true}}','{{900, 12, 14, false, 1}, {9000, 24, 12, true, 3}, {9000, 24, 20, true, 3}}')
F[p]=F[p].replace('    const auto dz = a.z - b.z;\n    return dx * dx + dz * dz;','    const auto dz = a.z - b.z;\n    const auto dy = a.y - b.y;\n    return dx * dx + dy * dy + dz * dz;')
F[p]=F[p].replace('{1001,1,-11000,0,4000,100,{}}','{1001,1,1,-11000,0,4000,100,{}}').replace('{2001,2,11000,0,-4000,100,{}}','{2001,2,2,11000,0,-4000,100,{}}')
F[p]=F[p].replace('        if (!sample(unit.x, unit.z, unit.y, unit.y))','        if (!(unit.move_mode==2 ? sampleAir(unit.x,unit.z,unit.y) : sample(unit.x, unit.z, unit.y, unit.y)))')
F[p]=F[p].replace('void Engine::reset()',r'''bool Engine::sampleAir(std::int64_t x,std::int64_t z,std::int64_t& y) const
{
    const auto result=map_->QueryWorld({x,0,z});
    if (!result.ok()) return false;
    y=static_cast<std::int64_t>(result.value.height_mm)+2000;
    return true; // 不读取IsWalkable/clearance；该地图尚无空域禁飞与天花板资产。
}
void Engine::reset()''')
F[p]=F[p].replace('distance2(unit,state_.units[index]) > def.range*def.range) return;','distance2(unit,state_.units[index]) > def.range*def.range ||\n        (def.target_modes & state_.units[index].move_mode)==0) return;')
F[p]=F[p].replace('<= 900*900 ? 1 : 3','<= 900*900 && other.move_mode==1 ? 1 : 3')
F[p]=F[p].replace('    // X后Z是固定的贴墙滑动顺序；不是由物理回调执行顺序决定。','    // X后Z是固定的贴墙滑动顺序；不是由物理回调执行顺序决定。')
F[p]=F[p].replace('if (sample(unit.x+sx,unit.z,unit.y,y))','if (unit.move_mode==2 ? sampleAir(unit.x+sx,unit.z,y) : sample(unit.x+sx,unit.z,unit.y,y))').replace('if (sample(unit.x,unit.z+sz,unit.y,y))','if (unit.move_mode==2 ? sampleAir(unit.x,unit.z+sz,y) : sample(unit.x,unit.z+sz,unit.y,y))')
F[p]=F[p].replace('const auto dz = it->z-bolt.z;\n        const auto span = std::max(std::abs(dx),std::abs(dz));','const auto dz = it->z-bolt.z;\n        const auto dy = it->y-bolt.y;\n        const auto span = std::max({std::abs(dx),std::abs(dy),std::abs(dz)});')
F[p]=F[p].replace('        bolt.z += dz*400/span;','        bolt.z += dz*400/span;\n        bolt.y += dy*400/span;')
F[p]=F[p].replace('size()*48','size()*52').replace('put(out,unit.camp,4);','put(out,unit.camp,4); put(out,unit.move_mode,4);')
F[p]=F[p].replace('unit.camp = static_cast<std::uint32_t>(get(bytes,offset,4));','unit.camp = static_cast<std::uint32_t>(get(bytes,offset,4));\n        unit.move_mode = static_cast<std::uint32_t>(get(bytes,offset,4));')
F[p]=F[p].replace('unit.id==0 || (unit.camp!=1','(unit.move_mode!=1 && unit.move_mode!=2) || unit.id==0 || (unit.camp!=1')
p='unity/BattleNavigation/Assets/BattleNavigation/client/FrameNative.cs'
F[p]=F[p].replace('public uint Id,Camp;','public uint Id,Camp,MoveMode;').replace('Camp=reader.ReadUInt32(),X=','Camp=reader.ReadUInt32(),MoveMode=reader.ReadUInt32(),X=')
# 升降是正式玩家输入；出生高度仅初始值，不约束后续高度。
p='server/native/frame_sync/frame_core.h'
F[p]=F[p].replace('固定离地2000mm的空中单位','可主动升降的空中单位').replace('    std::int32_t skill = 0;','    std::int32_t y = 0; // -1下降，0保持高度，1上升；地面单位忽略。\n    std::int32_t skill = 0;')
F[p]=F[p].replace('int x, int z, int skill);','int x, int z, int skill, int y);').replace('sampleAir(std::int64_t x, std::int64_t z, std::int64_t& y)','sampleAir(std::int64_t x, std::int64_t z, std::int64_t desired_y, std::int64_t& y)')
p='server/native/frame_sync/frame_core.cpp'
F[p]=F[p].replace('std::int64_t z,std::int64_t& y) const','std::int64_t z,std::int64_t desired_y,std::int64_t& y) const')
F[p]=F[p].replace('    y=static_cast<std::int64_t>(result.value.height_mm)+2000;','    if (desired_y<static_cast<std::int64_t>(result.value.height_mm)+200 || desired_y>10000) return false;\n    y=desired_y;')
F[p]=F[p].replace('{2001,2,2,11000,0,-4000,100,{}}','{2001,2,2,11000,2000,-4000,100,{}}')
F[p]=F[p].replace('sampleAir(unit.x,unit.z,unit.y)','sampleAir(unit.x,unit.z,unit.y,unit.y)')
F[p]=F[p].replace('sampleAir(unit.x+sx,unit.z,y)','sampleAir(unit.x+sx,unit.z,unit.y,y)').replace('sampleAir(unit.x,unit.z+sz,y)','sampleAir(unit.x,unit.z+sz,unit.y,y)')
F[p]=F[p].replace('    const std::int64_t length = input.x != 0 && input.z != 0 ? 106 : 150;','    if (unit.move_mode==1) input.y=0;\n    const int axes=(input.x!=0)+(input.z!=0)+(input.y!=0);\n    const std::int64_t length = axes==3 ? 86 : axes==2 ? 106 : 150;')
F[p]=F[p].replace('    const auto dz = input.z * length;','    const auto dz = input.z * length;\n    const auto dy = input.y * length;')
F[p]=F[p].replace('        const auto sz = dz*n/steps - dz*(n-1)/steps;','        const auto sz = dz*n/steps - dz*(n-1)/steps;\n        const auto sy = dy*n/steps - dy*(n-1)/steps;')
F[p]=F[p].replace('if (unit.move_mode==2 ? sampleAir(unit.x,unit.z+sz,unit.y,y) : sample(unit.x,unit.z+sz,unit.y,y)) { unit.z+=sz; unit.y=y; }','if (unit.move_mode==2 ? sampleAir(unit.x,unit.z+sz,unit.y,y) : sample(unit.x,unit.z+sz,unit.y,y)) { unit.z+=sz; unit.y=y; }\n        if (unit.move_mode==2 && sampleAir(unit.x,unit.z,unit.y+sy,y)) unit.y=y;')
F[p]=F[p].replace('input.skill < 0 || input.skill > 3','input.y != 0 || input.skill < 0 || input.skill > 3')
F[p]=F[p].replace('int x,int z,int skill)','int x,int z,int skill,int y)').replace('->step({x,z,skill});','->step({x,z,y,skill});')
# Input新增y在skill之前，旧Golden的aggregate同步修正。
p='server/native/frame_sync/frame_test.cpp'
F[p]=F[p].replace('Input input{','Input input{')
F[p]=re.sub(r'(Input input\{[^,\n]+,[^,\n]+),',r'\1,0,',F[p])
p='server/native/frame_sync/frame_binding.cpp'
F[p]=F[p].replace('int x=0,z=0,skill=0;','int x=0,z=0,skill=0,y=0;').replace('!lua.readValue(4,skill))','!lua.readValue(4,skill) || !lua.readValue(5,y))').replace('fs_step(owner->handle,x,z,skill)','fs_step(owner->handle,x,z,skill,y)')
p='shared/protocol/frame_sync_messages.proto.inc'
F[p]=F[p].replace('  uint32 skill = 4;', '  sint32 y = 5;          // -1下降，0保持，1上升；作为正式输入确认与回放。\n  uint32 skill = 4;')
p='server/lualib/battle/frame_sync/runtime.lua'
F[p]=F[p].replace('local x, z, skill = input.x or 0, input.z or 0, input.skill or 0','local x, z, skill, y = input.x or 0, input.z or 0, input.skill or 0, input.y or 0')
F[p]=F[p].replace('x < -1 or x > 1 or','math.type(y) ~= "integer" or y < -1 or y > 1 or x < -1 or x > 1 or')
F[p]=F[p].replace('previous.skill == skill and','previous.skill == skill and previous.y == y and').replace('x = x, z = z, skill = skill','x = x, z = z, skill = skill, y = y')
F[p]=F[p].replace('last_z        = 0,','last_z        = 0,\n        last_y        = 0,')
F[p]=F[p].replace('runtime.last_x, runtime.last_z = input.x, input.z','runtime.last_x, runtime.last_z, runtime.last_y = input.x, input.z, input.y')
F[p]=F[p].replace('z = hold and runtime.last_z or 0, skill = 0','z = hold and runtime.last_z or 0, y = hold and runtime.last_y or 0, skill = 0')
F[p]=F[p].replace('runtime.engine:step(input.x, input.z, input.skill)','runtime.engine:step(input.x, input.z, input.skill, input.y)').replace('y < -1 or y > 1','y ~= 0')
worker_path='server/service/battle/frame_sync/worker.lua'
F[worker_path]=F[worker_path].replace('battle.core.last_x, battle.core.last_z = 0, 0','battle.core.last_x, battle.core.last_z, battle.core.last_y = 0, 0, 0')
cpp_path='server/native/frame_sync/frame_core.cpp'
F[cpp_path]=F[cpp_path].replace('    if (distance2(unit, other) > 800*800)\n    {','''    if (unit.move_mode==2)
    {
        input.x=sign(other.x-unit.x);
        input.z=sign(other.z-unit.z);
        // 水平距离越大，追击高度越高；接近目标时下俯，目标移动后重新计算。
        const auto horizontal=std::max(std::abs(other.x-unit.x),std::abs(other.z-unit.z));
        const auto desired_y=other.y+400+std::min<std::int64_t>(2400,horizontal/2);
        input.y=std::abs(desired_y-unit.y)>=150 ? sign(desired_y-unit.y) : 0;
        std::int64_t probe_y=unit.y;
        if (!sampleAir(unit.x+input.x*150,unit.z+input.z*150,unit.y,probe_y)) input.y=1;
        if (distance2(unit,other)<=800*800) input.x=input.z=0;
    }
    else if (distance2(unit, other) > 800*800)
    {''')
F[cpp_path]=F[cpp_path].replace('{2001,2,2,11000,2000,-4000,100,{}}','{2001,2,2,11000,2000,-4000,100,{}}, {2002,2,1,11000,0,-4000,100,{}}')
p='unity/BattleNavigation/Assets/BattleNavigation/client/FrameNative.cs'
F[p]=F[p].replace('public uint Id,Camp,Ready1','public uint Id,Camp,MoveMode,Ready1').replace('int x,int z,int skill)','int x,int z,int skill,int y=0)').replace('fs_step(handle,x,z,skill)','fs_step(handle,x,z,skill,y)')
p='unity/BattleNavigation/Assets/BattleNavigation/client/FrameBattleController.cs'
F[p]=F[p].replace('X=x,Z=z,Skill=','X=x,Z=z,Y=0,Skill=')
F[p]=F[p].replace('input.Z,(int)input.Skill)','input.Z,(int)input.Skill,input.Y)').replace('record.Input.Z,(int)record.Input.Skill)','record.Input.Z,(int)record.Input.Skill,record.Input.Y)')
# 玩家合同不提供升降字段；飞行敌人的内部AI仍使用Input.y。
F['shared/protocol/frame_sync_messages.proto.inc']=re.sub(r'^  sint32 y = 5;.*\n','',F['shared/protocol/frame_sync_messages.proto.inc'],flags=re.M)
F['server/native/frame_sync/frame_core.h']=F['server/native/frame_sync/frame_core.h'].replace('int x, int z, int skill, int y);','int x, int z, int skill);')
F['server/native/frame_sync/frame_core.cpp']=F['server/native/frame_sync/frame_core.cpp'].replace('int x,int z,int skill,int y)','int x,int z,int skill)').replace('->step({x,z,y,skill});','->step({x,z,0,skill});')
F['server/native/frame_sync/frame_binding.cpp']=F['server/native/frame_sync/frame_binding.cpp'].replace('int x=0,z=0,skill=0,y=0;','int x=0,z=0,skill=0;').replace(' || !lua.readValue(5,y)','').replace('fs_step(owner->handle,x,z,skill,y)','fs_step(owner->handle,x,z,skill)')
F['server/lualib/battle/frame_sync/runtime.lua']=F['server/lualib/battle/frame_sync/runtime.lua'].replace('runtime.engine:step(input.x, input.z, input.skill, input.y)','runtime.engine:step(input.x, input.z, input.skill)')
F['unity/BattleNavigation/Assets/BattleNavigation/client/FrameNative.cs']=F['unity/BattleNavigation/Assets/BattleNavigation/client/FrameNative.cs'].replace('int x,int z,int skill,int y=0)','int x,int z,int skill)').replace('fs_step(handle,x,z,skill,y)','fs_step(handle,x,z,skill)')
F[p]=F[p].replace(',input.Y)',')').replace(',record.Input.Y)',')').replace('X=x,Z=z,Y=0,Skill=','X=x,Z=z,Skill=')
F[p]=F[p].replace('uint target=Math.Max(predictedFrame,authorityFrame);','uint oldFrame=predictedFrame;\n            uint target=Math.Max(predictedFrame,authorityFrame+2);')
F[p]=F[p].replace('if(FrameNative.Hash(before)!=FrameNative.Hash(predicted.Save()))','if(oldFrame==predictedFrame && FrameNative.Hash(before)!=FrameNative.Hash(predicted.Save()))')
F[p]=F[p].replace('                actor.SetActive(unit.Hp>0);','                var official=replay!=null ? unit : FrameState.Decode(confirmed.Save()).Units.First(u=>u.Id==unit.Id);\n                actor.SetActive(official.Hp>0);')
F[p]=F[p].replace('var view=FrameState.Decode(predicted.Save());\n                foreach','var view=FrameState.Decode(replay!=null?predicted.Save():confirmed.Save());\n                foreach')
F[p]=F[p].replace('WASD移动，J近战，K火球','WASD移动，J近战，K表现弹丸，L逻辑火球').replace('skillReady={unit.Ready1}/{unit.Ready2}','mode={unit.MoveMode} y={unit.Y}mm skillReady={unit.Ready1}/{unit.Ready2}/{unit.Ready3}')
F[p]=F[p].replace('        private GameObject Actor(uint id,bool projectile)','        private readonly List<Material> ownedMaterials=new List<Material>();\n        private bool savingReplay;\n        private void DestroyActor(GameObject actor)\n        {\n            var material=actor.GetComponent<Renderer>().sharedMaterial;\n            ownedMaterials.Remove(material); Destroy(material); Destroy(actor);\n        }\n        private GameObject Actor(uint id,bool projectile)')
F[p]=F[p].replace('            index.Add(id,actor);','            ownedMaterials.Add(actor.GetComponent<Renderer>().material);\n            index.Add(id,actor);')
F[p]=F[p].replace('Destroy(bolts[id]);','DestroyActor(bolts[id]);').replace('foreach(var actor in actors.Values) Destroy(actor);','foreach(var actor in actors.Values) DestroyActor(actor);').replace('foreach(var bolt in bolts.Values) Destroy(bolt);','foreach(var bolt in bolts.Values) DestroyActor(bolt);')
F[p]=F[p].replace('        private async void SaveReplay()\n        {\n            try','        private async void SaveReplay()\n        {\n            if(savingReplay || destroyed || replay!=null) return;\n            savingReplay=true;\n            try')
F[p]=F[p].replace('                    var page=FrameReplayResponse.Parser.ParseFrom(envelope.Body);','                    if(destroyed) return;\n                    var page=FrameReplayResponse.Parser.ParseFrom(envelope.Body);')
F[p]=F[p].replace('            catch(Exception ex) { status=ex.Message; }','            catch(Exception ex) { if(!destroyed) status=ex.Message; }\n            finally { savingReplay=false; }')
F[p]=F[p].replace('                    if(replay.FormatVersion!=1) throw new InvalidDataException("REPLAY_VERSION");','                    if(replay.FormatVersion!=1) throw new InvalidDataException("REPLAY_VERSION");\n                    if(replay.Records.Count<1 || replay.Records.Count>3600 || replay.Initial==null || replay.Initial.Frame!=0)\n                        throw new InvalidDataException("REPLAY_RANGE");')
F[p]=F[p].replace('if(replayIndex>=replay.Records.Count) { winner=3; status="replay end"; return; }','if(replayIndex>=replay.Records.Count) throw new InvalidDataException("REPLAY_INCOMPLETE");')
# 主线程分成网络收取、按键反馈、固定步、渲染，方便逐阶段设置断点。
begin=F[p].index('        private void Update()')
end=F[p].index('        private void LocalStep()',begin)
F[p]=F[p][:begin]+r'''
        private void DrainFrames()
        {
            if(connection.Fault!=null) throw new IOException(connection.Fault);
            int processed=0;
            while(connection.TryPush(out var push))
            {
                if(++processed>256) throw new IOException("PUSH_BUDGET");
                Receive(push);
            }
        }
        private void CaptureSkill()
        {
            int skill=Input.GetKeyDown(KeyCode.L)?3:Input.GetKeyDown(KeyCode.K)?2:Input.GetKeyDown(KeyCode.J)?1:0;
            if(skill==0) return;
            queuedSkill=skill; castPreviewUntil=Time.unscaledTime+.12f;
        }
        private void AdvanceLocalClock()
        {
            accumulated+=Time.unscaledDeltaTime;
            int catchup=0;
            while(accumulated>=.05f && winner==0)
            {
                if(++catchup>4) throw new IOException("CLIENT_OVERLOAD");
                accumulated-=.05f;
                if(replay!=null) PlaybackStep(); else LocalStep();
            }
        }
        private void Update()
        {
            if(!ready || connecting) return;
            try
            {
                if(replay==null) { DrainFrames(); CaptureSkill(); }
                AdvanceLocalClock();
                Render(FrameState.Decode(predicted.Save()));
            }
            catch(Exception ex) { StopWith(ex.Message); }
        }
'''+F[p][end:]
# Reconcile只负责恢复与审计，未来帧重演单独命名。
begin=F[p].index('            if(FrameState.Decode(predicted.Save()).Winner==0)\n            {',F[p].index('private void Reconcile'))
end=F[p].index('            if(oldFrame==predictedFrame',begin)
body=F[p][begin:end]
F[p]=F[p][:begin]+'            ReplayPending(target);\n'+F[p][end:]
where=F[p].index('        private void PlaybackStep()')
F[p]=F[p][:where]+'        private void ReplayPending(uint target)\n        {\n'+body+'        }\n'+F[p][where:]
# 公开跨模块API的owner、I/O与错误在IDE中可读。
native_cs='unity/BattleNavigation/Assets/BattleNavigation/client/FrameNative.cs'
F[native_cs]=F[native_cs].replace('        public FrameNative(string path)','        /// <summary>读取UTF-8资产路径并拥有独占Native；失败抛MAP_LOAD，调用方主线程Dispose。</summary>\n        public FrameNative(string path)').replace('        public void Step(int x,int z,int skill)','        /// <summary>同步推进50ms；方向-1/0/1、技能0..3；无I/O，失败不改变旧State。</summary>\n        public void Step(int x,int z,int skill)').replace('        public byte[] Save()','        /// <summary>分配并返回本实例规范化状态副本，最大16384bytes；调用方拥有数组。</summary>\n        public byte[] Save()').replace('        public void Restore(byte[] bytes)','        /// <summary>同步借用字节到调用返回；全部验证后替换State，失败保持旧State。</summary>\n        public void Restore(byte[] bytes)')
F[native_cs]=F[native_cs].replace('using System.Runtime.InteropServices;','using System.Runtime.InteropServices;\nusing Microsoft.Win32.SafeHandles;')
F[native_cs]=F[native_cs].replace('        private IntPtr handle; // 此实例独占；只在Unity主线程调用，Dispose后为0。','''        private sealed class FrameHandle : SafeHandleZeroOrMinusOneIsInvalid
        {
            public FrameHandle(IntPtr value) : base(true) { SetHandle(value); }
            protected override bool ReleaseHandle() { fs_close(handle); return true; }
        }
        private FrameHandle handle; // SafeHandle为P/Invoke借用自动保活；仍只在主线程使用。''')
for name in ['fs_step','fs_save','fs_restore','fs_map_version','fs_map_id']:
    F[native_cs]=F[native_cs].replace(name+'(IntPtr handle',name+'(FrameHandle handle')
F[native_cs]=F[native_cs].replace('handle=fs_open(path);','handle=new FrameHandle(fs_open(path));').replace('if(handle==IntPtr.Zero)','if(handle.IsInvalid)')
old='''            var old=handle;
            handle=IntPtr.Zero;
            if(old!=IntPtr.Zero) fs_close(old);
            GC.SuppressFinalize(this);'''
F[native_cs]=F[native_cs].replace(old,'            handle?.Dispose(); // 幂等；SafeHandle critical finalizer兜底。')
F[native_cs]=re.sub(r'^        ~FrameNative\(\).*\n','',F[native_cs],flags=re.M)
connection_cs='unity/BattleNavigation/Assets/BattleNavigation/client/FrameConnection.cs'
F[connection_cs]=F[connection_cs].replace('        public static async Task<FrameConnection> Connect','        /// <summary>后台连接与握手；超时3秒；成功调用方拥有连接并Dispose，不访问Unity对象。</summary>\n        public static async Task<FrameConnection> Connect').replace('        public async Task<Envelope> Request','        /// <summary>控制请求最多8个，等待3秒；await期间只持有纯Proto对象，错误抛异常。</summary>\n        public async Task<Envelope> Request').replace('        public void SendInputs','        /// <summary>单向输入加入最多128项出站队列；不等待确认，满队列显式关闭。</summary>\n        public void SendInputs')
# 规则身份包括真实参与编译的导航源码与头文件；不只比较宿主技能代码。
core_path='server/native/frame_sync/frame_core.cpp'
F[core_path]=F[core_path].replace('constexpr std::int64_t kPositionLimit = 1000000000;','constexpr std::int64_t kPositionLimit = 500000000; // 三轴差值平方和<=3e18，避免int64溢出。')
F[core_path]=F[core_path].replace('struct Skill { std::int64_t range; std::uint32_t cooldown; std::int32_t damage; bool bolt; std::uint32_t target_modes; };','enum class SkillEffect { kInstant, kVisualBolt, kLogicalBolt };\nstruct Skill { std::int64_t range; std::uint32_t cooldown; std::int32_t damage; SkillEffect effect; std::uint32_t target_modes; };')
F[core_path]=F[core_path].replace('{{900, 12, 14, false, 1}, {9000, 24, 12, true, 3}, {9000, 24, 20, true, 3}}','{{900, 12, 14, SkillEffect::kInstant, 1}, {9000, 24, 12, SkillEffect::kVisualBolt, 3}, {9000, 24, 20, SkillEffect::kLogicalBolt, 3}}')
F[core_path]=F[core_path].replace('if (def.bolt &&','if (def.effect!=SkillEffect::kInstant &&').replace('if (!def.bolt)','if (def.effect==SkillEffect::kInstant)').replace('if (skill_id==2)','if (def.effect==SkillEffect::kVisualBolt)').replace('skill_id==2 ? 0 : def.damage','def.effect==SkillEffect::kVisualBolt ? 0 : def.damage')
F[core_path]=F[core_path].replace('if (def.effect!=SkillEffect::kInstant && state_.bolts.size() >= kMaxBolts)','if (def.effect==SkillEffect::kLogicalBolt && state_.bolts.size() >= kMaxBolts)')
F[core_path]=F[core_path].replace('    state_.bolts.push_back({','    if (state_.bolts.size()>=kMaxBolts) return; // 表现球满槽仅降级视觉，不撤回已提交的伤害与冷却。\n    state_.bolts.push_back({')
worker_path='server/service/battle/frame_sync/worker.lua'
F[worker_path]=F[worker_path].replace('    battle.generation = battle.generation + 1','    if battle.failed then return { code = battle.failure_code } end\n    battle.generation = battle.generation + 1').replace('            battle.failed = true\n            push(battle, {}, "INTERNAL")','            battle.failed = true\n            battle.failure_code = "INTERNAL"\n            push(battle, {}, "INTERNAL")').replace('        battle.failed = true\n        push(battle, {}, "OVERLOAD")','        battle.failed = true\n        battle.failure_code = "OVERLOAD"\n        push(battle, {}, "OVERLOAD")')
F[worker_path]=F[worker_path].replace('local function inputs(args)','''--- 截止以Worker处理时钟为准；Timer稍晚执行也不能给已到期帧重新开窗口。
local function admit(battle, input)
    local frame = input.frame or 0
    if math.type(frame) == "integer" and frame > battle.core.frame then
        local deadline = battle.due + (frame - battle.core.frame - 1) * config.tick_cs
        if skynet.now() >= deadline then return "LATE" end
    end
    return core.accept(battle.core, input)
end
local function inputs(args)''').replace('local code = core.accept(battle.core, input)','local code = admit(battle, input)')
# 反序列化按“头/单位/弹丸/原子发布”拆开，审计每类边界无需穿过长函数。
code=F[core_path]
start=code.index('void Engine::restore(')
end=code.index('\n}\n}',start)+2
restore=code[start:end]
unit_body=restore[restore.index('        Unit unit;'):restore.index('        candidate.units.push_back(unit);')]
bolt_body=restore[restore.index('        Bolt bolt;'):restore.index('        candidate.bolts.push_back(bolt);')]
header_body=restore[restore.index('    if (get(bytes,offset,4)!=1)'):restore.index('    for (std::size_t i = 0; i < count; ++i)')]
header_body=header_body.replace('    State candidate;\n','')
helpers='''
std::size_t readStateHeader(const std::string& bytes,std::size_t& offset,State& candidate)
{
'''+header_body+'''    return static_cast<std::size_t>(count);
}
Unit readUnit(const std::string& bytes,std::size_t& offset,const State& candidate)
{
'''+unit_body+'''        return unit;
}
Bolt readBolt(const std::string& bytes,std::size_t& offset,const State& candidate)
{
'''+bolt_body+'''        return bolt;
}
'''
new_restore='''void Engine::restore(const std::string& bytes)
{
    std::size_t offset=0;
    State candidate;
    const auto count=readStateHeader(bytes,offset,candidate);
    for (std::size_t i=0;i<count;++i) candidate.units.push_back(readUnit(bytes,offset,candidate));

    const auto bolts=get(bytes,offset,4);
    if (bolts>kMaxBolts) throw std::runtime_error("STATE_BOLTS");
    for (std::size_t i=0;i<bolts;++i) candidate.bolts.push_back(readBolt(bytes,offset,candidate));
    if (offset!=bytes.size()) throw std::runtime_error("STATE_TRAILING");
    state_=std::move(candidate); // 所有校验通过后唯一发布点。
}'''
code=code[:start]+new_restore+code[end:]
code=code.replace('\n}\n\nEngine::Engine', '\n'+helpers+'}\n\nEngine::Engine',1)
F[core_path]=code
F[core_path]=F[core_path].replace('candidate.next_bolt==0)','candidate.next_bolt==0 || candidate.next_bolt>kMaxFrames*kMaxUnits+1)')
F[core_path]=F[core_path].replace('unit.hp = static_cast<std::int32_t>(get(bytes,offset,4));','const auto hp=get(bytes,offset,4);\n        if (hp>100) throw std::runtime_error("STATE_HP");\n        unit.hp = static_cast<std::int32_t>(hp);')
F['server/native/frame_sync/frame_core.h']=F['server/native/frame_sync/frame_core.h'].replace('std::size_t target(const Unit& unit) const;','std::size_t target(const Unit& unit, std::uint32_t target_modes=3) const;')
F[core_path]=F[core_path].replace('std::size_t Engine::target(const Unit& unit) const','std::size_t Engine::target(const Unit& unit,std::uint32_t target_modes) const').replace('if (other.hp <= 0 || other.camp == unit.camp)','if (other.hp <= 0 || other.camp == unit.camp || (other.move_mode & target_modes)==0)').replace('const auto index = target(unit);','const auto index = target(unit,def.target_modes);')
# AI把两个空间的决策拆成独立函数，避免寻路/升降/技能选择堆在一个长块中。
code=F[core_path]
begin=code.index('Input Engine::ai('); stop=code.index('void Engine::move(',begin)
ai_block=code[begin:stop]
air_start=ai_block.index('        input.x=sign('); air_stop=ai_block.index('\n    }\n    else if',air_start)
ground_start=ai_block.index('        input.x = sign(other.x-unit.x);'); ground_stop=ai_block.index('\n    }\n    input.skill',ground_start)
code=code[:begin]+'''void Engine::chaseAir(const Unit& unit,const Unit& other,Input& input) const
{
'''+ai_block[air_start:air_stop]+'''
}
void Engine::chaseGround(const Unit& unit,const Unit& other,Input& input)
{
'''+ai_block[ground_start:ground_stop]+'''
}
Input Engine::ai(const Unit& unit)
{
    const auto index=target(unit);
    if (index==state_.units.size()) return {};
    const auto& other=state_.units[index];
    Input input;
    if (unit.move_mode==2) chaseAir(unit,other,input);
    else if (distance2(unit,other)>800*800) chaseGround(unit,other,input);
    input.skill=distance2(unit,other)<=900*900 && other.move_mode==1 ? 1 : 3;
    return input;
}
'''+code[stop:]
F[core_path]=code
header_path='server/native/frame_sync/frame_core.h'
F[header_path]=F[header_path].replace('    void stepUnchecked(Input input);','    void stepUnchecked(Input input);\n    void chaseAir(const Unit& unit,const Unit& other,Input& input) const;\n    void chaseGround(const Unit& unit,const Unit& other,Input& input);')
p='server/native/frame_sync/CMakeLists.txt'
F[p]=F[p].replace('string(SHA256 RULES_HASH "${CORE_HASH}${HEADER_HASH}")','''set(RULES_CONTENT "${CORE_HASH}${HEADER_HASH}")
file(GLOB NAV_HEADERS "${GRID}/*.h")
set(NAV_SOURCES bmap_reader.cpp grid_map.cpp nav_result.cpp dynamic_occupancy.cpp navigation_context.cpp navigation_profile_registry.cpp grid_pathfinder.cpp)
foreach(HEADER IN LISTS NAV_HEADERS)
    file(SHA256 "${HEADER}" NAV_HASH)
    string(APPEND RULES_CONTENT "${NAV_HASH}")
endforeach()
foreach(SOURCE IN LISTS NAV_SOURCES)
    file(SHA256 "${GRID}/${SOURCE}" NAV_HASH)
    string(APPEND RULES_CONTENT "${NAV_HASH}")
endforeach()
string(SHA256 RULES_HASH "${RULES_CONTENT}")''')
gateway_test_path='server/third_party/skynet-flywow/gateway/tests/gateway_async_test.lua'
gateway_test=(R/gateway_test_path).read_text()
gateway_test=gateway_test.replace('local root = assert(arg[1])','local root = assert(arg[1])\npackage.preload["shared.debug.luapanda_debug"] = function() return {start=function() end} end')
gateway_test=gateway_test.replace('ready = function() return true end,','ready = function() return e.ready ~= false end,')
gateway_test=gateway_test.replace('print("GATEWAY_ASYNC_UNIT_OK")',r'''
-- 两连接定向push审计；与旧用例独立，不修改旧用例的fork下标。
e = scenario()
e.streams[10] = frame(1)
e.streams[11] = frame(2)
e.accept(10, "peer-a"); resume(e.forks[2])
e.accept(11, "peer-b"); resume(e.forks[3])
local targeted =
{
    gateway_epoch = e.sends[1][3].gateway_epoch,
    connection_id = e.sends[1][3].connection_id,
    command_id    = 1001,
    request_id    = 0,
    data          = { result = 7 },
}
e.dispatch(0, 7, "send_data", targeted)
assert(#e.writes == 1 and e.writes[1][1] == 10, "target push must not broadcast")
assert(e.writes[1][2] == frame(0), "push preserves request_id zero")
local epoch = targeted.gateway_epoch
targeted.gateway_epoch = "old"
e.dispatch(0, 7, "send_data", targeted)
assert(#e.writes == 1, "old epoch push must be dropped")
targeted.gateway_epoch = epoch
e.ready = false
e.dispatch(0, 7, "send_data", targeted)
assert(#e.writes == 1, "not-ready push must be dropped")
e.ready = true
targeted.connection_id = 0
e.dispatch(0, 7, "send_data", targeted)
assert(#e.writes == 3, "broadcast still reaches both ready connections")
targeted.request_id = 1
e.dispatch(0, 7, "send_data", targeted)
assert(#e.writes == 3, "broadcast cannot pretend to be correlated response")
targeted.connection_id = 1; targeted.request_id = 0
e.dispatch(0, 7, "close", targeted); resume(e.forks[4])
e.dispatch(0, 7, "send_data", targeted)
assert(#e.writes == 3, "closed target must not fall back to broadcast")
targeted.connection_id = 9999
e.dispatch(0, 7, "send_data", targeted)
assert(#e.writes == 3, "unknown target must be dropped")
print("GATEWAY_ASYNC_UNIT_OK")
''')
add(gateway_test_path,'lua','审计定向主动消息，同时保持原异步合同回归。','完整替换测试夹具；所有断言只代表替身单测，不替代真实网络测试。',gateway_test)

header_path='server/native/frame_sync/frame_core.h'
core_path='server/native/frame_sync/frame_core.cpp'
F[header_path]=F[header_path].replace('#include "grid_map.h"','#include "grid_map.h"\n#include "navigation_context.h"')
F[header_path]=F[header_path].replace('    State state_;','    flywow_navigation::NavigationContext context_; // 当前Engine独占A* scratch；不写入State。\n    State state_;')
F[header_path]=F[header_path].replace('Input ai(const Unit& unit) const;','Input ai(const Unit& unit);')
F[core_path]=F[core_path].replace('#include "bmap_reader.h"','#include "bmap_reader.h"\n#include "grid_pathfinder.h"')
F[core_path]=F[core_path].replace(': map_(std::move(map))',': map_(std::move(map)), context_(map_)')
F[core_path]=F[core_path].replace('Input Engine::ai(const Unit& unit) const','Input Engine::ai(const Unit& unit)')
F[core_path]=F[core_path].replace('''        input.x = sign(other.x-unit.x);
        input.z = sign(other.z-unit.z);''','''        auto profile = flywow_navigation::MakeDefaultNavigationProfile(unit.id);
        profile.radius_mm = 200;
        profile.max_step_mm = 600;
        profile.max_slope_permille = 1500;
        const auto path = flywow_navigation::GridPathfinder::FindPathStatic(context_,profile,
            {unit.x,unit.y,unit.z},{other.x,other.y,other.z});
        // 路线不存入逻辑事实：相同当前State重新查询得到相同结果；不可达停住。
        if (path.ok() && path.value.count()>1)
        {
            const auto& next = path.value.WorldPoint(1);
            input.x = sign(next.x_mm-unit.x);
            input.z = sign(next.z_mm-unit.z);
        }''')
cmake_path='server/native/frame_sync/CMakeLists.txt'
F[cmake_path]=F[cmake_path].replace('"${GRID}/nav_result.cpp")','"${GRID}/nav_result.cpp" "${GRID}/dynamic_occupancy.cpp" "${GRID}/navigation_context.cpp" "${GRID}/navigation_profile_registry.cpp" "${GRID}/grid_pathfinder.cpp")')

F['server/native/frame_sync/frame_test.cpp']=F['server/native/frame_sync/frame_test.cpp'].replace('    const auto initial=a.save();','''    const auto initial=a.save();
    assert(a.state().units[0].move_mode==1 && a.state().units[1].move_mode==2);
    const auto born_y=a.state().units[1].y;
    for (int i=0;i<12;++i) a.step({});
    assert(a.state().units[1].y!=born_y); // Server AI确实升降，不固定高度。
    a.restore(initial);''')
add('server/tests/frame_runtime_test.lua','lua','把输入窗口与缺输入规则独立于网络验证。','正式输入记录包含实际采用的补缺结果；不把发送记录冒充确认。',r'''
--- 职责：Frame Runtime无网络聚焦单测；Native替身只控制帧/winner。
package.path = "./?.lua;./lualib/?.lua;" .. package.path
local closed = false
package.preload.lesson_frame_native = function()
    return { open = function()
        local frame = 0
        return {
            step = function() frame = frame + 1; return true end,
            save = function() return string.pack("<I4I4I4",1,frame,0) end,
            close = function() closed = true; return true end,
        }
    end }
end
local core = require "battle.frame_sync.runtime"
local state = assert(core.create({map_path="stub",future_window=8,max_frames=3600}))
assert(core.accept(state,{frame=1,x=1,skill=3}) == "OK")
assert(core.accept(state,{frame=1,x=1,skill=3}) == "OK")
assert(core.accept(state,{frame=1,x=-1}) == "CONFLICT")
assert(core.accept(state,{frame=9}) == "INPUT_WINDOW")
assert(core.accept(state,{frame=2,x=1.5}) == "BAD_INPUT")
assert(core.accept(state,{frame=2,y=1}) == "BAD_INPUT", "ground player cannot inject flight")
local first = assert(core.step(state))
assert(first.supplied and first.input.skill == 3)
assert(core.accept(state,{frame=1}) == "LATE")
for i=1,3 do
    local record = assert(core.step(state))
    assert(not record.supplied and record.input.skill == 0)
    assert(record.input.x == (i<=2 and 1 or 0))
end
assert(#state.records == 4 and state.pending[1] == nil)
core.close(state); core.close(state); assert(closed)
print("FRAME_RUNTIME_OK")
''')

add('server/tests/frame_binding_test.lua','lua','验证真实userdata加载、返回错误和幂等关闭。','Lua State拥有两个独立Engine；非法调用不会借助pcall抛出参数错误。',r'''
--- 职责：真实Native Binding聚焦测试；须在server工作目录使用固定Lua运行。
package.cpath = "./build/frame_sync/?.so;" .. package.cpath
local native = require "lesson_frame_native"
local a = assert(native.open("../shared/navigation/battle_1001/battle_1001.bmap"))
local b = assert(native.open("../shared/navigation/battle_1001/battle_1001.bmap"))
assert(a:save() == b:save())
local before = assert(a:save())
local ok, err = a:step(9,0,0,0)
assert(ok == nil and type(err.code) == "string")
assert(a:save() == before)
assert(a:step(1,0,3,0))
assert(a:save() ~= b:save(), "separate userdata must own separate State")
assert(b:restore(a:save()))
assert(a:save() == b:save())
assert(a:close()); assert(a:close())
ok, err = a:save(); assert(ok == nil and type(err.code) == "string")
assert(b:close())
collectgarbage("collect")
print("FRAME_BINDING_OK")
''')

add('server/tests/frame_sync_integration.py','python','用真实握手、TCP、Gateway、Cluster、Worker与Native证明输入日志能够重演。','定向推送不串场、重连代数、错误凭据、连续帧hash与回放分页。',r'''
# 职责：第三课真实双进程验收客户端；仅Test使用，不成为Runtime协议实现。
# 输入：已启动的Frame Gateway及相同编译产物；输出断言与FRAME_INTEGRATION_OK。
# 本测试的通用wire解析器只用于避免测试环境另装Python Protobuf；业务合同仍来自唯一Proto。
from pathlib import Path
import ctypes
import socket
import struct
import time
from gateway_handshake_client import perform

ROOT = Path(__file__).resolve().parents[2]

def varint(value):
    result=bytearray()
    while value>127: result.append((value&127)|128); value>>=7
    result.append(value)
    return bytes(result)

def number(field,value): return varint(field<<3)+varint(value)
def blob(field,value): return varint((field<<3)|2)+varint(len(value))+value
def zigzag(value): return (value<<1)^(value>>31)

def fields(data):
    result={}; offset=0
    def read():
        nonlocal offset
        value=0; shift=0
        while True:
            byte=data[offset]; offset+=1; value|=(byte&127)<<shift
            if byte<128: return value
            shift+=7
            assert shift<=63
    while offset<len(data):
        tag=read(); field,wire=tag>>3,tag&7
        if wire==0: value=read()
        elif wire==2:
            size=read(); value=data[offset:offset+size]; offset+=size
        elif wire==5: value=struct.unpack_from('<I',data,offset)[0]; offset+=4
        elif wire==1: value=struct.unpack_from('<Q',data,offset)[0]; offset+=8
        else: raise AssertionError('unsupported wire')
        result.setdefault(field,[]).append(value)
    return result

def one(data,field,default=0): return data.get(field,[default])[0]

class Client:
    def __init__(self):
        self.sock=socket.create_connection(('127.0.0.1',19021),timeout=3)
        self.sock.settimeout(3); self.sock.setsockopt(socket.IPPROTO_TCP,socket.TCP_NODELAY,1)
        self.seq=0; self.pushes=[]
        perform(self.send,self.receive)
    def exact(self,size):
        data=b''
        while len(data)<size:
            part=self.sock.recv(size-len(data)); assert part,'unexpected EOF'; data+=part
        return data
    def send(self,data): self.sock.sendall(struct.pack('>H',len(data))+data)
    def receive(self): return self.exact(struct.unpack('>H',self.exact(2))[0])
    def send_request(self,command,body):
        self.seq+=1
        self.send(number(1,3)+number(2,command)+number(3,self.seq)+blob(4,body))
        return self.seq
    def request(self,command,body):
        request_id=self.send_request(command,body)
        for _ in range(100):
            env=fields(self.receive()); response=fields(one(env,4,b''))
            if one(env,3)==0:
                assert one(env,2)==1103; self.pushes.append(response); continue
            assert one(env,3)==request_id and one(env,2)==command
            return response
        raise AssertionError('control starved')
    def push(self):
        if self.pushes: return self.pushes.pop(0)
        env=fields(self.receive()); assert one(env,3)==0 and one(env,2)==1103
        return fields(one(env,4,b''))
    def close(self): self.sock.close()

class Native:
    def __init__(self):
        self.lib=ctypes.CDLL(str(ROOT/'server/build/frame_sync/libframe_core.so'))
        self.lib.fs_open.argtypes=[ctypes.c_char_p]; self.lib.fs_open.restype=ctypes.c_void_p
        self.lib.fs_close.argtypes=[ctypes.c_void_p]
        self.lib.fs_step.argtypes=[ctypes.c_void_p,ctypes.c_int,ctypes.c_int,ctypes.c_int]
        self.lib.fs_save.argtypes=[ctypes.c_void_p,ctypes.c_void_p,ctypes.c_int]
        self.lib.fs_restore.argtypes=[ctypes.c_void_p,ctypes.c_void_p,ctypes.c_int]
        self.handle=self.lib.fs_open(str(ROOT/'shared/navigation/battle_1001/battle_1001.bmap').encode())
        assert self.handle
    def restore(self,data): assert self.lib.fs_restore(self.handle,data,len(data))==1
    def save(self):
        out=ctypes.create_string_buffer(16384); size=self.lib.fs_save(self.handle,out,len(out)); assert size>0
        return out.raw[:size]
    def step(self,record):
        command=fields(one(record,1,b''))
        def signed(field):
            value=one(command,field); return (value>>1)^-(value&1)
        assert self.lib.fs_step(self.handle,signed(2),signed(3),one(command,4))==1
        state=self.save(); digest=2166136261
        for byte in state: digest=((digest^byte)*16777619)&0xffffffff
        assert digest==one(record,3),'STATE_DIVERGENCE'
    def close(self): self.lib.fs_close(self.handle)

def run():
    first=second=reconnected=engine=None
    try:
        first=Client(); a=first.request(1101,number(1,1001)); assert one(a,1)==b'OK'
        second=Client(); b=second.request(1101,number(1,1001)); assert one(b,1)==b'OK'
        battle=one(a,2); generation=one(a,4); token=one(a,3); assert len(token)==32
        assert battle!=one(b,2)
        engine=Native(); engine.restore(one(a,10)); frame=one(a,9)
        # Server正式采用的输入是回放来源；测试不以发送的输入代替它。
        for _ in range(16):
            target=frame+3
            command=number(1,target)+number(2,zigzag(1))+number(4,2)
            first.send_request(1102,number(1,battle)+number(2,generation)+blob(3,command))
            push=first.push(); assert one(push,1)==battle and one(push,2)==generation
            assert one(push,4)==b'OK'
            for raw in push.get(3,[]):
                record=fields(raw); f=one(fields(one(record,1,b'')),1)
                assert f==frame+1; engine.step(record); frame=f
            other=second.push(); assert one(other,1)==one(b,2),'cross battle broadcast'
        assert frame>=16
        first.close(); first=None
        reconnected=Client()
        denied=reconnected.request(1104,number(1,battle)+blob(2,b'x'*32))
        assert one(fields(one(denied,1,b'')),1)==b'NOT_FOUND'
        recovered=reconnected.request(1104,number(1,battle)+blob(2,token))
        current=fields(one(recovered,1,b'')); assert one(current,1)==b'OK'
        assert one(current,4)==generation+1 and one(current,9)>=frame
        engine.restore(one(current,10)); frame=one(current,9)
        push=reconnected.push()
        assert one(push,1)==battle and one(push,2)==generation+1
        for raw in push.get(3,[]): engine.step(fields(raw))
        replay=reconnected.request(1106,number(1,battle)+blob(2,token)+number(3,0))
        assert one(replay,1)==b'OK' and one(replay,3)>0
        initial=fields(one(replay,4,b'')); assert one(initial,3,b'')==b''
        engine.restore(one(initial,10)); expected=0
        for raw in replay.get(2,[]):
            record=fields(raw); expected+=1
            assert one(fields(one(record,1,b'')),1)==expected
            engine.step(record)
        assert expected==one(replay,3)
        print('FRAME_INTEGRATION_OK frames=',expected,'generation=',one(current,4))
    finally:
        for value in [first,second,reconnected,engine]:
            if value: value.close()

if __name__=='__main__': run()
''')
