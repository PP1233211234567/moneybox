# Godot 与 Blender MCP 部署说明

部署说明整理日期：2026-10-03；连接验收更新：2026-10-04。以下是用户在普通 PowerShell 和软件界面执行的部署步骤。用户完成部署并把 Blender 面板端口调整为 9877 后，Codex 已真实通过两条 MCP 的基础场景、截图、临时编辑、保存和重开验收，详见 [MCP_ACCEPTANCE_20261004.md](MCP_ACCEPTANCE_20261004.md)。这不代表所有工具能力、Android 或正式美术已验收；正式项目文件未修改。

## 本机已确认的路径

| 工具 | 路径与实际版本 |
|---|---|
| Godot | `D:\Apps\Godot\Godot-4.7.2\Godot_v4.7.2-stable_win64_console.exe`；4.7.2 stable |
| Blender | `D:\Apps\Blender\blender.exe`；5.2.2 LTS |
| Python | `D:\miniconda\python.exe`；3.13.5 |
| Git | `D:\Apps\Git\cmd\git.exe` |
| Codex 配置 | `C:\Users\10857\.codex\config.toml`；已有 DeepSeek 等配置，必须保留 |
| 游戏项目 | `D:\GameProjects\moneybox\game`，其中有 `project.godot` |

当前 Codex 会话的 PATH 中有内置 Node，但未找到 npm、npx、uv、uvx；这不证明普通 PowerShell 中也缺少它们。先在普通 PowerShell 检查 `Get-Command node,npm,npx,uvx -ErrorAction SilentlyContinue`。下面使用独立 D 盘路径，避免依赖 Codex 内置运行时或改变 DeepSeek 环境。

## 1. 准备独立目录和 Node

先保存 Godot 和 Blender 中打开的文件。前期连接验收使用临时项目和临时 Blender 场景。

从 [Node.js 官方下载页](https://nodejs.org/en/download)下载当前 LTS 的 Windows x64 ZIP，解压并整理到 `D:\Tools\nodejs`，使该目录直接包含 `node.exe`、`npm.cmd`。若该目录已有安装，保留它，检查版本并据实际路径调整后续命令；不要覆盖已有目录。Godot MCP 候选要求 Node 20+。

```powershell
& 'D:\Tools\nodejs\node.exe' --version
& 'D:\Tools\nodejs\npm.cmd' --version
```

这两条必须成功。后续逐步执行，某一步失败就停止该安装路线并保留错误，不把失败后的后续命令当作安装成功。

## 2. 安装 Godot MCP 候选

本项目使用标准 Godot 和 GDScript。本说明选择 [Vollkorn-Games/godot-mcp](https://github.com/Vollkorn-Games/godot-mcp)，因其文档包含场景检查、运行截图、输入模拟和性能查询。它是社区工具；2026-10-04 已在本机隔离项目通过本说明末尾的基础验收，输入模拟和性能查询等其他能力仍未验收。安装时固定其本地检出和锁文件；先在临时项目验证，再用于游戏。

以下目录不存在时执行。若已存在 `godot-mcp` 检出，先检查其来源和状态，不重复克隆或覆盖。

```powershell
New-Item -ItemType Directory -Path 'D:\Tools\MCP' -Force | Out-Null
& 'D:\Apps\Git\cmd\git.exe' clone https://github.com/Vollkorn-Games/godot-mcp.git 'D:\Tools\MCP\godot-mcp'
```

在**同一个 PowerShell 窗口**中安装该候选当前声明的 pnpm 版本并构建。以下命令逐行执行，每步成功再继续；`--version` 应显示 `10.28.2`，依赖安装成功后才运行构建：

```powershell
$env:Path = 'D:\Tools\nodejs;D:\Tools\MCP\pnpm\node_modules\.bin;' + $env:Path
& 'D:\Tools\nodejs\npm.cmd' install --prefix 'D:\Tools\MCP\pnpm' 'pnpm@10.28.2'
& 'D:\Tools\MCP\pnpm\node_modules\.bin\pnpm.cmd' --version
Set-Location 'D:\Tools\MCP\godot-mcp'
& 'D:\Tools\MCP\pnpm\node_modules\.bin\pnpm.cmd' install --frozen-lockfile
& 'D:\Tools\MCP\pnpm\node_modules\.bin\pnpm.cmd' run build
Test-Path -LiteralPath 'D:\Tools\MCP\godot-mcp\build\index.js'
& 'D:\Apps\Git\cmd\git.exe' rev-parse HEAD
```

记录最后的 commit ID；`build\index.js` 必须存在。这些安装/构建命令尚未在本轮执行；若依赖或协议兼容失败，保留底层错误，先解决候选工具，不改动游戏来迁就它。

路径更正：这里的 npm 命令使用局部安装，启动文件在 `node_modules\.bin\pnpm.cmd`，不是安装目录根下的 `pnpm.cmd`，参见 [npm 可执行文件目录说明](https://docs.npmjs.com/cli/v11/configuring-npm/folders/#executables)。用户已成功安装 pnpm；本机只读检查确认原路径不存在、正确路径存在，实际运行正确路径的 `--version` 返回 `10.28.2`，退出码 0。已安装成功时无需重装 pnpm或重新克隆 Godot MCP，直接从修正 PATH 和验证版本继续。Git commit ID 只能证明检出版本，不能证明构建成功。

## 3. 安装 Blender MCP 的独立 Python 环境

选择 [ahujasid/mcp-for-blender](https://github.com/ahujasid/mcp-for-blender)。核查时仓库版本为 2.1.3，且 [PyPI 已发布该版本](https://pypi.org/project/mcp-for-blender/2.1.3/)；Python 包声明支持 3.10+，入口为 `mcp-for-blender`。以下使用新 venv 安装该版本，是根据包定义采用的独立安装方式；维护者 README 另提供 uv/pipx 路线。用户完成安装后，2026-10-04 已通过真实 MCP 场景、截图和保存重开验收。不要复用或修改 `D:\API\DeepSeek` 的环境。

这条安装路线由 `pip` 自动下载 Python 包及依赖，无需先手动下载 GitHub 仓库。PowerShell 安装完成后，仍须在 Blender 界面安装包内的 `addon.py` 并启动连接，然后完成 Codex 配置。

若 `.venv` 已存在，先检查，不覆盖重建：

```powershell
New-Item -ItemType Directory -Path 'D:\Tools\MCP\blender' -Force | Out-Null
& 'D:\miniconda\python.exe' -m venv 'D:\Tools\MCP\blender\.venv'
& 'D:\Tools\MCP\blender\.venv\Scripts\python.exe' -m pip install 'mcp-for-blender==2.1.3'
& 'D:\Tools\MCP\blender\.venv\Scripts\python.exe' -m pip show mcp-for-blender
Test-Path -LiteralPath 'D:\Tools\MCP\blender\.venv\Scripts\mcp-for-blender.exe'
Test-Path -LiteralPath 'D:\Tools\MCP\blender\.venv\Lib\site-packages\blender_mcp\bundled\addon.py'
```

然后在 Blender 中操作：

1. 打开偏好设置 → 插件 → 从磁盘安装（部分版本在右上角菜单）。
2. 选择上面安装包内的 `addon.py`，启用 **MCP for Blender**。
3. 在三维视图按 `N` 打开侧栏，找到 MCP 面板。
4. 如已连接，先 Disconnect；把端口设为 **9877**，再 Connect / Start MCP Server。
5. 初次验证使用临时场景，保持本机监听；关闭外部素材库/付费生成服务和内容遥测选项。后续需要这些服务时单独评估。

**端口原因**：这个 Godot 候选的交互模式和 Blender 默认都用 9876。因此本说明保留 Godot 9876，把 Blender 改为 9877；Codex 里的 `BLENDER_PORT` 必须与 Blender 面板一致。Blender 端口设置随场景状态变化，打开另一份 `.blend` 后再次检查面板。不要同时启动多个客户端争用同一 Blender 实例。

### 保存 9877，使重新启动也沿用

已安装插件把 `blendermcp_port` 定义为 **Scene 属性**，默认 9876，端口会随 `.blend` 场景保存。保存一个测试文件不会同时更新 Blender 默认启动场景；仅保存偏好设置也不会保存这项 Scene 属性。

希望普通启动和新建通用文件默认使用9877时，由用户在 Blender 界面操作：

1. 先保存当前有用的工作，再选择“文件 → 新建 → 通用”，使用希望以后默认打开的干净场景。
2. 按 `N` 打开 MCP 面板；如已连接，先 Disconnect，让端口输入框显示。
3. 将端口设为9877，再启动连接，确认面板显示 `Connected on port 9877`。
4. 选择“文件 → 默认 → 保存启动文件”（`File → Defaults → Save Startup File`），确认保存。
5. 关闭并重新打开 Blender，检查端口仍为9877；若连接未启动，点击连接。

“保存启动文件”会把当前场景与界面作为默认，所以先使用干净场景，不把临时验收立方体或正式罐体保存成启动场景。菜单和启动文件作用参见 [Blender 官方默认设置说明](https://docs.blender.org/manual/en/latest/getting_started/configuration/defaults.html)。打开旧 `.blend` 时仍会加载该文件自己的端口；需要在该文件中改为9877并按 `Ctrl+S` 保存，启动文件设置不会覆盖旧文件。

2026-10-04 用户报告重新启动 Blender 后回到9876；本说明已补齐上述持久化操作。前轮通过了临时 `.blend` 保存重开及两条 MCP 基础调用，**没有验证保存默认启动文件后的整软件重启**。上述用户界面操作本轮尚未执行，不将这一项标为已通过。

可在 PowerShell 检查监听：

```powershell
Get-NetTCPConnection -State Listen -LocalPort 9877 -ErrorAction SilentlyContinue |
    Select-Object LocalAddress,LocalPort,OwningProcess
```

监听存在只证明端口启动，不能证明 MCP 调用完成。

## 4. 向 Codex 添加两个服务

按 [OpenAI 官方 MCP 配置文档](https://developers.openai.com/codex/mcp)，STDIO 服务可在 `config.toml` 的 `[mcp_servers.<name>]` 下配置。本机继续用已有用户级配置，避免重复配置。

先备份，随后用编辑器打开：

```powershell
$taskConfig = 'C:\Users\10857\.codex\config.toml'
$taskBackup = $taskConfig + '.bak-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
Copy-Item -LiteralPath $taskConfig -Destination $taskBackup
notepad.exe $taskConfig
```

仅在不存在同名条目的情况下，把下面两段**追加到文件末尾**。保留原来的 DeepSeek、其他 MCP、模型和沙盒配置。这里的路径对应本说明的安装位置；若实际位置不同，先替换为真实绝对路径。

```toml
[mcp_servers.godot]
command = 'D:\Tools\nodejs\node.exe'
args = ['D:\Tools\MCP\godot-mcp\build\index.js']
startup_timeout_sec = 60
tool_timeout_sec = 180
enabled = true

[mcp_servers.godot.env]
GODOT_PATH = 'D:\Apps\Godot\Godot-4.7.2\Godot_v4.7.2-stable_win64_console.exe'

[mcp_servers.blender]
command = 'D:\Tools\MCP\blender\.venv\Scripts\mcp-for-blender.exe'
args = []
startup_timeout_sec = 60
tool_timeout_sec = 180
enabled = true

[mcp_servers.blender.env]
BLENDER_HOST = 'localhost'
BLENDER_PORT = '9877'
BLENDER_MCP_SAFE_MODE = '1'
DISABLE_TELEMETRY = 'true'
```

两段使用 TOML 单引号，Windows 反斜杠无需加倍。不要把其他客户端的 `mcpServers` JSON 整块贴进 TOML。超时只是等待上限，不保证耗时操作成功；长渲染应拆分执行和取结果。MCP 标准输出留给协议，额外诊断应写 stderr 或脱敏文件。

保存后**完全退出并重新打开 Codex**。不要在普通终端长期运行同一份 STDIO MCP 服务；让 Codex 按配置启动。Blender 软件及其侧栏连接需保持运行。

## 5. 真正验收，不能只看“已启用”

重启后可在本聊天继续，或在**同一 moneybox 项目**中新建聊天。先发送下面这段：

```text
先验收新部署的 Godot 和 Blender MCP，不开发正式功能。
列出当前会话实际可调用的相关工具名称，不把服务器名称当工具名称。
真实调用 Godot 版本和项目信息工具；项目路径为 D:\GameProjects\moneybox\game。
真实调用 Blender 插件状态、场景信息和视口截图工具。
随后仅在项目 tmp 下的隔离 Godot 测试项目和独立临时 Blender 场景中，
各完成一次创建对象、运行/查看、截图反馈、保存并重开验证。
Godot 交互工具可能临时修改 project.godot/autoload，必须先在隔离项目验证清理恢复。
不要修改正式场景、覆盖 gold_jar.blend、读取个人账本或打印密钥。
逐项报告实际工具名、返回结果和错误；工具缺失或失败要如实记录。
```

只有两个工具链各自真实返回场景信息、可查看画面和临时编辑验证结果，才算初步接通。Godot 文档宣称的运行桥清理行为仍须本机验证；构建成功、配置启用和一条 OK 回复均不能代替这个验收。

## 接通后续做

建议在同一个 moneybox 项目下新开“金豆罐体验重设计与行情接入”聊天，使用 [CONTINUATION_PROMPT.md](CONTINUATION_PROMPT.md)。新聊天是交接选择，不是新项目；MCP 是否可用以实际工具清单和返回为准。现有聊天也可以继续。

外部股价、基金净值、汇率、黄金行情 API 属于软件运行时需求，和开发用 Godot/Blender MCP 分别配置。现有规格 U15 与第 10 章已经要求自动行情；新提示词进一步明确真实供应商联调、许可、时间标记、失败回退和密钥保留在后端。

其他核查依据：[Godot 候选的构建依赖](https://github.com/Vollkorn-Games/godot-mcp/blob/main/package.json)、[Blender Python 包定义](https://github.com/ahujasid/mcp-for-blender/blob/main/pyproject.toml)、[Blender 插件端口面板源码](https://github.com/ahujasid/mcp-for-blender/blob/main/addon.py)。

2026-10-03 说明验证：6 个 PowerShell 命令块仅做语法解析，0 个语法错误；1 个 TOML 配置块通过 Python `tomllib` 解析，并确认 Blender 端口为 9877。该轮没有执行安装命令或修改用户级配置。验证过程首次 TOML 提取受外层 PowerShell 引号转义影响而失败，改用字面量脚本后通过，配置内容本身没有解析错误。

2026-10-04 用户部署后的基础验收通过：真实版本、场景、截图、创建对象、保存和重开均成功；Godot 两次停止后均恢复原配置并清理临时接收脚本。早期 Blender 连接错误、安全模式拒绝和 Godot 接收脚本警告保留在验收记录中。再次部署或更新版本后，仍需重新核实实际能力。
