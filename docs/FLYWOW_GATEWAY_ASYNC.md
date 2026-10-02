# FlyWow Gateway 数据面合同

## 职责边界

Gateway 只负责连接、握手、心跳、协议解码、协议编码、转发、指定连接发送和广播。

Gateway 不保存业务请求，不创建 pending，不生成 route_token，不等待 Battle 结果，也不判断业务成功、失败或超时。

## 统一内部接口

业务数据统一使用 send_data：

    {
        gateway_epoch = "...",
        connection_id = 123,
        command_id = 1001,
        data = {...},
    }

连接控制使用 close：

    {
        gateway_epoch = "...",
        connection_id = 123,
    }

gateway_epoch 用于隔离 Gateway 重启前的迟到消息；connection_id 只在当前 Gateway 实例内有效。

## Gateway 到 Battle

Gateway 解码客户端 Envelope 后，通过 Proxy 使用一次 send_data：

    Gateway -> Proxy -> Battle

数据包含：

- gateway_epoch
- connection_id
- command_id
- 解码后的 data

Gateway 不缓存这些业务数据。

## Battle 到 Gateway

Battle 处理完成后，使用同一个 send_data：

    Battle -> Proxy -> Gateway -> Client

Battle 可以发送：

- 请求处理结果
- 服务端主动下发
- 广播消息

Gateway 不区分这三种情况。

## 指定发送和广播

    connection_id = 123

发送给指定连接。

    connection_id = 0

广播给当前 Gateway 中所有已经握手成功且仍然有效的连接。

广播不创建任何业务状态；某个连接写失败不影响其他连接。

## 主动关闭连接

Battle 使用 close 通知 Gateway 关闭指定连接。Gateway 只校验连接身份、摘除连接并关闭底层传输。

## 协议 Envelope

客户端 Envelope 只包含：

    message Envelope {
      uint32 protocol_version = 1;
      uint32 command = 2;
      bytes body = 3;
    }

客户端只根据 command 选择消息类型。请求响应关联不进入客户端协议。

## CommandId 注册

生成器根据消息是否存在建立映射：

- XxxRequest 和 XxxResponse 都存在：请求-响应命令
- 只有 XxxRequest：单向请求
- 只有 XxxResponse：服务端主动下发命令

不使用 service/rpc、自定义 option 或 request_id。

## 业务职责

Battle 自己决定：

- 是否返回
- 什么时候返回
- 是否主动推送
- 是否广播
- 业务超时如何处理
- 业务失败如何编码

Gateway 只负责可靠地完成本地连接层的接收和发送。
