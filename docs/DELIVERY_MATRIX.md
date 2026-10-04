# 金豆罐规格交付矩阵

初版审计日期：2026-09-27；Android 普通应用门槛更新：2026-09-27。依据 `AGENTS.md`、`docs/IMPLEMENTATION_SPEC.md` v1.1、`docs/DECISIONS.md`、`docs/PROGRESS.md`、`docs/KNOWN_ISSUES.md`，对照当前工作树的代码、测试、截图和已记录的运行结果。初版为静态审计；本次补入用户对 v2 调试包的实机反馈、v3 本机构建与回归证据。下列路径除特别说明外均相对项目根目录。工作树原有的大量暂存及未跟踪文件均保留；本矩阵描述当前文件状态，并不表示它们已经提交。

## 判定口径

| 标记 | 含义 |
|---|---|
| 已完成 | 该**行的具体范围**已有实现和相符的运行证据。测试用例的本地通过不自动使上层产品需求、阶段或平台门槛完成。 |
| 部分完成 | 存在有用代码或局部验证，但规格中的功能、集成、用户流程或验收证据尚缺。 |
| 未实现 | 正式产品路径尚无对应实现；设计、独立算法、诊断探针或空接口不能代替产品功能。 |
| 受外部条件阻塞 | 完成该行必须取得目前缺失的设备、工具链、许可或服务。此标记**不表示**已有代码工作全部完成；缺失的实现也在行内写明。 |

证据分层：本次 `scripts/verify.ps1 -Scope all` 的 **46 个 Godot 脚本和 7 项 Python 回环 HTTP 测试通过**（退出码 0）；SQLite 独立 Python 4 项为前轮结果；原始 Godot 日志在被忽略的 `tests/logs/`。用户已在荣耀 Magic 6 Pro、MagicOS 10（Android 16）侧载 v2，实际看见横屏黑边、快摇金豆飞出及初始多豆运动卡顿。v3 调试 APK 已在本机导出，静态 manifest 为 `screenOrientation=1`（竖屏），签名与对齐检查通过；本轮 `adb devices -l` 未列出设备，用户也暂不能连接，**v3 未经手机安装、画面、`user://` 恢复、传感器或帧率验证**。Windows Godot 540×960 证据图在 `docs/evidence/`，本轮 440×960 的演示、个人和生态界面截图在忽略目录 `tmp/android-ui-check/`；它们都不是 Android 截图。强摇回归修复前退出码 1、修复后退出码 0，但桌面 headless 帧时不能推定手机 FPS。`docs/REQUIREMENTS_TRACE.md` 仍记录较早的 44 个脚本及“其他估值资产待做”，已落后于 `docs/PROGRESS.md` 和 KI-014；本矩阵按当前代码、最近证据和已知问题判定，后续需同步旧追踪文档。木箱 `pipeline_asset` 只算资源管线演示，不算正式罐体。

## 四个验收门槛

这四个门槛是本次审计对规格 M0–M6 和第 17–18 章的组织方式，不是另设的产品需求。

| 门槛 | 当前判定与证据文件 | 尚缺的用户操作或测试 | 下一步任务 |
|---|---|---|---|
| 桌面本地可用 | **部分完成**。`game/project.godot`、`game/scenes/personal_main.tscn`、`game/scripts/visual/personal_app.gd`、`game/tests/visual/run_jar_shake_regression.gd`、`docs/evidence/finance_desktop_asset_entry.png`、`docs/evidence/formal_jar_desktop_basic.png`；合成账本、手工报价、金豆刚体、恢复和局部页面可在 Windows Godot 开发环境运行。本轮 440×960 桌面图形截图覆盖演示、个人和生态页面；50 豆强摇及 300 豆约束本地回归通过。 | 用隔离测试数据走完桌面建账、录入、重估、整理、重启、导出恢复和错误路径的人工操作；完整账户/资产、历史、对账、加密备份尚无产品验收。 | 先完成 L01–L12 的缺口和持久化，再按实际桌面用户流程、异常注入与图形效果逐项验收。当前只可称**受限本地原型可体验**。 |
| Android 普通应用可用 | **受外部条件阻塞：v2 已有严重实机反馈，v3 修复候选尚未实机验收**。用户在荣耀 Magic 6 Pro / MagicOS 10（Android 16）侧载 `tmp/android-debug-artifacts/moneybox-debug-20260927-v2.apk`，报告横屏黑边、快摇豆越界、初始多豆卡顿。`game/project.godot` 设置竖屏、画面扩展和物理插值；`game/scripts/visual/jar_view.gd` 改善封闭碰撞壳与豆碰撞形状；`game/scripts/visual/demo_app.gd` 和 `game/scripts/visual/personal_app.gd` 调整手机尺寸字体/按钮。`tmp/android-debug-artifacts/moneybox-debug-20260927-v3.apk` 的 manifest 为 `screenOrientation=1`，本机签名与对齐通过。 | 本轮 `adb devices -l` 无设备且用户暂不能 USB 连接；v3 尚缺同机安装、竖屏满幅/可读性、快摇不越界、多豆流畅度、保存恢复、触控输入、传感器、日志与截图。现有财务功能也未完整达到规格。 | 用户侧载 v3，在同一手机按竖屏画面、强摇急停与初始 50 豆运动逐项复测并提供截图/短录像；设备可连接时采集脱敏日志与帧时间，再按 T 项补齐完整功能。APK 构建不等于手机可用。 |
| Android 动态壁纸可用 | **受外部条件阻塞，正式渲染桥未实现**。`wallpaper-android/app/src/main/java/com/jindouguan/wallpaperprobe/ProbeWallpaperService.java` 只是 Canvas 诊断探针；`wallpaper-android/GODOT_SURFACE_FEASIBILITY.md` 与 KI-005 说明候选桥未注册、未编译且单 Surface 不能证明双实例持续动画。 | 真实 Godot 画面写入 WallpaperService Surface；系统预览/启用/切换、主屏/锁屏、多 Engine、熄亮屏/回收恢复、传感器、隐私、同版快照和 T21–T28/T32/T43–T44 真机记录。 | 先编译并安装探针，再实现并验证 Godot 外部 Surface 桥及多实例策略；在不同设备逐项录屏、量测和复核。探针通过仍不等于此门槛通过。 |
| 可发布 | **未实现完整发行条件**。`docs/IMPLEMENTATION_SPEC.md` 第 14–18 章、`backend/dev_server.py`、`docs/PROGRESS.md`、`docs/KNOWN_ISSUES.md`；当前后端仅回环开发骨架，无签名 AAB。 | M5 完整财务、M6 发行：合法商用行情与授权、正式 SQLite/迁移/加密备份、生产 HTTPS/鉴权/恢复、AI 隐私、内购状态、商店材料与许可、三类设备兼容/性能/耗电、无障碍和 T33–T35/T41–T42/T47。 | 先分别关闭桌面和 Android 产品门槛，再完成 B0/B1/B2/B4 与 M5/M6 的实际材料、演练和签名构建；由产品所有者审阅真实画面和发布声明。 |

## U01–U20：不可丢失的产品需求

| 项 | 状态 | 证据文件与当前边界 | 尚缺的用户操作或测试 | 下一步任务 |
|---|---|---|---|---|
| U01 原总账保留 | 部分完成 | `game/scripts/data/ledger_core.gd`、`game/scripts/data/personal_asset_flow.gd`、`tests/data/test_ledger.gd`；L01–L12 都只有局部覆盖。 | 完整资产类别、流水、收益、费用税务、导入对账与移动端全流程。 | 按 L01–L12 补全并逐项端到端验收。 |
| U02 手机先落地 | 受外部条件阻塞 | `scripts/export_android_debug.ps1`、`tmp/android-debug-artifacts/moneybox-debug-20260927-v3.apk`、KI-004；用户已在荣耀 Magic 6 Pro 上试用 v2 并报告严重显示/运动问题。v3 静态竖屏 manifest、签名与对齐通过，但尚无 v3 手机画面。 | 同机侧载 v3，检查满幅竖屏、可读性、运动、输入、保存和重启，并在设备可连接时检查脱敏日志；完整手机账本尚有 L/P 项缺口。 | 先取得 v3 用户侧试用结果，再执行普通 App 真机矩阵并继续完成账本与页面缺项。 |
| U03 汇总个人总资产 | 部分完成 | `game/scripts/data/ledger_core.gd`、`game/scripts/quotes/valuation_batch_service.gd`、`game/scripts/ui/personal_overview.gd`、`tests/data/test_ledger.gd`；局部投影和去重。 | 展示渠道/托管账户去重、多币种 UI、负债/净资产、同时间账户对账。 | 完整账户实体与汇总边界，核对真实用户账单的脱敏样本。 |
| U04 透明玻璃正式罐 | 部分完成 | `art_source/blender/gold_jar.blend`、`game/assets/3d/gold_jar.glb`、`docs/evidence/formal_jar_desktop_basic.png`；Windows 截图可见罐与豆，KI-009 记豆偏深。 | 少量/近满/混合面额样张、产品所有者确认、Android 透明排序和可读性。 | 补指定状态样张并在目标手机复核材质与玻璃厚度。 |
| U05 治愈画风及皮肤 | 部分完成 | `game/scripts/visual/jar_view.gd`、`game/scripts/ecology/ecology_service.gd`、`docs/evidence/formal_jar_desktop_ecology.png`；基础/生态切换。 | 独立可扩展皮肤配置、日夜/声音/已购预览、用户视觉确认。 | 建立正式皮肤配置和视觉验收记录。 |
| U06 现货黄金折算 | 部分完成 | `game/scripts/domain/gold_mapping_service.gd`、`game/scripts/quotes/personal_gold_flow.gd`、`game/tests/quotes/run_personal_gold_tests.gd`；手工/合成报价可追溯。 | 合法现货金价和 FX、自动批次、用户重估详情、真实刷新失败。 | 接入有许可的数据源并做同版账本到金豆的端到端测试。 |
| U07 1 克基本计量 | 部分完成 | `game/scripts/domain/jar_inventory.gd`、`game/tests/domain/run_domain_tests.gd`；23 颗加 0.7 克等局部断言。 | 小数余量 UI、混合面额/多罐真机容量和性能。 | 把权威库存与展示容量统一并验证大量资产。 |
| U08 手机运动的真实物理 | 部分完成 | `game/scripts/visual/jar_view.gd`、`game/scripts/visual/jar_smoke_test.gd`、`game/tests/visual/run_jar_shake_regression.gd`；本地刚体、重力和落体烟测。用户报告 v2 快摇豆飞出；加厚封闭碰撞壳、简化豆碰撞形状后的合成强摇回归从失败变为通过。 | 目标设备坐标变换、左/右倾、倒置、平放摇晃/静置、碰撞与传感器录像；v3 是否仍越界未知。 | 在荣耀 Magic 6 Pro 上先复测 v3，再实机执行 T21/T22/T43/T44。 |
| U09 自愿 10 合 1 | 部分完成 | `game/scripts/domain/jar_inventory.gd`、`game/scripts/domain/personal_bean_organizer_flow.gd`、`game/tests/domain/run_personal_bean_organizer_tests.gd`；本地预览、确认、重启。 | 真机触控操作及动画中杀进程的 T18。 | 在 Android 执行 T17–T19 和中断恢复。 |
| U10 亮屏见罐 | 受外部条件阻塞 | `wallpaper-android/GODOT_SURFACE_FEASIBILITY.md`、`docs/COMPATIBILITY.md`；尚无 Godot 壁纸画面。 | APK、壁纸启用、熄亮屏和系统回收 T23–T25。 | 实现 Surface 桥并实测恢复，不重播历史投豆。 |
| U11 主屏/锁屏 | 受外部条件阻塞 | `wallpaper-android/README.md`、`docs/COMPATIBILITY.md`；仅有待测矩阵。 | 不同厂商主屏、锁屏、系统预览；iOS 需按第 09 章声明不同形态。 | 真机录屏和设备兼容性报告。 |
| U12 默认总额与隐私 | 部分完成 | `game/scripts/data/display_snapshot_service.gd`、`tests/data/test_display_snapshot.gd`、`docs/evidence/m0_godot_privacy_preview.png`；本地隐藏金额和待重估防旧值。 | 壁纸/锁屏/小组件同 generation、清空/应用锁联动、无旧金额闪现。 | 接正式跨进程只读载荷并执行 T27/T32。 |
| U13 简洁不干扰桌面 | 未实现 | `wallpaper-android/app/src/main/java/com/jindouguan/wallpaperprobe/ProbeWallpaperService.java` 仅诊断画面关闭触摸；`docs/COMPATIBILITY.md` 无正式壁纸。 | 正式桌面图标清晰度、翻页、触控不拦截、无菜单/广告的真机检查。 | 正式壁纸完成后执行 T23 与可读性/交互验收。 |
| U14 商店变现 | 未实现 | `backend/dev_server.py` 公开开发态 `purchases_configured=false`；`docs/PROGRESS.md` M6 未达。 | 内购取消/待付款/成功/离线/恢复/退款、权益、签名包与商店材料。 | 按 M6 实现并用沙箱执行 T33–T35。 |
| U15 自动股票/基金/FX/黄金 | 部分完成 | `game/scripts/quotes/quote_gateway.gd`、`game/scripts/quotes/manual_quote_provider.gd`、`game/tests/quotes/run_quote_tests.gd`；合成源验证缓存/失败回退。 | 合法可商用来源、自动调度、TLS、真实后端与 T37/T38。 | 明确授权与服务适配，验证失败/过期及成本。 |
| U16 自然语言录入 | 部分完成 | `game/scripts/trade/trade_draft_service.gd`、`game/scripts/trade/personal_trade_flow.gd`、`game/tests/trade/run_trade_tests.gd`；本地规则草稿和确认。 | AI 解析服务、最少字段脱敏、异常/歧义及后端幂等端到端。 | 接版本化 AI 草稿契约并跑 T39–T41。 |
| U17 非破坏升级 | 部分完成 | `game/scripts/data/project_store.gd`、`tests/data/test_store_fault_matrix.gd`、`storage/sqlite/migrations/0001_snapshot_bridge.sql`；开发 JSON v1→v2 与 Python SQL 证明。 | Godot/Android SQLite provider、已发布版本样本、断电/并发/失败回退、加密备份。 | 建正式只追加迁移链，执行 T30/T31/T34/T36。 |
| U18 可替换后端 | 部分完成 | `contracts/openapi/dev_backend_v1.openapi.json`、`backend/dev_server.py`、`backend/test_dev_server.py`；B0 回环 HTTP。 | 生产鉴权/持久幂等/PostgreSQL、供应商适配和双客户端契约。 | 完成 B0/B1/B2/B4 并执行 T38/T41/T42/T47。 |
| U19 非慢动作碰撞 | 部分完成 | `game/scripts/visual/jar_smoke_test.gd`、`game/tests/visual/run_jar_shake_regression.gd`、`docs/PROGRESS.md`；桌面固定步长 0.10/0.20 米首次接触约 0.167/0.217 秒，时间倍率仍为 1.0；新增强摇回归验证不越界。 | 用户已观察 v2 初始多豆卡顿；v3 仍需实机高速录屏、1/10 克同高对比、摇晃撞击衰减/静置及连续帧时量测。 | 在目标手机复测 v3，再完成 T43/T44 与第 17 章偏差检查。 |
| U20 海草鱼虾生态 | 部分完成 | `game/scripts/ecology/ecology_service.gd`、`game/tests/ecology/run_ecology_store_tests.gd`、`docs/evidence/formal_jar_desktop_ecology.png`；离线恢复和财务隔离本地通过。 | 真机双层隔舱/自然行为/性能、产品所有者视觉确认、端到端 T45/T46。 | 完善行为与展示并做生态实机验收。 |

## L01–L12：原总账继承清单

| 项 | 状态 | 证据文件与当前边界 | 尚缺的用户操作或测试 | 下一步任务 |
|---|---|---|---|---|
| L01 多来源多账户/人民币汇总 | 部分完成 | `game/scripts/data/ledger_core.gd`、`game/scripts/data/personal_asset_flow.gd`、`game/scripts/ui/personal_overview.gd`；账户及余额局部可读。 | 展示渠道与托管账户去重、完整机构字段、跨币账户/账单核对。 | 完整账户模型及独立账户验收。 |
| L02 多币种/在线汇率 | 部分完成 | `game/scripts/quotes/quote_gateway.gd`、`game/scripts/quotes/valuation_batch_service.gd`、`game/tests/quotes/run_quote_tests.gd`；合成 FX 和旧值回退。 | 六种预置币种完整 UI、合法在线 FX、实际断网和过期处理。 | 接线上 provider 并验证本位币锁定汇率。 |
| L03 三种建账入口 | 部分完成 | `game/scripts/data/ledger_core.gd`、`tests/data/test_ledger.gd`、`game/scenes/personal_main.tscn`；期初、汇总替代和个人现金入口。 | 完整历史导入向导、当前余额/期初/历史三入口手机操作。 | 做三种建账导航和迁移样本。 |
| L04 分资产类型表单 | 部分完成 | `game/scripts/visual/personal_asset_entry.gd`、`game/tests/data/run_other_asset_tests.gd`、`game/tests/data/run_restricted_asset_tests.gd`；KI-014 的“其他估值资产”**本地闭环已关闭**。 | 存款、实物黄金、基金申赎、负债及公积金/养老金缴存提取利息等；Android 表单。 | 按规格第 04 章资产表逐类补表单、命令和测试。 |
| L05 事件/现金持仓/成本 | 部分完成 | `game/scripts/data/ledger_core.gd`、`tests/data/test_ledger.gd`；T01–T06 与派息局部数值。 | 利息、公司行动、费用税务、一般更正和完整成本投影。 | 扩展事件模型并用账本重建验证。 |
| L06 行情/估值快照 | 部分完成 | `game/scripts/quotes/quote_gateway.gd`、`game/scripts/quotes/valuation_batch_service.gd`、`game/tests/quotes/run_quote_store_tests.gd`；本地批次/旧价/待重估。 | 合法自动刷新、真实历史持久化、成交临时报价全流程。 | 对接 B1 并保留可追溯来源时间。 |
| L07 曲线/TWR/XIRR | 部分完成 | `game/scripts/analytics/portfolio_analytics.gd`、`game/scripts/analytics/historical_valuation_service.gd`、对应 `game/tests/analytics/`；仅独立输入契约/数值例。 | 权威连续历史、当时 FX/外部流、日月年 K 和两点测量 UI；KI-008。 | 将完整历史快照接 ProjectStore/正式库后再显示精确收益。 |
| L08 派息/利息/公司行动 | 部分完成 | `game/scripts/data/ledger_core.gd`、`tests/data/test_ledger.gd`；派息建议、确认及预扣税 T08。 | 利息、红利再投、公司行动及对应用户流程。 | 增加事件与状态迁移测试。 |
| L09 收费计划 | 部分完成 | `game/scripts/fees/fee_rule_service.gd`、`game/tests/fees/run_fee_tests.gd`；独立合成规则引擎。 | 经核实的机构费率/版本包、账单覆盖、账本与 P14 接入。 | 确认合法规则来源后接收费 UI 和差额核对。 |
| L10 税务底稿 | 部分完成 | `game/scripts/tax/tax_workpaper_service.gd`、`game/tests/tax/run_tax_tests.gd`；缺有效规则时拒绝假精确税额。 | 合法规则包、凭证/报告、真实账本与 P14 接入。 | 核验规则并完成底稿与报告流程。 |
| L11 导入与对账 | 部分完成 | `game/scripts/import/csv_import_service.gd`、`game/scripts/reconciliation/reconciliation_service.gd`、`game/tests/import/run_import_tests.gd`；粘贴 CSV 和局部只读对账。 | 券商 CSV、Android 文件选择器、账户总额/待交收三级对账、批次冲销及报告；KI-012。 | 扩展格式适配和完整对账，测试文件竞争/原子提交。 |
| L12 本地优先/导出恢复/隐私 | 部分完成 | `game/scripts/data/project_store.gd`、`game/scripts/backup/backup_service.gd`、`game/scripts/data/display_snapshot_service.gd`；开发期明文 JSON 双槽。 | 正式 SQLite、认证加密、Android SAF、壁纸跨进程隐私、干净安装/错误密码/升级恢复。 | 完成 U17 与 T30–T36/T47，云同步另按 M8 选择。 |

## P01–P17：手机页面与导航

以下“页面”状态只认可当前 Godot 场景的局部能力；**所有 P 项均无 Android 真机页面验收**。四个一级入口及统一移动导航也未贯通。

| 项 | 状态 | 证据文件与当前边界 | 尚缺的用户操作或测试 | 下一步任务 |
|---|---|---|---|---|
| P01 金豆罐首页 | 部分完成 | `game/scenes/personal_main.tscn`、`game/scripts/visual/personal_app.gd`、`docs/evidence/formal_jar_desktop_empty.png`；现金建账与罐体。 | 完整总额、更新时间、全屏观察/更新入口及手机操作。 | 接正式估值和移动首页验收。 |
| P02 总览 | 部分完成 | `game/scenes/personal_overview.tscn`、`game/tests/ui/run_personal_overview_tests.gd`、`docs/evidence/finance_desktop_overview.png`；严格条件下只读总额/账户。 | 净资产、配置、完整盈亏/净投入和行情新鲜度。 | 接 L01/L07 历史与完整估值。 |
| P03 成长曲线 | 未实现 | `game/scripts/analytics/historical_valuation_service.gd` 仅数据契约；`docs/PROGRESS.md` M5 缺口。 | 日/月/年/全部、两点测量与数据完整度页面。 | 先建立权威历史，再做图表和区间验收。 |
| P04 账本内账户 | 部分完成 | `game/scenes/personal_overview.tscn`、`game/scripts/ui/personal_overview.gd`；只读账户摘要。 | 机构来源、收费计划、对账状态与手机账户列表。 | 完整账户字段和列表导航。 |
| P05 账户详情/持仓 | 部分完成 | `game/scripts/ui/personal_overview.gd`、`docs/evidence/finance_desktop_overview.png`；局部持仓摘要。 | 按资产打开账户详情、成本/收益/报价依据全字段。 | 接资产详情和数据不足状态。 |
| P06 流水列表/详情 | 部分完成 | `game/scenes/personal_ledger_history.tscn`、`game/tests/integration/run_personal_ledger_history_scene.gd`；只读筛选/冲销记录。 | 完整搜索、更正、凭证/计算来源、手机操作。 | 建流水详情及审计更正流程。 |
| P07 新增记录 | 部分完成 | `game/scenes/personal_asset_entry.tscn`、`game/scenes/personal_trade_draft.tscn`、对应 `game/tests/integration/`；结构化与本地草稿确认。 | 所有类型表单、后端 AI、逐字段确认和真实手机输入。 | 完成 L04/U16 并实测键盘/滚动。 |
| P08 更新资产 | 部分完成 | `game/scenes/personal_manual_revaluation.tscn`、`game/tests/integration/run_personal_manual_revaluation_scene.gd`；手工完整重估预览。 | 自动刷新、文件入口、真实批次状态与手机页面。 | 接 B1 并展示失败/过期项。 |
| P09 黄金折算详情 | 未实现 | `game/scripts/domain/gold_mapping_service.gd`、`game/scripts/quotes/personal_gold_flow.gd` 有数据，无规格所述独立详情页。 | 指标、版本、报价口径/时间/汇率和原因拆分的用户查看。 | 新建可追溯详情视图并验收。 |
| P10 整理金豆 | 部分完成 | `game/scenes/personal_bean_organizer.tscn`、`game/tests/integration/run_personal_bean_organizer_scene.gd`、`docs/evidence/finance_desktop_bean_organizer.png`。 | 多罐混排/重排、动画中断及真机操作。 | 补 T18/T28 和设备 UI。 |
| P11 壁纸设置 | 未实现 | `wallpaper-android/` 只有诊断探针；`docs/COMPATIBILITY.md` 无正式壁纸设置页。 | 全屏预览、位置、隐私/性能模式、系统设置入口。 | Godot 壁纸接通后实现并执行系统选择器流程。 |
| P12 皮肤/生态 | 部分完成 | `game/scripts/visual/jar_view.gd`、`game/scripts/ecology/ecology_service.gd`、`docs/evidence/formal_jar_desktop_ecology.png`。 | 背景/罐型/豆外观/日夜/已购预览和产品视觉确认。 | 独立皮肤配置、完整 UI 与真机验收。 |
| P13 导入/对账 | 部分完成 | `game/scenes/personal_csv_import.tscn`、`game/scenes/personal_reconciliation.tscn`、对应场景测试及截图。 | 文件选择、证券匹配、待交收和可解释的完整差异报告。 | 完成 L11 并在 Android 测试系统文件接口。 |
| P14 费用/税务 | 未实现 | `game/scripts/fees/fee_rule_service.gd`、`game/scripts/tax/tax_workpaper_service.gd` 仅独立数据层。 | 规则版本、年度凭证、计算缺口与报告页面。 | 完成 L09/L10 后建用户页。 |
| P15 我的设置/备份 | 部分完成 | `game/scenes/personal_backup_restore.tscn`、`game/tests/integration/run_personal_backup_restore_scene.gd`、`docs/evidence/finance_desktop_backup_restore.png`；明文备份页。 | 币种时区、应用锁/删除数据、认证加密、系统文件选择器。 | 完成 L12 及隐私和恢复 UI。 |
| P16 购买/恢复购买 | 未实现 | `backend/dev_server.py` 开发态无购买配置；`docs/PROGRESS.md` M6。 | 真实平台付款、待处理、恢复、退款与离线权益。 | 实现发行权益及沙箱验收。 |
| P17 首次使用 | 部分完成 | `game/scenes/personal_main.tscn`、`game/tests/integration/run_personal_scene.gd`；空罐现金+手工金价。 | 三种建账、首次折算解释和壁纸引导。 | 补完整引导并在新装手机测试。 |

## T01–T47：规格逐项验收用例

下表中标为“已完成”的 T 项只指**该行具体的本地数值/逻辑样例**：测试文件存在，且最近一次本地回归通过记录在 `docs/PROGRESS.md`。它不证明对应 U/L/P 项、Android 或发行门槛完成。凡用例要求真机、生产后端、跨进程或中断情境，本地模拟不能代替。表内“缺项”为该行剩余验收；写“本地样例无”时，仍须完成其上层产品集成。

### 数值与数据 T01–T20

| 用例 | 状态 | 证据文件与已验证范围 | 尚缺的用户操作或测试 | 下一步任务 |
|---|---|---|---|---|
| T01 买入/现金/成本/总额 | 已完成 | `tests/data/test_ledger.gd`、`docs/PROGRESS.md`；合成账户 10000→1990/8000/8010/9990。 | 本地数值样例无；正式 UI/Android 属 L05/U02。 | 将相同金标准纳入正式账本端到端。 |
| T02 本人账户转账 | 已完成 | `tests/data/test_ledger.gd`；两侧现金、总额与净投入断言。 | 本地数值样例无；多账户手机操作仍缺。 | 与 L01 页面和账户对账联测。 |
| T03 FIFO/均价 | 已完成 | `tests/data/test_ledger.gd`；两种已实现收益和剩余成本断言。 | 本地数值样例无；完整券商成本批次仍缺。 | 纳入真实导入/费用/税务回归。 |
| T04 补录旧交易不覆盖行情 | 已完成 | `tests/data/test_ledger.gd`；报价时间和当前估值断言。 | 本地数值样例无；正式历史刷新缺。 | 接 L06 权威报价历史。 |
| T05 汇总余额替代 | 已完成 | `tests/data/test_ledger.gd`；100000 不双计、40000/60000 拆分。 | 本地数值样例无；三入口向导缺。 | 在 L03 用户流程复用此例。 |
| T06 作废替代期初 | 已完成 | `tests/data/test_ledger.gd`；现金和原事件留存。 | 本地数值样例无；完整更正页面缺。 | 与 P06 审计详情联测。 |
| T07 20 证券/3 FX 部分失败 | 部分完成 | `game/tests/quotes/run_quote_tests.gd`、`game/scripts/quotes/manual_quote_provider.gd`；合成批次/旧价/单快照。 | 自动合法来源、真实失败/过期及客户端重估。 | 接 B1 后重跑端到端批次。 |
| T08 派息建议/确认 | 已完成 | `tests/data/test_ledger.gd`；建议不入现金，确认后税前 100/预扣 10/净增 90。 | 本地数值样例无；用户派息流程仍缺。 | 与 L08 页面和账单导入联测。 |
| T09 区间净投入/TWR | 已完成 | `game/tests/analytics/run_analytics_tests.gd`、`game/tests/analytics/run_historical_valuation_tests.gd`；合成完整边界得 100/31/21%。 | 本地数值样例无；真实历史快照和曲线缺，见 KI-008。 | 接权威历史后再发布收益。 |
| T10 365 日 XIRR | 已完成 | `game/tests/analytics/run_analytics_tests.gd`；10%及不可计算分支。 | 本地数值样例无；真实现金流输入缺。 | 与 L07 持续估值和外部流联测。 |
| T11 总资产/净资产标签 | 部分完成 | `game/tests/domain/run_domain_tests.gd`；100/80 克及 `net_assets` 字段。 | App/壁纸切换后的“净资产”标签和负债账本。 | 做完整指标切换和展示快照测试。 |
| T12 金衡盎司/FX | 已完成 | `game/tests/domain/run_domain_tests.gd`；3110.34768 USD/oz ×7→700 CNY/g→10 克。 | 本地算术样例无；真实数据源属 U15。 | 将单位/来源契约用于在线报价。 |
| T13 小数克 | 已完成 | `game/tests/domain/run_domain_tests.gd`；23700/1000→23 颗+0.7 克。 | 本地数值样例无；余量 UI 和容量属 U07。 | 在个人详情展示小数余量。 |
| T14 映射重放 100 次 | 已完成 | `game/tests/domain/run_domain_tests.gd`；100 次重复命令后库存 hash/revision 不变。 | 本地逻辑样例无；跨进程壁纸动画尚未验收。 | 在 T27 的多进程流程复查事件消费。 |
| T15 主动金价重估 | 部分完成 | `game/tests/domain/run_domain_tests.gd`、`game/tests/quotes/run_personal_gold_tests.gd`；100→80 克、金额不变。 | 用户主动操作与原因标签在 App/壁纸完整显示。 | 补 P09 详情和真机流程。 |
| T16 无效金价 | 已完成 | `game/tests/domain/run_domain_tests.gd`、`game/tests/quotes/run_personal_gold_tests.gd`；零/负/无单位拒绝，不覆盖旧映射。 | 本地输入样例无；在线异常仍由 T38 验证。 | 接真实 provider 后验证错误传播。 |
| T17 双击合成 | 部分完成 | `game/tests/domain/run_domain_tests.gd`、`game/tests/domain/run_personal_bean_organizer_tests.gd`；同命令重复只提交一次。 | 真机连续触摸和动画时序。 | 在设备上重复触控并核对持久库存。 |
| T18 合成半途关进程 | 部分完成 | `game/tests/domain/run_domain_tests.gd`、`game/tests/domain/run_personal_bean_organizer_tests.gd`；已提交态序列化重载。 | 真正动画中杀进程、提交前/后两侧故障注入；现有测试没有杀进程。 | 在正式存储与 Android 上中断恢复。 |
| T19 10 克目标降为 9 克 | 部分完成 | `game/tests/domain/run_domain_tests.gd`；一颗 10 克拆成九颗 1 克。 | 用户重估原因、账本不反写和场景恢复的同一流程。 | 将库存/映射/账本联测并在真机查看。 |
| T20 超单罐容量拒绝合成 | 部分完成 | `game/tests/domain/run_domain_tests.gd`、`game/tests/visual/run_capacity_smoke.gd`；多罐逻辑及桌面 300 豆烟测。 | 用户拒绝合成、混合面额多罐画面/性能；KI-007。 | 统一容量规则并执行目标设备压力测试。 |

### 设备、体验与恢复 T21–T35、T43–T46

| 用例 | 状态 | 证据文件与已验证范围 | 尚缺的用户操作或测试 | 下一步任务 |
|---|---|---|---|---|
| T21 左右倾/倒置 | 受外部条件阻塞 | `game/scripts/visual/jar_view.gd`、`game/tests/visual/run_jar_shake_regression.gd`、`tmp/android-debug-artifacts/moneybox-debug-20260927-v3.apk`；合成倾斜/倒置回归通过，但用户报告 v2 快摇豆飞出。 | v3 同机动作/录屏，检查坐标方向、倒置和防穿罐。 | 用户侧载 v3 测普通 App 传感器与碰撞；壁纸另测。 |
| T22 平放摇晃/静置 | 受外部条件阻塞 | `game/tests/visual/run_jar_shake_regression.gd`、`docs/COMPATIBILITY.md`；合成 50 豆强摇 360 个物理 tick 和 300 豆 90 个 tick 的本地边界回归通过，不能替代真实手机摇晃与静置。 | v3 真机平放、急停与 10 秒稳定录像，观察是否越界或明显卡顿。 | 在 T21 同批设备执行，设备可连接后采集帧时间。 |
| T23 壁纸翻页/开关/锁屏 | 受外部条件阻塞 | `wallpaper-android/README.md`、`docs/COMPATIBILITY.md`；只有诊断探针源码。 | Godot 正式壁纸 APK 的触控、恢复和无重复投豆。 | Surface 桥完成后执行生命周期矩阵。 |
| T24 预览与正式并存 | 受外部条件阻塞 | `wallpaper-android/GODOT_SURFACE_FEASIBILITY.md`；现有单 Surface 候选不能证明并存。 | 双 Engine 同版金额、同时帧更新及不重复消费。 | 建多实例渲染策略并在系统选择器验证。 |
| T25 熄屏 30 分钟 | 受外部条件阻塞 | `docs/COMPATIBILITY.md`、`docs/KNOWN_ISSUES.md` KI-005；无设备结果。 | 真机熄亮屏、物理不补算、无爆炸/穿透。 | 实测停止/恢复及日志/录像。 |
| T26 锁屏受限/无传感器 | 受外部条件阻塞 | `wallpaper-android/README.md`、`docs/COMPATIBILITY.md`；能力矩阵待填。 | 不同厂商、限制场景和替代说明的实际操作。 | 至少三类设备形成兼容报告。 |
| T27 记账同时打开壁纸 | 部分完成 | `game/scripts/data/display_snapshot_service.gd`、`storage/sqlite/test_snapshot_bridge.py`；同 generation 证明仅 Python，KI-011 跨进程风险仍在。 | 正式数据库写锁、App+壁纸并发读取旧/新版完整快照。 | 接 SQLite provider 后做双进程故障注入。 |
| T28 两罐/皮肤恢复 | 部分完成 | `game/scripts/data/project_store.gd`、`game/tests/domain/run_personal_bean_organizer_tests.gd`、`game/tests/ecology/run_ecology_store_tests.gd`；本地保存。 | 真机切换、混合面额可见和重建布局。 | Android 页面与壁纸共用库存版本后重测。 |
| T29 重复 CSV/1000 行错误 | 已完成 | `game/tests/import/run_import_tests.gd`、`game/tests/import/run_personal_import_tests.gd`；合成 CSV 重放和整批拒绝。 | 本地用例无；真实文件选择/券商格式属 L11。 | 在 Android 文件接口和正式数据库重验原子性。 |
| T30 备份后干净恢复 | 部分完成 | `game/tests/backup/run_backup_tests.gd`、`game/tests/integration/run_personal_backup_restore_scene.gd`；本地隔离新存储路径还原。 | Android 干净安装、系统文件选择器、正式加密库/壁纸同版。 | 完成 L12 后进行设备恢复演练。 |
| T31 错密码/损坏/未来版本 | 部分完成 | `game/tests/backup/run_backup_tests.gd`；损坏/未来格式拒绝且原状态不变。 | 当前明文备份没有密码，故错误密码分支无法测试；Android 壁纸保留状态。 | 先实现认证加密，再跑三种失败及跨进程恢复。 |
| T32 隐私/清空/应用锁 | 部分完成 | `game/scripts/data/display_snapshot_service.gd`、`tests/data/test_display_snapshot.gd`、`docs/evidence/m0_godot_privacy_preview.png`；本地页面隐藏金额。 | 所有壁纸实例/小组件即时同步、清空和应用锁无旧值闪现。 | 以正式跨进程载荷执行隐私全矩阵。 |
| T33 内购状态 | 未实现 | `backend/dev_server.py`、`docs/PROGRESS.md` M6；无购买实现。 | 平台沙箱取消/待付款/成功/离线/恢复/退款及金豆重量不变。 | 实现权益状态机并跑沙箱。 |
| T34 安装/升级/迁移失败 | 部分完成 | `tests/data/test_store_fault_matrix.gd`、`docs/MIGRATION_MATRIX.md`；开发 JSON v1→v2/损坏回退。 | APK 正常安装、正式数据库版本升级、中断迁移回退。 | 建已发布样本和设备升级矩阵。 |
| T35 商店截图/视频 | 未实现 | `docs/evidence/` 仅桌面测试截图；`docs/PROGRESS.md` M6。 | 真实设备商店媒体与功能/行情声明复核。 | 发布前拍摄并审阅正式 App/壁纸。 |
| T43 0.10/0.20 米自由落体 | 部分完成 | `game/scripts/visual/jar_smoke_test.gd`、`docs/PROGRESS.md`；改动后桌面固定步长首次接触仍约 0.167/0.217 秒，1.0 时间倍率未改。 | 1/10 克真机高速录屏、理论偏差和时间倍率量测。 | 取得设备后逐帧测量并存档。 |
| T44 快摇急停/翻转碰撞 | 受外部条件阻塞 | `game/scripts/visual/jar_view.gd`、`game/tests/visual/run_jar_shake_regression.gd`、`docs/COMPATIBILITY.md`；用户 v2 报告豆飞出，v3 合成强摇回归通过但无 v3 手机录像。 | 同机复测惯性、反弹、衰减、不穿透/漂浮/磁吸，尤其急停与翻转。 | 荣耀 Magic 6 Pro 侧载 v3 后录屏并对照静止过程。 |
| T45 生态离线三日恢复 | 部分完成 | `game/tests/ecology/run_ecology_tests.gd`、`game/tests/ecology/run_ecology_store_tests.gd`；模拟三日、切肤、重启状态。 | 真机后台三日/系统回收、可见自然状态与性能。 | 完成 App/壁纸生态恢复测试。 |
| T46 生态与财务隔离 | 部分完成 | `game/tests/ecology/run_ecology_tests.gd`、`game/tests/ecology/run_ecology_store_tests.gd`；指纹不变及本地外层记录。 | 真机喂食/移植/刷新资产和内外舱视觉隔离。 | 实机操作、截图及同版财务核对。 |

### 后端、迁移与隐私 T36–T42、T47

| 用例 | 状态 | 证据文件与已验证范围 | 尚缺的用户操作或测试 | 下一步任务 |
|---|---|---|---|---|
| T36 每个已发布 Schema/断电 | 部分完成 | `storage/sqlite/migrations/0001_snapshot_bridge.sql`、`storage/sqlite/test_snapshot_bridge.py`、`docs/MIGRATION_MATRIX.md`；独立 SQL 事务证明，不存在已发布库样本。 | Godot/Android provider、全版本样本及迁移中杀进程/断电。 | 建正式实体及只追加迁移/恢复矩阵。 |
| T37 后端自动批次缓存 | 部分完成 | `game/tests/quotes/run_quote_tests.gd`、`backend/dev_server.py`；客户端合成 20+3+金、缓存/一次估值。 | 生产后端自动抓取、合法来源、客户端实际请求及同版快照。 | 完成 B1 并执行网络端到端场景。 |
| T38 供应商故障切换 | 部分完成 | `game/tests/quotes/run_quote_tests.gd`；手工 provider 零价/禁用及旧价过期。 | 真实超时/熔断、两个合法供应商/许可配置、后端与 App 联测。 | 完成 provider 适配和故障演练。 |
| T39 自然语言买 VOO | 部分完成 | `game/tests/trade/run_trade_tests.gd`、`game/tests/integration/run_personal_trade_draft_scene.gd`；本地规则草稿/确认账本。 | 后端 AI 解析、最小字段传输、真实页面完整输入与确认。 | 接 B2 并在测试后端重跑原句。 |
| T40 缺字段/冲突追问 | 部分完成 | `game/tests/trade/run_trade_tests.gd`；本地缺账户/日期/数量冲突不写账本。 | AI 返回歧义、客户端追问和网络失败恢复。 | 补 AI 契约及 UI 交互测试。 |
| T41 三类请求幂等 100 次 | 部分完成 | `game/tests/trade/run_trade_tests.gd`；确认交易命令重放 100 次；`backend/test_dev_server.py` 仅回环契约测试。 | 行情和 AI 请求各 100 次、超时重试、后端持久幂等。 | 建持久键与三类请求联测。 |
| T42 当前/上代客户端契约 | 部分完成 | `contracts/openapi/dev_backend_v1.openapi.json`、`backend/test_dev_server.py`；v1 与未来版本拒绝的局部检查。 | 实际上一支持客户端、新字段忽略和稳定升级提示。 | 在 B0/B4 建双版本客户端回归。 |
| T47 敏感数据泄漏审计 | 部分完成 | `backend/dev_server.py`、`game/scripts/data/display_snapshot_service.gd`、`docs/DECISIONS.md` D-019/D-020；局部最小载荷与回环日志边界。 | 客户端请求、服务日志、崩溃报告、第三方 AI/行情及商店隐私材料全链路检查。 | 生产配置和发行包就绪后执行泄漏/申报审计。 |

## I01–I04：iOS 适配用例

iOS 是规格 M7 的独立平台；其壁纸形态是导出静态内容，不应声称有 Android 式动态壁纸。当前仓库没有 iOS App、小组件或可安装测试构建。

| 用例 | 状态 | 证据文件与当前边界 | 尚缺的用户操作或测试 | 下一步任务 |
|---|---|---|---|---|
| I01 前台物理与恢复 | 未实现 | `docs/IMPLEMENTATION_SPEC.md` 第 09/18 章、`docs/COMPATIBILITY.md`；仅 Godot 桌面场景。 | iOS App、倾斜摇晃、退出重进和账本/豆面额恢复。 | M7 建可安装测试版后实测。 |
| I02 小组件同版摘要 | 未实现 | `contracts/json-schema/display_snapshot.schema.json` 是可复用载荷契约；`docs/COMPATIBILITY.md` 无小组件。 | WidgetKit 实现、系统刷新限制和隐私/版本核对。 | M7 接只读载荷并测试刷新。 |
| I03 壁纸导出时点 | 未实现 | `docs/IMPLEMENTATION_SPEC.md` 第 09/18 章；无 iOS 导出实现。 | 修改资产前后导出文件及“不会自动更新”提示。 | M7 实作导出和时间标签。 |
| I04 隐私/备份/购买恢复 | 未实现 | `game/scripts/backup/backup_service.gd` 仅开发期本地 JSON；`docs/COMPATIBILITY.md` 无 iOS 验证。 | iOS 文件接口、应用锁、恢复和平台购买状态。 | M7 按实际系统能力执行共享契约。 |

## M0–M8 阶段退出与 B0–B4 后端工作

任何阶段有代码不等于退出。M0–M8 的正式退出条件见 `docs/IMPLEMENTATION_SPEC.md` 第 16 章；B0–B4 是同章交叉追踪工作。M8 和 B3 属条件性/扩展范围，未实现不应挤占 M0–M6 的必需工作。

| 阶段 | 状态 | 证据文件与当前边界 | 尚缺的用户操作或测试 | 下一步任务 |
|---|---|---|---|---|
| M0 系统与物理验证 | 受外部条件阻塞 | `game/scripts/visual/jar_smoke_test.gd`、`game/tests/visual/run_jar_shake_regression.gd`、`scripts/export_android_debug.ps1`、`tmp/android-debug-artifacts/moneybox-debug-20260927-v3.apk`、`wallpaper-android/GODOT_SURFACE_FEASIBILITY.md`；用户试用 v2 报告横屏黑边、豆越界和卡顿。v3 已导出并静态确认竖屏，本地 50/300 豆合成运动回归通过；本轮未编译壁纸探针。 | v3 普通 App 同机画面与碰撞/帧时量测、Godot→壁纸 Surface、T21–T26/T43–T44 及主/锁屏录屏。 | 用户先在荣耀 Magic 6 Pro 侧载 v3 复测，再单独完成壁纸探针与正式渲染桥；M0 尚未退出。 |
| M1 总账数据核心 | 部分完成 | `game/scripts/data/ledger_core.gd`、`game/scripts/data/project_store.gd`、`tests/data/test_ledger.gd`、`docs/MIGRATION_MATRIX.md`；局部金标准与开发迁移。 | 正式 SQLite、完整实体历史、T34/T36 和数据重建。 | 完成非破坏数据库迁移及故障矩阵。 |
| M2 手机总账/后端基础 | 部分完成 | `game/scenes/personal_main.tscn`、`game/scenes/personal_asset_entry.tscn`、`backend/dev_server.py`、`contracts/openapi/dev_backend_v1.openapi.json`；本地页面和回环 HTTP。 | 三种建账、完整离线手机账本、PostgreSQL、AI 预览及 T07–T10/T29–T32/T39–T42。 | 补 L/P 缺口、生产测试后端和 Android 普通 App。 |
| M3 自动行情/映射/库存 | 部分完成 | `game/scripts/quotes/quote_gateway.gd`、`game/scripts/domain/gold_mapping_service.gd`、`game/scripts/domain/jar_inventory.gd`、`game/tests/quotes/run_quote_tests.gd`；手工/合成闭环。 | 合法自动数据源、T11–T20/T27–T28/T37–T38 全流程。 | 完成 B1 与正式持久化后联测。 |
| M4 美术生态/稳定 | 部分完成 | `game/assets/3d/gold_jar.glb`、`game/scripts/ecology/ecology_service.gd`、`docs/evidence/formal_jar_desktop_ecology.png`、`tmp/android-ui-check/`、`tmp/android-debug-artifacts/moneybox-debug-20260927-v3.apk`；桌面视觉与 440×960 生态页面截图已检查，普通 App v3 调试包已有。 | v3 真机显示、正式 Blender 资产在目标手机的视觉确认、T45/T46 和第 17 章性能/耗电/可用性。 | 真机检查混合豆、生态、隐私和性能；桌面截图不代替正式资产真机验收。 |
| M5 完整财务 | 部分完成 | `game/scripts/analytics/portfolio_analytics.gd`、`game/scripts/fees/fee_rule_service.gd`、`game/scripts/tax/tax_workpaper_service.gd`；数据层局部。 | L01–L12 的移动交付及逐项完整证据，特别是历史/税费/对账。 | 以 L 表为清单闭环，记录明确范围调整。 |
| M6 商店发行 | 未实现 | `backend/dev_server.py`、`docs/PROGRESS.md`；没有签名 AAB、真实内购或生产材料。 | B0/B1/B2/B4，T33–T35/T41–T42/T47、许可/隐私/恢复/商店审阅。 | 等正式产品链路可用后准备发行包与审核材料。 |
| M7 iOS 适配 | 未实现 | `docs/COMPATIBILITY.md`、`docs/IMPLEMENTATION_SPEC.md`；仅目标描述。 | 可安装 iOS 测试版、I01–I04。 | 固定跨平台契约后单独实施。 |
| M8 扩展 | 未实现 | `docs/IMPLEMENTATION_SPEC.md` 第 12/16 章；尚无云同步扩展。 | 需先由用户确定各扩展范围，再做迁移、生态隔离和克数守恒验收。 | 在核心产品完成后另立规格与测试。 |
| B0 契约/后端骨架 | 部分完成 | `backend/dev_server.py`、`backend/test_dev_server.py`、`contracts/openapi/dev_backend_v1.openapi.json`；7 项回环 HTTP 测试。 | 可部署测试环境、数据库迁移纪律、鉴权与生产运行手册。 | 从回环开发服务演进为受控测试后端。 |
| B1 自动行情/缓存 | 部分完成 | `game/scripts/quotes/quote_gateway.gd`、`game/tests/quotes/run_quote_tests.gd`；客户端合成 provider。 | 后端自动采集、合法商用来源、供应商切换。 | 建真实 provider 与 T37/T38 网络测试。 |
| B2 AI 草稿/脱敏/熔断 | 部分完成 | `game/scripts/trade/trade_draft_service.gd`、`game/tests/trade/run_trade_tests.gd`；本地规则草稿。 | 后端 AI、脱敏请求审计、费用/故障熔断。 | 接版控草稿契约和服务级 T39–T41。 |
| B3 账号/同步（按需） | 未实现 | `docs/IMPLEMENTATION_SPEC.md` 第 12/16 章；本地首版不以其为前提。 | 若用户选择多设备同步，需账号、冲突解决、隐私与迁移测试。 | 待范围决策后启动，不作为 M6 前置项。 |
| B4 生产安全/恢复 | 未实现 | `backend/README.md`、`docs/PROGRESS.md`；当前仅开发服务器。 | 监控、持久备份/恢复演练、供应商切换、生产安全及运行手册。 | 建生产环境后完成 T41/T42/T47 和故障演练。 |

## 第 17 章质量目标与横向约束

以下编号 `Q01–Q17` 仅为本矩阵的审计索引，并非规格原有编号。规格的目标需在 M0 声明的参考设备、指定数据规模与测量方法下验证；桌面 headless 烟测不能推定手机性能。

| 索引/目标 | 状态 | 证据文件与当前边界 | 尚缺的用户操作或测试 | 下一步任务 |
|---|---|---|---|---|
| Q01 冷启动 3 秒内可交互 | 受外部条件阻塞 | `tmp/android-debug-artifacts/moneybox-debug-20260927-v3.apk` 已构建；`docs/IMPLEMENTATION_SPEC.md` 第 17 章。 | v3 目标设备、指定数据规模、冷启动计时。 | 真机启动后量测。 |
| Q02 壁纸亮屏 1 秒内恢复 | 受外部条件阻塞 | `wallpaper-android/GODOT_SURFACE_FEASIBILITY.md` 无正式桥。 | 真机亮屏、Surface 重建计时。 | 正式壁纸后录像/日志对齐。 |
| Q03 300 豆 95% 帧 ≤33.3 ms | 受外部条件阻塞 | `game/tests/visual/run_capacity_smoke.gd`、`game/tests/visual/run_jar_shake_regression.gd`、KI-007；300 豆 90 tick 的桌面 headless 边界回归通过，不同定向运行的采样 p95 约 17–23 ms，但**不是目标手机渲染帧时间**，且未覆盖真机持续 60 秒。 | 荣耀 Magic 6 Pro 上以 300 豆持续倾斜 60 秒采集实际帧时间，并检查生态同时显示。 | 设备可连接后建立真机性能采样并量测；用户侧先观察 v3 是否仍明显卡顿。 |
| Q04 自由落体偏差 ≤20% | 部分完成 | `game/scripts/visual/jar_smoke_test.gd`、`docs/PROGRESS.md`；改动后桌面固定步长接触时间保持约 0.167/0.217 秒。 | 真机逐帧量测 1/10 克与两种高度。 | 执行 T43。 |
| Q05 碰撞质感 | 受外部条件阻塞 | `game/scripts/visual/jar_view.gd`、`game/tests/visual/run_jar_shake_regression.gd`；合成强摇不越界回归通过，用户 v2 曾看见豆飞出。 | v3 手机高速录屏确认防穿罐、反弹、翻滚与衰减。 | 执行 T44 和所有者视觉确认。 |
| Q06 静置 10 秒稳定 | 受外部条件阻塞 | `game/tests/visual/run_jar_shake_regression.gd` 仅短时合成静置；`docs/COMPATIBILITY.md` 无 T22 真机。 | v3 水平设备静置 10 秒录像。 | 执行 T22。 |
| Q07 不可见不持续渲染/物理/音效 | 受外部条件阻塞 | `wallpaper-android/app/src/main/java/com/jindouguan/wallpaperprobe/ProbeWallpaperService.java` 仅探针生命周期。 | 正式 App/壁纸被覆盖和熄屏活动监测。 | Surface 桥后测 CPU/帧/传感器。 |
| Q08 10000 流水首屏 ≤1 秒 | 部分完成 | `game/scripts/export/ledger_csv_export_service.gd` 有 10000 条导出上限；不是列表性能证据。 | 真实 10000 条账本首屏计时、异步进度。 | 构造脱敏规模样本并测 UI。 |
| Q09 缓存行情 3 秒内批次返回 | 部分完成 | `game/tests/quotes/run_quote_tests.gd` 有合成缓存行为；无实际网络计时。 | 20+3+金供应商、缓存/失败时延。 | B1 后量测 T37/T38。 |
| Q10 AI 10 秒或可恢复失败 | 未实现 | `backend/dev_server.py` 的 AI 未配置；`game/tests/trade/run_trade_tests.gd` 仅本地规则。 | 20 条中英文语句、联网延迟及失败恢复。 | B2 后计时。 |
| Q11 映射重放 100 次幂等 | 已完成 | `game/tests/domain/run_domain_tests.gd`、`docs/PROGRESS.md`；本地库存 hash/revision 不变。 | 本地目标无；多进程消费另见 T27。 | 保留为正式库存回归。 |
| Q12 30 次随机中断无数据丢失 | 部分完成 | `tests/data/test_store_fault_matrix.gd` 有开发双槽故障矩阵；不足 30 次系统中断。 | 保存、导入、合成随机中断及真机文件系统语义。 | 正式数据库完成后故障注入。 |
| Q13 干净安装备份一致 | 部分完成 | `game/tests/backup/run_backup_tests.gd` 本地隔离路径恢复。 | Android 干净安装、认证加密及全实体核对。 | 执行 T30/T31。 |
| Q14 生态+300 豆性能 | 受外部条件阻塞 | `game/tests/visual/run_jar_shake_regression.gd` 验证 300 豆本地运动，`tmp/android-ui-check/` 有 440×960 桌面生态图；两项分别验证，未在手机上同时测量。 | 同机同时运行植物/鱼虾/300 豆的连续帧时间。 | v3 真机性能档验收。 |
| Q15 30 分钟三类耗电对照 | 受外部条件阻塞 | `docs/IMPLEMENTATION_SPEC.md` 第 17 章、`docs/COMPATIBILITY.md`；尚无设备记录。 | 静置、持续晃动、日常亮灭屏，与静态壁纸同条件重复测量。 | 正式壁纸后形成温度/电流/帧率报告。 |
| Q16 所有者视觉确认 | 部分完成 | `docs/evidence/formal_jar_desktop_basic.png`、`docs/evidence/formal_jar_desktop_empty.png`、`docs/evidence/formal_jar_desktop_ecology.png`、`docs/KNOWN_ISSUES.md` KI-009；已有开发侧人工查看。 | 近满/混排、生态双层、图标清晰度、碰撞视频及产品所有者确认。 | 补齐样张与真机录屏后收集明确结论。 |
| Q17 基础无障碍 | 未实现 | `game/scenes/personal_main.tscn`、`game/scenes/personal_asset_entry.tscn` 为本地页面；`docs/PROGRESS.md` 无字体放大/读屏/减少动态效果验证。 | 系统大字、金额读屏、触控面积、减少动态效果。 | Android UI 稳定后逐项测试并修复。 |

## 第 11–14、19 章横向约束

此处汇总不以 U/L/P/T 单独命名、但会阻止交付的实体、异常和隐私约束；状态表第 13 章的具体场景应在相应 T 项端到端测试时逐一核对。

| 规格范围 | 状态 | 证据文件与当前边界 | 尚缺的用户操作或测试 | 下一步任务 |
|---|---|---|---|---|
| 第 11 章继承实体、精度与 ID | 部分完成 | `game/scripts/data/decimal_text.gd`、`game/scripts/data/ledger_core.gd`、`storage/sqlite/migrations/0001_snapshot_bridge.sql`；开发金额字符串和局部事件。 | Portfolio/Institution 等全实体、旧 ID/关联迁移、精度跨 JSON/SQLite/Android 检查；KI-006。 | 建正式实体映射及旧版样本对账。 |
| 第 11 章事务、版本发布、并发 | 部分完成 | `game/scripts/data/project_store.gd`、`game/scripts/data/display_snapshot_service.gd`、`storage/sqlite/test_snapshot_bridge.py`；单进程同版保存与 Python SQL 证明。 | 正式映射/库存同事务、跨进程写锁/读版本、两步重估故障；KI-010/KI-011/KI-013。 | Godot SQLite 接入后执行 T18/T27/T34/T36。 |
| 第 12 章备份、删除、隐私与权限 | 部分完成 | `game/scripts/backup/backup_service.gd`、`game/scripts/data/display_snapshot_service.gd`、`docs/MIGRATION_MATRIX.md`；明文备份和局部隐私载荷。 | 认证加密、系统文件选择器、清空传播、应用锁联动、权限核对、日志审计和用户恢复演练。 | 完成 L12、T30–T32/T47。 |
| 第 13 章完整状态与异常 | 部分完成 | `game/scripts/quotes/personal_gold_flow.gd`、`game/scripts/trade/trade_draft_service.gd`、`game/scripts/ecology/ecology_service.gd`、`game/tests/backup/run_backup_tests.gd`；旧价、待重估、草稿、离线生态等局部状态。 | 规格异常表中壁纸回收/无传感器/购买/迁移失败/过期异步响应等未走用户端到端；“零/无数据/失败”需逐态文案。 | 以第 13 章逐行建立状态机及 UI 故障演练。 |
| 第 14 章权益、合法来源与商店资料 | 未实现 | `backend/dev_server.py`、`docs/PROGRESS.md`；无购买服务、商用行情许可或发行物。 | 用户/法务确认真实收费与行情再分发、许可证、真实媒体及购买恢复。 | M6 前先锁定许可/权益，完成 T33–T35/T47。 |
| 第 19 章工程与数据保护 | 部分完成 | `AGENTS.md`、`.gitignore`、`scripts/verify.ps1`、`docs/DECISIONS.md`；已有规格优先、演示数据隔离、测试及密钥禁入规则。 | 正式 APK/后端依赖和普通/崩溃日志的敏感数据检查；UI 是否只通过命令写账、上一版契约兼容的全链路证据。 | 发布前将这些工程约束纳入代码审查及 T41/T42/T47。 |

## 主要未关闭风险与审计后续

1. **平台路径**：KI-004/KI-005/KI-015 仍约束 Android 真机运行和真正 Godot 动态壁纸。用户已在荣耀 Magic 6 Pro 上试用 v2 并报告横屏黑边、豆飞出与卡顿；v3 仅通过本机竖屏 manifest、签名、对齐和局部视觉/物理回归，本轮无 adb 设备或 v3 手机复测。壁纸探针仍缺 API 36/Gradle 构建路径，Surface 桥和多实例实现缺失。不能用 APK 产出、Canvas 探针或桌面截图替代真机验收。
2. **权威数据**：KI-006/KI-010/KI-011/KI-013 限定了开发 JSON 双槽及两步重估的可靠性边界。SQL+Python 过渡证明尚未成为 Godot/Android SQLite provider；正式跨进程壁纸读取、迁移和失败恢复未达标。
3. **财务与服务**：KI-008、L01–L12、B1/B2/B4 尚缺真实历史、完整资产类型、合法自动行情、AI 和生产后端。KI-002 的系统证书读取错误在联网服务前仍需定位；KI-001 的默认 `user://logs`、KI-012 的 CSV 目标竞态也仍开放。
4. **视觉与规模**：KI-003/KI-007/KI-009 尚需正式 Blender 资源的材质/缩略图问题、混合面额容量和 Android 透明度/性能复核。新强摇回归验证的是桌面合成边界；其 headless 帧时不能代表荣耀 Magic 6 Pro 的丝滑程度，v3 的竖屏可读性与豆不越界也须用户重新试用确认。KI-014 仅关闭“其他估值资产”**本地手工闭环**，不扩大为 L04、Android、正式数据库或整项目完成。
5. **证据维护**：后续真正完成一项时，将代码/测试、实际执行命令与退出码、设备或人工操作证据及剩余限制一起更新本矩阵、`docs/PROGRESS.md` 和 `docs/KNOWN_ISSUES.md`；同时同步落后的 `docs/REQUIREMENTS_TRACE.md`。本次 v3 Android 导出与完整本地回归的实际结果见 `docs/PROGRESS.md`，没有据测试数量计算项目完成百分比。
