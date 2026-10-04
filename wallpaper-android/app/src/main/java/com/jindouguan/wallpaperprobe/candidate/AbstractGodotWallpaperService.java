package com.jindouguan.wallpaperprobe.candidate;

import android.service.wallpaper.WallpaperService;
import android.view.SurfaceHolder;

/**
 * Unregistered adapter scaffold. A concrete subclass must supply a verified Godot surface bridge
 * before it is added to AndroidManifest.xml. The existing diagnostic probe stays independent.
 */
public abstract class AbstractGodotWallpaperService extends WallpaperService {
    private int nextEngineId = 1;
    private WallpaperSurfaceCoordinator coordinator;
    private boolean destroyed;

    protected abstract SurfaceRenderBridge createSurfaceBridge();

    @Override
    public void onCreate() {
        super.onCreate();
        coordinator = new WallpaperSurfaceCoordinator(createSurfaceBridge());
    }

    @Override
    public Engine onCreateEngine() {
        if (coordinator == null || destroyed) {
            throw new IllegalStateException("wallpaper service is not initialized");
        }
        return new HostedEngine(nextEngineId++);
    }

    @Override
    public void onDestroy() {
        if (coordinator != null) {
            coordinator.close();
        }
        destroyed = true;
        super.onDestroy();
    }

    private final class HostedEngine extends Engine {
        private final int id;

        HostedEngine(int id) {
            this.id = id;
        }

        @Override
        public void onCreate(SurfaceHolder holder) {
            super.onCreate(holder);
            setTouchEventsEnabled(false);
            coordinator.add(id, isPreview());
        }

        @Override
        public void onSurfaceCreated(SurfaceHolder holder) {
            super.onSurfaceCreated(holder);
            coordinator.surfaceCreated(id, holder);
        }

        @Override
        public void onSurfaceChanged(SurfaceHolder holder, int format, int width, int height) {
            super.onSurfaceChanged(holder, format, width, height);
            coordinator.surfaceChanged(id, holder, width, height);
        }

        @Override
        public void onVisibilityChanged(boolean visible) {
            super.onVisibilityChanged(visible);
            coordinator.setVisible(id, visible);
        }

        @Override
        public void onSurfaceDestroyed(SurfaceHolder holder) {
            coordinator.surfaceDestroyed(id, holder);
            super.onSurfaceDestroyed(holder);
        }

        @Override
        public void onDestroy() {
            coordinator.remove(id);
            super.onDestroy();
        }
    }
}
