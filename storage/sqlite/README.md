# SQLite 事务过渡层（未接入游戏运行时）

`migrations/0001_snapshot_bridge.sql` 是把当前完整项目快照与最小展示载荷同事务保存的**开发期过渡结构**，不是规格第 11 章全部实体的正式数据库。`test_snapshot_bridge.py` 只用 Python 标准库 SQLite 验证 SQL 约束、预期 generation 冲突、事务回滚与一致性备份；它不证明 Godot/Android 已能打开数据库。

拟定的运行时路径是固定版本的 Godot SQLite GDExtension。仓库尚无该扩展，也未验证 Godot 4.7.2 Windows ABI 或 Android 动态壁纸宿主。正式接入前需记录插件二进制哈希、MIT 许可证和内嵌 SQLite 版本；对个人项目须采用独立数据库，旧双槽 JSON 保留为只读迁移来源。导入验证 ID、账本事件、十进制金额、金豆守恒和展示快照一致后，才切换读写入口。后续按编号迁移拆出规格所列账户、事件、报价、估值、库存、对账和审计实体，已发布迁移不得原地修改。

事务顺序：`BEGIN IMMEDIATE` → 读取当前 generation → 比较调用方期望版本 → 同一事务保存项目与最小展示载荷 → `COMMIT`。失败回滚并保留旧数据；使用绑定参数，不把金融数字转成 SQL `REAL`。当前测试使用 SQLite 默认回滚日志、`synchronous=FULL`、`foreign_keys=ON`。未来壁纸只短暂读取 `published_display` 的一个已提交版本，并缓存用于绘制。

不要在未升级内嵌 SQLite 并完成多进程压力测试前启用 WAL：截至本阶段调研，[SQLite 官方 WAL 文档](https://www.sqlite.org/wal.html#the_wal_reset_bug)记录旧版本多连接并发时的罕见损坏问题。活跃数据库备份应使用 [SQLite backup API](https://www.sqlite.org/backup.html)，不能只复制数据库主文件。当前 Python 测试中的备份调用只是接口演练；认证加密、真机恢复和发布级迁移仍未实现。

本机验证：`python -m unittest storage.sqlite.test_snapshot_bridge -v`。完整项目回归仍用 `scripts/verify.ps1 -Scope all`。
