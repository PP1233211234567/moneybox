package com.jindouguan.wallpaperprobe.candidate;

import android.view.SurfaceHolder;

import java.util.LinkedHashMap;
import java.util.Map;

/** Main-thread-only lease manager for the service's one prospective Godot renderer. */
final class WallpaperSurfaceCoordinator {
    private static final class Target {
        final boolean preview;
        SurfaceHolder holder;
        boolean visible;
        int width;
        int height;
        long visibleOrder;

        Target(boolean preview) {
            this.preview = preview;
        }

        boolean canRender() {
            return visible && holder != null && width > 0 && height > 0;
        }
    }

    private final SurfaceRenderBridge bridge;
    private final Map<Integer, Target> targets = new LinkedHashMap<>();
    private long nextVisibleOrder;
    private Integer attachedId;
    private int attachedWidth;
    private int attachedHeight;
    private boolean closed;

    WallpaperSurfaceCoordinator(SurfaceRenderBridge bridge) {
        if (bridge == null) {
            throw new IllegalArgumentException("renderer bridge is required");
        }
        this.bridge = bridge;
    }

    void add(int id, boolean preview) {
        if (closed || targets.containsKey(id)) {
            throw new IllegalStateException("duplicate or closed wallpaper engine");
        }
        targets.put(id, new Target(preview));
    }

    void surfaceCreated(int id, SurfaceHolder holder) {
        Target target = targets.get(id);
        if (target == null || holder == null || closed) {
            return;
        }
        if (attachedId != null && attachedId == id) {
            // A new holder for the same Engine is a new render target even when size matches.
            detach();
        }
        target.holder = holder;
        target.width = 0;
        target.height = 0;
        reconcile();
    }

    void surfaceChanged(int id, SurfaceHolder holder, int width, int height) {
        Target target = targets.get(id);
        if (target == null || target.holder != holder || closed) {
            return; // An old Surface callback must never acquire a newer surface.
        }
        target.width = width;
        target.height = height;
        reconcile();
    }

    void surfaceDestroyed(int id, SurfaceHolder holder) {
        Target target = targets.get(id);
        if (target == null || target.holder != holder || closed) {
            return;
        }
        target.holder = null;
        target.width = 0;
        target.height = 0;
        reconcile(); // pause and detach before Android releases this surface.
    }

    void setVisible(int id, boolean visible) {
        Target target = targets.get(id);
        if (target == null || closed) {
            return;
        }
        target.visible = visible;
        if (visible) {
            target.visibleOrder = ++nextVisibleOrder;
        }
        reconcile();
    }

    void remove(int id) {
        if (!closed && targets.remove(id) != null) {
            reconcile();
        }
    }

    void close() {
        if (closed) {
            return;
        }
        detach();
        targets.clear();
        closed = true;
        bridge.close();
    }

    private void reconcile() {
        Integer winnerId = null;
        Target winner = null;
        for (Map.Entry<Integer, Target> entry : targets.entrySet()) {
            Target candidate = entry.getValue();
            if (!candidate.canRender()) {
                continue;
            }
            // A visible system preview needs the renderer; otherwise use the latest visible
            // wallpaper. This is a single-surface policy, not simultaneous render support.
            if (winner == null || (candidate.preview && !winner.preview)
                    || (candidate.preview == winner.preview
                    && candidate.visibleOrder > winner.visibleOrder)) {
                winnerId = entry.getKey();
                winner = candidate;
            }
        }

        if (attachedId != null && attachedId.equals(winnerId)) {
            if (winner != null && (winner.width != attachedWidth || winner.height != attachedHeight)) {
                bridge.resize(winner.width, winner.height);
                attachedWidth = winner.width;
                attachedHeight = winner.height;
            }
            return;
        }

        detach();
        if (winner != null && bridge.attach(winner.holder, winner.width, winner.height,
                winner.preview)) {
            attachedId = winnerId;
            attachedWidth = winner.width;
            attachedHeight = winner.height;
        }
    }

    private void detach() {
        if (attachedId != null) {
            bridge.pause();
            bridge.detach();
            attachedId = null;
            attachedWidth = 0;
            attachedHeight = 0;
        }
    }
}
