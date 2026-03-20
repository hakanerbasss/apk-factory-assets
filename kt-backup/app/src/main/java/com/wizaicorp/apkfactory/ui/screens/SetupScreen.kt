package com.wizaicorp.apkfactory.ui.screens

import android.content.Context
import android.content.Intent
import android.net.Uri
import androidx.compose.animation.*
import androidx.compose.animation.core.*
import androidx.compose.foundation.*
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.wizaicorp.apkfactory.data.TermuxBridge
import kotlinx.coroutines.*

val BG      = Color(0xFF0A0A10)
val SURFACE = Color(0xFF13131A)
val CARD    = Color(0xFF1A1A24)
val BORDER  = Color(0xFF2A2A3A)
val ACCENT  = Color(0xFF4B7BFF)
val ACCENT2 = Color(0xFF7C5CFC)
val GREEN   = Color(0xFF2ECC88)
val ORANGE  = Color(0xFFFF6B35)
val RED     = Color(0xFFFF4444)
val WHITE   = Color(0xFFFFFFFF)
val GREY    = Color(0xFF8A8A9A)

enum class SetupPhase { WELCOME, TERMUX_MISSING, TERMUX_PERMISSIONS, BOOT_CHECK, INSTALLING, DONE }

data class SetupStep(val title: String, val done: Boolean = false, val active: Boolean = false, val error: Boolean = false)

fun isTermuxBootInstalled(ctx: Context): Boolean {
    return try {
        ctx.packageManager.getPackageInfo("com.termux.boot", 0)
        true
    } catch (e: Exception) { false }
}

@OptIn(ExperimentalAnimationApi::class)
@Composable
fun SetupScreen(onSetupDone: () -> Unit, onSkip: () -> Unit = {}) {
    val ctx = LocalContext.current
    val scope = rememberCoroutineScope()
    var phase by remember { mutableStateOf(SetupPhase.WELCOME) }
    var logLines by remember { mutableStateOf(listOf<String>()) }
    var steps by remember { mutableStateOf(initialSteps()) }
    var currentStepIdx by remember { mutableIntStateOf(0) }

    LaunchedEffect(phase) {
        if (phase == SetupPhase.INSTALLING) {
            scope.launch { delay(300); TermuxBridge.runSetup(ctx) }
            while (phase == SetupPhase.INSTALLING) {
                delay(1500)
                val log = TermuxBridge.readSetupLog(ctx)
                if (log.isNotEmpty()) {
                    logLines = log.lines().filter { it.isNotBlank() }.takeLast(100)
                    steps = updateSteps(log, steps)
                    currentStepIdx = steps.indexOfLast { it.done }.coerceAtLeast(0)
                }
                if (TermuxBridge.isSetupDone(ctx)) {
                    // Son log okumalarını yap, adımları güncelle
                    repeat(5) {
                        delay(800)
                        val finalLog = TermuxBridge.readSetupLog(ctx)
                        if (finalLog.isNotEmpty()) {
                            logLines = finalLog.lines().filter { it.isNotBlank() }.takeLast(100)
                            steps = updateSteps(finalLog, steps)
                            currentStepIdx = steps.indexOfLast { it.done }.coerceAtLeast(0)
                        }
                    }
                    phase = SetupPhase.DONE
                    delay(1000)
                    onSetupDone()
                }
            }
        }
    }

    Box(modifier = Modifier.fillMaxSize().background(BG)) {
        AnimatedContent(
            targetState = phase,
            transitionSpec = { fadeIn(tween(400)) togetherWith fadeOut(tween(400)) },
            label = "phase"
        ) { p ->
            when (p) {
                SetupPhase.WELCOME -> WelcomeContent(
                    onStart = {
                        when {
                            !TermuxBridge.isTermuxInstalled(ctx) -> phase = SetupPhase.TERMUX_MISSING
                            !isTermuxBootInstalled(ctx)          -> phase = SetupPhase.BOOT_CHECK
                            else -> {
                                phase = SetupPhase.TERMUX_PERMISSIONS
                            }
                        }
                    },
                    onSkip = onSkip,
                    isTermuxInstalled = TermuxBridge.isTermuxInstalled(ctx)
                )
                SetupPhase.TERMUX_MISSING -> TermuxMissingContent(
                    onDownload = { TermuxBridge.openTermuxDownload(ctx) },
                    onRetry = {
                        if (TermuxBridge.isTermuxInstalled(ctx)) phase = SetupPhase.TERMUX_PERMISSIONS
                    }
                )
                SetupPhase.TERMUX_PERMISSIONS -> TermuxPermissionsContent(
                    onContinue = {
                        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.R &&
                            !android.os.Environment.isExternalStorageManager()) {
                            val intent = android.content.Intent(
                                android.provider.Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION,
                                android.net.Uri.parse("package:${ctx.packageName}")
                            ).addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK)
                            ctx.startActivity(intent)
                        } else {
                            phase = SetupPhase.INSTALLING
                        }
                    }
                )
                SetupPhase.BOOT_CHECK -> BootCheckContent(
                    isInstalled = isTermuxBootInstalled(ctx),
                    onDownload = {
                        val intent = Intent(Intent.ACTION_VIEW,
                            Uri.parse("https://f-droid.org/packages/com.termux.boot/"))
                        ctx.startActivity(intent)
                    },
                    onContinue = {
                        phase = SetupPhase.TERMUX_PERMISSIONS
                    },
                    onRetry = {
                        // Boot kurulduysa devam et
                        if (isTermuxBootInstalled(ctx)) phase = SetupPhase.TERMUX_PERMISSIONS
                        else phase = SetupPhase.BOOT_CHECK
                    }
                )
                SetupPhase.INSTALLING -> InstallingContent(
                    steps = steps, logLines = logLines, currentStep = currentStepIdx,
                    onSkip = onSkip
                )
                SetupPhase.DONE -> DoneContent(ctx = ctx, onContinue = onSetupDone)
            }
        }
    }
}

// ── Hoş Geldin ────────────────────────────────────────────────
@Composable
fun WelcomeContent(onStart: () -> Unit, onSkip: () -> Unit, isTermuxInstalled: Boolean) {
    Column(
        modifier = Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center
    ) {
        Box(
            modifier = Modifier.size(120.dp).clip(RoundedCornerShape(28.dp))
                .background(Brush.linearGradient(listOf(ACCENT, ACCENT2))),
            contentAlignment = Alignment.Center
        ) { Icon(Icons.Default.Build, null, modifier = Modifier.size(60.dp), tint = WHITE) }

        Spacer(Modifier.height(32.dp))
        Text("APK Factory", fontSize = 36.sp, fontWeight = FontWeight.Black, color = WHITE)
        Text("Telefonunuzdan APK üretin", fontSize = 16.sp, color = GREY, modifier = Modifier.padding(top = 8.dp))
        Spacer(Modifier.height(48.dp))

        listOf(
            Pair(Icons.Default.AutoFixHigh, "AI ile otomatik kod üretimi"),
            Pair(Icons.Default.PhoneAndroid, "Telefondan tek tıkla APK"),
            Pair(Icons.Default.CloudUpload, "Play Store'a direkt yükleme"),
            Pair(Icons.Default.Terminal, "Termux gücü, sade arayüz")
        ).forEach { (icon, text) ->
            Row(modifier = Modifier.fillMaxWidth().padding(vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                Box(modifier = Modifier.size(40.dp).clip(CircleShape).background(ACCENT.copy(alpha = 0.15f)), contentAlignment = Alignment.Center) {
                    Icon(icon, null, tint = ACCENT, modifier = Modifier.size(20.dp))
                }
                Spacer(Modifier.width(16.dp))
                Text(text, color = WHITE, fontSize = 15.sp)
            }
        }

        Spacer(Modifier.height(48.dp))

        if (isTermuxInstalled) {
            Row(
                modifier = Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp))
                    .background(GREEN.copy(alpha = 0.1f))
                    .border(1.dp, GREEN.copy(alpha = 0.3f), RoundedCornerShape(12.dp))
                    .padding(12.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Icon(Icons.Default.CheckCircle, null, tint = GREEN, modifier = Modifier.size(20.dp))
                Spacer(Modifier.width(12.dp))
                Text("Termux kurulu ✓", color = GREEN, fontWeight = FontWeight.Medium)
            }
            Spacer(Modifier.height(16.dp))
        }

        Button(
            onClick = onStart,
            modifier = Modifier.fillMaxWidth().height(56.dp),
            shape = RoundedCornerShape(16.dp),
            colors = ButtonDefaults.buttonColors(containerColor = Color.Transparent),
            contentPadding = PaddingValues(0.dp)
        ) {
            Box(
                modifier = Modifier.fillMaxSize()
                    .background(Brush.horizontalGradient(listOf(ACCENT, ACCENT2)), RoundedCornerShape(16.dp)),
                contentAlignment = Alignment.Center
            ) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(Icons.Default.RocketLaunch, null, tint = WHITE)
                    Spacer(Modifier.width(8.dp))
                    Text(
                        if (isTermuxInstalled) "Kurulumu Başlat" else "Termux Gerekli",
                        fontSize = 17.sp, fontWeight = FontWeight.Bold, color = WHITE
                    )
                }
            }
        }
        Spacer(Modifier.height(12.dp))
        TextButton(onClick = onSkip, modifier = Modifier.fillMaxWidth()) {
            Text("Zaten kurulu, atla →", color = GREY, fontSize = 14.sp)
        }
    }
}

// ── Termux Yok ────────────────────────────────────────────────
@Composable
fun TermuxMissingContent(onDownload: () -> Unit, onRetry: () -> Unit) {
    Column(
        modifier = Modifier.fillMaxSize().padding(24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center
    ) {
        Icon(Icons.Default.Terminal, null, modifier = Modifier.size(80.dp), tint = ORANGE)
        Spacer(Modifier.height(24.dp))
        Text("Termux Gerekli", fontSize = 28.sp, fontWeight = FontWeight.Bold, color = WHITE)
        Spacer(Modifier.height(12.dp))
        Text(
            "APK Factory, derleme işlemleri için Termux uygulamasına ihtiyaç duyar.",
            fontSize = 15.sp, color = GREY, modifier = Modifier.padding(horizontal = 16.dp),
            lineHeight = 22.sp, textAlign = TextAlign.Center
        )
        Spacer(Modifier.height(32.dp))
        Card(
            modifier = Modifier.fillMaxWidth(),
            colors = CardDefaults.cardColors(containerColor = ORANGE.copy(alpha = 0.1f)),
            border = BorderStroke(1.dp, ORANGE.copy(alpha = 0.3f)), shape = RoundedCornerShape(12.dp)
        ) {
            Row(modifier = Modifier.padding(16.dp), verticalAlignment = Alignment.Top) {
                Icon(Icons.Default.Info, null, tint = ORANGE, modifier = Modifier.size(20.dp))
                Spacer(Modifier.width(12.dp))
                Column {
                    Text("F-Droid üzerinden indirin", fontWeight = FontWeight.Bold, color = ORANGE, fontSize = 14.sp)
                    Text("Termux, Google Play'de artık güncelleme almıyor. F-Droid'den indirin.", color = GREY, fontSize = 12.sp, lineHeight = 18.sp)
                }
            }
        }
        Spacer(Modifier.height(24.dp))
        Button(
            onClick = onDownload,
            modifier = Modifier.fillMaxWidth().height(52.dp), shape = RoundedCornerShape(14.dp),
            colors = ButtonDefaults.buttonColors(containerColor = ACCENT)
        ) {
            Icon(Icons.Default.Download, null, tint = WHITE); Spacer(Modifier.width(8.dp))
            Text("F-Droid'den İndir", fontSize = 16.sp, fontWeight = FontWeight.Bold, color = WHITE)
        }
        Spacer(Modifier.height(12.dp))
        OutlinedButton(
            onClick = onRetry, modifier = Modifier.fillMaxWidth().height(52.dp),
            shape = RoundedCornerShape(14.dp), border = BorderStroke(1.dp, BORDER)
        ) {
            Icon(Icons.Default.Refresh, null, tint = GREY); Spacer(Modifier.width(8.dp))
            Text("Kurdum, Tekrar Dene", fontSize = 15.sp, color = GREY)
        }
    }
}

// ── Termux:Boot Kurulum ───────────────────────────────────────

// ── Termux İzin Rehberi ───────────────────────────────────────
@Composable
fun TermuxPermissionsContent(onContinue: () -> Unit) {
    val ctx = LocalContext.current
    val scope = rememberCoroutineScope()

    // Pil optimizasyonu butona basınca isteniyor

    Column(
        modifier = Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center
    ) {
        Box(
            modifier = Modifier.size(100.dp).clip(RoundedCornerShape(24.dp))
                .background(ORANGE.copy(alpha = 0.15f))
                .border(2.dp, ORANGE.copy(alpha = 0.4f), RoundedCornerShape(24.dp)),
            contentAlignment = Alignment.Center
        ) { Icon(Icons.Default.Security, null, modifier = Modifier.size(50.dp), tint = ORANGE) }

        Spacer(Modifier.height(24.dp))
        Text("Termux İzinleri", fontSize = 28.sp, fontWeight = FontWeight.Black, color = WHITE)
        Text("Kuruluma başlamadan önce", fontSize = 14.sp, color = GREY, modifier = Modifier.padding(top = 6.dp))
        Spacer(Modifier.height(32.dp))

        // Adım 1 — allow-external-apps
        PermissionStepCard(
            number = "1",
            title = "Dış Uygulama İzni",
            description = "Termux'u açın ve aşağıdaki komutu yapıştırıp Enter'a basın. Sonra Termux'u kapatıp tekrar açın.",
            color = ACCENT,
            action = {
                Button(
                    onClick = {
                        val intent = android.content.Intent().apply {
                            setClassName("com.termux", "com.termux.app.TermuxActivity")
                            addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK)
                        }
                        try { ctx.startActivity(intent) } catch(e: Exception) {}
                    },
                    shape = RoundedCornerShape(10.dp),
                    colors = ButtonDefaults.buttonColors(containerColor = ACCENT),
                    contentPadding = PaddingValues(horizontal = 14.dp, vertical = 8.dp)
                ) {
                    Icon(Icons.Default.OpenInNew, null, modifier = Modifier.size(14.dp))
                    Spacer(Modifier.width(6.dp))
                    Text("Termux'u Aç", fontSize = 12.sp)
                }
            }
        )

        Spacer(Modifier.height(12.dp))

        // Adım 2 — Depolama izni
        val cmd2 = "termux-setup-storage"
        val clipManager2 = ctx.getSystemService(android.content.Context.CLIPBOARD_SERVICE) as android.content.ClipboardManager
        PermissionStepCard(
            number = "2",
            title = "Depolama İzni",
            description = "Termux'ta aşağıdaki komutu çalıştırın. \"y/n?\" sorusu çıkarsa y yazıp Enter'a basın. Ardından İzin Ver deyin.",
            color = GREEN,
            action = {
                Card(
                    colors = CardDefaults.cardColors(containerColor = Color(0xFF060608)),
                    shape = RoundedCornerShape(8.dp),
                    border = androidx.compose.foundation.BorderStroke(1.dp, BORDER)
                ) {
                    Row(
                        modifier = Modifier.padding(horizontal = 12.dp, vertical = 8.dp),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Text(cmd2, color = GREEN, fontSize = 11.sp,
                            fontFamily = FontFamily.Monospace, modifier = Modifier.weight(1f))
                        IconButton(
                            onClick = { clipManager2.setPrimaryClip(android.content.ClipData.newPlainText("cmd", cmd2)) },
                            modifier = Modifier.size(32.dp)
                        ) {
                            Icon(Icons.Default.ContentCopy, null, tint = GREY, modifier = Modifier.size(16.dp))
                        }
                    }
                }
            }
        )

        Spacer(Modifier.height(12.dp))

        // Adım 3 — Pil optimizasyonu
        PermissionStepCard(
            number = "3",
            title = "Pil Optimizasyonu",
            description = "Açılan ekranda Termux'u bulun → \"Kısıtlama yok\" seçin. Kurulum 10-20 dakika sürer, ekranı kapatmayın.",
            color = ORANGE,
            action = {
                Button(
                    onClick = {
                        try {
                            val intent = android.content.Intent(
                                android.provider.Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                                android.net.Uri.parse("package:com.termux")
                            ).addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK)
                            ctx.startActivity(intent)
                        } catch(e: Exception) {}
                    },
                    shape = RoundedCornerShape(10.dp),
                    colors = ButtonDefaults.buttonColors(containerColor = ORANGE),
                    contentPadding = PaddingValues(horizontal = 14.dp, vertical = 8.dp)
                ) {
                    Icon(Icons.Default.BatteryFull, null, modifier = Modifier.size(14.dp))
                    Spacer(Modifier.width(6.dp))
                    Text("Pil İznini Ver", fontSize = 12.sp)
                }
            }
        )

        Spacer(Modifier.height(12.dp))

        // Adım 4 — Termux Depolama izni
        PermissionStepCard(
            number = "4",
            title = "Termux Dosya İzni",
            description = "Ayarlar → Uygulamalar → Termux → İzinler → Dosyalar → İzin Ver",
            color = GREEN,
            action = {
                Button(
                    onClick = {
                        val intent = android.content.Intent(
                            android.provider.Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                            android.net.Uri.parse("package:com.termux")
                        ).addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK)
                        try { ctx.startActivity(intent) } catch(e: Exception) {}
                    },
                    shape = RoundedCornerShape(10.dp),
                    colors = ButtonDefaults.buttonColors(containerColor = GREEN),
                    contentPadding = PaddingValues(horizontal = 14.dp, vertical = 8.dp)
                ) {
                    Icon(Icons.Default.Settings, null, modifier = Modifier.size(14.dp))
                    Spacer(Modifier.width(6.dp))
                    Text("Termux İzinlerine Git → Run Commands İzni Ver", fontSize = 12.sp)
                }
            }
        )

        Spacer(Modifier.height(12.dp))

        // Adım 5 — APK Factory Run Commands izni
        PermissionStepCard(
            number = "5",
            title = "APK Factory Komut İzni",
            description = "APK Factory ayarları → Run commands in Termux environment → Aç",
            color = ACCENT,
            action = {
                Button(
                    onClick = {
                        val intent = android.content.Intent(
                            android.provider.Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                            android.net.Uri.parse("package:com.wizaicorp.apkfactory")
                        ).addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK)
                        try { ctx.startActivity(intent) } catch(e: Exception) {}
                    },
                    shape = RoundedCornerShape(10.dp),
                    colors = ButtonDefaults.buttonColors(containerColor = ACCENT),
                    contentPadding = PaddingValues(horizontal = 14.dp, vertical = 8.dp)
                ) {
                    Icon(Icons.Default.Security, null, modifier = Modifier.size(14.dp))
                    Spacer(Modifier.width(6.dp))
                    Text("APK Factory Ayarlarını Aç", fontSize = 12.sp)
                }
            }
        )

        Spacer(Modifier.height(32.dp))

        Button(
            onClick = {
                scope.launch {
                    onContinue()
                }
            },
            modifier = Modifier.fillMaxWidth().height(54.dp),
            shape = RoundedCornerShape(14.dp),
            colors = ButtonDefaults.buttonColors(containerColor = GREEN)
        ) {
            Text("İzinleri Verdim, Devam Et →", fontSize = 15.sp, fontWeight = FontWeight.Bold, color = WHITE)
        }

        Spacer(Modifier.height(12.dp))
        Text(
            "⚠️ Kurulum boyunca ekranı kapatmayın",
            color = ORANGE.copy(alpha = 0.8f), fontSize = 12.sp, textAlign = TextAlign.Center
        )
    }
}

@Composable
fun PermissionStepCard(
    number: String,
    title: String,
    description: String,
    color: Color,
    action: (@Composable () -> Unit)?
) {
    Card(
        modifier = Modifier.fillMaxWidth(),
        colors = CardDefaults.cardColors(containerColor = CARD),
        shape = RoundedCornerShape(14.dp),
        border = androidx.compose.foundation.BorderStroke(1.dp, color.copy(alpha = 0.3f))
    ) {
        Row(modifier = Modifier.padding(16.dp), verticalAlignment = Alignment.Top) {
            Box(
                modifier = Modifier.size(32.dp).clip(CircleShape)
                    .background(color.copy(alpha = 0.15f))
                    .border(1.dp, color.copy(alpha = 0.5f), CircleShape),
                contentAlignment = Alignment.Center
            ) { Text(number, color = color, fontWeight = FontWeight.Bold, fontSize = 14.sp) }
            Spacer(Modifier.width(14.dp))
            Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Text(title, color = WHITE, fontWeight = FontWeight.SemiBold, fontSize = 14.sp)
                Text(description, color = GREY, fontSize = 12.sp, lineHeight = 18.sp)
                action?.invoke()
            }
        }
    }
}

@Composable
fun BootCheckContent(
    isInstalled: Boolean,
    onDownload: () -> Unit,
    onContinue: () -> Unit,
    onRetry: () -> Unit
) {
    Column(
        modifier = Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center
    ) {
        Box(
            modifier = Modifier.size(100.dp).clip(RoundedCornerShape(24.dp))
                .background(if (isInstalled) GREEN.copy(alpha = 0.1f) else ACCENT.copy(alpha = 0.1f))
                .border(2.dp, if (isInstalled) GREEN.copy(alpha = 0.4f) else ACCENT.copy(alpha = 0.4f), RoundedCornerShape(24.dp)),
            contentAlignment = Alignment.Center
        ) {
            Icon(
                if (isInstalled) Icons.Default.CheckCircle else Icons.Default.Autorenew,
                null, modifier = Modifier.size(52.dp),
                tint = if (isInstalled) GREEN else ACCENT
            )
        }
        Spacer(Modifier.height(28.dp))
        Text("Termux:Boot", fontSize = 28.sp, fontWeight = FontWeight.Bold, color = WHITE)
        Spacer(Modifier.height(8.dp))
        Text(
            if (isInstalled) "Termux:Boot kurulu ✓" else "Otomatik başlatma için gerekli",
            fontSize = 15.sp, color = if (isInstalled) GREEN else GREY, textAlign = TextAlign.Center
        )
        Spacer(Modifier.height(24.dp))

        if (!isInstalled) {
            // Neden gerekli açıklaması
            Card(
                modifier = Modifier.fillMaxWidth(),
                colors = CardDefaults.cardColors(containerColor = ACCENT.copy(alpha = 0.07f)),
                border = BorderStroke(1.dp, ACCENT.copy(alpha = 0.25f)), shape = RoundedCornerShape(14.dp)
            ) {
                Column(modifier = Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    Text("Neden gerekli?", fontWeight = FontWeight.Bold, color = WHITE, fontSize = 14.sp)
                    listOf(
                        "📱 Telefon yeniden başlayınca ws_bridge otomatik başlar",
                        "🔌 Termux'u manuel açmana gerek kalmaz",
                        "⚡ Uygulama her zaman hazır olur"
                    ).forEach { text ->
                        Row(verticalAlignment = Alignment.Top) {
                            Text(text, color = GREY, fontSize = 13.sp, lineHeight = 20.sp)
                        }
                    }
                }
            }
            Spacer(Modifier.height(20.dp))

            // Kurulum talimatları
            Card(
                modifier = Modifier.fillMaxWidth(),
                colors = CardDefaults.cardColors(containerColor = ORANGE.copy(alpha = 0.07f)),
                border = BorderStroke(1.dp, ORANGE.copy(alpha = 0.25f)), shape = RoundedCornerShape(14.dp)
            ) {
                Column(modifier = Modifier.padding(16.dp)) {
                    Text("⚠️ Kurulum Notu", fontWeight = FontWeight.Bold, color = ORANGE, fontSize = 14.sp)
                    Spacer(Modifier.height(8.dp))
                    Text(
                        "F-Droid, güvenlik uyarısı gösterebilir. \"Yine de indir\" veya \"Install anyway\" seçeneğine tıklayın — bu normaldir.",
                        color = GREY, fontSize = 13.sp, lineHeight = 20.sp
                    )
                    Spacer(Modifier.height(4.dp))
                    Text(
                        "Kurduktan sonra Termux:Boot uygulamasını bir kez açın, otomatik olarak arka planda çalışacaktır.",
                        color = GREY, fontSize = 13.sp, lineHeight = 20.sp
                    )
                }
            }
            Spacer(Modifier.height(24.dp))

            Button(
                onClick = onDownload,
                modifier = Modifier.fillMaxWidth().height(54.dp), shape = RoundedCornerShape(14.dp),
                colors = ButtonDefaults.buttonColors(containerColor = ACCENT)
            ) {
                Icon(Icons.Default.Download, null, tint = WHITE); Spacer(Modifier.width(8.dp))
                Text("F-Droid'den İndir", fontSize = 16.sp, fontWeight = FontWeight.Bold, color = WHITE)
            }
            Spacer(Modifier.height(10.dp))
            OutlinedButton(
                onClick = onRetry, modifier = Modifier.fillMaxWidth().height(48.dp),
                shape = RoundedCornerShape(14.dp), border = BorderStroke(1.dp, BORDER)
            ) {
                Icon(Icons.Default.Refresh, null, tint = GREY, modifier = Modifier.size(16.dp))
                Spacer(Modifier.width(6.dp))
                Text("Kurdum, kontrol et", color = GREY, fontSize = 14.sp)
            }
            Spacer(Modifier.height(10.dp))
            TextButton(onClick = onContinue, modifier = Modifier.fillMaxWidth()) {
                Text("Şimdilik atla, kuruluma devam et →", color = GREY, fontSize = 13.sp)
            }
        } else {
            // Kurulu — devam et
            Card(
                modifier = Modifier.fillMaxWidth(),
                colors = CardDefaults.cardColors(containerColor = GREEN.copy(alpha = 0.07f)),
                border = BorderStroke(1.dp, GREEN.copy(alpha = 0.25f)), shape = RoundedCornerShape(14.dp)
            ) {
                Row(modifier = Modifier.padding(16.dp), verticalAlignment = Alignment.CenterVertically) {
                    Icon(Icons.Default.CheckCircle, null, tint = GREEN, modifier = Modifier.size(24.dp))
                    Spacer(Modifier.width(12.dp))
                    Column {
                        Text("Termux:Boot hazır!", fontWeight = FontWeight.Bold, color = GREEN, fontSize = 14.sp)
                        Text("ws_bridge telefon açılınca otomatik başlayacak.", color = GREY, fontSize = 12.sp)
                    }
                }
            }
            Spacer(Modifier.height(12.dp))
            // Play Protect uyarısı
            Card(
                colors = CardDefaults.cardColors(containerColor = ORANGE.copy(alpha = 0.08f)),
                shape = RoundedCornerShape(10.dp),
                border = androidx.compose.foundation.BorderStroke(1.dp, ORANGE.copy(alpha = 0.3f)),
                modifier = Modifier.fillMaxWidth()
            ) {
                Row(modifier = Modifier.padding(12.dp), verticalAlignment = Alignment.Top) {
                    Text("⚠️", fontSize = 16.sp)
                    Spacer(Modifier.width(8.dp))
                    Column {
                        Text("Google Play Protect Uyarısı", color = ORANGE, fontWeight = FontWeight.SemiBold, fontSize = 13.sp)
                        Spacer(Modifier.height(4.dp))
                        Text(
                            "Play Protect uyarisi cikarsa: Diger ayrintilar > Yine de yukle secin. Bu normaldir.",
                            color = GREY, fontSize = 12.sp, lineHeight = 18.sp
                        )
                    }
                }
            }
            Spacer(Modifier.height(24.dp))
            Button(
                onClick = onContinue,
                modifier = Modifier.fillMaxWidth().height(54.dp), shape = RoundedCornerShape(14.dp),
                colors = ButtonDefaults.buttonColors(containerColor = GREEN)
            ) {
                Text("Kuruluma Devam Et →", fontSize = 16.sp, fontWeight = FontWeight.Bold, color = WHITE)
            }
        }
    }
}

// ── Kurulum Devam Ediyor ──────────────────────────────────────
@Composable
fun InstallingContent(steps: List<SetupStep>, logLines: List<String>, currentStep: Int, onSkip: () -> Unit = {}) {
    val logScrollState = rememberScrollState()
    val clipboardManager = LocalClipboardManager.current
    val ctx = LocalContext.current
    val setupCmd = "bash <(curl -sf https://raw.githubusercontent.com/hakanerbasss/apk-factory-assets/main/scripts/setup_full.sh)"

    LaunchedEffect(logLines.size) { logScrollState.animateScrollTo(logScrollState.maxValue) }

    val doneCount = steps.count { it.done }
    val totalCount = steps.size
    val activeStep = steps.getOrNull(currentStep + 1) ?: steps.lastOrNull { !it.done }

    Column(modifier = Modifier.fillMaxSize().padding(horizontal = 20.dp)) {
        Spacer(Modifier.height(48.dp))

        // Başlık + Atla
        Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Text("Kurulum Devam Ediyor", fontSize = 22.sp, fontWeight = FontWeight.Bold, color = WHITE, modifier = Modifier.weight(1f))
            TextButton(onClick = onSkip) { Text("Atla →", color = GREY, fontSize = 13.sp) }
        }

        Spacer(Modifier.height(12.dp))

        // Adım sayacı + aktif adım adı
        Row(verticalAlignment = Alignment.CenterVertically) {
            Box(
                modifier = Modifier.size(52.dp).clip(CircleShape)
                    .background(ACCENT.copy(alpha = 0.15f))
                    .border(2.dp, ACCENT.copy(alpha = 0.4f), CircleShape),
                contentAlignment = Alignment.Center
            ) {
                Text("$doneCount/$totalCount", fontSize = 14.sp, fontWeight = FontWeight.Bold, color = ACCENT)
            }
            Spacer(Modifier.width(12.dp))
            Column {
                Text(activeStep?.title ?: "Tamamlandı", fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = WHITE)
                Text("işlem devam ediyor...", fontSize = 11.sp, color = GREY)
            }
        }

        Spacer(Modifier.height(12.dp))

        // Adımlar — yatay kaydırmalı chip'ler
        Row(
            modifier = Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()),
            horizontalArrangement = Arrangement.spacedBy(6.dp)
        ) {
            steps.forEachIndexed { idx, step ->
                val isActive = idx == currentStep + 1
                val bg = when { step.done -> GREEN.copy(alpha=0.15f); isActive -> ACCENT.copy(alpha=0.15f); else -> SURFACE }
                val border = when { step.done -> GREEN.copy(alpha=0.4f); isActive -> ACCENT.copy(alpha=0.4f); else -> BORDER }
                Box(
                    modifier = Modifier.clip(RoundedCornerShape(20.dp)).background(bg)
                        .border(1.dp, border, RoundedCornerShape(20.dp))
                        .padding(horizontal = 10.dp, vertical = 6.dp)
                ) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        when {
                            step.done -> Icon(Icons.Default.Check, null, tint = GREEN, modifier = Modifier.size(12.dp))
                            isActive -> CircularProgressIndicator(modifier = Modifier.size(12.dp), color = ACCENT, strokeWidth = 1.5.dp)
                            else -> Box(modifier = Modifier.size(6.dp).clip(CircleShape).background(BORDER))
                        }
                        Spacer(Modifier.width(4.dp))
                        Text(step.title, fontSize = 11.sp, color = if (step.done || isActive) WHITE else GREY)
                    }
                }
            }
        }

        Spacer(Modifier.height(10.dp))

        Spacer(Modifier.height(10.dp))

        // Log kutusu — kalan tüm alanı kapla
        Text("Çıktı", fontSize = 12.sp, color = GREY, fontWeight = FontWeight.Medium)
        Spacer(Modifier.height(4.dp))
        Box(
            modifier = Modifier.fillMaxWidth().weight(1f)
                .clip(RoundedCornerShape(12.dp))
                .background(Color(0xFF060608))
                .border(1.dp, BORDER, RoundedCornerShape(12.dp))
                .padding(12.dp)
        ) {
            Column(modifier = Modifier.fillMaxSize().verticalScroll(logScrollState)) {
                if (logLines.isEmpty()) {
                    Text("Başlatılıyor...", fontSize = 11.sp, color = GREY, fontFamily = FontFamily.Monospace)
                }
                logLines.forEach { line ->
                    val color = when {
                        line.contains("✅") || line.contains("TAMAM") -> GREEN
                        line.contains("❌") || line.contains("HATA") -> RED
                        line.contains("...") || line.contains("►") -> Color(0xFFFFD700)
                        else -> Color(0xFF8AE1A0)
                    }
                    Text(line, fontSize = 11.sp, color = color, fontFamily = FontFamily.Monospace, lineHeight = 16.sp)
                }
            }
        }
        Spacer(Modifier.height(16.dp))
    }
}

// ── Adım Satırı ───────────────────────────────────────────────
@Composable
fun StepRow(step: SetupStep, isActive: Boolean) {
    Row(modifier = Modifier.fillMaxWidth().padding(vertical = 4.dp), verticalAlignment = Alignment.CenterVertically) {
        Box(
            modifier = Modifier.size(38.dp).clip(CircleShape)
                .background(when {
                    step.error -> RED.copy(alpha = 0.15f)
                    step.done  -> GREEN.copy(alpha = 0.15f)
                    isActive   -> ACCENT.copy(alpha = 0.15f)
                    else       -> SURFACE
                })
                .border(1.dp, when {
                    step.error -> RED.copy(alpha = 0.5f)
                    step.done  -> GREEN.copy(alpha = 0.5f)
                    isActive   -> ACCENT.copy(alpha = 0.5f)
                    else       -> BORDER
                }, CircleShape),
            contentAlignment = Alignment.Center
        ) {
            when {
                step.error -> Icon(Icons.Default.Close, null, tint = RED, modifier = Modifier.size(18.dp))
                step.done  -> Icon(Icons.Default.Check, null, tint = GREEN, modifier = Modifier.size(18.dp))
                isActive   -> CircularProgressIndicator(modifier = Modifier.size(20.dp), color = ACCENT, strokeWidth = 2.dp)
                else       -> Box(modifier = Modifier.size(8.dp).clip(CircleShape).background(BORDER))
            }
        }
        Spacer(Modifier.width(14.dp))
        Text(
            step.title, fontSize = 14.sp,
            color = when { step.error -> RED; step.done -> WHITE; isActive -> WHITE; else -> GREY },
            fontWeight = if (isActive || step.done) FontWeight.Medium else FontWeight.Normal
        )
    }
}

// ── Tamamlandı ────────────────────────────────────────────────
@Composable
fun DoneContent(ctx: android.content.Context, onContinue: () -> Unit) {
    Column(
        modifier = Modifier.fillMaxSize().padding(24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center
    ) {
        Box(
            modifier = Modifier.size(120.dp).clip(CircleShape)
                .background(GREEN.copy(alpha = 0.15f))
                .border(2.dp, GREEN.copy(alpha = 0.5f), CircleShape),
            contentAlignment = Alignment.Center
        ) { Icon(Icons.Default.CheckCircle, null, modifier = Modifier.size(60.dp), tint = GREEN) }
        Spacer(Modifier.height(32.dp))
        Text("Hazır! 🎉", fontSize = 36.sp, fontWeight = FontWeight.Black, color = WHITE)
        Spacer(Modifier.height(12.dp))
        Text("APK Factory kuruldu ve çalışıyor!", fontSize = 16.sp, color = GREY, lineHeight = 24.sp)
        Spacer(Modifier.height(48.dp))
        Button(
            onClick = { com.wizaicorp.apkfactory.data.TermuxBridge.startWsBridge(ctx); onContinue() },
            modifier = Modifier.fillMaxWidth().height(56.dp), shape = RoundedCornerShape(16.dp),
            colors = ButtonDefaults.buttonColors(containerColor = GREEN)
        ) {
            Text("Başlayalım →", fontSize = 17.sp, fontWeight = FontWeight.Bold, color = WHITE)
        }
    }
}

private fun initialSteps() = listOf(
    SetupStep("Paket listesi güncelleniyor"), SetupStep("Temel araçlar kuruluyor"),
    SetupStep("Python + WebSocket"), SetupStep("Java (OpenJDK 17)"),
    SetupStep("Android SDK indiriliyor"), SetupStep("Lisanslar kabul ediliyor"),
    SetupStep("Build Tools"), SetupStep("aapt2 düzeltiliyor"),
    SetupStep("Factory scriptler"), SetupStep("WebSocket sunucusu")
)

private fun updateSteps(log: String, steps: List<SetupStep>): List<SetupStep> {
    val markers = listOf(
        "Paket listesi güncellendi", "Temel araçlar kuruldu", "Python + WebSocket hazır",
        "Java kuruldu", "SDK araçları indirildi", "Lisanslar kabul edildi",
        "Build Tools kuruldu", "aapt2 hazır", "Factory scriptler hazır", "WebSocket bridge yazıldı"
    )
    return steps.mapIndexed { i, step -> step.copy(done = markers.getOrNull(i)?.let { log.contains(it) } ?: false) }
}
