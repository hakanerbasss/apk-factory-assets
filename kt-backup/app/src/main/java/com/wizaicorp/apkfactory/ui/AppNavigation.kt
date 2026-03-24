package com.wizaicorp.apkfactory.ui

import android.content.Intent
import android.net.Uri
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import com.wizaicorp.apkfactory.data.WsManager
import com.wizaicorp.apkfactory.ui.screens.BG
import com.wizaicorp.apkfactory.ui.screens.ACCENT
import com.wizaicorp.apkfactory.ui.screens.MainScreen
import com.wizaicorp.apkfactory.ui.screens.SetupScreen
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.withTimeoutOrNull

@Composable
fun AppNavigation() {
    var screen by remember { mutableStateOf("loading") }
    val context = LocalContext.current

    LaunchedEffect(Unit) {
        // Termux kurulu mu?
        val termuxInstalled = try {
            context.packageManager.getPackageInfo("com.termux", 0); true
        } catch (e: Exception) { false }

        if (!termuxInstalled) { screen = "no_termux"; return@LaunchedEffect }

        // Bağlanmayı dene — 5 saniye bekle
        WsManager.connect()
        val connected = withTimeoutOrNull(5000) {
            WsManager.connected.first { it }
        }
        if (connected == true) {
            // ws bağlı ama setup tamamlandı mı kontrol et
            val setupDone = com.wizaicorp.apkfactory.data.TermuxBridge.isSetupDone(context)
            screen = if (setupDone) "main" else "setup"
        } else {
            screen = "setup"
        }
    }

    when (screen) {
        "loading" -> Box(
            modifier = Modifier.fillMaxSize().background(BG),
            contentAlignment = Alignment.Center
        ) { CircularProgressIndicator(color = ACCENT) }

        "no_termux" -> NoTermuxScreen(
            onInstall = {
                val intent = Intent(Intent.ACTION_VIEW,
                    Uri.parse("https://f-droid.org/en/packages/com.termux/"))
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                context.startActivity(intent)
            }
        )

        "setup" -> SetupScreen(
            onSetupDone = { screen = "main" },
            onSkip = { screen = "main" }
        )
        "main" -> MainScreen()
    }
}

@Composable
fun NoTermuxScreen(onInstall: () -> Unit) {
    Box(modifier = Modifier.fillMaxSize().background(BG), contentAlignment = Alignment.Center) {
        androidx.compose.material3.Card(
            modifier = Modifier.padding(32.dp),
            colors = androidx.compose.material3.CardDefaults.cardColors(
                containerColor = androidx.compose.ui.graphics.Color(0xFF1E1E2E)
            ),
            shape = androidx.compose.foundation.shape.RoundedCornerShape(16.dp)
        ) {
            Column(
                modifier = Modifier.padding(24.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(16.dp)
            ) {
                androidx.compose.material3.Text("⚠️", fontSize = androidx.compose.ui.unit.TextUnit(40f, androidx.compose.ui.unit.TextUnitType.Sp))
                androidx.compose.material3.Text(
                    "Termux Gerekli",
                    color = androidx.compose.ui.graphics.Color.White,
                    fontWeight = androidx.compose.ui.text.font.FontWeight.Bold,
                    fontSize = androidx.compose.ui.unit.TextUnit(18f, androidx.compose.ui.unit.TextUnitType.Sp)
                )
                androidx.compose.material3.Text(
                    "APK Factory çalışmak için Termux uygulamasına ihtiyaç duyar. F-Droid üzerinden ücretsiz indirilebilir.",
                    color = androidx.compose.ui.graphics.Color(0xFF94A3B8),
                    fontSize = androidx.compose.ui.unit.TextUnit(13f, androidx.compose.ui.unit.TextUnitType.Sp),
                    textAlign = androidx.compose.ui.text.style.TextAlign.Center
                )
                androidx.compose.material3.Button(
                    onClick = onInstall,
                    modifier = Modifier.fillMaxWidth(),
                    shape = androidx.compose.foundation.shape.RoundedCornerShape(10.dp),
                    colors = androidx.compose.material3.ButtonDefaults.buttonColors(
                        containerColor = ACCENT
                    )
                ) {
                    androidx.compose.material3.Text("F-Droid'den İndir", fontWeight = androidx.compose.ui.text.font.FontWeight.Bold)
                }
                androidx.compose.material3.Text(
                    "F-Droid güvenlik uyarısı gösterebilir → 'Yine de indir' seçin",
                    color = androidx.compose.ui.graphics.Color(0xFF64748B),
                    fontSize = androidx.compose.ui.unit.TextUnit(11f, androidx.compose.ui.unit.TextUnitType.Sp),
                    textAlign = androidx.compose.ui.text.style.TextAlign.Center
                )
            }
        }
    }
}
