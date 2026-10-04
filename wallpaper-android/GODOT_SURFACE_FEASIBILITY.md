# Godot 画面接入 Android 动态壁纸：平台可行性状态

日期：2026-09-27。这里记录 M0 的代码证据和未验证边界；现有 `ProbeWallpaperService` 仍是独立的 Android Canvas 诊断探针。

## 已确认的接口形状

- Android 的 [`WallpaperService.Engine`](https://developer.android.com/reference/android/service/wallpaper/WallpaperService.Engine) 向每个壁纸实例提供自己的 `SurfaceHolder`，并通过 `onSurfaceCreated`、`onSurfaceChanged`、`onSurfaceDestroyed` 和 `onVisibilityChanged` 报告生命周期；[WallpaperService](https://developer.android.com/reference/android/service/wallpaper/WallpaperService) 可以同时有预览与已启用的 `Engine`。
- [Godot 4.7 Android 库文档](https://docs.godotengine.org/en/4.7/tutorials/platform/android/android_library.html) 支持把 AAR 嵌入 Android 应用，但说明目前每个进程只支持一个 Godot 引擎实例，并提醒自动尺寸或方向变化可能崩溃。
- 对 [Godot 4.7 `Godot.kt`](https://github.com/godotengine/godot/blob/4.7-stable/platform/android/java/lib/src/main/java/org/godotengine/godot/Godot.kt) 的源码检查显示，`onInitRenderView` 自行创建 `GodotVulkanRenderView` 或 `GodotGLRenderView` 并添加到宿主 `FrameLayout`。[OpenGL 实现](https://github.com/godotengine/godot/blob/4.7-stable/platform/android/java/lib/src/main/java/org/godotengine/godot/GodotGLRenderView.java) 继承 `GLSurfaceView`，[Vulkan 实现](https://github.com/godotengine/godot/blob/4.7-stable/platform/android/java/lib/src/main/java/org/godotengine/godot/GodotVulkanRenderView.java) 继承 `VkSurfaceView`。这些代码没有展示把外部 `WallpaperService.Engine.getSurfaceHolder()` 交给现成 AAR 渲染视图的入口。此项是对公开文档与源码的判断，仍需在目标 AAR/设备上验证，不是对所有改造路径不可能的证明。

直接用 `GodotFragment` 或把它的 `SurfaceView` 加到 Activity，只会在该 View 自己的 Surface 绘图；它不会自动画入壁纸 Engine 的 Surface。单进程单 Godot 引擎也不能推出两个可同时绘制的预览和已启用壁纸画面。

## 已落地的适配边界

`app/src/main/java/com/jindouguan/wallpaperprobe/candidate/` 包含三个**未注册**的 Java 类：

- `AbstractGodotWallpaperService` 将每个 Engine 的创建、可见性、尺寸变化、Surface 销毁和实例销毁传给协调器。
- `WallpaperSurfaceCoordinator` 在一个服务进程里只租出一个 Surface；可见预览优先，然后选择最近变为可见的已启用实例。切换前调用 `pause`、`detach`，Surface 销毁回调返回前同步释放引用，忽略旧 holder 的迟到回调。
- `SurfaceRenderBridge` 是未来渲染器需要实现的最小接口。当前没有实现，候选服务也没有加入 `AndroidManifest.xml`，因此不会伪装成已显示 Godot 的壁纸。已启用与预览同时可见时，这个单 Surface 策略会暂停非选中实例，**不满足**双实例同时连续动画或无缝预览验收。

上述宿主侧脚手架是为了隔离生命周期问题。实际 `SurfaceRenderBridge` 仍需要经过编译和真机验证的 Godot 4.7 渲染后端适配；可能涉及修改 Godot Android 平台层，将外部 `Surface`/`ANativeWindow` 交给 OpenGL/Vulkan 初始化和恢复路径，之后构建与应用版本匹配的 AAR/模板。不能只传 `SurfaceHolder` 给 GDScript 或使用标准 AAR 嵌入示例来代替此步。是否可在满足预览与正式壁纸并存、可见性切换及尺寸变化的前提下完成，当前未知。

## 本机验证及后续门槛

本次运行 `wallpaper-android/build.ps1 -Action check`，脚本返回成功并报告 JDK `java`、Android SDK、API 36、Gradle 可执行文件和 ADB 均缺失；仓库也没有 wrapper JAR。Python 标准库解析 `AndroidManifest.xml` 成功，确认仍只注册 `.ProbeWallpaperService`；三个候选 Java 文件均可按 UTF-8 读取且无行尾空格。这些是静态检查，不能代替 Java 编译。候选源码未编译，未生成 APK，未接入 Godot AAR，未在 Android 真机展示画面。`ProbeWallpaperService`、其清单注册和诊断画面均未修改。

下一次取得工具链后，先运行 `./build.ps1 -Action build` 验证现有探针和候选源码编译，再在设备上执行 README 的预览、启用、并存、切换、回收与恢复测试。实现真实渲染桥后，还需分别验证：实际画面确实来自 Godot 项目；预览与已启用实例同时可见时各自内容和帧更新；Surface 重建/方向变化无崩溃；不可见时停止帧与传感器；重启后从持久化状态恢复。只有这些实测通过，才可关闭规格中的 Android/Godot 动态壁纸风险。
