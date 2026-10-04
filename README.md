# 金豆罐（开发中）

`docs/IMPLEMENTATION_SPEC.md` v1.1 是唯一产品规格。当前仓库包含 Godot 4 金豆罐场景、隔离演示账本与个人现金账本、正式罐体 Blender/GLB 资源、Android 动态壁纸平台探针及开发用回环后端。木箱保留为 Blender→Godot 管线演示资产，位于 `game/scenes/pipeline_demo.tscn`；主场景为金豆罐原型。

## 当前环境与运行

- 已运行：Godot 4.7.2 stable Windows 控制台版。可设置 `GODOT_EXE` 为本机可执行文件路径。
- Android 平台探针固定 Android Gradle Plugin 8.13.2、Gradle 8.13、JDK 17、SDK API 36，最低 API 29。当前机器缺 JDK、Android SDK、Gradle、ADB 和 Godot Android 导出模板；没有 APK 或真机结论。Godot 壁纸 Surface 接入的公开接口障碍与未注册候选代码见 `wallpaper-android/GODOT_SURFACE_FEASIBILITY.md`。
- 游戏代码使用 GDScript；财务、黄金映射和库存使用十进制字符串，不从物理浮点状态反写账本。

打开 `game/project.godot` 后运行主场景即可观察正式金豆罐，并操作演示金额、皮肤和隐私按钮；页面可进入独立的个人空罐，输入人民币现金额与手工黄金参考价建账。个人页有资产录入、手工重估及“更多”菜单；菜单可进入只读账户总览、整理金豆、本地交易草稿、粘贴 CSV 导入、明文备份恢复、流水记录、只读对账检查和明文流水 CSV 导出。资产录入支持住房公积金/养老金余额检查点，受限余额与可用现金分开，手工重估可将其纳入完整估值；缴存、提取及利息流水尚未实现。演示金额 50000 CNY 和 1000 CNY/g 仅为隔离的**演示数据**，存于 `user://demo/moneybox.*.json`，不进入 `user://personal/moneybox.*.json`。两类状态使用校验双槽交替保存。个人 CSV/交易确认后的账本会标记“待重估”，旧罐仍显示为上次完整快照；生产数据库、加密备份、自动行情和 Android 端还在开发中。

## 验证

在仓库根目录运行：

```powershell
.\scripts\verify.ps1 -Scope core
.\scripts\verify.ps1 -Scope all
.\wallpaper-android\build.ps1 -Action check
```

`core` 运行十进制、账本、开发双槽保存及损坏恢复、演示/个人现金和只读显示载荷测试；`all` 再运行正式 GLB 导入、三维场景、30/300 颗容量、个人资产录入/受限余额/手工重估/草稿/CSV 导入导出/整理金豆/总览/流水/对账/备份场景、报价、生态、历史估值、收益分析、开发后端 HTTP 测试，并检查 Android 工具。最近一次完整运行是 **44 个 Godot 脚本和 7 项 HTTP 测试通过**；验证脚本还检查 Godot 输出中的脚本错误。独立的 `python -m unittest storage.sqlite.test_snapshot_bridge -v` 有 4 项 SQLite 事务证明通过，尚未接入 Godot 或 Android。`docs/evidence/` 保存十张桌面财务页面及四张受限余额页面截图，不能作为真机证据。日志放在忽略目录 `tests/logs/`。退出码 0 表示相应**本地脚本**通过；设备、Android 编译、锁屏支持和商店发行须分别验收。当前环境的 Godot 系统证书读取错误和开发存储跨进程写入风险见 `docs/KNOWN_ISSUES.md`。

阶段和证据见 `docs/PROGRESS.md`、`docs/REQUIREMENTS_TRACE.md`、`docs/COMPATIBILITY.md`。如需继续实施，请先读取这些文件和 `docs/DECISIONS.md`、`docs/KNOWN_ISSUES.md`，保护现有未提交文件。
