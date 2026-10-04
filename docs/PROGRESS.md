# 项目进度

最后整理：2026-10-04

## 当前状态

- 产品工作名：金豆罐；唯一产品规格是 [`IMPLEMENTATION_SPEC.md`](IMPLEMENTATION_SPEC.md) v1.1。旧木箱留在 `art_source/blender/pipeline_asset.blend` 与 `game/assets/3d/pipeline_asset.glb`，仅供管线演示；游戏主场景已改为金豆罐原型，旧场景另存 `game/scenes/pipeline_demo.tscn`。
- 已建立隔离演示闭环：事件账本记录手工演示现金，十进制映射为金豆克数，库存生成 1 克豆，完整状态写入校验双槽，场景读取同版快照并创建三维刚体。测试实际检查 50→51 颗、场景重建后仍为 51 颗；初始金额 50000 CNY 和金价 1000 CNY/g 均为**演示值**，不代表真实资产或行情。
- 演示罐的基础/生态皮肤与金额隐私设置已本地保存并在重启后恢复；隐藏金额时同时不显示手工参考金价。隐私联动范围目前仅限演示 App 页面，壁纸与小组件仍未接入。
- 个人账本入口已与隔离演示罐分开：空罐建账时由用户输入现金金额和手工黄金参考价，确认后一次保存账本事件、金豆映射与库存。个人现金变动、双槽重启恢复、皮肤、隐私和多罐选择的本地场景测试通过。独立资产录入页可追加账户、股票/ETF/基金身份、期初现金和持仓、同币种转账，以及住房公积金/养老金账户与余额检查点。受限余额独立于可用于买卖和转账的现金；手工完整重估页可按当前账本填写证券/受限余额/汇率/黄金价格，并在覆盖全部有效项时映射到金豆。缴存、提取和利息流水尚未实现；自动报价仍未接入。
- 个人 CSV 批次和本地交易草稿确认已各自贯通 ProjectStore，并有独立的粘贴 CSV 映射页和本地草稿逐项确认页；账本变动与待重估标记一次保存，重启后旧罐明确标为“上次完整快照”。`PersonalGoldFlow` 用绑定同一账本 hash 的完整估值及黄金/汇率批次创建新映射与库存，成功后清除待重估标记；真实供应商、系统文件选择器与远端 AI 尚未接入。
- 已定义 `DisplaySnapshotService` 的最小只读载荷与 JSON Schema，个人和演示流程均生成。它把空罐、当前版和上次完整快照分开，隐私/待重估载荷不发布金额，不包含账户、持仓、交易原文或税务信息。壁纸跨进程读取和 UI 共用渲染入口仍在实施中。
- Blender 正式罐体源文件与 GLB 已生成，Godot JarView 使用正式罐体和 1/10 克豆网格，物理碰撞仍使用独立封闭内舱。三张 Blender 预览及 Windows Godot 图形模式的正式基础、空罐、生态截图已人工查看；金豆略偏深但可辨，Android 样张尚需复核。个人生态状态已驱动正式 GLB 的鱼虾海草可见实例。木箱仍仅是管线演示资产。
- “更多”菜单可进入只读总览与账户、整理金豆、交易草稿、粘贴 CSV、明文备份恢复、流水记录、只读对账检查和流水 CSV 导出；整理页对同一罐的十颗 1 克豆和一颗 10 克豆执行预览、显式确认、单次持久化及重启恢复，账本与映射不变。总览在完整估值绑定当前账本且覆盖全部有效项时，或纯现金账本的当前映射与投影严格一致时显示总额；受限余额单列，隐私模式隐藏金额和精确持仓。流水页保留已冲销原记录，仅筛选展示；对账页比较已记录现金、有效持仓数量和实际买卖手续费，不修改账本，对含受限余额的账本明确返回资料不足，账户总额与待交收仍不构成完整对账。CSV 导出是最多 10000 条、16 MiB 的明文流水表格，包含已冲销原记录，写后检查大小与 SHA-256；目标文件并发创建竞态见 KI-012，它不替代备份。这些页面仍是手机尺寸的本地 Godot 场景，未在手机上验收。
- B0 新增仅监听本机回环的开发 HTTP 骨架与 OpenAPI 3.1 契约，7 项实际 HTTP 测试通过。行情、AI、购买、鉴权与持久存储明确未配置；不能作为生产后端使用。
- `storage/sqlite/` 现有编号 SQL 过渡结构与 4 项 Python SQLite 事务证明：同 generation 项目和最小展示载荷、预期版本冲突、失败回滚与一致性备份。它尚未接 Godot；本机 SQLite 命令行/Python 模块不是 Android 或 Godot 数据库驱动。GDExtension 候选、日志模式风险和迁移门槛见 D-031/KI-013。
- “其他估值资产”的本地闭环已专项验证：个人录入页可新增或更新估值并先预览、显式确认；账本事件、所有权、去重键、依据与待重估标记保存并在重启后恢复。手工完整估值要求外币汇率，确认后把该资产计入总资产与金豆映射；重启后显示为当前快照。专项脚本和场景测试见下文，KI-014 按此本地范围关闭；Android 和正式数据库仍未验收。
- Android 普通应用的隔离调试包由 `scripts/prepare_android_debug.ps1` 和 `scripts/export_android_debug.ps1` 构建：只暂存 `game/project.godot`、`scenes/`、`scripts/`、`assets/`，白名单未复制 `game/tests/`、`game/tmp/` 或 JSON/CSV，密钥类文件名/扩展名被拒。用户已在荣耀 Magic 6 Pro / MagicOS 10（Android 16）侧载前版 v2，并报告横屏黑边、豆子逃出和卡顿；修复候选 v3 在 `tmp/android-debug-artifacts/moneybox-debug-20260927-v3.apk`，包名 `com.jindouguan.moneybox.debug`，本机包结构、竖屏清单、签名和对齐检查通过。**本轮 adb 无设备，v3 尚未在手机上运行或量测**。此包是合成数据开发调试品，不代表正式手机账本或发行包。
- `wallpaper-android/` 提供真实 `WallpaperService` 的平台诊断探针源码，画面只显示系统生命周期与传感器信息；另有未注册的 Surface 生命周期仲裁候选与官方接口可行性记录。**没有接入 Godot、没有壁纸 APK、没有真机验证**；单 Surface 候选不能满足预览和正式壁纸同时连续动画。

## 阶段状态（均未整体验收）

| 阶段 | 已有可验证工作 | 尚缺退出条件 |
|---|---|---|
| M0 系统与物理 | Godot 4.7.2 场景含封闭干燥内舱、50 颗 1 克豆、10 克质量比例、9.81 m/s²、1.0 时间倍率与外层鱼虾海草视觉原型；本地模拟落体/生命周期测试。本地 30/300 刚体烟测通过，300 颗初始建体约 0.4–0.5 秒，仅为桌面 headless 诊断。本轮加入强摇晃封闭性回归：修复前失败、修复后 50/300 豆均未越界；开启物理插值、简化凸碰撞体和加厚封闭碰撞壳，未改变重力或时间倍率。Windows Godot 440×960 竖屏图形截图及个人基础/生态布局已检查；v3 普通 Android 调试 APK 本机静态检查通过。壁纸探针仍只有源码与静态审查。 | 荣耀 Magic 6 Pro 上的 v3 竖屏、场景/数据恢复、强摇晃与实际流畅度复测；其他参考设备物理量测。壁纸探针还需 API 36/Gradle 构建路径，正式 Godot Surface 桥、预览和正式壁纸同时显示、T21–T26/T43–T44、性能/耗电和正式资源真机样张确认。 |
| M1 总账核心 | `decimal_text.gd`、`ledger_core.gd`、`project_store.gd`：现金/转账/买卖、FIFO/移动平均、期初持仓、汇总余额替代、冲销、派息建议与确认；住房公积金/养老金余额检查点单列为受限余额，不能用于现金买卖或转账；开发 Schema v1→v2、双槽恢复、金额入口拒绝浮点；个人现金建账→映射→库存一次保存，T01–T06/T08 本地数值样例与开发双槽迁移/故障矩阵 12 项通过。独立 SQL 过渡结构与 Python 事务证明通过 4 项，尚未连接游戏。 | 正式 SQLite provider、完整实体历史、完整账户与资产类型及受限账户缴存/提取/利息、各已发布版本升级和真机中断矩阵；T34/T36 未完成。 |
| M2 手机账本与后端 | 本地自然语言待确认草稿、确定性校验、显式确认接入 LedgerCore；交易日现金余额预览复核；草稿与个人 CSV 确认各自原子保存账本和待重估状态。独立资产录入、手工重估、草稿确认、粘贴 CSV、只读总览与账户、流水记录、只读对账、明文备份恢复及明文流水 CSV 导出页面经个人页导航可达；CSV 映射、全批预览、重复批次、1000 行错误拒绝、受限余额和其他估值资产本地重估已测。对账检查局限于现金/有效持仓数量/实际买卖手续费，受限余额仍为资料不足；账户总额仅记未验证检查点。历史估值输入契约可核对声明的账本事件片段、分项价值和锁定汇率，尚未接 ProjectStore。B0 回环 HTTP 与 OpenAPI 契约实际跑通。 | 其余完整资产类型、四级手机导航和完整对账、CSV 券商适配与报告导出、历史估值持久化、生产行情/AI 后端、PostgreSQL、加密备份、Android 系统文件选择器；T07–T10/T29–T32/T39–T42 尚无端到端全量验收。 |
| M3 映射与库存 | 手工/测试黄金报价、30 位十进制映射、1/10 克自愿合成拆分、多罐、幂等与重估逻辑；报价身份/缓存/批次/旧价回退和完整账本持仓覆盖校验，批次快照随个人项目双槽保存。个人黄金流已验证同版账本估值→黄金映射→库存一次保存、旧价确认与同金额新事件版本；展示载荷只在账本 hash 匹配时标当前。整理金豆页的同罐选豆、预览、确认、重启及账本不变已有本地测试。 | 合法商用行情、自动调度、全部资产类型映射、手机真机整理操作、T27/T28/T37/T38 完整验收。 |
| M4 生态与稳定 | 外层鱼虾海草与内层刚体隔离。生态状态服务已验证三日离线成长、皮肤切换保留状态、投喂/移动植物不触碰财务快照，并接入个人项目双槽保存与正式 GLB 可见实例；Windows Godot 生态图见 `docs/evidence/formal_jar_desktop_ecology.png`。个人/演示皮肤与隐私选择可恢复。 | 生态水层真机可见度、隐私跨壁纸/小组件、300 豆真机性能与耗电、T45/T46 端到端；正式美术真机确认。 |
| M5–M8 | M5 的派息、历史估值输入契约与 TWR/XIRR、收费规则和税务底稿仍是独立数据层。缺少真实账本 prefix hash 与持续估值持久化时不输出精确历史收益；收费规则无真实券商费率，税务底稿没有有效法规定价规则时明确不输出税额。 | 完整继承财务、发行、iOS、扩展分别按规格验收。 |

## 最近验证证据（按轮次）

- **2026-10-04 首次 GitHub 备份核实**：用户提供个人仓库地址和提交作者后，只读检查发现首次基线提交 `4d2d0478c0f917a8c6b4a6f93b719cd39f700c96`（“备份金豆罐当前开发基线”）及 `origin` 已存在，工作区干净，作者配置与用户提供的信息一致。本轮不重复创建首次快照。`git ls-remote https://github.com/PP1233211234567/moneybox.git` 在沙盒内因无法连接本地代理退出码128；获准在沙盒外重跑退出码0，远程HEAD和master分支均与本地HEAD、origin/master哈希一致，已证明首次代码版本真实上传。仅更新Git备份文档与进度，没有修改游戏功能或运行Godot回归；仓库可见性未用API核对。更新后的日常提交、推送和恢复步骤见 [`GIT_BACKUP_GUIDE.md`](GIT_BACKUP_GUIDE.md)。

- **2026-10-04 Git 版本备份准备**：用户明确授权提交并上传自己的远程仓库。只读检查确认已有 `.git`、分支 `master`，但当时无 commit、无 remote、无提交作者配置；原有暂存与未提交文件均保留。补充 `.gitignore` 排除本地环境、Android 构建与签名文件、开发期双槽账本和数据库；27 项忽略规则检查退出码0。对280个候选文件（约5.5MB）中的252个文本文件进行常见密钥模式扫描，未命中；两张财务截图确认合成测试数据；未声称所有二进制均完成秘密扫描。只修改备份规则与文档，没有修改游戏功能或运行重复的 Godot 回归。远程仓库地址和提交作者信息待用户提供，首次提交及上传必须另以实际 Git 结果确认。后续备份与恢复说明见 [`GIT_BACKUP_GUIDE.md`](GIT_BACKUP_GUIDE.md)。

  备份暂存：首次 `git add --all -- .` 因 `.git/index.lock` 沙盒权限退出码128，获准后重跑退出码0，281个文件进入暂存。新增备份文档后复核253个文本文件仍无常见密钥命中。工作区 `git diff --check` 退出码0；`git diff --cached --check` 退出码2，仅报告既有 `game/scenes/personal_main.tscn:54` 文件末尾空行，保持原场景不改。尚未提交或推送；暂存不构成可回退版本。

- **2026-10-04 Godot / Blender MCP 基础验收**：当前会话真实暴露 75 项 Godot、36 项 Blender 工具，本轮实际调用 15 个不同工具、31 次调用；工具清单不代表全能力验收。Godot 返回 `4.7.2.stable.official.ed1daf0bf` 和正式项目信息，隔离项目创建 ColorRect、运行截图、停止、保存与重开通过；两次停止后 `project.godot` 原哈希恢复，临时接收脚本与 UID 清除。用户澄清并把 Blender 面板端口调整到9877后，状态返回 `5.2.2 LTS`、协议13匹配、遥测内容同意为false；独立测试场景创建立方体、截图、Save Copy及重开通过。两组前后截图的 SHA-256 分别完全相同；5个受保护的正式项目/资源文件哈希未变。3次早期 Blender 连接错误、1次安全模式拒绝及3项 Godot MCP桥警告均保留，安全模式草稿按规则改写后通过。仅使用 `tmp/mcp-acceptance-20261004/` 测试，没有开发正式功能、运行正式全量回归或改变 Android/行情/正式美术验收状态。详细工具名、返回、错误和本地命令退出码见 [`MCP_ACCEPTANCE_20261004.md`](MCP_ACCEPTANCE_20261004.md)。

- **本轮荣耀 Magic 6 Pro 反馈修复**：用户报告前版 v2 在 MagicOS 10（Android 16）出现横屏内嵌竖屏、大黑边且文字小、强摇晃金豆逃逸和初始多豆运动卡顿。本轮在 `game/project.godot` 设置手持竖屏、`expand` 拉伸和物理插值；`game/scripts/visual/jar_view.gd` 将内舱碰撞壳改为 16 个更厚且重叠的墙面及封闭顶底、每颗豆凸碰撞体由 74 点减至 26 点，并对按渲染帧动画的生态分支关闭插值；`demo_app.gd`、`personal_app.gd` 增大主界面文字、输入和按钮。保留 9.81 m/s²、60 Hz、1.0 时间倍率、豆子刚体与 CCD。修复前新合成摇晃测试退出码 1，50 豆与 300 豆均越界；修复后 `game/tests/visual/run_jar_shake_regression.gd` 退出码 0，50 豆连续 360 物理帧强摇晃/倾斜/倒置与独立 300 豆 90 帧最大越界均为 0。一次定向运行的桌面 headless 50 豆 p95 为 20.921 ms、300 豆 p95 为 23.102 ms；它们不是手机渲染帧时间，不能认定 Magic 6 Pro 已流畅。`jar_smoke_test.gd` 退出码 0，落体首次接触仍约 0.167/0.217 秒。
- **本轮布局与可见画面**：`run_capacity_smoke.gd`、`run_demo_scene.gd`、`run_personal_scene.gd` 定向运行均退出码 0。首次 `inspect_personal_layout.gd` 因按钮增大后的生态罐与页脚重叠退出码 1，调整生态镜头后复跑退出码 0；基础罐 jar base 643.47 / footer top 725、生态罐 jar base 551.28 / footer top 570（540×960）。Godot 图形模式的 440×960 合成数据截图 `tmp/android-ui-check/portrait-440x960-v2.png`、`personal-440x960-v3.png`、`personal-opened-440x960-v3.png`、`personal-ecology-440x960-v3.png` 已人工查看：罐体和操作按钮位于竖屏视口内，文字比前版大，生态和个人页底部按钮未裁切。这些都是桌面模拟窗口，不是手机截图。
- **本轮 v3 导出与静态检查**：`scripts/export_android_debug.ps1` 退出码 0；资源 ZIP 131 项、禁止路径 0；`tmp/android-debug-artifacts/moneybox-resources-20260927-v3.zip` 为 785373 字节，SHA-256 `59AFA41930D1A58CB706020B9E4A2103B84AE426B05322EEA9C532344552AC4C`；`tmp/android-debug-artifacts/moneybox-debug-20260927-v3.apk` 为 58372679 字节，SHA-256 `6014B5F812F1BB0B62417AC94AB6F2A81C85CD66CDEFF41F754A618233975B4A`。`aapt dump xmltree` 退出码 0，`com.godot.game.GodotApp` 的 `android:screenOrientation=1`（竖屏），`aapt dump badging` 退出码 0（包名 `com.jindouguan.moneybox.debug`、min SDK 24 / target 36）；`apksigner verify --verbose` 退出码 0（v2/v3 签名），`zipalign -c -v 4` 退出码 0。`adb devices -l` 退出码 0、列表为空；用户本轮无法连接手机，故 v3 未安装/启动/抓日志，也没有 Android 实测 FPS。
- **本轮完整回归**：`& .\scripts\verify.ps1 -Scope all` 退出码 0，**46 个 Godot 脚本与 7 项 Python 回环 HTTP 测试通过**，含新摇晃回归。仍输出 KI-002 的 Windows 根证书读取错误；内嵌壁纸 `build.ps1 -Action check` 在当前环境变量下报告工具 `MISSING`，它只检查环境、不编译壁纸，也不推翻上面绝对路径导出成功的证据。

以下保留前轮 Android 工具链和 KI-014 的原始证据：

- Android 普通应用工具链：`D:\Apps\MoneyboxAndroid\jdk\jdk-17.0.20.1+1`（OpenJDK 17.0.20.1+1）、`D:\Apps\MoneyboxAndroid\sdk`（cmdline-tools 22.0、platform-tools 37.0.1、build-tools 35.0.1、platform android-35 rev2、CMake 3.10.2.4988404、NDK 28.1.13356709）和隔离的 `D:\Apps\MoneyboxAndroid\godot-portable`（Godot 4.7.2 及同版官方 Android 导出模板）。`sdkmanager --list_installed`、`adb version` 退出码均为 0；`adb devices -l` 退出码 0，但设备列表为空。普通 App 使用预构建 Godot 模板导出，不需要 Gradle。模板的调试 APK manifest 为 `minSdkVersion=24`、`targetSdkVersion=36`；项目规格建议首版最低 Android 10，此调试包的最低版本尚未据该建议锁定。
- Android 导出：`scripts/prepare_android_debug.ps1` 创建独立暂存并执行白名单审计；`scripts/export_android_debug.ps1` 的最终运行退出码 0，其中 Godot 导入、资源 ZIP、调试 APK、`apksigner verify` 均退出码 0。`tmp/android-debug-artifacts/moneybox-resources-20260927-v2.zip` 含 131 项，禁止路径命中 0；白名单未复制原项目 `game/tests/`、`game/tmp/` 或 JSON/CSV，文本签名扫描未命中常见 Key 形态。静态审计不能证明任意二进制没有敏感值。`tmp/android-debug-artifacts/moneybox-debug-20260927-v2.apk` 为 58,372,679 字节，SHA-256 `EC028DEBB297CDA76AEF1945F00678FD13E86229A300690A95E42B3E76B06FB1`；包名 `com.jindouguan.moneybox.debug`，含 arm64-v8a/armeabi-v7a 与启动入口。`aapt dump badging`、`aapt dump permissions`、`apksigner verify --verbose`、`zipalign -c -v 4`、APK 内容全读均退出码 0；签名含 v2/v3，未见额外权限。此处的“通过”只覆盖主机上的包静态检查。

  最终导出命令（退出码 0；输出路径不可复用已存在文件名）：

  ```powershell
  & .\scripts\export_android_debug.ps1 -GodotExe 'D:\Apps\MoneyboxAndroid\godot-portable\Godot_v4.7.2-stable_win64_console.exe' -JdkRoot 'D:\Apps\MoneyboxAndroid\jdk\jdk-17.0.20.1+1' -SdkRoot 'D:\Apps\MoneyboxAndroid\sdk' -TemplatePath 'D:\Apps\MoneyboxAndroid\export_templates\4.7.2.stable\android_debug.apk' -ApkPath 'D:\GameProjects\moneybox\tmp\android-debug-artifacts\moneybox-debug-20260927-v2.apk' -PackPath 'D:\GameProjects\moneybox\tmp\android-debug-artifacts\moneybox-resources-20260927-v2.zip'
  ```
- Android 构建中的已处理失败：SDK 尚未装完时脚本预检因缺少 `adb.exe` 退出码 1；工具齐备后首次执行因 PowerShell StrictMode 下读取未设置的 `$LASTEXITCODE` 退出码 1，已修正。随后一次导出在沙盒阻止便携 Godot 临时目录写入时退出码 1，获准后重试；资源 ZIP 成功而 APK 因 ETC2/ASTC 压缩设置不适配退出码 1，仅修正隔离暂存项目的设置后最终成功。SDK 首次安装 platform android-35 时出现 `Error reading Zip content from a SeekableByteChannel`，单独重试后退出码 0；已安装平台文件经 ZIP 全读检查未见损坏。Godot 导出还提示图标未指定，实际设备图标待核验；build-tools 35 回退警告存在于 target SDK 36 模板路径，未见静态包校验失败，真机影响未知。
- 前轮 `& .\scripts\verify.ps1 -Scope all`：**45 个 Godot 脚本和 7 项 Python 回环 HTTP 测试通过，退出码 0**。当时仍打印 KI-002 的 Windows 根证书读取错误，壁纸环境检查未通过验收；该结果已由上方本轮 46 脚本回归更新。
- 前轮 DeepSeek MCP：当时为 Android 导出脚本任务调用 `mcp__deepseek_worker__deepseek_worker` 一次，37.657 秒后返回 `Error executing tool deepseek_worker`；未收到代码草稿，也未重试。可见错误未附 stderr、异常类型或 HTTP 状态，底层原因未知；脚本由 Codex 独立编写、审查和运行。本轮手机画面/物理修复未调用 DeepSeek。
- 前轮 KI-014 验证：当时 `scripts/verify.ps1 -Scope all` 的 **45 个 Godot 脚本和 7 项 Python 回环 HTTP 测试通过**，退出码 0。覆盖十进制、账本、双槽存储、报价、库存、生态、分析、费用、税务与场景回归，以及其他估值资产专项 17 项、资产录入场景 44 项、手工重估场景 41 项。布局脚本确认十条个人财务导航路径；日志写入忽略目录 `tests/logs/`。前轮当时 Android 工具尚缺。本轮完整回归已在上述单独记录。
- 前轮 KI-014 定向验证：`game/tests/data/run_other_asset_tests.gd` 最终 17 项通过，覆盖新增与更新估值、所有权和去重、无写入预览、显式确认、双槽重启、待重估旧快照、USD/CNY 汇率覆盖、完整估值 28200 CNY→28.2 克、金豆映射重启、缺失或过期资产行拒绝认证；`game/tests/integration/run_personal_asset_entry_scene.gd` 44 项通过，检查两张表单与选择器；`game/tests/integration/run_personal_manual_revaluation_scene.gd` 41 项通过，检查重估预览显示该资产的依据与计入总额。专项数据脚本初跑两次均退出码 1，分别为换行赋值的 `Expected an expression after "="`、两个变量的 `Cannot infer the type` 解析错误；修复测试代码后第三次退出码 0，再运行前轮完整回归。Godot 仍输出 KI-002 根证书读取错误。
- 前轮 KI-014 曾调用 `mcp__deepseek_worker__deepseek_worker` 一次，请求只含脱敏的 UI 字段和命令形状；返回 `Error executing tool deepseek_worker`，未收到草稿且未重试。这是历史记录，与本轮 Android 导出脚本的单次调用分开计数。
- 前次报价存储夹具收尾（历史记录）：修改前 `run_quote_store_tests.gd` 为 25 项通过；修改后报价存储 27 项、报价服务 37 项及相关个人流程脚本通过，当时完整本地回归为 44 个 Godot 脚本和 7 项 Python 测试。新断言检查估值提交后待映射标记随快照持久化、重启与幂等重放保留、账本变化后哈希更新、纯现金批次也保留标记。前次 DeepSeek 调用也返回了通用工具错误；本轮未重复该夹具工作。
- `python -m unittest storage.sqlite.test_snapshot_bridge -v`：4 项 SQLite 事务过渡结构证明通过，覆盖同 generation 保存、冲突、回滚与备份；这组独立 Python 测试不在 Godot `verify.ps1` 中，也不证明 Godot 或 Android SQLite provider 可用。
- Windows Godot 图形模式实际输出并人工检查 `docs/evidence/formal_jar_desktop_{basic,empty,ecology}.png`：标题完整、玻璃侧壁和罐底可辨，金豆略偏深。`docs/evidence/finance_desktop_{overview,asset_entry,manual_revaluation,trade_draft,csv_import,bean_organizer,backup_restore,ledger_history,reconciliation,csv_export}.png` 是隔离测试账本的十张 540×960 桌面页面截图；另有 `finance_desktop_restricted_{entry,revaluation,revaluation_bottom,overview}.png` 四张受限余额录入、重估及总览截图。首轮发现表单与选择器文字对比度不足，修改后重拍并检查为清晰可读。长表单需要滚动；这些图不是 Android 画面或壁纸截图。
- 三维烟测在本机 Godot 固定步长下首次接触：1 克与 10 克均为 0.10 米约 0.167 秒、0.20 米约 0.217 秒；理论值分别约 0.143/0.202 秒。它不是传感器真机录像，也不是 T43 的完整通过证据。
- 前轮 `wallpaper-android/build.ps1 -Action check` 曾报告 JDK、Android SDK/API 36、Gradle、ADB 和 Godot 模板缺失；该历史环境检查已被本轮 D 盘工具链安装部分取代。当前**仍缺用于壁纸探针的 SDK platform API 36 与 Gradle 8.13/完整 wrapper**，Android Java/XML 尚未编译；在当前进程未设置环境变量时旧检查脚本仍可能误报新工具链缺失。
- `wallpaper-android/GODOT_SURFACE_FEASIBILITY.md`：按 Godot 4.7 与 Android 官方接口检查，标准 AAR 尚无已证实的壁纸 Engine Surface 注入路径。未注册候选 Java 的 UTF-8、清单注册与尾空格静态检查通过；此结果不等于 Java 编译或 Android 可行性通过。
- Godot 默认日志路径启动复现 KI-001，所有本地验证仍输出 KI-002 系统证书读取错误。指定 `--log-file` 只使测试日志写到工作区，未解决根因。
- 已运行演示与个人场景 headless 50→51→重启恢复。早期截图 `docs/evidence/m0_godot_desktop_preview.png`、`docs/evidence/m0_godot_privacy_preview.png`、`docs/evidence/personal_empty_desktop_preview.png` 拍摄时尚未切换为正式 GLB；当前正式资源与页面证据见上条。

## 下一步直接续做

1. **普通 App 真机步骤**：用户本轮先将 `D:\GameProjects\moneybox\tmp\android-debug-artifacts\moneybox-debug-20260927-v3.apk` 复制到荣耀 Magic 6 Pro 并侧载；如与前版同包名且系统提示更新，先保留数据更新安装，勿为试包删除真实数据。检查是否从启动即竖屏满幅、文字与底部按钮能看清、初始 50 豆运动、强摇晃/倒置后没有豆子越界；用合成数据检查个人页基础/生态、保存与重启恢复，并提供截图/短录像与结果。下轮如可连接 USB 并授权，先确认 `& 'D:\Apps\MoneyboxAndroid\sdk\platform-tools\adb.exe' devices -l` 显示 `device`，再用同一 v3 包 `adb install -r`、启动并采集脱敏 logcat 和帧时间。新包实机结果未取得前不得关闭 KI-015 或 Android 普通应用门槛。
2. **动态壁纸单独继续**：JDK/SDK 基础、ADB、Godot 模板已有；仍需 SDK API 36、Gradle 8.13/完整 wrapper 与目标设备。设置正确环境变量后运行 `wallpaper-android/build.ps1 -Action check/build`，在真机执行 `wallpaper-android/README.md` 的主屏/锁屏/预览/恢复矩阵。先验证系统探针，再按 `wallpaper-android/GODOT_SURFACE_FEASIBILITY.md` 实作并验证 Godot 画面的外部 Surface 桥；不得把 Canvas 探针或未注册仲裁候选当正式画面。
3. 在不依赖设备的工作中，先验证并固定 Godot SQLite provider，再把双槽 JSON 非破坏迁入事务数据库、扩展完整实体与只追加迁移样本；补齐完整资产类型/账户详情/CSV 对账与认证加密备份。将历史估值输入契约、真实账本 prefix hash、当时汇率、外部资金流、TWR/XIRR、税费底稿接入同一持久化流程。自动行情须先确认合法来源，演示数据与个人数据继续隔离。
4. 在目标手机检查正式 GLB 的空罐、50 豆、满罐、1/10 克混排、生态透明排序、字体/表单滚动、传感器落体录像、帧率与耗电。Windows 540×960 截图只能证明本地桌面可见效果。
5. Git 基线文件此前已暂存，新工作文件仍未暂存；本轮未提交，也未访问远程仓库。不要重置或覆盖现有暂存内容。以下命令须由用户在独立 PowerShell 中先审核暂存内容，再决定是否提交：

```powershell
Set-Location 'D:\GameProjects\moneybox'
git status --short
git add -- .gitignore README.md docs/DECISIONS.md docs/KNOWN_ISSUES.md docs/PROGRESS.md docs/COMPATIBILITY.md docs/REQUIREMENTS_TRACE.md docs/MIGRATION_MATRIX.md docs/evidence art_source/blender/gold_jar.blend art_source/blender/previews backend contracts game/project.godot game/assets/3d/gold_jar.glb game/assets/3d/gold_jar.glb.import game/scenes game/scripts game/tests scripts storage tests tools/blender/create_gold_jar.py tools/blender/render_gold_jar_preview.py wallpaper-android
git diff --cached --check
git diff --cached --stat
git diff --cached
git commit -m 'feat: build moneybox local ledger and jar prototype'
```

`git diff --cached` 会包含此前已暂存的 AGENTS、规格、木箱管线文件及主场景基线；提交前必须一并审阅。上述命令不包含 push。
