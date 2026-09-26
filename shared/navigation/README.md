# 共享导航资产

本目录保存 Unity Authoring 流水线验证通过并准备交给 Server 使用的不可变导航资产。每张地图使用独立目录，例如 `battle_1001/`，其中 BMAP 与 manifest 必须成对提交。

Bake 发生在 Unity 编辑器进程中，但 Server 只读取 Git 更新得到的发布版本。两端是否位于同一台机器不影响这个合同。修改场景或重新 Bake 后，先检查 Overlay、Validator、manifest 和二进制差异，再提交；未提交的本地 Bake 不会改变其他机器正在运行的 Server。
