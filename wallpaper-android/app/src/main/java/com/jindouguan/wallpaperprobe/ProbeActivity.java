package com.jindouguan.wallpaperprobe;

import android.app.Activity;
import android.app.WallpaperManager;
import android.content.ActivityNotFoundException;
import android.content.ComponentName;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.os.Bundle;
import android.view.Gravity;
import android.view.ViewGroup;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.TextView;
import android.widget.Toast;

/** Entry point for the platform probe. The system remains responsible for wallpaper selection. */
public final class ProbeActivity extends Activity {
    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);

        int padding = Math.round(24 * getResources().getDisplayMetrics().density);
        LinearLayout layout = new LinearLayout(this);
        layout.setOrientation(LinearLayout.VERTICAL);
        layout.setGravity(Gravity.CENTER);
        layout.setPadding(padding, padding, padding, padding);

        TextView message = new TextView(this);
        message.setText("金豆罐 Android 壁纸平台诊断\n\n此画面用于检查系统壁纸预览、启用、恢复与运动传感器。没有连接正式账本，也不是金豆罐产品画面。");
        message.setTextSize(18);
        layout.addView(message, new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));

        Button preview = new Button(this);
        preview.setText("打开系统壁纸预览");
        preview.setOnClickListener(view -> openSystemWallpaperPicker());
        layout.addView(preview, new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));

        setContentView(layout);
    }

    private void openSystemWallpaperPicker() {
        if (!getPackageManager().hasSystemFeature(PackageManager.FEATURE_LIVE_WALLPAPER)) {
            Toast.makeText(this, "这台设备未声明支持系统动态壁纸", Toast.LENGTH_LONG).show();
            return;
        }
        Intent intent = new Intent(WallpaperManager.ACTION_CHANGE_LIVE_WALLPAPER);
        intent.putExtra(WallpaperManager.EXTRA_LIVE_WALLPAPER_COMPONENT,
                new ComponentName(this, ProbeWallpaperService.class));
        try {
            startActivity(intent);
        } catch (ActivityNotFoundException unsupported) {
            try {
                startActivity(new Intent(WallpaperManager.ACTION_LIVE_WALLPAPER_CHOOSER));
            } catch (ActivityNotFoundException unavailable) {
                Toast.makeText(this, "这台设备没有可用的系统动态壁纸选择器", Toast.LENGTH_LONG).show();
            }
        }
    }
}
