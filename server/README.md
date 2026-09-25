# Battle Navigation Server

这里是课程的 WSL/Linux Server 工程。仓库根目录下的三个主要边界为：

```text
unity/BattleNavigation/   Unity Authoring 与后续客户端表现
server/                   C++、Lua、Skynet、协议与 Server 测试
docs/                     课程正文、格式合同与架构说明
```

`third_party/`、`build/`、生成的 Protobuf descriptor 和 Native 二进制不提交。依赖版本由 `protocol/VERSIONS.env` 与 `scripts/linux/` 下的 bootstrap/build 脚本固定。

Server 内部目录按运行身份划分：

```text
service/   由 newservice/uniqueservice 启动的 Service 入口
lualib/    Service Lua State 内通过 require 加载的普通模块
protocol/  .proto 源、版本和生成物
config/    Skynet 进程配置与只读业务配置
native/    C++ Runtime 与 Lua C Binding
```

在 WSL 中从本目录执行：

```bash
./scripts/linux/bootstrap_skynet.sh
./scripts/linux/bootstrap_protocol_tools.sh
./scripts/linux/build_lua_protobuf.sh
./native/grid_map/make_test.sh

cmake -S native/lua_battle_nav -B build/lua_battle_nav -DCMAKE_BUILD_TYPE=Debug
cmake --build build/lua_battle_nav -j"$(nproc)"
```

预期结果：

```text
grid_map_test: passed
build/lua_battle_nav/battle_nav.so: generated
```

本目录不提交 Unity 导出的临时 BMAP。需要联调时，按第一课实操文档把指定版本的 BMAP 发布到 `maps/`，再由 `BMapReader` 在加载阶段校验格式和 CRC。
