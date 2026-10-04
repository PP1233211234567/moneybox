package com.jindouguan.wallpaperprobe.candidate;

import android.view.SurfaceHolder;

/**
 * Boundary for a future renderer that can draw directly into a WallpaperService.Engine surface.
 *
 * Godot 4.7's published Android AAR does not provide this implementation. In particular, merely
 * creating a GodotFragment or copying its SurfaceView does not bind it to the wallpaper surface.
 * No implementation is registered by this project.
 */
public interface SurfaceRenderBridge {
    /**
     * Acquire the holder and start rendering. Return true only after the renderer owns this exact
     * surface. Return false with no retained holder or renderer resources on failure. The caller
     * will not pass the holder to another bridge until detach returns.
     */
    boolean attach(SurfaceHolder holder, int width, int height, boolean preview);

    /** Called only while the same holder remains attached. */
    void resize(int width, int height);

    /** Stop frame production and sensors before a surface is detached or replaced. */
    void pause();

    /** Synchronously release all references to the attached holder before returning. */
    void detach();

    /** Release the single renderer instance when the wallpaper service is destroyed. */
    void close();
}
