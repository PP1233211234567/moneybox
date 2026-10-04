# Android 动态壁纸平台探针

此目录是金豆罐 M0 的独立平台探针。它注册真实的 Android `WallpaperService`，通过系统选择器预览和启用；每个系统 `Engine` 有自己的 `Surface`、动画计时和运动传感器监听。画面明确标为“平台诊断”，不连接账本、不绘制 Godot 画面，也不作为正式产品模型或物理验收证据。

## 当前状态

- 源码和构建配置已准备；本机尚无 JDK、Android SDK、Gradle、ADB 或连接的 Android 真机，因此没有 APK、编译结果或真机结论。
- 依赖固定为 Android Gradle Plugin 8.13.2、Gradle 8.13、JDK 17、Android SDK API 36；最低系统 API 29（Android 10）。[AGP 8.13 官方兼容表](https://developer.android.com/build/releases/agp-8-13-0-release-notes)列出 Gradle 8.13 和 JDK 17。仓库保留 Gradle wrapper 配置及[官方 SHA-256](https://gradle.org/release-checksums/)，但当前没有 wrapper JAR，也没有伪装可执行的 `gradlew.bat`。
- `android:process=":wallpaper"` 将壁纸与启动 Activity 分进程；同一壁纸进程中仍可能同时有预览和正式壁纸两个 `Engine`。
- 探针只记录生命周期、预览标记、Surface 尺寸和传感器注册状态，不记录财务数据。不可见或 Surface 销毁时停止帧循环并注销传感器。恢复可见时重置计时，不补算隐藏时间。

## 构建和安装

在装好上述工具后，于此目录运行：

```powershell
.\build.ps1 -Action check
.\build.ps1 -Action build
.\build.ps1 -Action install
```

脚本使用已存在的 wrapper（需要 JAR 和批处理文件同时存在）或系统 `gradle`。首次建立 wrapper 时，在已安装 Gradle 8.13 的环境执行 `gradle wrapper --gradle-version 8.13`。构建产物为 `app/build/outputs/apk/debug/app-debug.apk`。测试版本的应用 ID 为 `com.jindouguan.wallpaperprobe`，避免误装为正式应用。

## 真机验证步骤

1. 记录设备型号、Android 版本、厂商系统、启动器和 `adb devices` 输出；安装探针并从应用按钮进入系统壁纸选择界面。
2. 先预览，再启用主屏幕壁纸；保持已启用的同时重新打开预览。运行 `adb logcat -s JindouWallpaper:I`，记录多个 `engine=` ID、各自的 `preview=` 值和 Surface 生命周期。确认预览没有替换正式实例。
3. 锁屏、亮屏、解锁、切换应用、切换另一张壁纸再切回；分别记录画面和日志。查询 `adb shell dumpsys wallpaper` 辅助判断系统当前选择。锁屏是否允许单独选择由设备系统决定，不能只凭服务声明推断。
4. 慢慢倾斜或旋转手机，观察 `Sensor x/y/z` 是否变化；在没有相应传感器的设备确认画面显示 `Sensor unavailable`。此探针显示原始向量，没有完成到 Godot 场景坐标的转换。
5. 熄屏至少 30 分钟后亮屏，确认恢复时诊断标记没有跨越不可见时间跳跃。再测试旋转屏幕、系统回收进程和重启后的系统恢复。保存日志、录屏和测试时间。

以上步骤为待执行方案，不能代替实机结果。探针动画仅证明系统 Surface 可连续绘制；T21、T22、T43、T44 的三维金豆碰撞与 Godot 画面还需要单独实现和实测。

## Godot 集成判断

Android `SurfaceHolder` 到 Godot 4.7 渲染器的接口调查、未注册的宿主侧生命周期脚手架，以及准确的验证门槛，见 [Godot Surface 可行性记录](GODOT_SURFACE_FEASIBILITY.md)。该脚手架没有渲染桥实现，也没有改变本探针的注册或绘图。

[Godot 4.7 Android 库文档](https://docs.godotengine.org/en/4.7/tutorials/platform/android/android_library.html)说明可将 Godot 嵌入 Android 应用，同时明确一个进程目前只支持一个 Godot 引擎，自动尺寸或方向变化也有崩溃风险。[Android `WallpaperService` 文档](https://developer.android.com/reference/android/service/wallpaper/WallpaperService)说明正式壁纸与系统预览可同时创建多个 `Engine`。因此 Godot Surface 接入需要实机证明如何处理同时预览、Surface 切换及恢复；本探针没有把 Canvas 画面当作 Godot 成功证据。

已有一个[社区 Godot 动态壁纸插件](https://github.com/TheOathMan/Godot-Android-Live-Wallpaper)，其公开说明针对 Godot 4.5 和 Compatibility renderer，且记录 Android 14 和部分 Samsung 启动器限制。项目目前未引入插件二进制，也未验证它与本项目 Godot 版本、多实例或数据恢复契约兼容。

Android 官方[2026 年 Google Play target SDK 要求](https://developer.android.com/google/play/requirements/target-sdk)规定新应用及更新需面向 API 36 或更高，本探针以 API 36 作构建起点；发行能力仍须按实际工具链、真机和商店要求复核。
