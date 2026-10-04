# 平台兼容性与 M0 实测矩阵

最后整理：2026-09-27。本文件只记录实际验证；待测步骤不等于通过。

| 环境 / 能力 | 当前证据 | 状态 |
|---|---|---|
| Windows Godot 4.7.2，三维场景与数据脚本 | `game/scripts/visual/jar_smoke_test.gd`、`game/tests/visual/inspect_personal_layout.gd`、`scripts/verify.ps1`、`docs/evidence/formal_jar_desktop_{basic,empty,ecology}.png`；详细结果见 `PROGRESS.md` | 本地脚本与正式 GLB 图形截图验证，非真机 |
| Android `WallpaperService` 声明、预览入口、各 Engine 生命周期探针 | `wallpaper-android/` 源码、XML 和 PowerShell 静态检查 | 源码准备；未编译、未安装 |
| Android 主屏幕启用/翻页 | 需要已连接设备、APK、录屏及 logcat | 未实测 |
| Android 锁屏启用/亮屏恢复 | 需要不同厂商设备的系统选择器与生命周期记录 | 未实测 |
| 同时正式壁纸与系统预览 | 需要检查两个 `Engine`、Surface 和展示版本 | 未实测 |
| Godot 渲染到 Android 壁纸 Surface | 当前探针仅 Canvas 诊断画面；未注册的宿主 Surface 仲裁候选和公开接口限制见 `wallpaper-android/GODOT_SURFACE_FEASIBILITY.md` | 候选未编译，无真实 Godot 桥，未实测 |
| 真实重力/线性加速度与场景坐标转换 | 本地 Godot 场景有传感器读入；Android 真机信号与坐标待测 | 未实测 |
| 0.10/0.20 米下落、摇晃、静置、耗电 | 仅本地固定步长测试；需高速录屏及同机静态壁纸对照 | 未实测 |
| iOS App、小组件与壁纸导出 | M7 阶段 | 未实现 |

## 下一轮设备记录模板

| 设备型号 | Android 版本/厂商系统 | 启动器 | 主屏幕 | 锁屏 | 预览多实例 | 传感器 | 恢复与耗电证据 |
|---|---|---|---|---|---|---|---|
| 待填 | 待填 | 待填 | 待测 | 待测 | 待测 | 待测 | 待测 |

优先按 `wallpaper-android/README.md` 的步骤安装平台探针，记录真实设备与日志。平台探针通过后，仍需让同一 Godot 场景接入壁纸 Surface，并重新执行 T21–T26、T43–T44。正式 App 和壁纸预览必须共享权威展示版本；预览不得修改金豆库存。
