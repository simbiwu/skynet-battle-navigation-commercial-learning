# Workspace Workflow

本文件记录本项目的**本机双工作区、编辑源和 Git 同步规则**。只有涉及修改位置、同步、提交、Push、跨 Windows/WSL 协作时才需要读取；普通算法分析和局部代码阅读不需要加载本文件。

## 1. 两个完整 Git 工作区

项目在当前开发机维护两个完整工作区，但每类文件只有一个编辑源：

```text
Windows:
G:\simbi\dev\skynet-battle-navigation-commercial-learning

WSL:
~/workspace/skynet-battle-navigation-commercial-learning
```

WSL 必须保留完整主仓库结构，Server 位于：

```text
~/workspace/skynet-battle-navigation-commercial-learning/server/
```

旧目录：

```text
~/workspace/skynet-battle-navigation-serve
```

不再作为开发源。

## 2. 唯一编辑源

Windows 主编辑源：

```text
docs/
unity/
shared/navigation/
shared/protocol/generated/unity/
codex/
根目录课程文档
文档/课程生成工具
```

WSL 主编辑源：

```text
server/
shared/protocol/ 源文件
shared/protocol/ Server 生成物
```

规则：

- 文档、课程规范和 Unity 修改只在 Windows 主工作区完成；
- `server/` 下 Lua、C++、协议、配置、构建脚本和测试只在 WSL 主工作区完成；
- Windows 工作区的 `server/` 只通过 Git 更新，不作为直接编辑源；
- 同一文件在两个工作区不能同时维护两份实现；
- 跨文档与 Server 的任务分别在各自编辑源完成并验证，通过 Git 同步；
- 不用目录复制覆盖另一侧未提交内容。

## 3. 本机路径不是 Runtime 合同

不得把以下内容写入 Runtime 配置或发布资产：

```text
G:\...
/mnt/g/...
~/workspace/...
另一工作区绝对路径
```

双工作区只是开发安排，不是部署拓扑。

真实部署必须允许：

```text
Unity Authoring
Build Machine
Server Runtime
```

位于不同机器。

## 4. 跨端共享资产

共享内容通过仓库根目录 `shared/` 和 Git/发布包交付：

```text
shared/protocol/
shared/navigation/
```

“共享”表示相同 Git 提交、业务版本和内容 hash，不表示运行时跨机器读取工作目录。

Unity Bake 产生本地候选资产；只有在验证、提交并同步后，Server 才消费相同版本。

## 5. Git 同步规则

在两个工作区都可能参与同一次任务时，Commit/Push 前检查：

```text
当前分支
HEAD
未提交修改
远端分叉
submodule 状态（适用时）
```

同一远端分支必须串行同步：

```text
A 工作区完成并提交
-> Push
-> B 工作区 Pull/Rebase 到新 HEAD
-> B 再继续修改
```

禁止：

```text
Windows 和 WSL 基于同一个旧 HEAD 各自修改同一远端分支后同时 Push
通过复制目录解决 Git 分叉
为了“同步方便”覆盖未提交文件
未经用户明确要求自动 commit / push
```

## 6. 跨工作区任务建议

一个任务同时涉及文档和 Server 时：

```text
1. 先确认当前两个工作区的状态。
2. 在对应唯一编辑源分别完成修改。
3. 每一侧先做本地验证。
4. 选择一个明确的提交顺序。
5. 第一个工作区提交并 Push 后，另一个工作区先同步远端。
6. 再完成第二侧提交。
```

如果发现任一工作区有与当前任务无关的未提交修改，不覆盖、不清理；先报告冲突风险。

## 7. Server 子目录不能再拆成独立 Git 仓库

以下目录属于主仓库的一部分：

```text
server/service/
server/lualib/
server/native/
server/protocol/
server/config/
```

不得把其中任意目录重新初始化成独立 Git 仓库。

FlyWow 是例外：它本身是独立仓库，通过 `server/third_party/skynet-flywow` submodule 固定版本。具体规则见：

```text
docs/FLYWOW_EXTRACTION_POLICY.md
```
