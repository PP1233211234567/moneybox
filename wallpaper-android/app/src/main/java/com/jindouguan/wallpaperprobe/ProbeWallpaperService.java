package com.jindouguan.wallpaperprobe;

import android.content.Context;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Paint;
import android.hardware.Sensor;
import android.hardware.SensorEvent;
import android.hardware.SensorEventListener;
import android.hardware.SensorManager;
import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;
import android.service.wallpaper.WallpaperService;
import android.util.Log;
import android.view.SurfaceHolder;

import java.util.concurrent.atomic.AtomicInteger;

/**
 * Native lifecycle probe for Android live wallpapers. It intentionally renders diagnostic
 * graphics only. Godot Surface hosting and the product's financial state are separate work.
 */
public final class ProbeWallpaperService extends WallpaperService {
    private static final String TAG = "JindouWallpaper";
    private static final long FRAME_DELAY_MS = 33L;
    private static final AtomicInteger NEXT_ENGINE_ID = new AtomicInteger(1);

    @Override
    public Engine onCreateEngine() {
        return new ProbeEngine(NEXT_ENGINE_ID.getAndIncrement());
    }

    private final class ProbeEngine extends Engine implements SensorEventListener {
        private final int id;
        private final Handler handler = new Handler(Looper.getMainLooper());
        private final SensorManager sensorManager;
        private final Sensor sensor;
        private final DiagnosticRenderer renderer = new DiagnosticRenderer(
                ProbeWallpaperService.this.getResources().getDisplayMetrics().density);
        private final Runnable drawFrame = this::drawFrame;

        private SurfaceHolder surfaceHolder;
        private boolean surfaceReady;
        private boolean visible;
        private boolean destroyed;
        private boolean sensorRegistered;
        private boolean frameScheduled;
        private long lastFrameNanos;

        ProbeEngine(int id) {
            this.id = id;
            sensorManager = (SensorManager) ProbeWallpaperService.this.getSystemService(Context.SENSOR_SERVICE);
            Sensor gravity = sensorManager == null ? null :
                    sensorManager.getDefaultSensor(Sensor.TYPE_GRAVITY);
            sensor = gravity != null ? gravity : sensorManager == null ? null :
                    sensorManager.getDefaultSensor(Sensor.TYPE_ACCELEROMETER);
            setTouchEventsEnabled(false);
            Log.i(TAG, "engine=" + id + " created");
        }

        @Override
        public void onSurfaceCreated(SurfaceHolder holder) {
            super.onSurfaceCreated(holder);
            surfaceHolder = holder;
            surfaceReady = true;
            lastFrameNanos = 0L;
            Log.i(TAG, "engine=" + id + " surface-created preview=" + isPreview());
            updateRunning();
        }

        @Override
        public void onSurfaceChanged(SurfaceHolder holder, int format, int width, int height) {
            super.onSurfaceChanged(holder, format, width, height);
            surfaceHolder = holder;
            Log.i(TAG, "engine=" + id + " surface-changed " + width + "x" + height);
            if (visible && surfaceReady) {
                scheduleFrame();
            }
        }

        @Override
        public void onSurfaceDestroyed(SurfaceHolder holder) {
            surfaceReady = false;
            surfaceHolder = null;
            updateRunning();
            Log.i(TAG, "engine=" + id + " surface-destroyed");
            super.onSurfaceDestroyed(holder);
        }

        @Override
        public void onVisibilityChanged(boolean isVisible) {
            super.onVisibilityChanged(isVisible);
            visible = isVisible;
            lastFrameNanos = 0L; // Do not simulate elapsed invisible time on resume.
            Log.i(TAG, "engine=" + id + " visible=" + visible + " preview=" + isPreview());
            updateRunning();
        }

        @Override
        public void onOffsetsChanged(float xOffset, float yOffset, float xOffsetStep,
                                     float yOffsetStep, int xPixelOffset, int yPixelOffset) {
            renderer.setOffset(xOffset);
            Log.i(TAG, "engine=" + id + " offsets=" + xOffset + "," + yOffset);
        }

        @Override
        public void onDestroy() {
            destroyed = true;
            updateRunning();
            Log.i(TAG, "engine=" + id + " destroyed");
            super.onDestroy();
        }

        private void updateRunning() {
            boolean shouldRun = visible && surfaceReady && !destroyed;
            if (shouldRun) {
                if (!sensorRegistered && sensor != null && sensorManager != null) {
                    sensorRegistered = sensorManager.registerListener(
                            this, sensor, SensorManager.SENSOR_DELAY_GAME, handler);
                    Log.i(TAG, "engine=" + id + " sensor=" + sensor.getName()
                            + " registered=" + sensorRegistered);
                }
                scheduleFrame();
            } else {
                handler.removeCallbacks(drawFrame);
                frameScheduled = false;
                if (sensorRegistered && sensorManager != null) {
                    sensorManager.unregisterListener(this);
                    sensorRegistered = false;
                    Log.i(TAG, "engine=" + id + " sensor-unregistered");
                }
            }
        }

        private void scheduleFrame() {
            if (!frameScheduled && visible && surfaceReady && !destroyed) {
                frameScheduled = true;
                handler.postDelayed(drawFrame, FRAME_DELAY_MS);
            }
        }

        private void drawFrame() {
            frameScheduled = false;
            if (!visible || !surfaceReady || destroyed || surfaceHolder == null) {
                return;
            }
            long now = SystemClock.elapsedRealtimeNanos();
            float deltaSeconds = lastFrameNanos == 0L ? 0f :
                    Math.min((now - lastFrameNanos) / 1_000_000_000f, 0.05f);
            lastFrameNanos = now;
            renderer.draw(surfaceHolder, id, isPreview(), sensor != null, deltaSeconds);
            scheduleFrame();
        }

        @Override
        public void onSensorChanged(SensorEvent event) {
            if (event.sensor == sensor && event.values.length >= 3) {
                renderer.setSensorValues(event.values[0], event.values[1], event.values[2]);
            }
        }

        @Override
        public void onAccuracyChanged(Sensor changedSensor, int accuracy) {
            // The raw vector and source are displayed; accuracy is not used for this probe.
        }
    }

    private static final class DiagnosticRenderer {
        private final Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG);
        private final float density;
        private float elapsedSeconds;
        private float gravityX;
        private float gravityY;
        private float gravityZ;
        private float offsetX = 0.5f;

        DiagnosticRenderer(float density) {
            this.density = density > 0f ? density : 1f;
        }

        void setSensorValues(float x, float y, float z) {
            gravityX = x;
            gravityY = y;
            gravityZ = z;
        }

        void setOffset(float offset) {
            offsetX = offset;
        }

        void draw(SurfaceHolder holder, int engineId, boolean preview,
                  boolean hasSensor, float deltaSeconds) {
            elapsedSeconds += deltaSeconds;
            Canvas canvas = null;
            try {
                canvas = holder.lockCanvas();
                if (canvas == null) {
                    return;
                }
                float scale = density;
                float width = canvas.getWidth();
                float height = canvas.getHeight();
                canvas.drawColor(Color.rgb(250, 247, 240));

                paint.setStyle(Paint.Style.FILL);
                paint.setColor(Color.rgb(217, 164, 65));
                float markerX = width * (0.2f + 0.6f *
                        (0.5f + 0.5f * (float) Math.sin(elapsedSeconds * 2.5f)));
                canvas.drawCircle(markerX, height * 0.38f, 16f * scale, paint);

                paint.setColor(Color.rgb(52, 49, 44));
                paint.setTextSize(20f * scale);
                canvas.drawText("金豆罐 · 平台诊断", 24f * scale, 60f * scale, paint);
                paint.setTextSize(15f * scale);
                canvas.drawText("Engine " + engineId + (preview ? "  PREVIEW" : "  ACTIVE"),
                        24f * scale, 90f * scale, paint);
                canvas.drawText("Surface " + (int) width + " x " + (int) height,
                        24f * scale, 114f * scale, paint);
                canvas.drawText("Launcher offset " + String.format(java.util.Locale.ROOT, "%.2f", offsetX),
                        24f * scale, 138f * scale, paint);
                String sensorText = hasSensor ? String.format(java.util.Locale.ROOT,
                        "Sensor x %.2f  y %.2f  z %.2f", gravityX, gravityY, gravityZ)
                        : "Sensor unavailable";
                canvas.drawText(sensorText, 24f * scale, height - 48f * scale, paint);
                canvas.drawText("No financial data · no Godot surface", 24f * scale,
                        height - 24f * scale, paint);
            } catch (RuntimeException e) {
                Log.w(TAG, "diagnostic surface draw failed", e);
            } finally {
                if (canvas != null) {
                    try {
                        holder.unlockCanvasAndPost(canvas);
                    } catch (RuntimeException e) {
                        Log.w(TAG, "diagnostic surface post failed", e);
                    }
                }
            }
        }
    }
}
