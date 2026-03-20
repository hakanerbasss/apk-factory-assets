
package com.wizaicorp.apkfactory.ui.screens
import androidx.compose.ui.layout.ContentScale
import androidx.compose.animation.*
import androidx.compose.foundation.*
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.lazy.*
import androidx.compose.foundation.shape.*
import androidx.compose.ui.draw.clip
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.*
import androidx.compose.ui.graphics.*
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.*
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.*
import com.wizaicorp.apkfactory.data.*
import com.wizaicorp.apkfactory.data.DriveUploadManager
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import com.google.android.gms.auth.api.signin.GoogleSignIn
import com.google.android.gms.common.api.ApiException
import kotlinx.coroutines.launch
import com.wizaicorp.apkfactory.data.TermuxBridge
import kotlinx.coroutines.*
import androidx.compose.runtime.collectAsState


// ── APK Yükleme Yardımcısı ────────────────────────────────────────────────────
fun installApk(context: android.content.Context, path: String) {
    try {
        val file = java.io.File(path)
        if (!file.exists()) {
            android.widget.Toast.makeText(context, "APK bulunamadı: $path", android.widget.Toast.LENGTH_LONG).show()
            return
        }

        // 1. Android 11+ Tüm Dosyalara Erişim İzni Kontrolü
        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.R && !android.os.Environment.isExternalStorageManager()) {
            val intent = android.content.Intent(android.provider.Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION)
            intent.data = android.net.Uri.parse("package:${context.packageName}")
            intent.addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK)
            context.startActivity(intent)
            android.widget.Toast.makeText(context, "Kurulum için 'Tüm dosyalara erişim' iznini verip APK'ya tekrar tıklayın.", android.widget.Toast.LENGTH_LONG).show()
            return
        }

        // 2. Android 8+ Bilinmeyen Kaynaklardan Yükleme İzni Kontrolü
        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.O && !context.packageManager.canRequestPackageInstalls()) {
            val intent = android.content.Intent(android.provider.Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, android.net.Uri.parse("package:${context.packageName}"))
            intent.addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK)
            context.startActivity(intent)
            android.widget.Toast.makeText(context, "Ayarlar → Özel uygulama erişimi → Bu kaynaktan yükle → İzin ver", android.widget.Toast.LENGTH_LONG).show()
            return
        }

        // 3. Güvenli URI oluşturma ve Doğru MIME Type ile yüklemeyi başlatma
        val uri = androidx.core.content.FileProvider.getUriForFile(context, "${context.packageName}.provider", file)
        val intent = android.content.Intent(android.content.Intent.ACTION_VIEW).apply {
            setDataAndType(uri, "application/vnd.android.package-archive")
            addFlags(android.content.Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        context.startActivity(intent)
    } catch (e: Exception) {
        android.widget.Toast.makeText(context, "Hata: ${e.message}", android.widget.Toast.LENGTH_LONG).show()
    }
}



private val PURPLE = Color(0xFF9C6FDE)

enum class AppTab { PROJECTS, AUTOFIX, APKS, SETTINGS }
enum class RunMode { IDLE, BUILDING, AUTOFIXING }
enum class PromptType { NONE, BUILD_SUCCESS, BUILD_FAILED, APPLY_CHANGES, STOPPED }

// ── Ana Ekran ──────────────────────────────────────────────────────────────
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MainScreen() {
    val scope     = rememberCoroutineScope()
    val context   = LocalContext.current
    val connected by WsManager.connected.collectAsState()

    var activeTab       by remember { mutableStateOf(AppTab.PROJECTS) }
    var projects        by remember { mutableStateOf(listOf<ProjectInfo>()) }
    var selectedProject by remember { mutableStateOf<ProjectInfo?>(null) }
    var logs            by remember { mutableStateOf(listOf<String>()) }
    var runMode         by remember { mutableStateOf(RunMode.IDLE) }
    var promptType      by remember { mutableStateOf(PromptType.NONE) }
    var promptErrorMsg  by remember { mutableStateOf("") }
    var autoMode        by remember { mutableStateOf(false) }
    var newApkPath      by remember { mutableStateOf("") }
    var globalToast     by remember { mutableStateOf("") }
    var showNewProject  by remember { mutableStateOf(false) }
    var chainTask by remember { mutableStateOf("") }
    var userActionDialog by remember { mutableStateOf("") }
    var pendingNewProjectTask by remember { mutableStateOf("") }

    LaunchedEffect(globalToast) { if (globalToast.isNotEmpty()) { delay(3000); globalToast = "" } }

    // Prompt zaman aşımı yok — kullanıcı karar verene kadar bekler

    LaunchedEffect(Unit) {
        WsManager.connect()
        WsManager.events.collect { event ->
            when (event) {
                is WsEvent.Log    -> logs = (logs + event.text).takeLast(600)
                is WsEvent.Status -> logs = (logs + "→ ${event.text}").takeLast(600)
                is WsEvent.Prompt -> {
                    promptType = when (event.promptType) {
                        "build_success" -> PromptType.BUILD_SUCCESS
                        "build_failed"  -> PromptType.BUILD_FAILED
                        "apply_changes" -> PromptType.APPLY_CHANGES
                        else            -> PromptType.NONE
                    }
                }
                is WsEvent.BuildDone -> {
                    runMode = RunMode.IDLE; promptType = PromptType.NONE
                    val msg = if (event.success) "✅ Build başarılı!" else "❌ Build başarısız"
                    logs = logs + msg; globalToast = msg
                    if (event.success && event.apkPath.isNotEmpty()) {
                        newApkPath = event.apkPath
                        globalToast = "✅ APK hazır!"
                    }
                }
                is WsEvent.TaskDone -> {
                    promptType = PromptType.NONE
                    if (event.success) {
                        chainTask = ""
                        val ts = java.text.SimpleDateFormat("HH:mm:ss", java.util.Locale.getDefault()).format(java.util.Date())
                        val projName = event.project.ifEmpty { selectedProject?.name ?: "-" }
                        logs = logs + "\n══ ✅ GÖREV TAMAMLANDI [$ts] ══\n📦 $projName"
                    }
                    val msg = event.text.ifEmpty { if (event.success) "✅ Tamamlandı!" else "❌ Başarısız" }
                    logs = logs + msg
                    if (event.success && event.apkPath.isNotEmpty()) {
                        newApkPath = event.apkPath
                        globalToast = "🎉 APK hazır!"
                    }
                    if (event.success) {
                        WsManager.checkNextTask(selectedProject?.name ?: "")
                    } else {
                        runMode = RunMode.IDLE
                        globalToast = msg
                    }
                }
                is WsEvent.ProjectDone -> {
                    logs = logs + if (event.success) "✅ Proje: ${event.name}" else "❌ Proje oluşturulamadı"
                    WsManager.listProjects()
                    if (event.success && pendingNewProjectTask.isNotEmpty()) {
                        val taskToRun = pendingNewProjectTask
                        pendingNewProjectTask = ""
                        runMode = RunMode.AUTOFIXING
                        WsManager.task(event.name, taskToRun)
                    } else {
                        runMode = RunMode.IDLE
                    }
                }
                is WsEvent.Error -> {
                    runMode = RunMode.IDLE; promptType = PromptType.NONE
                    globalToast = "❌ ${event.msg}"
                    logs = logs + "❌ ${event.msg}"
                }
                is WsEvent.Projects    -> projects = event.list
                is WsEvent.Disconnected -> { delay(8000); WsManager.connect() }
                        is WsEvent.UserAction -> logs = (logs + "\n⚠️ KULLANICI AKSİYONU:\n${event.text}").takeLast(600)
                is WsEvent.ChainTask -> {
                    chainTask = event.task
                }
                is WsEvent.NextTask -> {
                    if (event.task.isNotEmpty()) {
                        logs = logs + "📬 Zincir aşama devam ediyor..."
                        globalToast = "📬 Zincir devam ediyor..."
                        val proj = projects.find { it.name == event.project } ?: selectedProject
                        if (proj != null) {
                            selectedProject = proj
                            runMode = RunMode.AUTOFIXING
                            WsManager.task(proj.name, event.task)
                        }
                    } else {
                        val rapor = buildString {
                            append("\n══════════════════════════════")
                            append("\n📋 ZİNCİR TAMAMLANDI — PROJE RAPORU")
                            append("\n══════════════════════════════")
                            append("\n📦 Proje: ${selectedProject?.name ?: "-"}")
                            append("\n📅 Tarih: ${java.text.SimpleDateFormat("dd.MM.yyyy HH:mm", java.util.Locale.getDefault()).format(java.util.Date())}")
                            append("\n✅ Tüm aşamalar başarıyla tamamlandı")
                            append("\n══════════════════════════════")
                        }
                        chainTask = ""
                        runMode = RunMode.IDLE
                        globalToast = "✅ Tüm görevler tamamlandı!"
                        logs = logs + rapor
                    }
                }
                else -> {}
            }
        }
    }

    LaunchedEffect(connected) {
        if (connected) {
            WsManager.listProjects()
            // Bağlantı kurulunca eksik dosya/prompt kontrolü yap
        }
    }

    Scaffold(
        containerColor = BG,
        contentWindowInsets = WindowInsets(0),
            topBar = {
            TopBar(connected = connected, selectedProject = selectedProject,
                onReconnect = {
                    com.wizaicorp.apkfactory.data.TermuxBridge.startWsBridge(context)
                    android.widget.Toast.makeText(context, "🔄 Termux zorla yenileniyor...", android.widget.Toast.LENGTH_SHORT).show()
                    scope.launch { WsManager.disconnect(); kotlinx.coroutines.delay(3000); WsManager.connect() }
                })
        },

        bottomBar = { BottomNavBar(activeTab) { activeTab = it } },
        floatingActionButton = {
            if (activeTab == AppTab.PROJECTS)
                FloatingActionButton(onClick = { showNewProject = true },
                    containerColor = ACCENT, contentColor = WHITE, shape = RoundedCornerShape(16.dp)) {
                    Icon(Icons.Default.Hub, null)
                }
        }
    ) { padding ->
        Box(modifier = Modifier.fillMaxSize().padding(padding).imePadding()) {
            when (activeTab) {
                AppTab.PROJECTS -> ProjectsTab(
                    projects = projects, selectedProject = selectedProject,
                    onSelect = { p -> selectedProject = p; activeTab = AppTab.AUTOFIX; WsManager.checkChainTask(p.name) },
                    onAutofix = { p ->
                        selectedProject = p
                        logs = listOf("🤖 AutoFix (af): ${p.name}...")
                        runMode = RunMode.AUTOFIXING; newApkPath = ""
                        WsManager.autofix(p.name)
                        activeTab = AppTab.AUTOFIX
                    },




                    onBackup = { p, type, note -> WsManager.backup(p.name, note = note, backupType = type); globalToast = "💾 Yedekleniyor..." },



                    onDelete = { p ->
                        WsManager.deleteProject(p.name)
                        if (selectedProject == p) selectedProject = null
                        globalToast = "🗑 ${p.name} silindi"
                        WsManager.listProjects()
                    },
                    onUserAction = { action -> userActionDialog = action }
                )
                AppTab.AUTOFIX -> AutoFixTab(
                    logs = logs, runMode = runMode, promptType = promptType,
                    selectedProject = selectedProject, newApkPath = newApkPath,
                    chainTask = chainTask, onDeleteChainTask = { WsManager.deleteChainTask(); chainTask = "" },
                    onAutofix = { p ->         // prj af — build + AI otodüzelt
                        logs = listOf("🤖 AutoFix (af): ${p.name}")
                        runMode = RunMode.AUTOFIXING; newApkPath = ""
                        WsManager.autofix(p.name)
                    },
                    onTask = { p, task ->      // prj e "task" — görev ver
                        logs = listOf("✨ Görev: ${p.name}\n→ $task")
                        runMode = RunMode.AUTOFIXING; newApkPath = ""
                        WsManager.task(p.name, task)
                    },
                    onBuildDebug = { p ->      // prj d — debug build
                        logs = listOf("🔨 Debug build: ${p.name}")
                        runMode = RunMode.BUILDING; newApkPath = ""
                        WsManager.buildDebug(p.name)
                    },
                    onBuildRelease = { p ->    // prj b — AAB release
                        logs = listOf("📦 Release build: ${p.name}")
                        runMode = RunMode.BUILDING; newApkPath = ""
                        WsManager.buildRelease(p.name)
                    },
                    onStop = {
                        WsManager.killProcess()
                        runMode = RunMode.IDLE
                        autoMode = false
                        logs = logs + "⏹ Durduruldu"
                        // Durdurulunca yedeğe dön seçeneği sun
                        promptType = PromptType.STOPPED
                    },
                    onContinue = { promptType = PromptType.NONE; promptErrorMsg = ""; WsManager.sendInput("") },
                    onRestoreAndStop = { promptType = PromptType.NONE; promptErrorMsg = ""; autoMode = false; WsManager.sendInput("b") },
                    onApplyChanges = { promptType = PromptType.NONE; promptErrorMsg = ""; WsManager.sendInput("") },
                    onRejectChanges = { promptType = PromptType.NONE; promptErrorMsg = ""; autoMode = false; WsManager.sendInput("İ") },
                    onKeepChanges = { promptType = PromptType.NONE },
                    onSetAutoMode = { enabled ->
                        autoMode = enabled
                        WsManager.setAutoMode(enabled)
                        if (enabled) {
                            // Eğer şu an build_failed veya apply_changes prompttaysa hemen devam et
                            if (promptType == PromptType.BUILD_FAILED || promptType == PromptType.APPLY_CHANGES) {
                                promptType = PromptType.NONE; promptErrorMsg = ""; WsManager.sendInput("")
                            }
                        }
                    },
                    autoMode = autoMode,
                    promptErrorMsg = promptErrorMsg,
                    onClearLogs = { logs = listOf() },
                    onGoToApks = { activeTab = AppTab.APKS }
                )
                AppTab.APKS     -> ApksTab(selectedProject = selectedProject)
                AppTab.SETTINGS -> SettingsTab()
            }

            // Toast
            AnimatedVisibility(
                visible = globalToast.isNotEmpty(),
                modifier = Modifier.align(Alignment.BottomCenter).padding(bottom = 16.dp, start = 16.dp, end = 16.dp),
                enter = slideInVertically { it } + fadeIn(),
                exit  = slideOutVertically { it } + fadeOut()
            ) {
                Card(colors = CardDefaults.cardColors(containerColor = CARD),
                    border = BorderStroke(1.dp, BORDER), shape = RoundedCornerShape(20.dp),
                    elevation = CardDefaults.cardElevation(8.dp)) {
                    Text(globalToast, modifier = Modifier.padding(horizontal = 20.dp, vertical = 10.dp),
                        color = WHITE, fontSize = 13.sp)
                }
            }
        }
    }

    if (showNewProject)
        NewProjectDialog(onDismiss = { showNewProject = false },
            onCreate = { name, task, pkg ->
                showNewProject = false
                pendingNewProjectTask = task
                logs = listOf("📦 Proje: $name")
                runMode = RunMode.AUTOFIXING; activeTab = AppTab.AUTOFIX
                WsManager.newProject(name, task, pkg)
            })
}

// ── TopBar — taşmaz ────────────────────────────────────────────────────────
// ── TopBar — taşmaz ────────────────────────────────────────────────────────
@Composable
fun TopBar(connected: Boolean, selectedProject: ProjectInfo?, onReconnect: () -> Unit) {
    val ctx = androidx.compose.ui.platform.LocalContext.current
    var showSystemDialog by remember { mutableStateOf(false) }
    var showNukeWarningDialog by remember { mutableStateOf(false) }
    var updating by remember { mutableStateOf(false) }
    var showConnStatusDialog by remember { mutableStateOf(false) }

    // Eskiden VersionInfo bekliyordu, artık sadece güncelleme bitince yükleme ikonunu durdurmak için TaskDone dinliyor
    LaunchedEffect(Unit) {
        com.wizaicorp.apkfactory.data.WsManager.events.collect { event ->
            if (event is com.wizaicorp.apkfactory.data.WsEvent.TaskDone) {
                if (updating) updating = false
            }
        }
    }

    // DİALOG 1: Anında açılan Sorun Giderme Odası (Eksiksiz!)
    if (showSystemDialog) {
        AlertDialog(
            onDismissRequest = { showSystemDialog = false },
            containerColor = androidx.compose.ui.graphics.Color(0xFF1E1E2E),
            title = { Text("Sistem Durumu", color = WHITE, fontWeight = androidx.compose.ui.text.font.FontWeight.Bold) },
            text = {
                Column {
                    Spacer(Modifier.height(12.dp))
                    androidx.compose.material3.Divider(color = androidx.compose.ui.graphics.Color(0xFF2A2A3E))
                    Spacer(Modifier.height(8.dp))
                    val uriHandler = androidx.compose.ui.platform.LocalUriHandler.current
                    val clipboardManager = androidx.compose.ui.platform.LocalClipboardManager.current
                    
                    Text("🔧 Sorun Giderme", color = WHITE, fontWeight = androidx.compose.ui.text.font.FontWeight.Bold, fontSize = 12.sp)
                    Spacer(Modifier.height(4.dp))
                    Text("• Bağlantı sorunu → Ayarlar'da 'Yeniden Başlat'", color = GREY, fontSize = 11.sp)
                    Spacer(Modifier.height(4.dp))
                    
                    listOf(
                        "bash ~/restart_bridge.sh",
                        "bash /sdcard/termux-otonom-sistem/check_updates.sh force",
                        "pgrep -f ws_bridge.py"
                    ).forEach { cmd ->
                        Row(modifier = Modifier.fillMaxWidth().padding(vertical = 2.dp), verticalAlignment = Alignment.CenterVertically) {
                            Text(cmd, color = androidx.compose.ui.graphics.Color(0xFF8AE1A0), fontSize = 10.sp, fontFamily = androidx.compose.ui.text.font.FontFamily.Monospace, modifier = Modifier.weight(1f))
                            IconButton(onClick = { clipboardManager.setText(androidx.compose.ui.text.AnnotatedString(cmd)); android.widget.Toast.makeText(ctx, "Kopyalandı", android.widget.Toast.LENGTH_SHORT).show() }, modifier = Modifier.size(24.dp)) {
                                Icon(Icons.Default.ContentCopy, null, tint = GREY, modifier = Modifier.size(12.dp))
                            }
                        }
                    }
                    
                    Spacer(Modifier.height(4.dp))
                    Surface(onClick = { val i = android.content.Intent(android.content.Intent.ACTION_MAIN).apply { setClassName("com.termux", "com.termux.app.TermuxActivity"); addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK) }; try { ctx.startActivity(i) } catch (e: Exception) {} }, shape = RoundedCornerShape(8.dp), color = androidx.compose.ui.graphics.Color(0xFF1A1A2E), border = BorderStroke(1.dp, BORDER)) {
                        Row(modifier = Modifier.padding(horizontal = 10.dp, vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
                            Text(">_", color = GREEN, fontSize = 12.sp, fontWeight = androidx.compose.ui.text.font.FontWeight.Bold, fontFamily = androidx.compose.ui.text.font.FontFamily.Monospace)
                            Spacer(Modifier.width(6.dp))
                            Text("Termux'u Aç", color = WHITE, fontSize = 11.sp)
                        }
                    }
                    
                    Spacer(Modifier.height(8.dp))
                    androidx.compose.material3.Divider(color = androidx.compose.ui.graphics.Color(0xFF2A2A3E))
                    Spacer(Modifier.height(8.dp))
                    Text("💬 Yardım & Kullanım Grubu", color = WHITE, fontWeight = androidx.compose.ui.text.font.FontWeight.Bold, fontSize = 12.sp)
                    Spacer(Modifier.height(4.dp))
                    Text("💬 WhatsApp grubuna katıl →", color = ACCENT, fontSize = 11.sp, modifier = Modifier.clickable { uriHandler.openUri("whatsapp://send?text=APK+Factory+grubuna+katılmak+istiyorum") })
                    Spacer(Modifier.height(4.dp))
                    Text("📖 Kullanım kılavuzu (GitHub) →", color = ACCENT, fontSize = 11.sp, modifier = Modifier.clickable { uriHandler.openUri("https://github.com/hakanerbasss/apk-factory-assets") })
                }
            },
            confirmButton = {
                // Güncelle butonuna basınca direkt indirme, UYARI penceresini aç!
                TextButton(onClick = { showSystemDialog = false; showNukeWarningDialog = true }) {
                    Text("GitHub'dan Güncelle", color = RED)
                }
            },
            dismissButton = {
                TextButton(onClick = { showSystemDialog = false }) { Text("Kapat", color = GREY) }
            }
        )
    }

    // DİALOG 2: KOCAMAN UYARI (Nuke Warning)
    if (showNukeWarningDialog) {
        AlertDialog(
            onDismissRequest = { showNukeWarningDialog = false },
            containerColor = CARD,
            title = {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(Icons.Default.Warning, null, tint = RED, modifier = Modifier.size(24.dp))
                    Spacer(Modifier.width(8.dp))
                    Text("DİKKAT! Üzerine Yazılacak", color = RED, fontWeight = androidx.compose.ui.text.font.FontWeight.Bold, fontSize = 16.sp)
                }
            },
            text = {
                Card(colors = CardDefaults.cardColors(containerColor = RED.copy(alpha = 0.1f)), border = BorderStroke(1.dp, RED.copy(alpha = 0.4f))) {
                    Text(
                        text = "Eğer devam ederseniz, yerelde (Termux içinde) ws_bridge.py gibi sistem dosyalarında yaptığınız TÜM ÖZEL DEĞİŞİKLİKLER ÇÖPE GİDER!\n\nGitHub'daki orijinal dosyalar acımasızca mevcut dosyalarınızın üzerine yazılır.\n\nYine de ateşleyelim mi?",
                        color = WHITE, fontSize = 13.sp, modifier = Modifier.padding(12.dp), lineHeight = 18.sp
                    )
                }
            },
            confirmButton = {
                Button(onClick = { 
                    showNukeWarningDialog = false
                    updating = true
                    // Doğrudan motorun güncelleme komutunu tetikle (Versiyon bekleme yok)
                    com.wizaicorp.apkfactory.data.WsManager.checkUpdates()
                    android.widget.Toast.makeText(ctx, "🔥 GitHub güncellemesi ateşlendi!", android.widget.Toast.LENGTH_LONG).show()
                }, colors = ButtonDefaults.buttonColors(containerColor = RED)) {
                    Text("Yine De İndir & Ez", color = WHITE, fontWeight = androidx.compose.ui.text.font.FontWeight.Bold)
                }
            },
            dismissButton = {
                TextButton(onClick = { showNukeWarningDialog = false }) { Text("Vazgeç", color = GREY) }
            }
        )
    }


    // DİALOG 3: Online/Offline Bilgi Kartı
    if (showConnStatusDialog) {
        AlertDialog(
            onDismissRequest = { showConnStatusDialog = false },
            containerColor = CARD,
            shape = RoundedCornerShape(16.dp),
            title = {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Box(modifier = Modifier.size(12.dp).background(if (connected) GREEN else RED, CircleShape))
                    Spacer(Modifier.width(8.dp))
                    Text(if (connected) "Durum: Online" else "Durum: Offline", color = WHITE, fontWeight = androidx.compose.ui.text.font.FontWeight.Bold, fontSize = 16.sp)
                }
            },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text("Bu gösterge uygulamanın tamamen ayakta olduğunu GARANTİ ETMEZ. Sadece arayüzün Termux'a giden iletişim kablosunun (WebSocket) takılı olduğunu gösterir.", color = WHITE, fontSize = 13.sp)
                    
                    Card(colors = CardDefaults.cardColors(containerColor = SURFACE), border = BorderStroke(1.dp, BORDER)) {
                        Text("⚠️ ÖNEMLİ: Eğer izinleriniz eksikse yeşil ışık yansa bile komutlar çalışmayabilir.\n\nGerçek bir bağlantı sorunu yaşıyorsanız veya motor donduysa, lütfen ana menüden AYARLAR sekmesine gidip oradaki ana şalterden motoru başlatın.",
                            modifier = Modifier.padding(10.dp), color = GREY, fontSize = 12.sp, lineHeight = 18.sp)
                    }
                }
            },
            confirmButton = {
                Button(onClick = {
                    showConnStatusDialog = false
                    onReconnect() // Eski işlevini koruyoruz, dilerse buradan da köprüyü yenileyebilir
                }, colors = ButtonDefaults.buttonColors(containerColor = ACCENT)) {
                    Text("Köprüyü Yenile")
                }
            },
            dismissButton = {
                TextButton(onClick = { showConnStatusDialog = false }) { Text("Anladım", color = GREY) }
            }
        )
    }



    // Üst Bar Görünümü
    Row(
        modifier = Modifier.fillMaxWidth().background(SURFACE).statusBarsPadding().padding(horizontal = 12.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Box(modifier = Modifier.size(30.dp).background(ACCENT.copy(alpha = 0.15f), RoundedCornerShape(8.dp)), contentAlignment = Alignment.Center) {
            Icon(Icons.Default.Build, null, tint = ACCENT, modifier = Modifier.size(16.dp))
        }
        Spacer(Modifier.width(8.dp))
        Column(modifier = Modifier.weight(1f)) {
            Text("APK Factory", fontWeight = androidx.compose.ui.text.font.FontWeight.Bold, fontSize = 14.sp, color = WHITE, maxLines = 1)
            Text(selectedProject?.name ?: "Proje seçilmedi", fontSize = 10.sp, color = GREY, maxLines = 1, overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis)
        }
        Spacer(Modifier.width(4.dp))
        
        // EKSİK OLAN YARDIM DÖKÜMANI İKONU GERİ GELDİ!
        IconButton(onClick = {
            val uri = android.net.Uri.parse("https://docs.google.com/document/d/1W-tTFORawExSRbio2Ae7atgopEi9C_ZaqiOCK53Ik4k/edit")
            val intent = android.content.Intent(android.content.Intent.ACTION_VIEW, uri).addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK)
            ctx.startActivity(intent)
        }, modifier = Modifier.size(30.dp)) {
            Icon(Icons.Default.HelpOutline, null, tint = GREY, modifier = Modifier.size(16.dp))
        }
        Spacer(Modifier.width(2.dp))
        
        // Yenile Butonu - Artık versiyon beklemez, direkt Dialog 1'i açar
        IconButton(onClick = { showSystemDialog = true }, modifier = Modifier.size(30.dp)) {
            Icon(Icons.Default.Refresh, null, tint = if (updating) ACCENT else GREY, modifier = Modifier.size(16.dp))
        }
        Spacer(Modifier.width(2.dp))
        
       
        Surface(onClick = { showConnStatusDialog = true }, shape = RoundedCornerShape(14.dp), color = if (connected) GREEN.copy(alpha = 0.12f) else RED.copy(alpha = 0.12f)) {
            Row(modifier = Modifier.padding(horizontal = 7.dp, vertical = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                Box(modifier = Modifier.size(6.dp).background(if (connected) GREEN else RED, CircleShape))
                Spacer(Modifier.width(4.dp))
                Text(if (connected) "Online" else "Offline", fontSize = 10.sp, color = if (connected) GREEN else RED, fontWeight = androidx.compose.ui.text.font.FontWeight.Medium, maxLines = 1)
            }
        }




    }
}

// ── Bottom Nav ─────────────────────────────────────────────────────────────
@Composable
fun BottomNavBar(active: AppTab, onSelect: (AppTab) -> Unit) {
    NavigationBar(containerColor = SURFACE, tonalElevation = 0.dp) {
        listOf(
            Triple(AppTab.PROJECTS, Icons.Default.Apps,     "Projeler"),
            Triple(AppTab.AUTOFIX,  Icons.Default.SmartToy, "AutoFix"),
            Triple(AppTab.APKS,     Icons.Default.Unarchive, "Çıktılar"),
            Triple(AppTab.SETTINGS, Icons.Default.Settings, "Ayarlar")
        ).forEach { (tab, icon, label) ->
            NavigationBarItem(
                selected = active == tab, onClick = { onSelect(tab) },
                icon = { Icon(icon, null, modifier = Modifier.size(22.dp)) },
                label = { Text(label, fontSize = 10.sp) },
                colors = NavigationBarItemDefaults.colors(
                    selectedIconColor = ACCENT, selectedTextColor = ACCENT,
                    unselectedIconColor = GREY,  unselectedTextColor = GREY,
                    indicatorColor = ACCENT.copy(alpha = 0.15f))
            )
        }
    }
}

// ── Projeler Tab ────────────────────────────────────────────────────────────
@Composable
fun ProjectsTab(
    projects: List<ProjectInfo>, selectedProject: ProjectInfo?,
    onSelect: (ProjectInfo) -> Unit, onAutofix: (ProjectInfo) -> Unit,
    onBackup: (ProjectInfo, String, String) -> Unit, onDelete: (ProjectInfo) -> Unit,
    onUserAction: (String) -> Unit = {}
) {
    var deleteConfirm by remember { mutableStateOf<ProjectInfo?>(null) }
    var targetLogoProject by remember { mutableStateOf<ProjectInfo?>(null) }
    var admobTargetProject by remember { mutableStateOf<ProjectInfo?>(null) }
    var logoStatus by remember { mutableStateOf("") }
    var searchQuery by remember { mutableStateOf("") }
    val filteredProjects = projects
        .filter { it.name.contains(searchQuery, ignoreCase = true) }
        .sortedByDescending { it.name }
    val context = androidx.compose.ui.platform.LocalContext.current
    val scope = rememberCoroutineScope()

    // 1. ÇÖZÜM: Launcher her zaman en üstte, şartlı (if) blokların DIŞINDA olmalı!
    val logoLauncher = androidx.activity.compose.rememberLauncherForActivityResult(
        androidx.activity.result.contract.ActivityResultContracts.GetContent()
    ) { uri ->
        uri?.let {
            val p = targetLogoProject ?: return@let
            try {
                val stream = context.contentResolver.openInputStream(it)
                val bitmap = android.graphics.BitmapFactory.decodeStream(stream)
                stream?.close()
                
                if (bitmap != null) {
                    // 3. ÇÖZÜM: Resmi Max 512px boyutuna ve %85 JPEG formatına sıkıştır (OOM Koruması)
                    val maxDim = 512f
                    val scale = kotlin.math.min(maxDim / bitmap.width, maxDim / bitmap.height)
                    val scaledBitmap = if (scale < 1f) {
                        android.graphics.Bitmap.createScaledBitmap(bitmap, (bitmap.width * scale).toInt(), (bitmap.height * scale).toInt(), true)
                    } else bitmap
                    
                    val outputStream = java.io.ByteArrayOutputStream()
                    scaledBitmap.compress(android.graphics.Bitmap.CompressFormat.JPEG, 85, outputStream)
                    val bytes = outputStream.toByteArray()
                    val b64 = android.util.Base64.encodeToString(bytes, android.util.Base64.NO_WRAP)
                    
                    WsManager.saveLogo(p.name, b64)
                    logoStatus = "⏳ Logo yükleniyor... Lütfen bekleyin."
                } else {
                    logoStatus = "❌ Resim okunamadı"
                }
            } catch (e: Exception) { logoStatus = "❌ Hata: ${e.message}" }
        }
    }

    // 2. ÇÖZÜM: Arka plandaki işlemi dinleyip sonsuz yüklemeyi durduran otomatik kapatıcı
    LaunchedEffect(Unit) {
        WsManager.events.collect { event ->
            if (logoStatus.startsWith("⏳")) {
                if (event is WsEvent.TaskDone || event is WsEvent.ProjectDone || event is WsEvent.Error) {
                    logoStatus = "✅ İşlem tamamlandı!"
                    kotlinx.coroutines.delay(1200) // 1.2 saniye başarı mesajını göster
                    targetLogoProject = null // Dialogu otomatik kapat
                    logoStatus = ""
                }
            }
        }
    }

    Column(modifier = Modifier.fillMaxSize()) {
        Text("Projeler", fontWeight = androidx.compose.ui.text.font.FontWeight.Bold, fontSize = 20.sp, color = WHITE,
            modifier = Modifier.padding(horizontal = 16.dp, vertical = 14.dp))
        
        if (projects.isEmpty()) {
            Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    Icon(Icons.Default.FolderOpen, null, tint = GREY, modifier = Modifier.size(48.dp))
                    Spacer(Modifier.height(12.dp))
                    Text("Proje yok", color = GREY, fontSize = 14.sp)
                    Text("+ ile yeni proje oluştur", color = GREY.copy(alpha = 0.6f), fontSize = 12.sp)
                }
            }
        } else {
            // Arama + Refresh
            Row(modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 6.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedTextField(
                    value = searchQuery, onValueChange = { searchQuery = it },
                    placeholder = { Text("Proje ara...", fontSize = 12.sp) },
                    modifier = Modifier.weight(1f), singleLine = true,
                    shape = RoundedCornerShape(10.dp),
                    colors = OutlinedTextFieldDefaults.colors(
                        focusedBorderColor = ACCENT, unfocusedBorderColor = BORDER,
                        focusedTextColor = WHITE, unfocusedTextColor = WHITE,
                        focusedContainerColor = CARD, unfocusedContainerColor = CARD),
                    textStyle = androidx.compose.ui.text.TextStyle(fontSize = 12.sp),
                    leadingIcon = { Icon(Icons.Default.Search, null, tint = GREY, modifier = Modifier.size(16.dp)) },
                    trailingIcon = {
                        if (searchQuery.isNotEmpty())
                            IconButton(onClick = { searchQuery = "" }, modifier = Modifier.size(32.dp)) {
                                Icon(Icons.Default.Close, null, tint = GREY, modifier = Modifier.size(14.dp))
                            }
                    }
                )
                IconButton(onClick = { WsManager.listProjects() },
                    modifier = Modifier.size(40.dp)) {
                    Icon(Icons.Default.Refresh, null, tint = ACCENT, modifier = Modifier.size(20.dp))
                }
            }
            LazyColumn(contentPadding = PaddingValues(horizontal = 12.dp, vertical = 4.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp)) {
                items(filteredProjects) { p ->
                    Card(modifier = Modifier.fillMaxWidth().clickable { onSelect(p) },
                        colors = CardDefaults.cardColors(
                            containerColor = if (p == selectedProject) ACCENT.copy(alpha = 0.08f) else CARD),
                        border = BorderStroke(1.dp, if (p == selectedProject) ACCENT.copy(alpha = 0.4f) else BORDER),
                        shape = RoundedCornerShape(14.dp)) {
                        Column(modifier = Modifier.padding(14.dp)) {
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                


                                Box(modifier = Modifier.size(38.dp)
                                    .background(PURPLE.copy(alpha = 0.15f), RoundedCornerShape(10.dp))
                                    .clip(RoundedCornerShape(10.dp)),
                                    contentAlignment = Alignment.Center) {
                                    ProjectLogo(projectName = p.name, modifier = Modifier.fillMaxSize(), fallbackIcon = Icons.Default.Android, fallbackTint = PURPLE)
                                }





                                
                                Spacer(Modifier.width(10.dp))
                                Column(modifier = Modifier.weight(1f)) {
                                    Text(p.name, fontWeight = androidx.compose.ui.text.font.FontWeight.Bold, fontSize = 14.sp, color = WHITE)
                                    Text(p.packageName, fontSize = 11.sp, color = GREY, maxLines = 1, overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis)
                                }
                                if (p == selectedProject)
                                    Icon(Icons.Default.CheckCircle, null, tint = ACCENT, modifier = Modifier.size(18.dp))
                            }
                            
                            var showMenu by remember { mutableStateOf(false) }
                            var showRenameDialog by remember { mutableStateOf(false) }

                            if (showRenameDialog) {
                                var newName by remember { mutableStateOf("${p.name}-klon") }
                                AlertDialog(
                                    onDismissRequest = { showRenameDialog = false },
                                    containerColor = CARD, shape = RoundedCornerShape(16.dp),
                                    title = { Text("Projeyi Klonla", color = WHITE, fontWeight = androidx.compose.ui.text.font.FontWeight.Bold) },
                                    text = {
                                        Column {
                                            Text("Proje kopyalanacak, yeni Keystore üretilecek ve listeye eklenecek.", color = GREY, fontSize = 11.sp)
                                            Spacer(Modifier.height(10.dp))
                                            OutlinedTextField(value = newName, onValueChange = { newName = it },
                                                label = { Text("Klonun yeni adı", color = GREY) }, singleLine = true,
                                                colors = OutlinedTextFieldDefaults.colors(focusedBorderColor = ACCENT, unfocusedBorderColor = BORDER,
                                                    focusedTextColor = WHITE, unfocusedTextColor = WHITE, cursorColor = ACCENT,
                                                    focusedContainerColor = CARD, unfocusedContainerColor = CARD))
                                        }
                                    },
                                    confirmButton = { 
                                        TextButton(onClick = { 
                                            if (newName.isNotBlank() && newName != p.name) {
                                                showRenameDialog = false
                                                scope.launch {
                                                    WsManager.cloneProject(p.name, newName)
                                                    kotlinx.coroutines.delay(2000) // Klonlama ve Keystore üretimi biraz sürebilir
                                                    WsManager.listProjects()
                                                }
                                            }
                                        }) { Text("Klonla", color = ACCENT) } 
                                    },
                                    dismissButton = { TextButton(onClick = { showRenameDialog = false }) { Text("İptal", color = GREY) } }
                                )
                            }

                            

                            Spacer(Modifier.height(10.dp))
                            Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                                ActionChip(Icons.Default.SmartToy, "AutoFix", ACCENT) { onAutofix(p) }
                                                                var showBackupMenu by remember { mutableStateOf(false) }
                                var pendingBackupType by remember { mutableStateOf<String?>(null) }

                                if (pendingBackupType != null) {
                                    var noteText by remember { mutableStateOf("") }
                                    AlertDialog(
                                        onDismissRequest = { pendingBackupType = null },
                                        containerColor = CARD, shape = RoundedCornerShape(16.dp),
                                        title = { Text("Yedek Notu", color = WHITE, fontWeight = androidx.compose.ui.text.font.FontWeight.Bold) },
                                        text = {
                                            Column {
                                                Text("Yedeğin adında görünecek kısa bir not yazın.", color = GREY, fontSize = 12.sp)
                                                Spacer(Modifier.height(8.dp))
                                                OutlinedTextField(
                                                    value = noteText, onValueChange = { noteText = it },
                                                    placeholder = { Text("örn: admob-eklendi", color = GREY) },
                                                    singleLine = true, modifier = Modifier.fillMaxWidth(),
                                                    shape = RoundedCornerShape(10.dp),
                                                    colors = OutlinedTextFieldDefaults.colors(
                                                        focusedBorderColor = ACCENT, unfocusedBorderColor = BORDER,
                                                        focusedTextColor = WHITE, unfocusedTextColor = WHITE, cursorColor = ACCENT,
                                                        focusedContainerColor = SURFACE, unfocusedContainerColor = SURFACE
                                                    )
                                                )
                                            }
                                        },
                                        confirmButton = {
                                            Button(onClick = {
                                                val finalNote = if (noteText.isBlank()) "yedek" else noteText.replace(" ", "-")
                                                onBackup(p, pendingBackupType!!, finalNote)
                                                pendingBackupType = null
                                            }, colors = ButtonDefaults.buttonColors(containerColor = GREEN)) { Text("Yedekle") }
                                        },
                                        dismissButton = { TextButton(onClick = { pendingBackupType = null }) { Text("İptal", color = GREY) } }
                                    )
                                }

                                Box {
                                    ActionChip(Icons.Default.Save, "Yedekle", GREEN) { showBackupMenu = true }
                                    DropdownMenu(expanded = showBackupMenu, onDismissRequest = { showBackupMenu = false }, modifier = Modifier.background(CARD)) {
                                        DropdownMenuItem(text = { Text("⚡ Hızlı Yedek", color = WHITE, fontSize = 13.sp) }, onClick = { showBackupMenu = false; pendingBackupType = "quick" })
                                        DropdownMenuItem(text = { Text("💾 Normal Yedek", color = WHITE, fontSize = 13.sp) }, onClick = { showBackupMenu = false; pendingBackupType = "normal" })
                                        DropdownMenuItem(text = { Text("📦 Tam Yedek (Gradle dahil)", color = WHITE, fontSize = 13.sp) }, onClick = { showBackupMenu = false; pendingBackupType = "full" })
                                    }
                                }

                                ActionChip(Icons.Default.PlayArrow,"Seç", GREY) { onSelect(p) }
                                Spacer(Modifier.weight(1f))
                                Box {
                                    IconButton(onClick = { showMenu = true }, modifier = Modifier.size(32.dp)) {
                                        Icon(Icons.Default.MoreVert, null, tint = GREY, modifier = Modifier.size(18.dp))
                                    }
                                    DropdownMenu(expanded = showMenu, onDismissRequest = { showMenu = false }, modifier = Modifier.background(CARD)) {
                                        DropdownMenuItem(text = { Text("🐑 Klonla (Çoğalt)", color = WHITE, fontSize = 13.sp) }, onClick = { showMenu = false; showRenameDialog = true })
                                        DropdownMenuItem(text = { Text("🖼 Logo Değiştir", color = WHITE, fontSize = 13.sp) }, onClick = { showMenu = false; targetLogoProject = p; logoStatus = "" })
                                        DropdownMenuItem(text = { Text("💰 AdMob Ekle", color = WHITE, fontSize = 13.sp) }, onClick = { showMenu = false; admobTargetProject = p })
                                        DropdownMenuItem(text = { Text("🗑 Sil", color = RED, fontSize = 13.sp) }, onClick = { showMenu = false; deleteConfirm = p })
                                    }
                                }
                            }
                        }
                    }
                }
                item { Spacer(Modifier.height(80.dp)) }
            }
        }
    }

    // --- DIŞ DİALOGLAR BÖLÜMÜ (Tıklanan projeye göre açılır) ---

    // Logo Değiştir Dialog'u
    targetLogoProject?.let { p ->
        AlertDialog(
            onDismissRequest = { if (!logoStatus.startsWith("⏳")) { targetLogoProject = null; logoStatus = "" } },
            containerColor = CARD, shape = RoundedCornerShape(16.dp),
            title = { Text("Logo Değiştir", color = WHITE, fontWeight = androidx.compose.ui.text.font.FontWeight.Bold) },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    Text("PNG veya JPG seçin. Otomatik olarak sıkıştırılıp ayarlanacaktır.", color = GREY, fontSize = 13.sp)
                    if (logoStatus.isNotEmpty()) Text(logoStatus, color = if (logoStatus.startsWith("❌")) RED else if (logoStatus.startsWith("✅")) GREEN else ACCENT, fontSize = 12.sp)
                    
                    // Pillow kurulu değilse uyarı kartı
                    Card(modifier = Modifier.fillMaxWidth(),
                        colors = CardDefaults.cardColors(containerColor = ORANGE.copy(alpha = 0.08f)),
                        border = BorderStroke(1.dp, ORANGE.copy(alpha = 0.3f)),
                        shape = RoundedCornerShape(10.dp)) {
                        Column(modifier = Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                            Text("⚠️ Termux'ta Pillow kurulu değilse çalışmaz", color = ORANGE, fontSize = 12.sp)
                            val clipMgr = androidx.compose.ui.platform.LocalClipboardManager.current
                            val pillowCmd = "pip install Pillow"
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                Text(pillowCmd, color = GREEN, fontSize = 11.sp, fontFamily = androidx.compose.ui.text.font.FontFamily.Monospace, modifier = Modifier.weight(1f))
                                IconButton(onClick = { clipMgr.setText(androidx.compose.ui.text.AnnotatedString(pillowCmd)) }, modifier = Modifier.size(24.dp)) {
                                    Icon(Icons.Default.ContentCopy, null, tint = GREY, modifier = Modifier.size(12.dp))
                                }
                            }
                            Surface(onClick = {
                                val i = android.content.Intent(android.content.Intent.ACTION_MAIN).apply { setClassName("com.termux","com.termux.app.TermuxActivity"); addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK) }
                                try { context.startActivity(i) } catch (e: Exception) {}
                            }, shape = RoundedCornerShape(8.dp), color = CARD, border = BorderStroke(1.dp, BORDER)) {
                                Row(modifier = Modifier.padding(horizontal = 10.dp, vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
                                    Text(">_", color = GREEN, fontSize = 11.sp, fontWeight = androidx.compose.ui.text.font.FontWeight.Bold)
                                    Spacer(Modifier.width(6.dp))
                                    Text("Termux'u Aç", color = WHITE, fontSize = 11.sp)
                                }
                            }
                        }
                    }
                    Button(onClick = { logoLauncher.launch("image/*") },
                        modifier = Modifier.fillMaxWidth(), shape = RoundedCornerShape(10.dp),
                        colors = ButtonDefaults.buttonColors(containerColor = ACCENT),
                        enabled = !logoStatus.startsWith("⏳") // Yüklenirken butonu dondur
                    ) { Text("Galeriden Seç") }
                }
            },
            confirmButton = {},
            dismissButton = { 
                TextButton(onClick = { targetLogoProject = null; logoStatus = "" }, enabled = !logoStatus.startsWith("⏳")) { 
                    Text("Kapat", color = GREY) 
                } 
            }
        )
    }

    // Silme onay dialog'u


    // AdMob Dialog
    admobTargetProject?.let { p ->
        var appId by remember { mutableStateOf("") }
        var unitId by remember { mutableStateOf("") }
        val testAppId = "ca-app-pub-3940256099942544~3347511713"
        val testUnitId = "ca-app-pub-3940256099942544/1033173712"
        AlertDialog(
            onDismissRequest = { admobTargetProject = null },
            containerColor = CARD, shape = RoundedCornerShape(16.dp),
            title = { Text("💰 AdMob Interstitial Ekle", color = WHITE, fontWeight = FontWeight.Bold) },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    Text("Boş bırakırsan test ID'leri kullanılır.", color = GREY, fontSize = 11.sp)
                    OutlinedTextField(value = appId, onValueChange = { appId = it },
                        label = { Text("App ID  (ca-app-pub-XXX~XXX)", fontSize = 11.sp) },
                        placeholder = { Text(testAppId, fontSize = 10.sp, color = GREY) },
                        singleLine = true, modifier = Modifier.fillMaxWidth(),
                        shape = RoundedCornerShape(8.dp),
                        colors = OutlinedTextFieldDefaults.colors(focusedBorderColor = ACCENT,
                            unfocusedBorderColor = BORDER, focusedTextColor = WHITE,
                            unfocusedTextColor = WHITE, focusedContainerColor = SURFACE,
                            unfocusedContainerColor = SURFACE))
                    OutlinedTextField(value = unitId, onValueChange = { unitId = it },
                        label = { Text("Interstitial Unit ID  (ca-app-pub-XXX/XXX)", fontSize = 11.sp) },
                        placeholder = { Text(testUnitId, fontSize = 10.sp, color = GREY) },
                        singleLine = true, modifier = Modifier.fillMaxWidth(),
                        shape = RoundedCornerShape(8.dp),
                        colors = OutlinedTextFieldDefaults.colors(focusedBorderColor = ACCENT,
                            unfocusedBorderColor = BORDER, focusedTextColor = WHITE,
                            unfocusedTextColor = WHITE, focusedContainerColor = SURFACE,
                            unfocusedContainerColor = SURFACE))
                }
            },
            confirmButton = {
                Button(onClick = {
                    val finalAppId = appId.ifBlank { testAppId }
                    val finalUnitId = unitId.ifBlank { testUnitId }
                    WsManager.addAdmob(p.name, finalAppId, finalUnitId)
                    admobTargetProject = null
                }, colors = ButtonDefaults.buttonColors(containerColor = ACCENT),
                    shape = RoundedCornerShape(10.dp)) { Text("Ekle") }
            },
            dismissButton = { TextButton(onClick = { admobTargetProject = null }) { Text("İptal", color = GREY) } }
        )
    }

    deleteConfirm?.let { p ->
        var confirmText by remember { mutableStateOf("") }
        AlertDialog(
            onDismissRequest = { deleteConfirm = null; confirmText = "" },
            containerColor = CARD, shape = RoundedCornerShape(16.dp),
            title = { Text("Projeyi Sil", color = WHITE, fontWeight = androidx.compose.ui.text.font.FontWeight.Bold) },
            text  = {
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    Text("Bu işlem geri alınamaz!", color = RED, fontSize = 12.sp, fontWeight = androidx.compose.ui.text.font.FontWeight.Bold)
                    Text("Onaylamak için proje adını yaz:", color = GREY, fontSize = 12.sp)
                    Text(p.name, color = ACCENT, fontSize = 13.sp, fontWeight = androidx.compose.ui.text.font.FontWeight.Bold)
                    OutlinedTextField(
                        value = confirmText, onValueChange = { confirmText = it },
                        placeholder = { Text(p.name, color = GREY) },
                        singleLine = true, modifier = Modifier.fillMaxWidth(),
                        shape = RoundedCornerShape(10.dp),
                        colors = OutlinedTextFieldDefaults.colors(
                            focusedBorderColor = if (confirmText == p.name) RED else BORDER,
                            unfocusedBorderColor = BORDER,
                            focusedTextColor = WHITE, unfocusedTextColor = WHITE,
                            cursorColor = RED, focusedContainerColor = SURFACE,
                            unfocusedContainerColor = SURFACE))
                }
            },
            confirmButton = {
                Button(
                    onClick = { onDelete(p); deleteConfirm = null; confirmText = "" },
                    enabled = confirmText == p.name,
                    colors = ButtonDefaults.buttonColors(
                        containerColor = RED, disabledContainerColor = RED.copy(alpha = 0.3f)),
                    shape = RoundedCornerShape(10.dp)) {
                    Text("Sil")
                }
            },
            dismissButton = { TextButton(onClick = { deleteConfirm = null; confirmText = "" }) { Text("İptal", color = GREY) } }
        )
    }
}


// ── AutoFix Tab ─────────────────────────────────────────────────────────────
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun AutoFixTab(
    logs: List<String>, runMode: RunMode, promptType: PromptType,
    selectedProject: ProjectInfo?, newApkPath: String,
    chainTask: String = "", onDeleteChainTask: () -> Unit = {},
    onAutofix: (ProjectInfo) -> Unit,
    onTask: (ProjectInfo, String) -> Unit,
    onBuildDebug: (ProjectInfo) -> Unit,
    onBuildRelease: (ProjectInfo) -> Unit,
    onStop: () -> Unit,
    onContinue: () -> Unit,
    onRestoreAndStop: () -> Unit,
    onApplyChanges: () -> Unit,
    onRejectChanges: () -> Unit,
    onSetAutoMode: (Boolean) -> Unit,
    autoMode: Boolean,
    promptErrorMsg: String,
    onKeepChanges: () -> Unit,
    onClearLogs: () -> Unit,
    onGoToApks: () -> Unit
) {
    val scrollState = rememberScrollState()
    val clipboard   = LocalClipboardManager.current
    var task        by remember { mutableStateOf("") }
    var copyToast   by remember { mutableStateOf("") }
    var showBuildMenu by remember { mutableStateOf(false) }
    val ctx = LocalContext.current
    var showTermuxPermissionError by remember { mutableStateOf(false) }
        
    LaunchedEffect(logs.size) { scrollState.animateScrollTo(scrollState.maxValue) }
    LaunchedEffect(copyToast) { if (copyToast.isNotEmpty()) { delay(1800); copyToast = "" } }

    Column(modifier = Modifier.fillMaxSize()) {

        // ── Header ───────────────────────────────────────────────────────────
        Row(modifier = Modifier.fillMaxWidth().background(SURFACE)
            .padding(horizontal = 12.dp, vertical = 9.dp),
            verticalAlignment = Alignment.CenterVertically) {
            Column(modifier = Modifier.weight(1f)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text("AutoFix", fontWeight = FontWeight.Bold, fontSize = 16.sp, color = WHITE)
                    if (runMode != RunMode.IDLE) {
                        Spacer(Modifier.width(8.dp))
                        CircularProgressIndicator(modifier = Modifier.size(13.dp), color = ACCENT, strokeWidth = 2.dp)
                        Spacer(Modifier.width(5.dp))
                        Text(if (runMode == RunMode.BUILDING) "Build..." else "AI...",
                            color = ACCENT, fontSize = 11.sp)
                    }
                }
                Text(selectedProject?.name ?: "← Projeler'den proje seç", fontSize = 10.sp, color = GREY)
            }
            if (logs.isNotEmpty() && runMode == RunMode.IDLE) {
                IconButton(onClick = { clipboard.setText(AnnotatedString(logs.joinToString("\n"))); copyToast = "Kopyalandı" },
                    modifier = Modifier.size(36.dp)) {
                    Icon(Icons.Default.ContentCopy, null, tint = GREY, modifier = Modifier.size(17.dp))
                }
                IconButton(onClick = onClearLogs, modifier = Modifier.size(36.dp)) {
                    Icon(Icons.Default.Delete, null, tint = GREY, modifier = Modifier.size(17.dp))
                }
            }
        }

        // ── APK hazır ─────────────────────────────────────────────────────────
        if (newApkPath.isNotEmpty() && runMode == RunMode.IDLE) {
            Row(modifier = Modifier.fillMaxWidth().background(GREEN.copy(alpha = 0.1f))
                .clickable { onGoToApks() }.padding(horizontal = 14.dp, vertical = 7.dp),
                verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.Default.Android, null, tint = GREEN, modifier = Modifier.size(15.dp))
                Spacer(Modifier.width(8.dp))
                Text("APK hazır — APKlar'a git →", color = GREEN, fontSize = 12.sp, modifier = Modifier.weight(1f))
                Icon(Icons.Default.ArrowForward, null, tint = GREEN, modifier = Modifier.size(13.dp))
            }
        }

        // ── Bekleyen görev kartı ──────────────────────────────────────────
        if (runMode == RunMode.IDLE && selectedProject != null && chainTask.isNotEmpty()) {
            var showChainEdit by remember { mutableStateOf(false) }
            var editedChainTask by remember(chainTask) { mutableStateOf(chainTask) }

            if (showChainEdit) {
                AlertDialog(
                    onDismissRequest = { showChainEdit = false },
                    containerColor = CARD, shape = RoundedCornerShape(16.dp),
                    title = { Text("📬 Görevi Düzenle", color = WHITE, fontWeight = FontWeight.Bold, fontSize = 15.sp) },
                    text = {
                        OutlinedTextField(
                            value = editedChainTask, onValueChange = { editedChainTask = it },
                            modifier = Modifier.fillMaxWidth(),
                            shape = RoundedCornerShape(8.dp), minLines = 8,
                            colors = OutlinedTextFieldDefaults.colors(
                                focusedBorderColor = ACCENT, unfocusedBorderColor = BORDER,
                                focusedTextColor = WHITE, unfocusedTextColor = WHITE,
                                focusedContainerColor = SURFACE, unfocusedContainerColor = SURFACE),
                            textStyle = androidx.compose.ui.text.TextStyle(fontSize = 12.sp)
                        )
                    },
                    confirmButton = {
                        Button(onClick = { showChainEdit = false },
                            colors = ButtonDefaults.buttonColors(containerColor = ACCENT)) {
                            Text("Kaydet")
                        }
                    },
                    dismissButton = { TextButton(onClick = { showChainEdit = false }) { Text("İptal", color = GREY) } }
                )
            }

            Card(modifier = Modifier.fillMaxWidth().padding(horizontal = 10.dp, vertical = 6.dp),
                colors = CardDefaults.cardColors(containerColor = ACCENT.copy(alpha = 0.1f)),
                border = BorderStroke(1.dp, ACCENT.copy(alpha = 0.4f))) {
                Column(modifier = Modifier.padding(10.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text("📬 Bekleyen Görev", color = ACCENT, fontWeight = FontWeight.Bold, fontSize = 12.sp)
                        Spacer(Modifier.weight(1f))
                        IconButton(onClick = { showChainEdit = true }, modifier = Modifier.size(28.dp)) {
                            Icon(Icons.Default.Edit, null, tint = ACCENT, modifier = Modifier.size(16.dp))
                        }
                        IconButton(onClick = { onDeleteChainTask() }, modifier = Modifier.size(28.dp)) {
                            Icon(Icons.Default.Delete, null, tint = RED, modifier = Modifier.size(16.dp))
                        }
                    }
                    Spacer(Modifier.height(4.dp))
                    Text(editedChainTask, color = GREY, fontSize = 11.sp, maxLines = 3,
                        overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis)
                    Spacer(Modifier.height(8.dp))
                    Button(onClick = { onTask(selectedProject, editedChainTask); onDeleteChainTask() },
                        modifier = Modifier.fillMaxWidth(), shape = RoundedCornerShape(8.dp),
                        colors = ButtonDefaults.buttonColors(containerColor = ACCENT)) {
                        Text("▶ Devam Et", color = WHITE, fontSize = 13.sp)
                    }
                }
            }
        }

                // ── Görev satırı (idle + proje seçili) ─────────────────────────────
        if (runMode == RunMode.IDLE && selectedProject != null) {
            Column(modifier = Modifier.background(SURFACE.copy(alpha = 0.4f))
                .padding(horizontal = 10.dp, vertical = 8.dp)) {

                // Textbox + butonlar
                Row(verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(7.dp)) {
                    OutlinedTextField(
                        value = task, onValueChange = { task = it },
                        placeholder = { Text("Görev yaz... (boş bırakırsan otodüzelt)", fontSize = 11.sp) },
                        modifier = Modifier.weight(1f),
                        shape = RoundedCornerShape(12.dp), singleLine = true,
                        colors = OutlinedTextFieldDefaults.colors(
                            focusedBorderColor = ACCENT, unfocusedBorderColor = BORDER,
                            focusedTextColor = WHITE, unfocusedTextColor = WHITE, cursorColor = ACCENT,
                            focusedContainerColor = CARD, unfocusedContainerColor = CARD),
                        textStyle = androidx.compose.ui.text.TextStyle(fontSize = 12.sp)
                    )
                    // 🤖 AI butonu
                    // Boş → prj af | Dolu → prj e "task"
                    Button(
                        onClick = {
                            if (task.isBlank()) onAutofix(selectedProject)
                            else onTask(selectedProject, task)
                        },
                        shape = RoundedCornerShape(10.dp),
                        colors = ButtonDefaults.buttonColors(containerColor = ACCENT),
                        contentPadding = PaddingValues(horizontal = 10.dp, vertical = 10.dp)
                    ) {
                        Icon(Icons.Default.SmartToy, null, modifier = Modifier.size(16.dp))
                        Spacer(Modifier.width(4.dp))
                        Text("AI", fontWeight = FontWeight.Bold, fontSize = 12.sp)
                    }
                    // 🔨 Build butonu → menü açar
                    Box {
                        Button(
                            onClick = { showBuildMenu = true },
                            shape = RoundedCornerShape(10.dp),
                            colors = ButtonDefaults.buttonColors(containerColor = GREEN),
                            contentPadding = PaddingValues(horizontal = 10.dp, vertical = 10.dp)
                        ) {
                            Icon(Icons.Default.PlayArrow, null, modifier = Modifier.size(16.dp))
                            Spacer(Modifier.width(4.dp))
                            Text("Build", fontWeight = FontWeight.Bold, fontSize = 12.sp)
                        }
                        DropdownMenu(
                            expanded = showBuildMenu,
                            onDismissRequest = { showBuildMenu = false },
                            modifier = Modifier.background(CARD)
                        ) {
                            DropdownMenuItem(
                                text = {
                                    Row(verticalAlignment = Alignment.CenterVertically) {
                                        Icon(Icons.Default.BugReport, null, tint = GREEN, modifier = Modifier.size(16.dp))
                                        Spacer(Modifier.width(8.dp))
                                        Column {
                                            Text("prj d — Debug APK", color = WHITE, fontSize = 13.sp, fontWeight = FontWeight.Medium)
                                            Text("Build + Download'a taşı", color = GREY, fontSize = 10.sp)
                                        }
                                    }
                                },
                                onClick = { showBuildMenu = false; onBuildDebug(selectedProject) }
                            )
                            Divider(color = BORDER, thickness = 0.5.dp)
                            DropdownMenuItem(
                                text = {
                                    Row(verticalAlignment = Alignment.CenterVertically) {
                                        Icon(Icons.Default.RocketLaunch, null, tint = PURPLE, modifier = Modifier.size(16.dp))
                                        Spacer(Modifier.width(8.dp))
                                        Column {
                                            Text("prj b — Release AAB", color = WHITE, fontSize = 13.sp, fontWeight = FontWeight.Medium)
                                            Text("AAB build + imzala", color = GREY, fontSize = 10.sp)
                                        }
                                    }
                                },
                                onClick = { showBuildMenu = false; onBuildRelease(selectedProject) }
                            )
                        }
                    }
                }

                // Kısa açıklama
                Text(
                    if (task.isBlank()) "AI: boş → prj af (build+otodüzelt)  |  Yazarsan → prj e \"görev\""
                    else "→ prj e \"$task\"",
                    fontSize = 9.sp, color = GREY.copy(alpha = 0.7f),
                    modifier = Modifier.padding(top = 3.dp),
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis
                )
            }
        }








            // ── Log alanı (Üst Bar - ARTIK HER ZAMAN GÖRÜNÜR) ───────────────────
        Row(
            modifier = Modifier.fillMaxWidth().background(Color(0xFF0A0A0F))
                .padding(horizontal = 8.dp, vertical = 3.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.SpaceBetween // Sol ve Sağ olarak ikiye böler
        ) {
            val ctx = LocalContext.current

            // 1. SOL TARAF: Panik Butonu (Log olsa da olmasa da HER ZAMAN görünür)
            TextButton(
                onClick = {
                    val success = com.wizaicorp.apkfactory.data.TermuxBridge.sendToTermux(ctx, "bash /data/data/com.termux/files/home/restart_bridge.sh")
                    if (!success) {
                        showTermuxPermissionError = true
                    } else {
                        android.widget.Toast.makeText(ctx, "🔄 Termux motoru zorla yenileniyor...", android.widget.Toast.LENGTH_SHORT).show()
                        kotlinx.coroutines.GlobalScope.launch {
                            kotlinx.coroutines.delay(2000)
                            com.wizaicorp.apkfactory.data.WsManager.connect()
                        }
                    }
                },
                contentPadding = PaddingValues(horizontal = 8.dp, vertical = 2.dp)
            ) {
                androidx.compose.material3.Icon(
                    androidx.compose.material.icons.Icons.Default.Refresh, 
                    contentDescription = null, 
                    tint = ORANGE, 
                    modifier = Modifier.size(12.dp)
                )
                Spacer(Modifier.width(3.dp))
                Text("Motoru Başlat", color = ORANGE, fontSize = 10.sp)
            }

            // 2. SAĞ TARAF: İndirme Butonları (SADECE LOG VARSA görünür)
            if (logs.isNotEmpty()) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    TextButton(
                        onClick = {
                            try {
                                val source = java.io.File("/sdcard/Download/last_ai_response.txt")
                                if (source.exists()) {
                                    val ts = java.text.SimpleDateFormat("yyyyMMdd-HHmm", java.util.Locale.getDefault()).format(java.util.Date())
                                    val dest = java.io.File("/sdcard/Download/ai-raw-log-$ts.json")
                                    source.copyTo(dest, overwrite = true)
                                    android.widget.Toast.makeText(ctx, "🤖 AI Logu kopyalandı: ${dest.name}", android.widget.Toast.LENGTH_LONG).show()
                                } else {
                                    android.widget.Toast.makeText(ctx, "❌ AI logu bulunamadı.", android.widget.Toast.LENGTH_SHORT).show()
                                }
                            } catch (e: Exception) {
                                android.widget.Toast.makeText(ctx, "Hata: ${e.message}", android.widget.Toast.LENGTH_SHORT).show()
                            }
                        },
                        contentPadding = PaddingValues(horizontal = 8.dp, vertical = 2.dp)
                    ) {
                        Icon(Icons.Default.BugReport, null, tint = PURPLE, modifier = Modifier.size(12.dp))
                        Spacer(Modifier.width(3.dp))
                        Text("AI Yanıtını İndir", color = PURPLE, fontSize = 10.sp)
                    }

                    Spacer(Modifier.width(8.dp))

                    TextButton(
                        onClick = {
                            try {
                                val ts = java.text.SimpleDateFormat("yyyyMMdd-HHmm", java.util.Locale.getDefault()).format(java.util.Date())
                                val file = java.io.File("/sdcard/Download/apkfactory-log-$ts.txt")
                                val onYazi = buildString {
                                    appendLine("═══════════════════════════════════════════")
                                    appendLine("📱 APK FACTORY — LOG RAPORU")
                                    appendLine("═══════════════════════════════════════════")
                                    appendLine("📅 Tarih    : $ts")
                                    appendLine("📦 Proje    : ${selectedProject?.name ?: "-"}")
                                    appendLine("🤖 Sistem   : APK Factory v11 (Termux + WebSocket)")
                                    appendLine("───────────────────────────────────────────")
                                    appendLine("🛠  ENVIRONMENT:")
                                    appendLine("  • Bridge   : python ~/apk-factory-ws/ws_bridge.py")
                                    appendLine("  • Restart  : pkill -f ws_bridge.py && python ~/apk-factory-ws/ws_bridge.py")
                                    appendLine("  • Build    : cd ~/PROJECT && prj d")
                                    appendLine("  * Task     : cd ~/PROJECT && prj e TASK")
                                    appendLine("  • AutoFix  : cd ~/PROJECT && prj af")
                                    appendLine("───────────────────────────────────────────")
                                    appendLine("📋 LOG START:")
                                    appendLine("═══════════════════════════════════════════")
                                    appendLine()
                                }
                                file.writeText(onYazi + logs.joinToString("\n"))
                                android.widget.Toast.makeText(ctx, "📄 Log kaydedildi: ${file.name}", android.widget.Toast.LENGTH_LONG).show()
                            } catch (e: Exception) {
                                android.widget.Toast.makeText(ctx, "❌ ${e.message}", android.widget.Toast.LENGTH_SHORT).show()
                            }
                        },
                        contentPadding = PaddingValues(horizontal = 8.dp, vertical = 2.dp)
                    ) {
                        Icon(Icons.Default.Download, null, tint = GREY, modifier = Modifier.size(12.dp))
                        Spacer(Modifier.width(3.dp))
                        Text("Logu İndir", color = GREY, fontSize = 10.sp)
                    }
                }
            }
        }
        // ─────────────────────────────────────────────────────────────────────






        Box(modifier = Modifier.weight(1f).background(Color(0xFF060608))) {
            Column(modifier = Modifier.fillMaxSize().padding(10.dp).verticalScroll(scrollState)) {
                if (logs.isEmpty())
                    Text("🤖 AI butonu:\n  • Boş → prj af (build + AI otodüzelt)\n  • Görev yazıp bas → prj e \"görev\"\n\n🔨 Build → Debug APK veya Release AAB\n\nSatıra uzun bas → kopyala",
                        color = GREY, fontSize = 12.sp, fontFamily = FontFamily.Monospace, lineHeight = 20.sp)
                logs.forEach { line ->
                    val color = when {
                        line.contains("✅") || line.contains("BUILD SUCCESSFUL") || line.contains("BAŞARILI") -> GREEN
                        line.contains("❌") || line.contains("BUILD FAILED") || line.contains("error:")      -> RED
                        line.contains("⚠️") || line.contains("warning:")                                     -> Color(0xFFFFD700)
                        line.contains("🤖") || line.startsWith("→") || line.contains("🔨") || line.contains("✨") -> ACCENT
                        line.contains("💾") || line.contains("↩")                                            -> ORANGE
                        line.contains("⏱")                                                                   -> GREY
                        else -> Color(0xFF8AE1A0)
                    }
                    Text(line, fontSize = 11.sp, color = color, fontFamily = FontFamily.Monospace,
                        lineHeight = 17.sp, modifier = Modifier.fillMaxWidth()
                            .combinedClickable(onClick = {}, onLongClick = {
                                clipboard.setText(AnnotatedString(line)); copyToast = "Kopyalandı"
                            }).padding(vertical = 1.dp))
                }
            }
            if (copyToast.isNotEmpty()) {
                Box(modifier = Modifier.align(Alignment.BottomCenter).padding(bottom = 4.dp)) {
                    Card(colors = CardDefaults.cardColors(containerColor = CARD),
                        border = BorderStroke(1.dp, BORDER), shape = RoundedCornerShape(20.dp)) {
                        Text(copyToast, modifier = Modifier.padding(horizontal = 14.dp, vertical = 6.dp),
                            color = WHITE, fontSize = 11.sp)
                    }
                }
            }
        }

        // ── Alt buton alanı ──────────────────────────────────────────────────
        // Çalışırken: Durdur
        AnimatedVisibility(visible = (runMode != RunMode.IDLE && promptType == PromptType.NONE) || autoMode) {
            Row(modifier = Modifier.fillMaxWidth().background(SURFACE)
                .padding(horizontal = 12.dp, vertical = 8.dp)) {
                Button(onClick = onStop, modifier = Modifier.fillMaxWidth(),
                    shape = RoundedCornerShape(10.dp),
                    colors = ButtonDefaults.buttonColors(containerColor = RED)) {
                    Icon(Icons.Default.Stop, null, modifier = Modifier.size(16.dp))
                    Spacer(Modifier.width(6.dp))
                    Text("⏹ Durdur", fontWeight = FontWeight.Bold)
                }
            }
        }

        // Prompt kartı (karar anında)
        AnimatedVisibility(visible = promptType != PromptType.NONE) {
            Column(modifier = Modifier.fillMaxWidth().background(SURFACE)) {
                when (promptType) {
                    PromptType.BUILD_SUCCESS -> PromptCard(
                        icon = "✅", title = "Build başarılı!",
                        errorMsg = promptErrorMsg,
                        subtitle = "Ne yapayım?",
                        leftLabel = "↩ Yedeğe Dön", leftColor = ORANGE,
                        rightLabel = "✅ Kalıcı Yap", rightColor = GREEN,
                        onLeft = onRestoreAndStop, onRight = onContinue,
                        showAutoBtn = false   // Kullanıcı kararı
                    )
                    PromptType.BUILD_FAILED -> PromptCard(
                        icon = "❌", title = "Build başarısız — deneme kaldı",
                        errorMsg = promptErrorMsg,
                        subtitle = "AI tekrar denesin mi?",
                        leftLabel = "↩ Yedeğe Dön", leftColor = RED,
                        rightLabel = "→ Devam Et", rightColor = ACCENT,
                        onLeft = onRestoreAndStop, onRight = onContinue,
                        showAutoBtn = true,
                        autoMode = autoMode,
                        onSetAutoMode = onSetAutoMode
                    )
                    PromptType.APPLY_CHANGES -> PromptCard(
                        icon = "🤖", title = "AI değişiklik hazırladı",
                        errorMsg = promptErrorMsg,
                        subtitle = "Uygulayıp derleyelim mi?",
                        leftLabel = "✗ İptal", leftColor = GREY,
                        rightLabel = "✓ Uygula & Derle", rightColor = ACCENT,
                        onLeft = onRejectChanges, onRight = onApplyChanges,
                        showAutoBtn = true,
                        autoMode = autoMode,
                        onSetAutoMode = onSetAutoMode
                    )
                    PromptType.STOPPED -> PromptCard(
                        icon = "⏹", title = "İşlem durduruldu",
                        subtitle = "Değişiklikler geri alınsın mı?",
                        errorMsg = "",
                        leftLabel = "✗ Değişiklikleri Koru", leftColor = GREY,
                        rightLabel = "↩ Yedeğe Dön", rightColor = ORANGE,
                        onLeft = onKeepChanges,
                        onRight = onRestoreAndStop,
                        showAutoBtn = false
                    )
                    PromptType.NONE -> {}
                }
            }
        }

        // Idle + log var → Yedekle + Temizle
        AnimatedVisibility(visible = runMode == RunMode.IDLE && logs.isNotEmpty() && promptType == PromptType.NONE) {
            Row(modifier = Modifier.fillMaxWidth().background(SURFACE)
                .padding(horizontal = 12.dp, vertical = 7.dp),
                horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                if (selectedProject != null) {
                    OutlinedButton(onClick = { WsManager.backup(selectedProject.name) },
                        modifier = Modifier.weight(1f), shape = RoundedCornerShape(10.dp),
                        border = BorderStroke(1.dp, ORANGE),
                        colors = ButtonDefaults.outlinedButtonColors(contentColor = ORANGE)) {
                        Icon(Icons.Default.Save, null, modifier = Modifier.size(14.dp))
                        Spacer(Modifier.width(4.dp))
                        Text("Yedekle", fontSize = 12.sp)
                    }
                }
                OutlinedButton(onClick = onClearLogs,
                    modifier = Modifier.weight(1f), shape = RoundedCornerShape(10.dp),
                    border = BorderStroke(1.dp, BORDER),
                    colors = ButtonDefaults.outlinedButtonColors(contentColor = GREY)) {
                    Icon(Icons.Default.ClearAll, null, modifier = Modifier.size(14.dp))
                    Spacer(Modifier.width(4.dp))
                    Text("Temizle", fontSize = 12.sp)
                }
            }
        }
    }
        // --- TERMUX İZİN HATA DİALOGU ---
        if (showTermuxPermissionError) {
            AlertDialog(
                onDismissRequest = { showTermuxPermissionError = false },
                containerColor = CARD, shape = RoundedCornerShape(16.dp),
                title = {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Icon(Icons.Default.Security, null, tint = RED, modifier = Modifier.size(24.dp))
                        Spacer(Modifier.width(8.dp))
                        Text("Kritik İzin Eksik", color = RED, fontWeight = FontWeight.Bold, fontSize = 18.sp)
                    }
                },
                text = {
                    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        Text("APK Factory'nin Termux motorunu başlatabilmesi için komut gönderme iznine ihtiyacı var.", color = WHITE, fontSize = 13.sp)
                        Card(colors = CardDefaults.cardColors(containerColor = SURFACE), border = BorderStroke(1.dp, BORDER)) {
                            Text("1. 'Ayarları Aç' butonuna tıklayın.\n2. İzinler (Permissions) bölümüne girin.\n3. 'Run commands in Termux environment' iznini verin.",
                                modifier = Modifier.padding(10.dp), color = GREY, fontSize = 12.sp, lineHeight = 18.sp)
                        }
                    }
                },
                confirmButton = {
                    Button(onClick = {
                        showTermuxPermissionError = false
                        val intent = android.content.Intent(
                            android.provider.Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                            android.net.Uri.parse("package:${ctx.packageName}")
                        ).addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK)
                        try { ctx.startActivity(intent) } catch(e: Exception) {}
                    }, colors = ButtonDefaults.buttonColors(containerColor = ACCENT)) {
                        Text("Ayarları Aç")
                    }
                },
                dismissButton = {
                    TextButton(onClick = { showTermuxPermissionError = false }) { Text("İptal", color = GREY) }
                }
            )
        }
}

// ── Prompt Karar Kartı ──────────────────────────────────────────────────────
@Composable
fun PromptCard(
    icon: String, title: String, subtitle: String,
    errorMsg: String = "",
    leftLabel: String, leftColor: Color,
    rightLabel: String, rightColor: Color,
    onLeft: () -> Unit, onRight: () -> Unit,
    showAutoBtn: Boolean = false,
    autoMode: Boolean = false,
    onSetAutoMode: ((Boolean) -> Unit)? = null
) {
    Card(modifier = Modifier.fillMaxWidth().padding(horizontal = 10.dp, vertical = 6.dp),
        colors = CardDefaults.cardColors(containerColor = Color(0xFF161820)),
        border = BorderStroke(1.dp, ACCENT.copy(alpha = 0.25f)), shape = RoundedCornerShape(14.dp)) {
        Column(modifier = Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(icon, fontSize = 18.sp)
                Spacer(Modifier.width(8.dp))
                Column(Modifier.weight(1f)) {
                    Text(title, fontWeight = FontWeight.Bold, fontSize = 13.sp, color = WHITE)
                    Text(subtitle, fontSize = 10.sp, color = GREY)
                }
            }
            if (errorMsg.isNotEmpty()) {
                Card(colors = CardDefaults.cardColors(containerColor = RED.copy(alpha = 0.08f)),
                    border = BorderStroke(1.dp, RED.copy(alpha = 0.3f)),
                    shape = RoundedCornerShape(8.dp)) {
                    Text(
                        text = errorMsg.take(120) + if (errorMsg.length > 120) "…" else "",
                        modifier = Modifier.padding(8.dp),
                        fontSize = 10.sp, color = RED.copy(alpha = 0.9f),
                        fontFamily = FontFamily.Monospace, lineHeight = 14.sp
                    )
                }
            }
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Button(onClick = onLeft, modifier = Modifier.weight(1f), shape = RoundedCornerShape(10.dp),
                    colors = ButtonDefaults.buttonColors(containerColor = leftColor.copy(alpha = 0.15f)),
                    border = BorderStroke(1.dp, leftColor.copy(alpha = 0.5f)),
                    contentPadding = PaddingValues(horizontal = 8.dp, vertical = 10.dp)) {
                    Text(leftLabel, color = leftColor, fontSize = 11.sp, fontWeight = FontWeight.Bold)
                }
                Button(onClick = onRight, modifier = Modifier.weight(1f), shape = RoundedCornerShape(10.dp),
                    colors = ButtonDefaults.buttonColors(containerColor = rightColor),
                    contentPadding = PaddingValues(horizontal = 8.dp, vertical = 10.dp)) {
                    Text(rightLabel, color = WHITE, fontSize = 11.sp, fontWeight = FontWeight.Bold)
                }
            }
            if (showAutoBtn && onSetAutoMode != null) {
                Row(modifier = Modifier.fillMaxWidth()
                    .clip(RoundedCornerShape(10.dp))
                    .background(if (autoMode) ACCENT.copy(alpha = 0.12f) else SURFACE)
                    .clickable { onSetAutoMode(!autoMode) }
                    .padding(horizontal = 10.dp, vertical = 8.dp),
                    verticalAlignment = Alignment.CenterVertically) {
                    Icon(
                        if (autoMode) Icons.Default.DoubleArrow else Icons.Default.PlayCircleOutline,
                        null, tint = if (autoMode) ACCENT else GREY,
                        modifier = Modifier.size(15.dp)
                    )
                    Spacer(Modifier.width(8.dp))
                    Column(Modifier.weight(1f)) {
                        Text(
                            if (autoMode) "⚡ Otomatik devam AÇIK" else "Otomatik devam",
                            color = if (autoMode) ACCENT else GREY,
                            fontSize = 11.sp, fontWeight = if (autoMode) FontWeight.Bold else FontWeight.Normal
                        )
                        if (!autoMode)
                            Text("Deneme hakkı bitene kadar sormadan devam et",
                                color = GREY.copy(alpha = 0.6f), fontSize = 9.sp)
                    }
                    Switch(
                        checked = autoMode, onCheckedChange = { onSetAutoMode(it) },
                        colors = SwitchDefaults.colors(
                            checkedThumbColor = WHITE, checkedTrackColor = ACCENT,
                            uncheckedThumbColor = GREY, uncheckedTrackColor = SURFACE)
                    )
                }
            }
        }
    }
}

// ── APKlar Tab ──────────────────────────────────────────────────────────────
@Composable
@OptIn(ExperimentalFoundationApi::class)
fun ApksTab(selectedProject: ProjectInfo?) {
    val context   = LocalContext.current
    val clipboard = LocalClipboardManager.current
    var apks  by remember { mutableStateOf(listOf<ApkInfo>()) }
    var toast by remember { mutableStateOf("") }
    LaunchedEffect(Unit) { WsManager.listApks() }
    LaunchedEffect(toast) { if (toast.isNotEmpty()) { delay(2000); toast = "" } }
    LaunchedEffect(Unit) {
        WsManager.events.collect { if (it is WsEvent.ApkList) apks = it.list }
    }

    var search by remember { mutableStateOf("") }
    val apkList = apks.filter { it.fileType == "apk" && (search.isBlank() || it.project.contains(search, ignoreCase = true)) }
    val aabList = apks.filter { it.fileType == "aab" && (search.isBlank() || it.project.contains(search, ignoreCase = true)) }

    Column(modifier = Modifier.fillMaxSize()) {
        Row(modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 10.dp),
            verticalAlignment = Alignment.CenterVertically) {
            Text("Çıktılar", fontWeight = FontWeight.Bold, fontSize = 20.sp, color = WHITE)
        }
        OutlinedTextField(
            value = search, onValueChange = { search = it },
            placeholder = { Text("Proje ara...", fontSize = 12.sp, color = GREY) },
            modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp).padding(bottom = 8.dp),
            shape = RoundedCornerShape(10.dp), singleLine = true,
            colors = OutlinedTextFieldDefaults.colors(
                focusedBorderColor = ACCENT, unfocusedBorderColor = BORDER,
                focusedTextColor = WHITE, unfocusedTextColor = WHITE, cursorColor = ACCENT,
                focusedContainerColor = CARD, unfocusedContainerColor = CARD),
            textStyle = androidx.compose.ui.text.TextStyle(fontSize = 12.sp),
            trailingIcon = { if (search.isNotEmpty()) IconButton(onClick = { search = "" }) { Icon(Icons.Default.Clear, null, tint = GREY, modifier = Modifier.size(16.dp)) } }
        )
        Row(modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp),
            verticalAlignment = Alignment.CenterVertically) {
            Text("", modifier = Modifier.weight(1f))
            IconButton(onClick = { WsManager.deleteAllApks(); WsManager.listApks() }) {
                Icon(Icons.Default.DeleteSweep, null, tint = RED.copy(alpha = 0.7f), modifier = Modifier.size(20.dp))
            }
            IconButton(onClick = { WsManager.listApks() }) {
                Icon(Icons.Default.Refresh, null, tint = GREY, modifier = Modifier.size(20.dp))
            }
        }
        if (apks.isEmpty()) {
            Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    Icon(Icons.Default.Unarchive, null, tint = GREY, modifier = Modifier.size(48.dp))
                    Spacer(Modifier.height(12.dp))
                    Text("Henüz çıktı yok", color = GREY, fontSize = 14.sp)
                    Text("Build sonrası APK/AAB buraya eklenir", color = GREY.copy(alpha = 0.6f), fontSize = 12.sp)
                }
            }
        } else {
            LazyColumn(contentPadding = PaddingValues(horizontal = 12.dp, vertical = 4.dp),
                verticalArrangement = Arrangement.spacedBy(6.dp)) {

                // APK Bölümü
                if (apkList.isNotEmpty()) {
                    item {
                        Row(modifier = Modifier.fillMaxWidth().padding(vertical = 6.dp),
                            verticalAlignment = Alignment.CenterVertically) {
                            Icon(Icons.Default.Android, null, tint = GREEN, modifier = Modifier.size(14.dp))
                            Spacer(Modifier.width(5.dp))
                            Text("APK — Debug", color = GREEN, fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
                            Spacer(Modifier.weight(1f))
                            Text("${apkList.size} dosya", color = GREY, fontSize = 10.sp)
                        }
                    }
                    items(apkList) { apk -> OutputFileCard(apk, GREEN, context, clipboard) }
                }

                // AAB Bölümü
                if (aabList.isNotEmpty()) {
                    item {
                        Row(modifier = Modifier.fillMaxWidth().padding(top = 10.dp, bottom = 6.dp),
                            verticalAlignment = Alignment.CenterVertically) {
                            Icon(Icons.Default.RocketLaunch, null, tint = PURPLE, modifier = Modifier.size(14.dp))
                            Spacer(Modifier.width(5.dp))
                            Text("AAB — Release", color = PURPLE, fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
                            Spacer(Modifier.weight(1f))
                            Text("${aabList.size} dosya", color = GREY, fontSize = 10.sp)
                        }
                    }
                    items(aabList) { apk -> OutputFileCard(apk, PURPLE, context, clipboard) }
                }

                item { Spacer(Modifier.height(80.dp)) }
            }
        }
    }

    if (toast.isNotEmpty()) {
        Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.BottomCenter) {
            Card(modifier = Modifier.padding(16.dp),
                colors = CardDefaults.cardColors(containerColor = CARD),
                border = BorderStroke(1.dp, BORDER), shape = RoundedCornerShape(20.dp)) {
                Text(toast, modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
                    color = WHITE, fontSize = 12.sp)
            }
        }
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
fun OutputFileCard(apk: ApkInfo, accentColor: Color, context: android.content.Context, clipboard: androidx.compose.ui.platform.ClipboardManager) {
    val isApk = apk.fileType == "apk"
    Card(
        modifier = Modifier.fillMaxWidth().combinedClickable(
            onClick = {
                if (isApk) {
                    installApk(context, apk.path)
                } else {
                    clipboard.setText(AnnotatedString(apk.path))
                }
            },
            onLongClick = { clipboard.setText(AnnotatedString(apk.path)) }
        ),
        colors = CardDefaults.cardColors(containerColor = CARD),
        border = BorderStroke(1.dp, BORDER), shape = RoundedCornerShape(12.dp)
    ) {
        Row(modifier = Modifier.padding(12.dp), verticalAlignment = Alignment.CenterVertically) {
            

            Box(modifier = Modifier.size(38.dp).background(accentColor.copy(alpha = 0.12f), RoundedCornerShape(9.dp))
                .clip(RoundedCornerShape(9.dp)),
                contentAlignment = Alignment.Center) {
                val fbIcon = if (isApk) Icons.Default.Android else Icons.Default.RocketLaunch
                ProjectLogo(projectName = apk.project, modifier = Modifier.fillMaxSize(), fallbackIcon = fbIcon, fallbackTint = accentColor)
            }




            Spacer(Modifier.width(10.dp))
            Column(modifier = Modifier.weight(1f)) {
                Text(apk.project, fontWeight = FontWeight.Bold, fontSize = 12.sp, color = WHITE, maxLines = 1,
                    overflow = TextOverflow.Ellipsis)
                Text(apk.date, fontSize = 10.sp, color = GREY)
                Text("${apk.size / 1024 / 1024} MB", fontSize = 10.sp, color = GREY.copy(alpha = 0.6f))
            }
            if (isApk) {
                // Yükle butonu
                Surface(onClick = {
                     installApk(context, apk.path)
                }, shape = RoundedCornerShape(8.dp), color = GREEN.copy(alpha = 0.15f),
                    border = BorderStroke(1.dp, GREEN.copy(alpha = 0.4f))) {
                    Row(modifier = Modifier.padding(horizontal = 10.dp, vertical = 5.dp),
                        verticalAlignment = Alignment.CenterVertically) {
                        Icon(Icons.Default.InstallMobile, null, tint = GREEN, modifier = Modifier.size(14.dp))
                        Spacer(Modifier.width(4.dp))
                        Text("Yükle", color = GREEN, fontSize = 11.sp, fontWeight = FontWeight.Bold)
                    }
                }
            } else {
                IconButton(onClick = { clipboard.setText(AnnotatedString(apk.path)) },
                    modifier = Modifier.size(34.dp)) {
                    Icon(Icons.Default.ContentCopy, null, tint = GREY, modifier = Modifier.size(17.dp))
                }
            }
            IconButton(onClick = { WsManager.deleteApk(apk.path); WsManager.listApks() },
                modifier = Modifier.size(34.dp)) {
                Icon(Icons.Default.Delete, null, tint = RED.copy(alpha = 0.7f), modifier = Modifier.size(17.dp))
            }
        }
    }
}

// ── Ayarlar Tab ─────────────────────────────────────────────────────────────
@Composable
fun SettingsTab() {
    val context = androidx.compose.ui.platform.LocalContext.current
    val scope = rememberCoroutineScope()
    var activeSection by remember { mutableStateOf("") }
 
    var apis      by remember { mutableStateOf(listOf<ApiInfo>()) }
    var keystores by remember { mutableStateOf(listOf<KeystoreInfo>()) }
    var backups   by remember { mutableStateOf(listOf<String>()) }
    var projConf  by remember { mutableStateOf("") }
    var toast     by remember { mutableStateOf("") }
    var selModel  by remember { mutableStateOf("claude-haiku-4-5-20251001") }
    var maxLoops  by remember { mutableStateOf("5") }
    var ksPass    by remember { mutableStateOf("") }
    var showTermuxPermissionError by remember { mutableStateOf(false) }
    var defProv   by remember { mutableStateOf("Claude") }
    var maxTokens by remember { mutableStateOf("8000") }
    var maxChars  by remember { mutableStateOf("200000") }
    var modelInfoDialog by remember { mutableStateOf<String?>(null) }
    var settingInfoDialog by remember { mutableStateOf<Pair<String, String>?>(null) }
    var providers  by remember { mutableStateOf<List<Map<String, Any>>>(emptyList()) }
    var backupSearch by remember { mutableStateOf("") }
    var seniorProv by remember { mutableStateOf("") }
    var seniorModel by remember { mutableStateOf("") }

    LaunchedEffect(Unit) { WsManager.getSettings(); WsManager.getProviders() }
    LaunchedEffect(toast) { if (toast.isNotEmpty()) { delay(2500); toast = "" } }
    LaunchedEffect(Unit) {
        WsManager.events.collect { event ->
            when (event) {
                is WsEvent.ApiList      -> apis = event.list
                is WsEvent.KeystoreList -> keystores = event.list
                is WsEvent.BackupList   -> backups = event.list
                is WsEvent.FileContent  -> projConf = event.content
                is WsEvent.TaskDone     -> if (event.text.isNotEmpty()) toast = event.text
                is WsEvent.Error        -> toast = "❌ ${event.msg}"
                is WsEvent.Providers    -> {
                    providers = event.list
                    if (providers.isNotEmpty() && providers.none { it["name"] == defProv }) {
                        defProv = providers[0]["name"] as String
                    }
                }
                is WsEvent.Settings     -> {
                    selModel = event.data["DEFAULT_MODEL"] ?: "claude-haiku-4-5-20251001"
                    maxLoops = event.data["MAX_LOOPS"] ?: "5"
                    ksPass   = event.data["KEYSTORE_PASS"] ?: ""
                    defProv  = event.data["DEFAULT_PROVIDER"] ?: "Claude"
                    maxTokens = event.data["MAX_TOKENS"] ?: "8000"
                    maxChars  = event.data["MAX_CHARS"] ?: "200000"
                    seniorProv = event.data["SENIOR_PROVIDER"] ?: ""
                    seniorModel = event.data["SENIOR_MODEL"] ?: ""
                }
                else -> {}
            }
        }
    }

    Column(modifier = Modifier.fillMaxSize().verticalScroll(rememberScrollState())) {
        
        if (modelInfoDialog != null) {
            AlertDialog(
                onDismissRequest = { modelInfoDialog = null },
                title = { Text(modelInfoDialog?.substringBefore("|") ?: "", color = WHITE, fontSize = 14.sp) },
                text = { Text(modelInfoDialog?.substringAfter("|") ?: "", color = GREY, fontSize = 13.sp) },
                confirmButton = { TextButton(onClick = { modelInfoDialog = null }) { Text("Tamam", color = ACCENT) } },
                containerColor = CARD
            )
        }

        if (settingInfoDialog != null) {
            AlertDialog(
                onDismissRequest = { settingInfoDialog = null },
                title = { Text(settingInfoDialog!!.first, color = WHITE, fontWeight = FontWeight.Bold, fontSize = 14.sp) },
                text = { Text(settingInfoDialog!!.second, color = GREY, fontSize = 13.sp) },
                confirmButton = { TextButton(onClick = { settingInfoDialog = null }) { Text("Anladım", color = ACCENT) } },
                containerColor = CARD
            )
        }

        Text("Ayarlar", fontWeight = FontWeight.Bold, fontSize = 20.sp, color = WHITE,
            modifier = Modifier.padding(horizontal = 16.dp, vertical = 14.dp))

        SettingsSection("🤖","AutoFix","Model, deneme, sınırlar, şifre",
            activeSection=="af", { activeSection = if (activeSection=="af") "" else "af" }) {
            Column(modifier = Modifier.padding(horizontal = 14.dp, vertical = 10.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp)) {
                
                Text("Varsayılan Provider", fontSize = 12.sp, color = GREY)
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    val providerNames = if (providers.isNotEmpty()) providers.map { it["name"] as String } else listOf("Claude","DeepSeek","Gemini")
                    providerNames.forEach { p ->
                        val sel = defProv == p
                        Surface(onClick = { defProv = p }, shape = RoundedCornerShape(20.dp),
                            color = if (sel) ACCENT.copy(alpha = 0.15f) else CARD,
                            border = BorderStroke(1.dp, if (sel) ACCENT else BORDER)) {
                            Text(p, modifier = Modifier.padding(horizontal = 12.dp, vertical = 6.dp),
                                color = if (sel) ACCENT else GREY, fontSize = 12.sp)
                        }
                    }
                }
                val currentProvider = providers.firstOrNull { it["name"] == defProv }
                val modelList = (currentProvider?.get("models") as? List<*>)?.filterIsInstance<String>() ?: emptyList()
                @Suppress("UNCHECKED_CAST")
                val modelInfos = (currentProvider?.get("model_infos") as? Map<String, String>) ?: emptyMap()
                if (modelList.isNotEmpty()) {
                    Text("Model", fontSize = 12.sp, color = GREY)
                    modelList.forEach { id ->
                        val sel = selModel == id
                        val info = modelInfos[id]
                        Surface(onClick = { selModel = id }, modifier = Modifier.fillMaxWidth(),
                            shape = RoundedCornerShape(10.dp),
                            color = if (sel) ACCENT.copy(alpha = 0.1f) else CARD,
                            border = BorderStroke(1.dp, if (sel) ACCENT else BORDER)) {
                            Row(modifier = Modifier.padding(horizontal = 14.dp, vertical = 9.dp),
                                verticalAlignment = Alignment.CenterVertically) {
                                Text(id, color = if (sel) ACCENT else WHITE, fontSize = 13.sp, modifier = Modifier.weight(1f))
                                if (!info.isNullOrEmpty()) {
                                    IconButton(onClick = { selModel = id; modelInfoDialog = "$id|${info}" }, modifier = Modifier.size(24.dp)) {
                                        Icon(Icons.Default.Info, null, tint = if (sel) ACCENT else GREY, modifier = Modifier.size(16.dp))
                                    }
                                }
                                if (sel) Icon(Icons.Default.Check, null, tint = ACCENT, modifier = Modifier.size(16.dp))
                            }
                        }
                    }
                }

                Text("Max Deneme: $maxLoops", fontSize = 12.sp, color = GREY)
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    listOf("3","5","8","10").forEach { n ->
                        val sel = maxLoops == n
                        Surface(onClick = { maxLoops = n }, shape = RoundedCornerShape(20.dp),
                            color = if (sel) GREEN.copy(alpha = 0.15f) else CARD,
                            border = BorderStroke(1.dp, if (sel) GREEN else BORDER)) {
                            Text(n, modifier = Modifier.padding(horizontal = 14.dp, vertical = 6.dp),
                                color = if (sel) GREEN else GREY, fontSize = 13.sp)
                        }
                    }
                }
        
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text("Max Token (Çıktı Sınırı): $maxTokens", fontSize = 12.sp, color = GREY, modifier = Modifier.weight(1f))
                    IconButton(onClick = { settingInfoDialog = "Max Token Nedir?" to "AI'ın sana verebileceği cevabın (üreteceği kodun) maksimum kelime/parça sınırıdır.\n\n🎯 İdeal Değer:\n• Ufak hata düzeltmeleri için: 8.000\n• Sıfırdan uygulama yazdırmak (Task) için: 16.000 veya 32.000\n\n⚠️ Dikkat: Çok yüksek token, AI'ın yanıt verme süresini uzatır ve ücretli API kullanıyorsan maliyeti artırır." }, modifier = Modifier.size(24.dp)) {
                        Icon(Icons.Default.Info, null, tint = ACCENT, modifier = Modifier.size(16.dp))
                    }
                }
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    listOf("4000","8000","16000","32000").forEach { n ->
                        val sel = maxTokens == n
                        Surface(onClick = { maxTokens = n }, shape = RoundedCornerShape(20.dp),
                            color = if (sel) ACCENT.copy(alpha = 0.15f) else CARD,
                            border = BorderStroke(1.dp, if (sel) ACCENT else BORDER)) {
                            Text(n, modifier = Modifier.padding(horizontal = 12.dp, vertical = 6.dp),
                                color = if (sel) ACCENT else GREY, fontSize = 12.sp)
                        }
                    }
                }

                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text("Max Char (Girdi Sınırı): $maxChars", fontSize = 12.sp, color = GREY, modifier = Modifier.weight(1f))
                    IconButton(onClick = { settingInfoDialog = "Max Char Nedir?" to "Senin projendeki dosyaların (kodların) AI'a gönderilen kısmının maksimum karakter sınırıdır.\n\n🎯 İdeal Değer: 200.000\n\n⚠️ Dikkat: Bu değeri çok düşük (örn: 60.000) tutarsan, büyük projelerde kodun yarısı yapay zekaya gitmeden kesilir. AI eksik koda baktığı için neyi düzelteceğini bulamaz ve sistem çöker." }, modifier = Modifier.size(24.dp)) {
                        Icon(Icons.Default.Info, null, tint = ACCENT, modifier = Modifier.size(16.dp))
                    }
                }
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    listOf("60000","100000","200000","300000").forEach { n ->
                        val sel = maxChars == n
                        Surface(onClick = { maxChars = n }, shape = RoundedCornerShape(20.dp),
                            color = if (sel) PURPLE.copy(alpha = 0.15f) else CARD,
                            border = BorderStroke(1.dp, if (sel) PURPLE else BORDER)) {
                            Text(n, modifier = Modifier.padding(horizontal = 12.dp, vertical = 6.dp),
                                color = if (sel) PURPLE else GREY, fontSize = 12.sp)
                        }
                    }
                }

                Text("Keystore Şifresi", fontSize = 12.sp, color = GREY)
                OutlinedTextField(value = ksPass, onValueChange = { ksPass = it },
                    placeholder = { Text("android123", fontSize = 12.sp) },
                    modifier = Modifier.fillMaxWidth(), shape = RoundedCornerShape(10.dp), singleLine = true,
                    colors = OutlinedTextFieldDefaults.colors(focusedBorderColor = ACCENT, unfocusedBorderColor = BORDER,
                        focusedTextColor = WHITE, unfocusedTextColor = WHITE, cursorColor = ACCENT,
                        focusedContainerColor = CARD, unfocusedContainerColor = CARD),
                    textStyle = androidx.compose.ui.text.TextStyle(fontSize = 13.sp))
                
                // Senior AI Seçimi
                Spacer(Modifier.height(12.dp))
                Text("🎓 Senior AI (Gözlemci)", fontSize = 12.sp, color = GREY)
                Text("Build hatası MAX_LOOPS/2 denemede çözülemezse devreye girer. Aktif provider'dan farklı olmalı.", 
                    fontSize = 10.sp, color = GREY.copy(alpha = 0.6f))
                Spacer(Modifier.height(6.dp))
                var showSeniorMenu by remember { mutableStateOf(false) }
                var showSeniorModelMenu by remember { mutableStateOf(false) }
                val seniorOptions = listOf("Devre Dışı") + providers.map { it["name"] as String }
                val seniorModels = providers.find { it["name"] == seniorProv }
                    ?.let { (it["models"] as? List<*>)?.filterIsInstance<String>() } ?: emptyList()

                // Provider seçimi
                Box {
                    OutlinedButton(onClick = { showSeniorMenu = true },
                        modifier = Modifier.fillMaxWidth(), shape = RoundedCornerShape(10.dp),
                        border = BorderStroke(1.dp, BORDER),
                        colors = ButtonDefaults.outlinedButtonColors(contentColor = WHITE)) {
                        Text(if (seniorProv.isEmpty()) "Devre Dışı" else seniorProv, fontSize = 13.sp, modifier = Modifier.weight(1f))
                        Icon(Icons.Default.ArrowDropDown, null, tint = GREY)
                    }
                    DropdownMenu(expanded = showSeniorMenu, onDismissRequest = { showSeniorMenu = false },
                        modifier = Modifier.background(CARD)) {
                        seniorOptions.forEach { opt ->
                            DropdownMenuItem(
                                text = { Text(opt, color = if (opt == "Devre Dışı") GREY else WHITE, fontSize = 13.sp) },
                                onClick = {
                                    seniorProv = if (opt == "Devre Dışı") "" else opt
                                    seniorModel = ""
                                    showSeniorMenu = false
                                }
                            )
                        }
                    }
                }

                // Model seçimi (provider seçiliyse)
                if (seniorProv.isNotEmpty() && seniorModels.isNotEmpty()) {
                    Spacer(Modifier.height(6.dp))
                    Box {
                        OutlinedButton(onClick = { showSeniorModelMenu = true },
                            modifier = Modifier.fillMaxWidth(), shape = RoundedCornerShape(10.dp),
                            border = BorderStroke(1.dp, BORDER),
                            colors = ButtonDefaults.outlinedButtonColors(contentColor = WHITE)) {
                            Text(if (seniorModel.isEmpty()) "Model seç..." else seniorModel, fontSize = 12.sp, modifier = Modifier.weight(1f))
                            Icon(Icons.Default.ArrowDropDown, null, tint = GREY)
                        }
                        DropdownMenu(expanded = showSeniorModelMenu, onDismissRequest = { showSeniorModelMenu = false },
                            modifier = Modifier.background(CARD)) {
                            seniorModels.forEach { m ->
                                DropdownMenuItem(
                                    text = { Text(m, color = WHITE, fontSize = 12.sp) },
                                    onClick = { seniorModel = m; showSeniorModelMenu = false }
                                )
                            }
                        }
                    }
                }
                Spacer(Modifier.height(12.dp))

                Button(onClick = { WsManager.saveSettings(mapOf("DEFAULT_PROVIDER" to defProv,
                    "DEFAULT_MODEL" to selModel, "MAX_LOOPS" to maxLoops, "MAX_TOKENS" to maxTokens, "MAX_CHARS" to maxChars, "KEYSTORE_PASS" to ksPass, "SENIOR_PROVIDER" to seniorProv, "SENIOR_MODEL" to seniorModel)) },
                    modifier = Modifier.fillMaxWidth(), shape = RoundedCornerShape(10.dp),
                    colors = ButtonDefaults.buttonColors(containerColor = ACCENT)) {
                    Icon(Icons.Default.Save, null, modifier = Modifier.size(16.dp))
                    Spacer(Modifier.width(6.dp))
                    Text("Kaydet", fontWeight = FontWeight.Bold)
                }
            }
        }

        Spacer(Modifier.height(8.dp))

        PromptSection(activeSection = activeSection, onToggle = {
            activeSection = if (activeSection == "prompts") "" else "prompts"
        }, scope = scope, onToast = { toast = it })

        Spacer(Modifier.height(8.dp))

        SettingsSection("🔑","API Key'ler","${apis.count{it.hasKey}}/${apis.size} ayarlı",
            activeSection=="api", {
                activeSection = if (activeSection=="api") "" else "api"
                if (activeSection=="api") WsManager.listApis()
            }) {
            apis.forEach { api ->
                ApiKeyRow(api) { key -> WsManager.saveApi(api.name, key); scope.launch { delay(500); WsManager.listApis() } }
            }
        }

        Spacer(Modifier.height(8.dp))

        val filteredBackups = backups.filter { backupSearch.isBlank() || it.contains(backupSearch, ignoreCase = true) }
        val groupedBackups  = filteredBackups.groupBy { it.split('-').firstOrNull() ?: "diğer" }
        SettingsSection("💾","Yedekler","${backups.size} yedek",
            activeSection=="bk", {
                activeSection = if (activeSection=="bk") "" else "bk"
                if (activeSection=="bk") WsManager.listBackups()
            }) {
            Column(modifier = Modifier.padding(horizontal = 14.dp, vertical = 8.dp)) {
                OutlinedTextField(value = backupSearch, onValueChange = { backupSearch = it },
                    placeholder = { Text("Yedek ara...", fontSize = 12.sp) },
                    modifier = Modifier.fillMaxWidth(), shape = RoundedCornerShape(10.dp), singleLine = true,
                    leadingIcon = { Icon(Icons.Default.Search, null, tint = GREY, modifier = Modifier.size(18.dp)) },
                    colors = OutlinedTextFieldDefaults.colors(focusedBorderColor = ACCENT, unfocusedBorderColor = BORDER,
                        focusedTextColor = WHITE, unfocusedTextColor = WHITE, cursorColor = ACCENT,
                        focusedContainerColor = CARD, unfocusedContainerColor = CARD),
                    textStyle = androidx.compose.ui.text.TextStyle(fontSize = 12.sp))
                Spacer(Modifier.height(8.dp))
            }
            groupedBackups.forEach { (projName, list) ->
                Row(modifier = Modifier.fillMaxWidth().background(SURFACE)
                    .padding(horizontal = 14.dp, vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
                    Icon(Icons.Default.Android, null, tint = PURPLE, modifier = Modifier.size(14.dp))
                    Spacer(Modifier.width(6.dp))
                    Text(projName, color = WHITE, fontSize = 12.sp, fontWeight = FontWeight.SemiBold, modifier = Modifier.weight(1f))
                    Text("${list.size}", color = GREY, fontSize = 10.sp)
                }
                list.forEach { b ->
                    val displayName = b.removePrefix("$projName-").removeSuffix(".tar.gz")
                    Row(modifier = Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 7.dp),
                        verticalAlignment = Alignment.CenterVertically) {
                        Icon(Icons.Default.Archive, null, tint = ACCENT.copy(alpha = 0.7f), modifier = Modifier.size(14.dp))
                        Spacer(Modifier.width(8.dp))
                        Text(displayName, color = WHITE.copy(alpha = 0.85f), fontSize = 12.sp,
                            modifier = Modifier.weight(1f), maxLines = 1, overflow = TextOverflow.Ellipsis)
                        TextButton(onClick = { WsManager.restoreBackup(b); toast = "↩ Geri yükleniyor..." },
                            contentPadding = PaddingValues(horizontal = 8.dp)) {
                            Text("Yükle", color = ORANGE, fontSize = 11.sp)
                        }
                    }
                    Divider(color = BORDER.copy(alpha = 0.3f), thickness = 0.5.dp, modifier = Modifier.padding(horizontal = 14.dp))
                }
            }
        }

        Spacer(Modifier.height(8.dp))

        DriveBackupSection(context = context)

        Spacer(Modifier.height(8.dp))

        Card(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp),
            colors = CardDefaults.cardColors(containerColor = CARD),
            border = BorderStroke(1.dp, BORDER), shape = RoundedCornerShape(12.dp)
        ) {
            Row(modifier = Modifier.padding(14.dp), verticalAlignment = Alignment.CenterVertically) {
                Text("⚠️", fontSize = 18.sp)
                Spacer(Modifier.width(10.dp))
                Column(modifier = Modifier.weight(1f)) {
                    Text("Sorun mu var?", fontWeight = FontWeight.Bold, fontSize = 13.sp, color = WHITE)
                    Text("Bağlantı sorunu yaşıyorsan motoru yeniden başlat", fontSize = 11.sp, color = GREY)
                }
                Spacer(Modifier.width(8.dp))
                Surface(
                    onClick = {
                        // startWsBridge yerine izni kontrol eden sendToTermux kullanıyoruz
                        val success = TermuxBridge.sendToTermux(context, "bash /data/data/com.termux/files/home/restart_bridge.sh")
                        
                        if (!success) {
                            // İzin yoksa kırmızı kalkanı (dialogu) aç
                            showTermuxPermissionError = true
                        } else {
                            // Başarılıysa motoru yenile
                            scope.launch { 
                                delay(3000)
                                WsManager.disconnect()
                                delay(500)
                                WsManager.connect() 
                            }
                        }
                    },
                    shape = RoundedCornerShape(8.dp),
                    color = ACCENT.copy(alpha = 0.15f),
                    border = BorderStroke(1.dp, ACCENT.copy(alpha = 0.4f))
                ) {
                    Text("Yeniden Başlat", modifier = Modifier.padding(horizontal = 10.dp, vertical = 6.dp),
                        color = ACCENT, fontSize = 11.sp, fontWeight = FontWeight.Bold)
                }
            
        

            }
        }

        Spacer(Modifier.height(8.dp))

        SettingsSection("🔐","Keystore'lar","${keystores.size} keystore",
            activeSection=="ks", {
                activeSection = if (activeSection=="ks") "" else "ks"
                if (activeSection=="ks") WsManager.listKeystores()
            }) {
            keystores.forEach { ks ->
                Row(modifier = Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 8.dp),
                    verticalAlignment = Alignment.CenterVertically) {
                    Icon(Icons.Default.Key, null, tint = ORANGE, modifier = Modifier.size(15.dp))
                    Spacer(Modifier.width(8.dp))
                    Column(modifier = Modifier.weight(1f)) {
                        Text(ks.name, color = WHITE, fontSize = 12.sp)
                        if (ks.project.isNotEmpty()) Text(ks.project, color = GREY, fontSize = 10.sp)
                    }
                    Text("${ks.size/1024}KB", color = GREY, fontSize = 11.sp)
                }
                Divider(color = BORDER.copy(alpha = 0.4f), thickness = 0.5.dp, modifier = Modifier.padding(horizontal = 14.dp))
            }
        }

        Spacer(Modifier.height(8.dp))

        SettingsSection("📋","projeler.conf","Proje listesini düzenle",
            activeSection=="conf", {
                activeSection = if (activeSection=="conf") "" else "conf"
                if (activeSection=="conf") WsManager.getProjectsConf()
            }) {
            Column(modifier = Modifier.padding(14.dp)) {
                OutlinedTextField(value = projConf, onValueChange = { projConf = it },
                    modifier = Modifier.fillMaxWidth().height(180.dp), shape = RoundedCornerShape(10.dp),
                    textStyle = androidx.compose.ui.text.TextStyle(fontSize = 11.sp, fontFamily = FontFamily.Monospace),
                    colors = OutlinedTextFieldDefaults.colors(focusedBorderColor = ACCENT, unfocusedBorderColor = BORDER,
                        focusedTextColor = WHITE, unfocusedTextColor = WHITE, cursorColor = ACCENT,
                        focusedContainerColor = CARD, unfocusedContainerColor = CARD))
                Spacer(Modifier.height(8.dp))
                Button(onClick = { WsManager.saveProjectsConf(projConf); toast = "✅ Kaydedildi" },
                    modifier = Modifier.fillMaxWidth(), shape = RoundedCornerShape(10.dp),
                    colors = ButtonDefaults.buttonColors(containerColor = ACCENT)) {
                    Text("Kaydet", fontWeight = FontWeight.Bold)
                }
            }
        }

        Spacer(Modifier.height(100.dp))

        if (toast.isNotEmpty()) {
            Box(modifier = Modifier.fillMaxWidth().padding(16.dp), contentAlignment = Alignment.Center) {
                Card(colors = CardDefaults.cardColors(containerColor = CARD),
                    border = BorderStroke(1.dp, BORDER), shape = RoundedCornerShape(20.dp)) {
                    Text(toast, modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp), color = WHITE, fontSize = 12.sp)
                }
            }
        }



        // --- TERMUX İZİN HATA DİALOGU (AYARLAR İÇİN NANO-SAFE) ---
        if (showTermuxPermissionError) {
            AlertDialog(
                onDismissRequest = { showTermuxPermissionError = false },
                containerColor = CARD, 
                shape = RoundedCornerShape(16.dp),
                title = {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Icon(Icons.Default.Security, null, tint = RED, modifier = Modifier.size(24.dp))
                        Spacer(Modifier.width(8.dp))
                        Text(
                            "Kritik İzin Eksik", 
                            color = RED, 
                            fontWeight = FontWeight.Bold, 
                            fontSize = 18.sp
                        )
                    }
                },
                text = {
                    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        Text(
                            "APK Factory'nin Termux motorunu başlatabilmesi " +
                            "için komut gönderme iznine ihtiyacı var.", 
                            color = WHITE, 
                            fontSize = 13.sp
                        )
                        Card(
                            colors = CardDefaults.cardColors(containerColor = SURFACE), 
                            border = BorderStroke(1.dp, BORDER)
                        ) {
                            Text(
                                "1. 'Ayarları Aç' butonuna tıklayın.\n" +
                                "2. İzinler (Permissions) bölümüne girin.\n" +
                                "3. 'Run commands in Termux environment' iznini verin.",
                                modifier = Modifier.padding(10.dp), 
                                color = GREY, 
                                fontSize = 12.sp, 
                                lineHeight = 18.sp
                            )
                        }
                    }
                },
                confirmButton = {
                    Button(
                        onClick = {
                            showTermuxPermissionError = false
                            val intent = android.content.Intent(
                                android.provider.Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                                android.net.Uri.parse("package:${context.packageName}")
                            ).addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK)
                            try { context.startActivity(intent) } catch(e: Exception) {}
                        }, 
                        colors = ButtonDefaults.buttonColors(containerColor = ACCENT)
                    ) {
                        Text("Ayarları Aç")
                    }
                },
                dismissButton = {
                    TextButton(onClick = { showTermuxPermissionError = false }) { 
                        Text("İptal", color = GREY) 
                    }
                }
            )
        }



}

    
}




@Composable
fun PromptSection(
    activeSection: String,
    onToggle: () -> Unit,
    scope: kotlinx.coroutines.CoroutineScope,
    onToast: (String) -> Unit
) {
    val context = androidx.compose.ui.platform.LocalContext.current

    var selectedPrompt  by remember { mutableStateOf("autofix_system") }
    var systemContent   by remember { mutableStateOf("") }
    var taskContent     by remember { mutableStateOf("") }
    var isEditing       by remember { mutableStateOf(false) }
    var editText        by remember { mutableStateOf("") }
    var isDefault       by remember { mutableStateOf(true) }
    var loading         by remember { mutableStateOf(false) }
    var resetting       by remember { mutableStateOf(false) }

    // Arşiv
    var archives        by remember { mutableStateOf(listOf<String>()) }
    var showArchives    by remember { mutableStateOf(false) }
    var showSaveArcDlg  by remember { mutableStateOf(false) }
    var arcName         by remember { mutableStateOf("") }

    // Dosya seçici
    val fileLauncher = androidx.activity.compose.rememberLauncherForActivityResult(
        androidx.activity.result.contract.ActivityResultContracts.GetContent()
    ) { uri ->
        uri?.let {
            try {
                val text = context.contentResolver.openInputStream(it)?.bufferedReader()?.readText() ?: ""
                editText = text
                onToast("📄 Dosya yüklendi")
            } catch (e: Exception) { onToast("❌ Dosya okunamadı") }
        }
    }

    // Event dinle
    LaunchedEffect(Unit) {
        WsManager.events.collect { event ->
            when (event) {
                is WsEvent.PromptContent -> {
                    loading = false; resetting = false
                    isDefault = event.isDefault
                    if (event.name == "autofix_system") {
                        systemContent = event.content  // bellekte güncelle
                        if (selectedPrompt == "autofix_system") editText = event.content
                    } else {
                        taskContent = event.content  // bellekte güncelle
                        if (selectedPrompt == "autofix_task") editText = event.content
                    }
                }
                is WsEvent.PromptArchives -> archives = event.list
                is WsEvent.TaskDone -> {
                    if (event.text.contains("arşiv") || event.text.contains("kaydedildi") ||
                        event.text.contains("sıfırlandı") || event.text.contains("silindi")) {
                        onToast(event.text)
                        isEditing = false
                        showSaveArcDlg = false
                        arcName = ""
                        WsManager.listPromptArchives()
                    }
                }
                else -> {}
            }
        }
    }

    LaunchedEffect(activeSection) {
        if (activeSection == "prompts") {
            loading = true
            WsManager.getPrompt("autofix_system")
            WsManager.getPrompt("autofix_task")
            WsManager.listPromptArchives()
        }
    }

    // Arşive kaydet dialog
    if (showSaveArcDlg) {
        AlertDialog(
            onDismissRequest = { showSaveArcDlg = false; arcName = "" },
            containerColor = CARD, shape = RoundedCornerShape(16.dp),
            title = { Text("Arşive Kaydet", color = WHITE, fontWeight = FontWeight.Bold) },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text("Bu prompt için bir isim gir:", color = GREY, fontSize = 12.sp)
                    OutlinedTextField(
                        value = arcName, onValueChange = { arcName = it },
                        placeholder = { Text("örn: agresif-düzeltici", fontSize = 12.sp) },
                        singleLine = true, modifier = Modifier.fillMaxWidth(),
                        shape = RoundedCornerShape(10.dp),
                        colors = OutlinedTextFieldDefaults.colors(
                            focusedBorderColor = ACCENT, unfocusedBorderColor = BORDER,
                            focusedTextColor = WHITE, unfocusedTextColor = WHITE,
                            cursorColor = ACCENT, focusedContainerColor = CARD,
                            unfocusedContainerColor = CARD)
                    )
                }
            },
            confirmButton = {
                Button(
                    onClick = {
                        if (arcName.isNotBlank())
                            WsManager.savePromptArchive(arcName.trim(), selectedPrompt, editText)
                    },
                    colors = ButtonDefaults.buttonColors(containerColor = ACCENT),
                    shape = RoundedCornerShape(10.dp)
                ) { Text("Kaydet") }
            },
            dismissButton = {
                TextButton(onClick = { showSaveArcDlg = false; arcName = "" }) {
                    Text("İptal", color = GREY)
                }
            }
        )
    }

    SettingsSection(
        icon = "📝", title = "Promptlar",
        subtitle = "AI davranış talimatları",
        isOpen = activeSection == "prompts",
        onToggle = onToggle
    ) {
        Column(modifier = Modifier.padding(14.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {

            // Prompt tipi seçici
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                listOf("autofix_system" to "🔧 Hata Düzeltici", "autofix_task" to "✨ Görev").forEach { (name, label) ->
                    val sel = selectedPrompt == name
                    Surface(
                        onClick = { selectedPrompt = name; editText = if (name == "autofix_system") systemContent else taskContent; isEditing = false },
                        shape = RoundedCornerShape(20.dp),
                        color = if (sel) ACCENT.copy(alpha = 0.15f) else CARD,
                        border = BorderStroke(1.dp, if (sel) ACCENT else BORDER)
                    ) {
                        Text(label, modifier = Modifier.padding(horizontal = 12.dp, vertical = 6.dp),
                            color = if (sel) ACCENT else GREY, fontSize = 12.sp)
                    }
                }
            }

            // Nerede kullanılır
            Card(colors = CardDefaults.cardColors(containerColor = SURFACE),
                shape = RoundedCornerShape(8.dp), border = BorderStroke(1.dp, BORDER)) {
                Text(
                    if (selectedPrompt == "autofix_system")
                        "🔧 Build hatası olduğunda AI'ya gönderilir. Nasıl düzelteceğini belirler."
                    else
                        "✨ 'prj e' veya AutoFix ekranından görev verildiğinde kullanılır.",
                    modifier = Modifier.padding(10.dp), color = GREY, fontSize = 11.sp
                )
            }

            if (loading) {
                Box(modifier = Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
                    CircularProgressIndicator(modifier = Modifier.size(24.dp), color = ACCENT, strokeWidth = 2.dp)
                }
            } else {
                // Önizleme veya editör
                if (!isEditing) {
                    Card(
                        colors = CardDefaults.cardColors(containerColor = SURFACE),
                        shape = RoundedCornerShape(8.dp),
                        border = BorderStroke(1.dp, if (isDefault) BORDER else ACCENT.copy(alpha = 0.5f))
                    ) {
                        Column(modifier = Modifier.padding(10.dp)) {
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                Text(
                                    if (isDefault) "GitHub (Varsayılan)" else "Özelleştirilmiş",
                                    color = if (isDefault) GREY else ACCENT,
                                    fontSize = 10.sp, modifier = Modifier.weight(1f)
                                )
                                if (!isDefault) Text("✏️ Senin promptun", color = ACCENT, fontSize = 10.sp)
                            }
                            Spacer(Modifier.height(6.dp))
                            Text(
                                editText.take(200) + if (editText.length > 200) "..." else "",
                                color = WHITE.copy(alpha = 0.8f), fontSize = 11.sp,
                                fontFamily = FontFamily.Monospace, lineHeight = 16.sp
                            )
                        }
                    }
                } else {
                    OutlinedTextField(
                        value = editText, onValueChange = { editText = it },
                        modifier = Modifier.fillMaxWidth().height(240.dp),
                        shape = RoundedCornerShape(10.dp),
                        textStyle = androidx.compose.ui.text.TextStyle(fontSize = 11.sp, fontFamily = FontFamily.Monospace),
                        colors = OutlinedTextFieldDefaults.colors(
                            focusedBorderColor = ACCENT, unfocusedBorderColor = BORDER,
                            focusedTextColor = WHITE, unfocusedTextColor = WHITE,
                            cursorColor = ACCENT, focusedContainerColor = CARD, unfocusedContainerColor = CARD)
                    )
                    // Dosyadan yükle + arşive kaydet
                    Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                        TextButton(onClick = { fileLauncher.launch("text/*") }, contentPadding = PaddingValues(0.dp)) {
                            Icon(Icons.Default.FileUpload, null, tint = GREY, modifier = Modifier.size(14.dp))
                            Spacer(Modifier.width(4.dp))
                            Text("Dosyadan Yükle", color = GREY, fontSize = 11.sp)
                        }
                        TextButton(onClick = { showSaveArcDlg = true }, contentPadding = PaddingValues(0.dp)) {
                            Icon(Icons.Default.Archive, null, tint = PURPLE, modifier = Modifier.size(14.dp))
                            Spacer(Modifier.width(4.dp))
                            Text("Arşive Kaydet", color = PURPLE, fontSize = 11.sp)
                        }
                    }
                }

                // Ana butonlar
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    if (!isEditing) {
                        Button(
                            onClick = { isEditing = true },
                            shape = RoundedCornerShape(8.dp),
                            colors = ButtonDefaults.buttonColors(containerColor = ACCENT),
                            contentPadding = PaddingValues(horizontal = 14.dp, vertical = 8.dp),
                            modifier = Modifier.weight(1f)
                        ) {
                            Icon(Icons.Default.Edit, null, modifier = Modifier.size(14.dp))
                            Spacer(Modifier.width(4.dp))
                            Text("Düzenle", fontSize = 12.sp)
                        }
                    } else {
                        Button(
                            onClick = { WsManager.savePrompt(selectedPrompt, editText) },
                            shape = RoundedCornerShape(8.dp),
                            colors = ButtonDefaults.buttonColors(containerColor = GREEN),
                            contentPadding = PaddingValues(horizontal = 14.dp, vertical = 8.dp),
                            modifier = Modifier.weight(1f)
                        ) {
                            Icon(Icons.Default.Save, null, modifier = Modifier.size(14.dp))
                            Spacer(Modifier.width(4.dp))
                            Text("Kaydet", fontSize = 12.sp)
                        }
                        TextButton(onClick = {
                            editText = if (selectedPrompt == "autofix_system") systemContent else taskContent
                            isEditing = false
                        }) { Text("İptal", color = GREY, fontSize = 12.sp) }
                    }

                    if (!isEditing) {
                        Button(
                            onClick = { resetting = true; WsManager.resetPrompt(selectedPrompt) },
                            enabled = !resetting,
                            shape = RoundedCornerShape(8.dp),
                            colors = ButtonDefaults.buttonColors(containerColor = ORANGE.copy(alpha = 0.8f)),
                            contentPadding = PaddingValues(horizontal = 10.dp, vertical = 8.dp)
                        ) {
                            Icon(Icons.Default.Refresh, null, modifier = Modifier.size(14.dp))
                            Spacer(Modifier.width(4.dp))
                            Text(if (resetting) "..." else "Sıfırla", fontSize = 11.sp)
                        }
                    }
                }

                // Arşiv bölümü
                if (archives.isNotEmpty()) {
                    Divider(color = BORDER, thickness = 0.5.dp)
                    Row(
                        modifier = Modifier.fillMaxWidth().clickable { showArchives = !showArchives },
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Icon(Icons.Default.Archive, null, tint = PURPLE, modifier = Modifier.size(14.dp))
                        Spacer(Modifier.width(6.dp))
                        Text("Arşiv (${archives.size})", color = PURPLE, fontSize = 12.sp, modifier = Modifier.weight(1f))
                        Icon(
                            if (showArchives) Icons.Default.ExpandLess else Icons.Default.ExpandMore,
                            null, tint = PURPLE, modifier = Modifier.size(16.dp)
                        )
                    }

                    if (showArchives) {
                        archives.forEach { arcFile ->
                            val displayName = arcFile
                                .removePrefix("autofix_system_")
                                .removePrefix("autofix_task_")
                                .removeSuffix(".txt")
                            val isSystem = arcFile.startsWith("autofix_system")
                            Row(
                                modifier = Modifier.fillMaxWidth().padding(vertical = 4.dp),
                                verticalAlignment = Alignment.CenterVertically
                            ) {
                                Text(
                                    if (isSystem) "🔧" else "✨",
                                    fontSize = 12.sp
                                )
                                Spacer(Modifier.width(6.dp))
                                Column(modifier = Modifier.weight(1f)) {
                                    Text(displayName, color = WHITE, fontSize = 12.sp)
                                    Text(
                                        if (isSystem) "Hata Düzeltici" else "Görev",
                                        color = GREY, fontSize = 10.sp
                                    )
                                }
                                TextButton(
                                    onClick = {
                                        val pname = if (isSystem) "autofix_system" else "autofix_task"
                                        selectedPrompt = pname
                                        // Arşiv içeriğini oku ve direkt kaydet
                                        val arcPath = "/storage/emulated/0/termux-otonom-sistem/prompts/arsiv/$arcFile"
                                        try {
                                            val cnt = java.io.File(arcPath).readText()
                                            WsManager.savePrompt(pname, cnt)
                                            if (isSystem) systemContent = cnt else taskContent = cnt
                                            editText = cnt
                                        } catch(e: Exception) {
                                            WsManager.loadPromptArchive(arcFile)
                                        }
                                    },
                                    contentPadding = PaddingValues(horizontal = 8.dp)
                                ) { Text("Yükle", color = ACCENT, fontSize = 11.sp) }
                                IconButton(
                                    onClick = { WsManager.deletePromptArchive(arcFile) },
                                    modifier = Modifier.size(28.dp)
                                ) {
                                    Icon(Icons.Default.Delete, null, tint = RED, modifier = Modifier.size(14.dp))
                                }
                            }
                            Divider(color = BORDER.copy(alpha = 0.3f), thickness = 0.5.dp)
                        }
                    }
                }
            }
        }
    }
}

@Composable
fun DriveBackupSection(context: android.content.Context) {
    val prefs = context.getSharedPreferences("apkfactory_prefs", android.content.Context.MODE_PRIVATE)
    var autoBackup by remember { mutableStateOf(prefs.getBoolean("drive_auto_backup", false)) }
    var backupKeystores by remember { mutableStateOf(prefs.getBoolean("drive_backup_keystores", true)) }
    var backupConf by remember { mutableStateOf(prefs.getBoolean("drive_backup_conf", true)) }
    var backupNormalYedekler by remember { mutableStateOf(prefs.getBoolean("drive_backup_normal", true)) }
    var isSignedIn by remember { mutableStateOf(DriveUploadManager.isSignedIn(context)) }
    var uploading  by remember { mutableStateOf(false) }
    var status     by remember { mutableStateOf("") }
    val scope      = rememberCoroutineScope()

    val signInLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.StartActivityForResult()
    ) { result ->
        val task = GoogleSignIn.getSignedInAccountFromIntent(result.data)
        try {
            task.getResult(ApiException::class.java)
            isSignedIn = true
            status = "✅ Google hesabı bağlandı"
        } catch (e: ApiException) {
            status = "❌ Giriş başarısız"
        }
    }

    Card(
        modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp),
        colors = CardDefaults.cardColors(containerColor = CARD),
        border = BorderStroke(1.dp, BORDER),
        shape = RoundedCornerShape(14.dp)
    ) {
        Column(modifier = Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("☁️", fontSize = 18.sp)
                Spacer(Modifier.width(10.dp))
                Column(modifier = Modifier.weight(1f)) {
                    Text("Google Drive Yedekleme", fontWeight = FontWeight.SemiBold, fontSize = 14.sp, color = WHITE)
                    Text("Keystore & projeler.conf otomatik yedekle", fontSize = 11.sp, color = GREY)
                }
                Switch(
                    checked = autoBackup,
                    onCheckedChange = { checked ->
                        if (checked && !isSignedIn) {
                            DriveUploadManager.signIn(signInLauncher, context)
                        } else {
                            autoBackup = checked
                            prefs.edit().putBoolean("drive_auto_backup", checked).apply()
                            if (checked) {
                                scope.launch {
                                    uploading = true
                                    status = "⏳ Yedekleniyor..."
                                    run {
                                        val yedekDir = java.io.File("/storage/emulated/0/termux-otonom-sistem/yedekler")
                                        val yedekler = if (yedekDir.exists()) yedekDir.listFiles()?.filter { it.name.endsWith("-yedek.tar.gz") }?.toList() ?: emptyList() else emptyList()
                                        DriveUploadManager.syncByToggles(context, DriveToggles(keystoreConf = backupKeystores, apiKeys = backupConf, normalYedek = backupNormalYedekler), yedekDosyalari = yedekler) { status = it }
                                    }
                                        .onSuccess { files ->
                                            status = "✅ ${files.size} dosya yedeklendi"
                                        }
                                        .onFailure { status = "❌ ${it.message}" }
                                    uploading = false
                                }
                            }
                        }
                    },
                    colors = SwitchDefaults.colors(checkedThumbColor = ACCENT, checkedTrackColor = ACCENT.copy(alpha = 0.3f))
                )
            }

            if (isSignedIn) {
                Divider(color = BORDER.copy(alpha = 0.5f))
                Text("Yedeklenecekler:", color = GREY, fontSize = 11.sp, fontWeight = FontWeight.SemiBold)
                listOf(
                    Triple("keystores", "🔑 Keystore dosyaları", backupKeystores),
                    Triple("conf", "📋 Conf & API key'ler", backupConf),
                    Triple("normal", "💾 Normal proje yedekleri", backupNormalYedekler)
                ).forEach { (key, label, checked) ->
                    Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                        Text(label, color = WHITE, fontSize = 12.sp, modifier = Modifier.weight(1f))
                        Switch(
                            checked = checked,
                            onCheckedChange = { v ->
                                when(key) {
                                    "keystores" -> { backupKeystores = v; prefs.edit().putBoolean("drive_backup_keystores", v).apply() }
                                    "conf" -> { backupConf = v; prefs.edit().putBoolean("drive_backup_conf", v).apply() }
                                    "normal" -> { backupNormalYedekler = v; prefs.edit().putBoolean("drive_backup_normal", v).apply() }
                                }
                            },
                            colors = SwitchDefaults.colors(checkedThumbColor = ACCENT, checkedTrackColor = ACCENT.copy(alpha = 0.3f))
                        )
                    }
                }
            }
            if (!isSignedIn && autoBackup) {
                Text("Google hesabı bağlanmadı", color = RED, fontSize = 11.sp)
            }

            if (isSignedIn) {
                Text(
                    DriveUploadManager.getSignedInAccount(context)?.email ?: "",
                    color = GREEN, fontSize = 11.sp
                )
            }

            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                if (!isSignedIn) {
                    Button(
                        onClick = { DriveUploadManager.signIn(signInLauncher, context) },
                        shape = RoundedCornerShape(8.dp),
                        colors = ButtonDefaults.buttonColors(containerColor = Color(0xFF1a73e8)),
                        contentPadding = PaddingValues(horizontal = 12.dp, vertical = 6.dp),
                        modifier = Modifier.height(32.dp)
                    ) { Text("Google ile Giriş", fontSize = 11.sp) }
                } else {
                    var showBackupOptions by remember { mutableStateOf(false) }
                    var showRestoreOptions by remember { mutableStateOf(false) }
                    Box {
                        Button(
                            onClick = { showBackupOptions = true },
                            enabled = !uploading,
                            shape = RoundedCornerShape(8.dp),
                            colors = ButtonDefaults.buttonColors(containerColor = ACCENT),
                            contentPadding = PaddingValues(horizontal = 12.dp, vertical = 6.dp),
                            modifier = Modifier.height(32.dp)
                        ) { Text(if (uploading) "Yükleniyor..." else "Şimdi Yedekle", fontSize = 11.sp) }
                        DropdownMenu(expanded = showBackupOptions, onDismissRequest = { showBackupOptions = false }, modifier = Modifier.background(CARD)) {
                            listOf(
                                "all"     to "☁️ Tümünü Yedekle",
                                "ks_conf" to "🔑 Keystore & Conf",
                                "api"     to "🔐 Sadece API Key'ler",
                                "backups" to "💾 Sadece Normal Yedekler"
                            ).forEach { (type, label) ->
                                DropdownMenuItem(
                                    text = { Text(label, color = WHITE, fontSize = 13.sp) },
                                    onClick = {
                                        showBackupOptions = false
                                        val toggles = when (type) {
                                            "ks_conf" -> DriveToggles(keystoreConf = true,  apiKeys = false, normalYedek = false)
                                            "api"     -> DriveToggles(keystoreConf = false, apiKeys = true,  normalYedek = false)
                                            "backups" -> DriveToggles(keystoreConf = false, apiKeys = false, normalYedek = true)
                                            else      -> DriveToggles(keystoreConf = true,  apiKeys = true,  normalYedek = true)
                                        }
                                        scope.launch {
                                            uploading = true
                                            status = "⏳ Yedekleniyor..."
                                            DriveUploadManager.syncByToggles(context, toggles) { status = it }
                                                .onSuccess { files ->
                                            val yuklenen = files.count { !it.startsWith("✓") }
                                            val atlanan  = files.count {  it.startsWith("✓") }
                                            status = when {
                                                yuklenen == 0 -> "✅ Tüm dosyalar zaten güncel"
                                                atlanan  == 0 -> "✅ $yuklenen dosya yedeklendi"
                                                else          -> "✅ $yuklenen yüklendi, $atlanan zaten günceldi"
                                            }
                                        }
                                                .onFailure { status = "❌ ${it.message}" }
                                            uploading = false
                                        }
                                    }
                                )
                            }
                        }
                    }

                    Button(
                        onClick = {
                            scope.launch {
                                uploading = true
                                status = "⏳ Geri yükleniyor..."
                                DriveUploadManager.restoreAll(context, "")  { status = it }
                                    .onSuccess { files -> status = "✅ ${files.size} dosya geri yüklendi" }
                                    .onFailure { status = "❌ ${it.message}" }
                                uploading = false
                            }
                        },
                        enabled = !uploading,
                        shape = RoundedCornerShape(8.dp),
                        colors = ButtonDefaults.buttonColors(containerColor = Color(0xFF1a73e8)),
                        contentPadding = PaddingValues(horizontal = 12.dp, vertical = 6.dp),
                        modifier = Modifier.height(32.dp)
                    ) { Text("Geri Yükle", fontSize = 11.sp) }

                    TextButton(
                        onClick = { DriveUploadManager.signOut(context); isSignedIn = false; autoBackup = false },
                        contentPadding = PaddingValues(horizontal = 8.dp, vertical = 6.dp),
                        modifier = Modifier.height(32.dp)
                    ) { Text("Çıkış", color = GREY, fontSize = 11.sp) }
                }
            }

            if (status.isNotEmpty()) {
                Text(status, color = if (status.startsWith("✅")) GREEN else if (status.startsWith("❌")) RED else GREY, fontSize = 11.sp)
            }
        }
    }
}


@Composable
fun SettingsSection(icon: String, title: String, subtitle: String, isOpen: Boolean,
                    onToggle: () -> Unit, content: @Composable () -> Unit) {
    Card(modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp),
        colors = CardDefaults.cardColors(containerColor = CARD),
        border = BorderStroke(1.dp, if (isOpen) ACCENT.copy(alpha = 0.3f) else BORDER),
        shape = RoundedCornerShape(14.dp)) {
        Column {
            Row(modifier = Modifier.fillMaxWidth().clickable { onToggle() }.padding(16.dp),
                verticalAlignment = Alignment.CenterVertically) {
                Text(icon, fontSize = 18.sp)
                Spacer(Modifier.width(10.dp))
                Column(modifier = Modifier.weight(1f)) {
                    Text(title, fontWeight = FontWeight.SemiBold, fontSize = 14.sp, color = WHITE)
                    Text(subtitle, fontSize = 11.sp, color = GREY)
                }
                Icon(if (isOpen) Icons.Default.ExpandLess else Icons.Default.ExpandMore,
                    null, tint = if (isOpen) ACCENT else GREY, modifier = Modifier.size(20.dp))
            }
            if (isOpen) { Divider(color = BORDER, thickness = 0.5.dp); content() }
        }
    }
}

@Composable
fun ApiKeyRow(api: ApiInfo, onSave: (String) -> Unit) {
    var editing by remember { mutableStateOf(false) }
    var keyText by remember { mutableStateOf("") }
    val icons = mapOf("claude" to "🤖","deepseek" to "🐳","gemini" to "♊","groq" to "⚡","openai" to "🟢","qwen" to "🌐")
    Column {
        Row(modifier = Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 10.dp),
            verticalAlignment = Alignment.CenterVertically) {
            Text(icons[api.name] ?: "🔑", fontSize = 16.sp)
            Spacer(Modifier.width(10.dp))
            Column(modifier = Modifier.weight(1f)) {
                Text(api.name.replaceFirstChar { it.uppercase() }, color = WHITE, fontSize = 13.sp, fontWeight = FontWeight.Medium)
                Text(if (api.hasKey) "✓ ${api.keyPreview}" else "Ayarlanmadı",
                    color = if (api.hasKey) GREEN else RED, fontSize = 11.sp)
            }
            IconButton(onClick = { editing = !editing }) {
                Icon(if (editing) Icons.Default.Close else Icons.Default.Edit, null, tint = GREY, modifier = Modifier.size(18.dp))
            }
        }
        if (editing) {
            Row(modifier = Modifier.padding(start = 14.dp, end = 14.dp, bottom = 10.dp),
                horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                OutlinedTextField(value = keyText, onValueChange = { keyText = it },
                    placeholder = { Text("API key...", fontSize = 11.sp) },
                    modifier = Modifier.weight(1f), shape = RoundedCornerShape(10.dp), singleLine = true,
                    colors = OutlinedTextFieldDefaults.colors(focusedBorderColor = ACCENT, unfocusedBorderColor = BORDER,
                        focusedTextColor = WHITE, unfocusedTextColor = WHITE, cursorColor = ACCENT,
                        focusedContainerColor = CARD, unfocusedContainerColor = CARD),
                    textStyle = androidx.compose.ui.text.TextStyle(fontSize = 11.sp))
                Button(onClick = { if (keyText.isNotBlank()) { onSave(keyText); editing = false; keyText = "" } },
                    shape = RoundedCornerShape(10.dp), colors = ButtonDefaults.buttonColors(containerColor = ACCENT),
                    contentPadding = PaddingValues(horizontal = 12.dp, vertical = 8.dp)) {
                    Text("Kaydet", fontSize = 12.sp)
                }
            }
        }
        Divider(color = BORDER.copy(alpha = 0.5f), thickness = 0.5.dp, modifier = Modifier.padding(horizontal = 14.dp))
    }
}

@Composable
fun ActionChip(icon: androidx.compose.ui.graphics.vector.ImageVector, label: String, color: Color, onClick: () -> Unit) {
    Surface(onClick = onClick, shape = RoundedCornerShape(20.dp), color = color.copy(alpha = 0.12f),
        border = BorderStroke(1.dp, color.copy(alpha = 0.25f))) {
        Row(modifier = Modifier.padding(horizontal = 10.dp, vertical = 5.dp), verticalAlignment = Alignment.CenterVertically) {
            Icon(icon, null, tint = color, modifier = Modifier.size(13.dp))
            Spacer(Modifier.width(4.dp))
            Text(label, color = color, fontSize = 11.sp, fontWeight = FontWeight.Medium)
        }
    }
}

@Composable
fun NewProjectDialog(onDismiss: () -> Unit, onCreate: (String, String, String) -> Unit) {
    var name by remember { mutableStateOf("") }
    var task by remember { mutableStateOf("") }
    var pkg  by remember { mutableStateOf("") }
    val nameValid = name.matches(Regex("^[a-z0-9][a-z0-9-]*$"))
    val nameError = when {
        name.isEmpty() -> ""
        name.any { it.isUpperCase() } -> "Uppercase not allowed — use lowercase"
        name.any { it == ' ' } -> "Spaces not allowed — use hyphens: my-app"
        name.any { !it.isLetterOrDigit() && it != '-' } -> "Special characters not allowed"
        !name[0].isLetterOrDigit() -> "Must start with a letter or digit"
        else -> ""
    }
    AlertDialog(onDismissRequest = onDismiss, containerColor = CARD, shape = RoundedCornerShape(16.dp),
        title = { Text("New Project", color = WHITE, fontWeight = FontWeight.Bold) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                OutlinedTextField(value = name, onValueChange = { name = it.lowercase().replace(" ", "-") },
                    label = { Text("Project Name  (e.g. my-calculator)", fontSize = 12.sp) }, singleLine = true,
                    isError = nameError.isNotEmpty(),
                    supportingText = { if (nameError.isNotEmpty()) Text(nameError, color = RED, fontSize = 10.sp) },
                    modifier = Modifier.fillMaxWidth(), shape = RoundedCornerShape(10.dp),
                    colors = OutlinedTextFieldDefaults.colors(focusedBorderColor = ACCENT, unfocusedBorderColor = BORDER,
                        focusedTextColor = WHITE, unfocusedTextColor = WHITE, cursorColor = ACCENT,
                        focusedContainerColor = SURFACE, unfocusedContainerColor = SURFACE))
                OutlinedTextField(value = pkg, onValueChange = { pkg = it },
                    label = { Text("Paket Adı  (boş bırakırsan otomatik)", fontSize = 12.sp) },
                    placeholder = { Text("com.sirketim.uygulamam", fontSize = 11.sp, color = GREY) },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth(), shape = RoundedCornerShape(10.dp),
                    colors = OutlinedTextFieldDefaults.colors(focusedBorderColor = ACCENT, unfocusedBorderColor = BORDER,
                        focusedTextColor = WHITE, unfocusedTextColor = WHITE, cursorColor = ACCENT,
                        focusedContainerColor = SURFACE, unfocusedContainerColor = SURFACE))
                OutlinedTextField(value = task, onValueChange = { task = it },
                    label = { Text("AI Görevi  (ne yapmasını istiyorsun?)", fontSize = 12.sp) },
                    placeholder = { Text("Bilimsel hesap makinesi yap, koyu tema olsun", fontSize = 11.sp, color = GREY) },
                    modifier = Modifier.fillMaxWidth().height(90.dp), shape = RoundedCornerShape(10.dp),
                    colors = OutlinedTextFieldDefaults.colors(focusedBorderColor = ACCENT, unfocusedBorderColor = BORDER,
                        focusedTextColor = WHITE, unfocusedTextColor = WHITE, cursorColor = ACCENT,
                        focusedContainerColor = SURFACE, unfocusedContainerColor = SURFACE))
            }
        },
        confirmButton = {
            Button(onClick = { if (nameValid && task.isNotBlank()) onCreate(name, task, pkg) },
                    enabled = nameValid && task.isNotBlank(),
                colors = ButtonDefaults.buttonColors(containerColor = ACCENT), shape = RoundedCornerShape(10.dp)) {
                Text("Oluştur")
            }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("İptal", color = GREY) } }
    )
}



@Composable
fun ProjectLogo(
    projectName: String, 
    modifier: Modifier = Modifier,
    fallbackIcon: androidx.compose.ui.graphics.vector.ImageVector = Icons.Default.Android,
    fallbackTint: androidx.compose.ui.graphics.Color = GREY
) {
    val path = "/storage/emulated/0/termux-otonom-sistem/logos/$projectName.png"
    val file = java.io.File(path)
    val lastModified = if (file.exists()) file.lastModified() else 0L

    val bitmap = remember(projectName, lastModified) {
        try {
            if (file.exists()) {
                android.graphics.BitmapFactory.decodeFile(file.absolutePath)?.asImageBitmap()
            } else null
        } catch (e: Exception) { null }
    }

    if (bitmap != null) {
        androidx.compose.foundation.Image(
            bitmap = bitmap,
            contentDescription = null,
            modifier = modifier.clip(RoundedCornerShape(8.dp)),
            contentScale = ContentScale.Crop
        )
    } else {
        Box(
            modifier = modifier
                .background(SURFACE, RoundedCornerShape(8.dp))
                .border(1.dp, BORDER, RoundedCornerShape(8.dp)),
            contentAlignment = Alignment.Center
        ) {
            Icon(
                imageVector = fallbackIcon, 
                contentDescription = null, 
                tint = fallbackTint.copy(0.5f), 
                modifier = Modifier.size(20.dp)
            )
        }
    }














}