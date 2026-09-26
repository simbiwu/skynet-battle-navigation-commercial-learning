# VS Code Git 实操：给长期使用 SVN 的开发者

这份文档只解决本课程日常版本管理。目标不是背 Git 命令，而是理解 Git 与 SVN 的工作模型差异，并能在 VS Code 中安全完成查看改动、暂存、提交、同步、分支和冲突处理。

当前仓库只有本地 `main` 分支，暂时没有远程仓库。远程地址由项目所有者之后提供；在此之前不执行 `push`，也不随便创建 GitHub/Gitee 仓库。

## 1. 先改掉一个最容易出错的 SVN 心智模型

SVN 常见流程：

```text
Working Copy
-> Commit
-> 中央仓库立即收到提交
```

Git 流程多一层本地仓库：

```text
Working Tree
-> Stage / Index
-> Commit 到本地仓库
-> Push 到远程仓库
```

因此 Git 的 `commit` 不等于 SVN 的 `commit`：

```text
git commit = 写入本机 .git 历史
git push   = 把本地提交发送到远程
```

断网时 Git 仍然可以查看历史、创建分支和提交。只有 fetch/pull/push 等远程动作需要网络。

## 2. SVN 与 Git 操作对照

| 目的 | SVN | Git | VS Code |
|---|---|---|---|
| 取得项目 | Checkout | Clone | `Git: Clone` |
| 查看状态 | Check for Modifications | `git status` | Source Control 列表 |
| 查看差异 | Diff | `git diff` | 单击 changed file |
| 选择本次提交内容 | changelist/选择文件 | Stage | 文件右侧 `+` |
| 提交 | Commit 到服务器 | Commit 到本地 | 输入消息后 Commit |
| 上传提交 | Commit 已经上传 | `git push` | Sync/Push |
| 获取远程变化 | Update | `git pull` | Pull/Sync |
| 只刷新远程信息 | 无完全相同概念 | `git fetch` | Fetch |
| 切换开发线 | Switch | switch/checkout branch | 左下角分支名 |
| 忽略文件 | svn:ignore | `.gitignore` | 编辑 `.gitignore` |
| 回退未提交修改 | Revert | Restore | Discard Changes |

特别注意：SVN 的 `revert` 通常指丢弃工作副本修改；Git 的 `git revert` 是“创建一个反向提交”。要丢弃未提交文件，Git 使用 `restore`。这两个名字最容易让 SVN 用户误操作。

## 3. 仓库中的三块区域

### 3.1 Working Tree

你正在编辑的实际文件。VS Code Source Control 中 `Changes` 下面的文件通常属于这里。

### 3.2 Stage / Index

下一次 commit 的精确内容。VS Code 中显示为 `Staged Changes`。

Stage 不是服务器上的临时区，也不是备份。它只是告诉 Git：“下一次提交包含这些改动”。同一个文件甚至可以只 Stage 一部分行。

### 3.3 Local Repository

`.git/` 中保存的本地提交历史。执行 Commit 后内容进入这里，但远程仓库仍然不知道。

日常流程：

```text
编辑
-> 查看 diff
-> Stage 相关文件
-> 再看 staged diff
-> Commit
-> 有远程时 Push
```

## 4. 用 VS Code 打开正确的仓库

在 PowerShell 中：

```powershell
Set-Location '<你克隆仓库的目录>'
$repoRoot = (git rev-parse --show-toplevel).Trim()
Set-Location $repoRoot
code .
```

必须打开仓库根目录，而不是只打开 `docs/` 或 Unity 的 `Assets/`。正确时 VS Code Explorer 顶部能同时看到：

```text
docs/
codex/
unity/
README.md
AGENTS.md
.gitignore
```

左侧点击分叉形状的 `Source Control` 图标，快捷键：

```text
Ctrl+Shift+G
```

左下角应显示当前分支 `main`。

## 5. 每次开始工作先检查状态

终端命令：

```bash
git status --short
git branch --show-current
git log --oneline -5
```

`git status --short` 常见标记：

```text
??  Git 从未跟踪的新文件
 M  Working Tree 中已修改，尚未 Stage
M   已 Stage，等待 Commit
MM  同一文件既有已 Stage 修改，又有未 Stage 修改
 D  Working Tree 中删除
D   删除操作已 Stage
```

前两列有明确含义，不要只看到 `M` 就认为已经进入提交。

VS Code 中对应查看 `Changes` 和 `Staged Changes`。如果列表数量异常大，例如出现成千上万个 Unity `Library` 文件，应停止操作并检查 `.gitignore`，不要全部 Stage。

## 6. 查看修改，而不是直接提交

在 Source Control 中单击一个修改文件，VS Code 会打开左右差异：

```text
左侧：上次提交/Index 中的旧内容
右侧：当前新内容
红色：删除
绿色：新增
```

终端等价命令：

```bash
git diff
git diff -- docs/VS_CODE_GIT_FOR_SVN.md
git diff --stat
```

Stage 以后，普通 `git diff` 不再显示那部分内容；要查看准备提交的内容：

```bash
git diff --cached
git diff --cached --stat
```

提交前至少回答：

```text
这些文件是否属于同一个目的？
有没有 Unity Library、日志、密码或本机路径？
有没有调试代码和临时文件？
删除是否是有意的？
```

## 7. Stage：选择下一次提交内容

### 7.1 VS Code 操作

在 `Changes` 中：

- 文件右侧点击 `+`：Stage 单个文件；
- `Changes` 标题右侧点击 `+`：Stage 全部；
- 已 Stage 文件右侧点击 `-`：Unstage，文件修改仍然保留。

第一次学习时优先逐个文件 Stage，避免把无关修改混进提交。

### 7.2 命令行操作

```bash
git add docs/VS_CODE_GIT_FOR_SVN.md
git add README.md
git status --short
```

`git add .` 会把当前目录以下所有新增、修改和删除都加入 Stage。只有完整检查过状态时才使用。

撤销 Stage，但保留文件修改：

```bash
git restore --staged README.md
```

这接近“从 SVN 提交列表取消勾选”，不会删除你的编辑内容。

## 8. Commit：写入本地历史

### 8.1 Commit 消息

消息说明这次提交完成的行为，不写“update”“修改文件”“test”。本课程示例：

```text
chore: initialize battle navigation course repository
docs: explain navmesh authoring for server developers
feat: add Battle_1001 authoring scene
test: cover bmap crc corruption
fix: use floor division for negative world coordinates
```

常用前缀只是团队约定：

```text
feat   新行为
fix    修复错误
docs   只改文档
test   测试
build  构建或依赖
chore  仓库维护
```

### 8.2 VS Code 提交

1. 检查 `Staged Changes`；
2. 在 Source Control 顶部输入 Commit 消息；
3. 点击 `Commit`；
4. 再看状态是否干净。

如果 VS Code 询问是否自动 Stage 所有文件，第一次学习请选择取消，回到列表明确选择文件。

命令行等价操作：

```bash
git commit -m "docs: explain navmesh authoring for server developers"
git status
git log --oneline -3
```

Commit 后没有网络传输。看到 `working tree clean` 只表示本地没有未提交修改。

## 9. `.gitignore` 与 Unity 工程

本仓库根目录和 Unity 工程目录都提供 `.gitignore`。Unity 中通常提交：

```text
Assets/
Packages/manifest.json
Packages/packages-lock.json
ProjectSettings/
```

通常不提交：

```text
Library/
Temp/
Logs/
UserSettings/
*.csproj
*.sln
```

为什么：`Library` 是本机根据 Assets、Packages 和 ProjectSettings 生成的缓存，体积大且包含机器相关状态。删除后 Unity 可以重新导入生成。

检查某个文件为什么被忽略：

```bash
git check-ignore -v unity/BattleNavigation/Library/SourceAssetDB
```

`.gitignore` 只影响尚未被 Git 跟踪的文件。已经提交过的文件，后来加 ignore 不会自动移除。

## 10. 安全地撤销未提交修改

VS Code 中 `Discard Changes` 会丢弃工作区修改，通常不可恢复。点击前先打开 diff，确认目标文件。

命令行恢复单个文件：

```bash
git restore docs/某个文件.md
```

恢复所有未提交文件是高风险操作，本课程不使用 `git reset --hard`，也不把整个仓库作为 restore 目标。

如果只是暂时不想提交，可使用 Stash，但初学阶段优先创建清晰的小提交。Stash 示例：

```bash
git stash push -m "wip: navmesh notes"
git stash list
git stash pop
```

未跟踪的新文件默认不会进入 stash，需要额外参数；因此执行前仍要看 `git status`。

## 11. 分支：Git 与 SVN branch 的差别

Git 分支只是指向某个提交的轻量引用，不会像传统 SVN 分支那样复制整个服务器目录。

创建并切换分支：

```bash
git switch -c lesson1/navmesh-authoring
```

查看：

```bash
git branch
git status
```

切回 main：

```bash
git switch main
```

VS Code 可以点击左下角分支名，再选择 `Create new branch` 或现有分支。切换前最好保持工作区干净，避免未提交修改一起被带到另一个分支。

课程建议分支名：

```text
lesson1/navmesh-authoring
lesson1/bmap-reader
lesson1/protobuf-query
fix/bmap-negative-coordinate
```

## 12. 配置远程仓库：等地址提供后再做

先查看当前远程：

```bash
git remote -v
```

当前预期没有输出。拿到远程 URL 后执行一次：

```bash
git remote add origin <REMOTE_URL>
git remote -v
git push -u origin main
```

`-u` 建立本地 `main` 与 `origin/main` 的跟踪关系。以后可以直接使用 `git push` 和 `git pull`。

如果 `origin` 已经存在，不要重复 add 或直接覆盖：

```bash
git remote get-url origin
```

先核对它是否是项目所有者提供的地址。需要修改时再明确执行：

```bash
git remote set-url origin <REMOTE_URL>
```

## 13. Fetch、Pull、Push

### Fetch

```bash
git fetch origin
```

只下载远程提交和分支信息，不改当前 Working Tree。它是检查远端变化最安全的第一步。

### Pull

```bash
git pull --ff-only
```

下载并更新当前分支。课程默认使用 `--ff-only`，如果本地和远端已经分叉就明确失败，不自动制造一个意外 merge commit。

### Push

```bash
git push
```

上传已经 commit 的本地提交。未 commit 的 Working Tree 修改不会被 push。

VS Code 的 `Sync Changes` 往往组合 Pull 和 Push。初学时优先分别执行 Fetch、Pull、Push，这样能看清每一步的影响。

## 14. 冲突处理

冲突不是文件损坏，而是 Git 无法自动判断两边修改应该怎样合并。

出现冲突后：

```bash
git status
```

VS Code 会把文件列在 `Merge Changes`，并提供：

```text
Accept Current   接受当前分支内容
Accept Incoming  接受合入分支内容
Accept Both      两边都保留，仍需人工整理
Compare Changes  查看差异
```

不要不看内容就点 `Accept Both`，否则 C#、Lua 或 JSON 可能出现重复代码。正确流程：

1. 理解双方修改目的；
2. 编辑成最终正确内容；
3. 搜索并清除 `<<<<<<<`、`=======`、`>>>>>>>`；
4. 编译或运行相关测试；
5. Stage 已解决文件；
6. 完成 merge/rebase 要求的提交。

检查是否还有冲突标记：

```bash
rg -n "^(<<<<<<<|=======|>>>>>>>)" .
```

## 15. 查看历史和定位改动

```bash
git log --oneline --decorate --graph --all -20
git show <commit-id>
git log -- docs/BMAP_FORMAT.md
git blame docs/BMAP_FORMAT.md
```

VS Code 文件编辑器右上角可以打开 Timeline，查看该文件的提交历史。GitLens 等扩展不是完成课程的前置条件，先掌握内置 Source Control。

## 16. 本课程每个阶段的提交节奏

一次提交只完成一个可说明、可检查的目的：

```text
chore: initialize course repository
feat: create Battle_1001 authoring scene
feat: export versioned bmap asset
feat: load immutable grid map in native module
feat: expose grid query to skynet
feat: query skynet from unity with protobuf
test: complete lesson one acceptance suite
```

不要等整课结束才提交一个巨大 commit。小提交能让你定位哪一步破坏了坐标、协议或资产格式，也便于以后 review 和 revert。

## 17. 提交前检查清单

```text
[ ] git branch --show-current 是预期分支
[ ] git status --short 已逐项看过
[ ] 新文件和删除都符合预期
[ ] git diff 已检查未 Stage 修改
[ ] git diff --cached 已检查待提交内容
[ ] 没有 Library、Temp、日志、密钥、token 或本机缓存
[ ] 相关构建或测试已经执行
[ ] Commit 消息说明行为
[ ] Commit 后 git status 符合预期
[ ] 有远程时才执行 Push
```

## 18. 当前仓库的下一步

当前只需要本地工作：

```bash
git status
git log --oneline --decorate -5
git remote -v
```

预期 `main` 已有初始化提交，`git remote -v` 没有输出。项目所有者提供 URL 后，再从第 12 节开始配置 `origin` 和首次 Push。
