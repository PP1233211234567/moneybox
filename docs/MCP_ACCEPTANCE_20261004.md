# Godot 与 Blender MCP 基础验收

日期：2026-10-04；工作目录：`D:\GameProjects\moneybox`。

## 结论与范围

用户部署并把 Blender 面板端口调整为 9877 后，两条 MCP 路径均通过本轮基础验收：读取真实版本/场景，创建隔离对象，取得并查看截图，保存到磁盘，从磁盘重开，验证对象和画面保持，验证 Godot 临时注入清理。本次不开发正式功能；没有运行正式游戏全量回归、导出 APK 或验收 Android/动态壁纸/正式美术。

当前实际暴露 75 项 Godot 工具、36 项 Blender 工具，完整名称见 [工具清单](../tmp/mcp-acceptance-20261004/tool-inventory.md)。本轮仅验收下表涉及的能力，不宣称其余工具已通过。

实际安装版本只读核对：Blender MCP 独立环境为 Python 3.13.5、`mcp-for-blender` 2.1.3；Godot MCP 本地 commit 为 `632530638448ea3e79394fbf74e9a5c92c4b67e5`。这些版本读取命令退出码均为0。

## 实际工具调用

| 完整工具名 | 实际返回与判定 |
|---|---|
| `mcp__godot__get_godot_version` | `4.7.2.stable.official.ed1daf0bf`；通过。 |
| `mcp__godot__get_project_info` | 正式项目名“金豆罐”，路径 `D:\GameProjects\moneybox\game`，14 scenes / 88 scripts / 4 assets / 2457 other；这是读取结果，不是产品完成度。 |
| `mcp__godot__create_scene` | 在隔离项目创建 `acceptance.tscn`，根 Node2D，Pack/Save 均 OK。 |
| `mcp__godot__add_node` | 创建 `AcceptanceSquare` ColorRect；位置 (220,140)、大小 (200,200)、金黄色。 |
| `mcp__godot__run_interactive` | 两次启动隔离场景；接收器监听 `127.0.0.1:9876`，临时注入 `_McpInputReceiver`。 |
| `mcp__godot__evaluate_expression` | 两次 `ok:true`、`square_exists:true`，位置与大小保持。第二次来自停止、保存并重新启动后的实例。 |
| `mcp__godot__game_screenshot` | 两次真实运行截图，均 640×480，已查看；首次和重开后的 PNG SHA-256 完全一致。 |
| `mcp__godot__get_debug_output` | 返回实际 OpenGL 3.3、Intel Arc 140T GPU、接收器监听及连接日志；桥脚本有下述 3 项警告。 |
| `mcp__godot__stop_project` | 两次返回 `Godot project stopped`。每次停止后配置恢复、接收脚本及 UID 均不存在。 |
| `mcp__godot__save_scene` | 第一次停止后将隔离 `acceptance.tscn` 重新保存；返回 Pack/Save OK，随后重开验证。 |
| `mcp__blender__get_addon_status` | 早期两次连接错误；端口调整后成功。Blender `5.2.2 LTS`、addon 1.8、协议 13/预期 13、`up_to_date:true`、`telemetry_consent:false`、无付费生成器。 |
| `mcp__blender__get_scene_info` | 首次连接失败；随后成功取得默认 Scene 的 Cube/Light/Camera。创建和重开后分别返回 `MCP_Acceptance_Temporary`，含一个 `MCP_Acceptance_Cube`。 |
| `mcp__blender__get_viewport_screenshot` | 三次真实返回 PNG：初始默认场景、创建后的测试场景、重开后的测试场景；已查看实际画面。 |
| `mcp__blender__bpy_api_lookup` | 真实查询 `bpy.ops.wm.save_as_mainfile` / `bpy.ops.wm.open_mainfile`，确认本机参数含 copy、filepath、load_ui、use_scripts。 |
| `mcp__blender__execute_blender_code` | 只读检查当前 filepath 为空、is_dirty:true、端口9877。保留默认场景，另建独立场景与 8 顶点/6 面立方体；Save Copy 到 tmp，再用 `use_scripts=False` 重开并断言对象、标记和端口保持。一次截图辅助写法被安全模式拒绝，改写后成功。原 Scene 的 Camera/Cube/Light 保留。 |

MCP 工具返回不是 shell 命令退出码；不能把文本返回中的成功/错误转换成虚构进程退出码。完整调用返回和客户端观察耗时见 [call-log.json](../tmp/mcp-acceptance-20261004/call-log.json)。其中耗时包含连接/等待，不用于推断编辑器或游戏性能。

## 隔离与恢复证据

- 独立 Godot 项目：`tmp/mcp-acceptance-20261004/godot/`，只有合成测试对象；未复制个人账本或正式场景。
- 独立 Blender 场景：`MCP_Acceptance_Temporary`。开始时 Blender 未打开任何 `.blend` 文件，原默认场景与对象保留。保存副本 `tmp/mcp-acceptance-20261004/blender_acceptance.blend`，重开后该测试文件成为当前打开文件。
- Godot 配置启动前和两次停止后 SHA-256 均为 `A34A3E59136AD9207AED748615D16713D6B013D68BF7E4D40BD809AC236FE610`。`.mcp_input_receiver.gd` 与其 `.uid` 均已清除。
- 受保护文件 `game/project.godot`、`game/scenes/main.tscn`、`game/scenes/jar_view.tscn`、`game/assets/3d/gold_jar.glb`、`art_source/blender/gold_jar.blend` 的前后 SHA-256 全部一致，详情见 [checks.json](../tmp/mcp-acceptance-20261004/checks.json)。
- Godot 两张 PNG SHA-256 均为 `F4A83D5587A96FBA85BA95E582AA0B32E10FD1FE0A61434D42AD5C678075DFFC`；Blender 两张离屏 PNG SHA-256 均为 `C22CFF8068028ACD80BD6787F9601A2FD051895F9559484A044CB94D8AD06DC5`。

## 失败、改写与实际限制

1. Blender 插件状态两次、场景信息一次返回 `Could not connect to Blender. Make sure the Blender addon is running.`。工具的 `isError:false` 不会消除文本中的实际失败。用户澄清先前端口确认有误并调整到9877后，后续场景、状态、截图、编辑及重开均成功。早期错误没有暴露底层 WinSock 类型或错误码，不编造原因。
2. `Get-NetTCPConnection` 在沙盒内报 `Microsoft.Management.Infrastructure.CimException: 拒绝访问`。最初检查组合命令退出1；随后捕获错误的只读诊断退出0，并确认 Blender 进程10668在运行。端口监听没有通过这条 CIM 命令验收；之后实际 MCP 调用和 Blender 场景属性确认9877。
3. 第一次重开草稿在执行前被 `BLENDER_MCP_SAFE_MODE=1` 拒绝：`line 5: bpy.types is a module namespace and may not be used as a value; continue the path to a concrete attribute or call`。代码中的 `getattr(bpy.types, ...)` 改为已核查的具体属性调用；没有关闭安全模式。用已安装验证器做 AST 预检后，再真实调用 MCP，截图及重开成功。修正脚本见 [blender-reopen.py](../tmp/mcp-acceptance-20261004/blender-reopen.py)。
4. Godot MCP 自带接收脚本有3项 GDScript 警告：第326行 name 遮蔽 Node 属性；第580行 lambda capture 重赋值不修改外层 received；第1124行三元表达式类型不兼容。两次运行均有警告，本次运行/查询/截图/清理通过。信号等待、输入批处理等其他桥能力未验收，未修改第三方 MCP 源码。
5. 验收结束后用户报告关闭并重启 Blender 时端口恢复9876。插件端口是 Scene 属性，临时 `.blend` 保存重开的通过证据仍成立，但默认启动文件持久化未验收。部署说明已补充“在干净场景设置9877并保存启动文件”的界面步骤；用户执行并重启核对前，不标为启动端口持久化通过。Codex 配置仍要求9877，重新启动后实际端口须与之匹配。

## 本地命令与退出码

| 命令或检查 | 退出码 | 结果 |
|---|---:|---|
| 目录、AGENTS、Git状态、部署说明只读检查 | 0 | 项目目录确认；保留已有修改。 |
| Blender 配置过滤 + CIM端口/进程首次检查 | 1 | 安全字段读取成功；端口/进程检查没有得到有效结果。 |
| 明确捕获异常的 CIM端口和 Blender进程诊断 | 0 | CIM拒绝访问已记录；看到Blender进程，不能据此认定端口已监听。 |
| `D:\Tools\MCP\blender\.venv\Scripts\python.exe -c ...validate_code(...)` | 0 | 修正后的重开脚本 Safe-mode preflight PASS。 |
| `Get-FileHash` + Godot注入清理/前后截图/保护文件检查 | 0 | 两组截图相同，配置恢复，5个正式文件未变。 |
| 独立 venv 的 Python/package 版本读取；`git -C D:\Tools\MCP\godot-mcp rev-parse HEAD` | 0 | Python 3.13.5 / mcp-for-blender 2.1.3 / 上述 Godot MCP commit。 |

## 可查看的结果

- [Godot 首次画面](../tmp/mcp-acceptance-20261004/godot-first.png) / [重开画面](../tmp/mcp-acceptance-20261004/godot-reopened.png)。
- [Blender 首次画面](../tmp/mcp-acceptance-20261004/blender-first.png) / [重开画面](../tmp/mcp-acceptance-20261004/blender-reopened.png)。
- [Blender 测试文件](../tmp/mcp-acceptance-20261004/blender_acceptance.blend)。Blender 当前打开的是该临时文件；正式 gold_jar.blend 没有被打开或覆盖。

下一步可使用既有续写提示词进入体验重设计与真实行情接入。此验收只解除两个开发工具的基础连接条件，不关闭 Android、动态壁纸、正式美术或真实行情的产品验收缺口。
