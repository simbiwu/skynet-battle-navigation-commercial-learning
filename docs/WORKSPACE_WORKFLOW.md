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

WSL 主编辑源：

```text
~/workspace/skynet-battle-navigation-commercial-learning/
```

负责：

```text
server/
server/third_party/skynet-flywow/   # FlyWow 子模块
docs/
codex/
shared/protocol/                    # 协议源和 Server 生成物
根目录脚本、课程工具及其它非 Unity 文件
```

Windows 主编辑源只保留 Unity 相关内容：

```text
G:\simbi\dev\skynet-battle-navigation-commercial-learning\unity/
G:\simbi\dev\skynet-battle-navigation-commercial-learning\shared/navigation/
G:\simbi\dev\skynet-battle-navigation-commercial-learning\shared/protocol/generated/unity/
```

Windows 侧负责 Unity Editor、场景、Prefab、Unity 测试，以及 Unity Bake/Export 产生的导航资产。WSL 侧负责 Server、FlyWow、文档、协议源和所有非 Unity 修改。Windows 工作区的非 Unity 文件只通过 Git 同步，不作为直接编辑源。

同一文件不能在两个工作区同时维护。Unity 导出的 `shared/navigation/` 资产必须先在 Windows 验证、提交并推送，WSL 再同步后供 Server 使用。

## 2.1 FlyWow 子模块规则

FlyWow 的唯一项目内编辑位置是：

```text
~/workspace/skynet-battle-navigation-commercial-learning/server/third_party/skynet-flywow/
```

独立的：

```text
/home/simbi/workspace/skynet-flywow
```

不再作为本项目开发源。需要修改 FlyWow 时，先在主仓库的子模块内切换到工作分支并检查状态；完成后按以下顺序提交：

```text
1. 在子模块内提交并推送 FlyWow；
2. 回到主仓库，更新 submodule 指针；
3. 提交并推送主仓库；
4. Windows 工作区 pull，Unity 再消费同步后的资产。
```

主仓库只记录 FlyWow 的提交指针，不把子模块目录重新初始化为主仓库目录，也不直接提交子模块内部文件到主仓库。

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

一个任务同时涉及 Unity 和 Server 时：

```text
1. 先确认 WSL 主仓库、FlyWow 子模块和 Windows Unity 工作区的状态。
2. WSL 先完成 Server、FlyWow、文档等修改并验证；FlyWow 子模块先提交推送，再提交主仓库指针。
3. Windows 再 pull 主仓库；Unity 修改和资产导出完成后，在 Windows 提交推送。
4. WSL 最后 pull Unity 提交，Server 使用已同步的 `shared/` 资产。
5. 完成后确认两个主仓库工作区和 FlyWow 子模块都干净，且 submodule 指针对应已推送提交。
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
