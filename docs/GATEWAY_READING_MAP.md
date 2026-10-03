# Gateway 阅读路线图

本文件解决的问题：让读者可以沿一条真实调用链阅读 Gateway、Proxy 和 Battle Dispatch，而不需要在多个 Service 之间猜测下一跳。

## 先看哪几个文件

```text
server/service/gateway/gateway_main.lua
  -> server/service/gateway/gateway_proxy.lua
  -> server/third_party/skynet-flywow/service/gateway/flywow_gateway.lua
  -> server/third_party/skynet-flywow/lualib/gateway/handshake.lua
  -> server/third_party/skynet-flywow/lualib/gateway/codec.lua
  -> server/service/battle/battle_dispatch.lua
  -> server/service/battle/navigation_query.lua / battle_mgr.lua
```

## 启动链

```text
battle_main
  -> navigation_query.ready
  -> battle_mgr.ready
  -> battle_dispatch.configure/ready
  -> cluster.register("battle_dispatch")

gateway_main
  -> gateway_proxy.start
  -> cluster.call(battle_dispatch, "ready")
  -> gateway_proxy.bind_gateway
  -> flywow_gateway.start
  -> socket.listen/socket.start
```

## 客户端连接链

```text
accept_client
  -> create_connection
  -> handshake.accept
  -> run_tcp 或 websocket.accept
  -> process_handshake
  -> handshake.confirm
  -> ready
```

## ready 后的业务链

```text
read_exact
  -> dispatch_payload
  -> codec.decode_envelope
  -> registry.find
  -> codec.decode_request
  -> skynet.send(handler, "gateway_dispatch", payload)
  -> gateway_proxy.dispatch_remote
  -> cluster.send(battle_dispatch, "gateway_dispatch", payload)
  -> battle_dispatch.forward_result
  -> cluster.send(gateway_proxy, "battle_result", token, result)
  -> endpoint.context:reply
  -> flywow_gateway.deliver_response
  -> codec.encode_response
  -> socket.write/websocket.write
```

## 读代码时先回答的四个问题

1. 当前对象归哪个 Service、Lua State 或 Native userdata 所有？
2. 当前调用是否可能 yield？yield 返回后重新验证了什么身份？
3. 失败是回业务错误、丢弃迟到结果，还是摘除并关闭连接？
4. 当前字段是 fd、connection_id、request_id 还是 route_token？它们不能互换。

## 验证入口

```text
server/third_party/skynet-flywow/tests/gateway_handshake_test.lua
server/tests/gateway_proxy_test.lua
server/tests/gateway_async_integration.py
```

先运行握手状态机和 Proxy 合同测试，再运行真实 TCP/WS 集成测试。聚焦测试不能替代容量、长期 soak 或 IL2CPP 验证。
