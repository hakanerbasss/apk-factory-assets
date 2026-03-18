package com.wizaicorp.apkfactory.data

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import java.io.File

object TermuxBridge {
    private const val TERMUX_PKG = "com.termux"
    private const val TERMUX_RUN_CMD = "com.termux.RUN_COMMAND"
    private const val TERMUX_SERVICE = "com.termux.app.RunCommandService"

    fun isTermuxInstalled(ctx: Context): Boolean {
        return try {
            ctx.packageManager.getPackageInfo(TERMUX_PKG, 0); true
        } catch (e: PackageManager.NameNotFoundException) { false }
    }

    fun openTermuxDownload(ctx: Context) {
        val uri = Uri.parse("https://f-droid.org/en/packages/com.termux/")
        ctx.startActivity(Intent(Intent.ACTION_VIEW, uri).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        })
    }

    // İzin gerektirmeyen uygulama dizini
    private fun logFile(ctx: Context) = File("/sdcard/Download/apkfactory_setup.log")
    private fun statusFile(ctx: Context) = File("/sdcard/Download/apkfactory_status.json")

    // GitHub repo bilgileri — setup.sh ve scriptler buradan indirilir
    private const val GITHUB_RAW =
        "https://raw.githubusercontent.com/hakanerbasss/apk-factory-assets/main"

    fun runSetup(ctx: Context): Boolean {
        val command = """
            source /data/data/com.termux/files/usr/etc/profile
            export LOG_FILE="/sdcard/Download/apkfactory_setup.log"
            export STATUS_FILE="/sdcard/Download/apkfactory_status.json"
            curl -fsSL https://raw.githubusercontent.com/hakanerbasss/apk-factory-assets/main/scripts/setup_full.sh -o /sdcard/Download/sf_run.sh && bash /sdcard/Download/sf_run.sh >> /sdcard/Download/apkfactory_bg_debug.log 2>&1
        """.trimIndent()
        return try {
            val intent = android.content.Intent().apply {
                action = TERMUX_RUN_CMD
                setClassName(TERMUX_PKG, TERMUX_SERVICE)
                putExtra("com.termux.RUN_COMMAND_PATH", "/data/data/com.termux/files/usr/bin/bash")
                putExtra("com.termux.RUN_COMMAND_ARGUMENTS", arrayOf("-c", command))
                putExtra("com.termux.RUN_COMMAND_WORKDIR", "/data/data/com.termux/files/home")
                putExtra("com.termux.RUN_COMMAND_BACKGROUND", true)
            }
            if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.O)
                ctx.startForegroundService(intent)
            else
                ctx.startService(intent)
            true
        } catch (e: Exception) { false }
    }

    fun sendToTermux(ctx: Context, command: String): Boolean {
        return try {
            val intent = Intent().apply {
                action = TERMUX_RUN_CMD
                setClassName(TERMUX_PKG, TERMUX_SERVICE)
                putExtra("com.termux.RUN_COMMAND_PATH",
                    "/data/data/com.termux/files/usr/bin/bash")
                putExtra("com.termux.RUN_COMMAND_ARGUMENTS", arrayOf("-c", command))
                putExtra("com.termux.RUN_COMMAND_WORKDIR",
                    "/data/data/com.termux/files/home")
                putExtra("com.termux.RUN_COMMAND_BACKGROUND", true)
            }
            if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.O) {
                ctx.startForegroundService(intent)
            } else {
                ctx.startService(intent)
            }
            true
        } catch (e: Exception) {
            android.util.Log.e("TermuxBridge", "sendToTermux FAILED: ${e::class.simpleName}: ${e.message}")
            false
        }
    }

    fun startWsBridge(ctx: Context) {
        sendToTermux(ctx,
            "bash /data/data/com.termux/files/home/restart_bridge.sh")
    }

    fun readSetupLog(ctx: Context) = runCatching { logFile(ctx).readText() }.getOrDefault("")
    fun readSetupStatus(ctx: Context) = runCatching { statusFile(ctx).readText() }.getOrDefault("{}")
    fun isSetupDone(ctx: Context) = readSetupStatus(ctx).contains("\"done\":true")
}
