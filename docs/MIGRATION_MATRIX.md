# 数据迁移与恢复验证矩阵

更新：2026-09-27。本表只描述当前 Godot 开发期 JSON 双槽状态；它不是正式 SQLite、Android Room 或服务器 PostgreSQL 的迁移验收。

| 情况 | 本地实际运行结果 | 证据 | 仍需验证 |
|---|---|---|---|
| Schema v1 读取并迁移到 v2 | 内存迁移；读取不覆盖旧槽，账户 ID、事件 ID 和 `123.45` 十进制金额保留 | `tests/data/test_store_fault_matrix.gd` | 多个已发布版本、全部资产类型与 10000 条流水 |
| 迁移后保存 | 以期望 generation 写入另一槽，写后校验 | 同上及 `tests/data/test_store.gd` | 进程被系统杀死、断电和真实文件系统同步语义 |
| 最新槽写入中断/损坏 | 截断最新槽后读取上一完整 generation，并标记 `recovered` | `test_store_fault_matrix.gd` | Android 真实杀进程矩阵与多进程并发写入 |
| 旧槽损坏 | 保留最新完整 generation、事件与金额 | 同上 | 真实闪存损坏和目录不可用 |
| 未知未来 Schema | 较新未来版本阻止旧代码继续保存；损坏的未来槽可回退完整旧版 | 同上 | 正式升级策略和用户可操作的恢复界面 |
| 明文完整导出与恢复 | 本地预览、损坏/未来版本拒绝、恢复前安全副本的独立测试与个人页面测试通过；新导出清单声明来源 generation，旧清单可读但版本未知 | `game/tests/backup/run_backup_tests.gd`、`game/tests/integration/run_personal_backup_restore_scene.gd` | 认证加密、密码错误、Android 系统文件选择器及干净安装恢复 T30/T31 |

本地运行：`./scripts/verify.ps1 -Scope core`。当前 JSON 双槽只提供开发期快照和单进程 generation 检查；`save_project` 的跨进程读改写不是数据库事务。正式账本须建立只追加迁移历史、已发布样本库、迁移前可恢复备份、失败回滚、并发事务和跨版本自动测试。任何正式迁移不得通过删除用户数据库重建。
