package com.wizaicorp.apkfactory.data

import android.content.Context
import android.content.Intent
import androidx.activity.result.ActivityResultLauncher
import com.google.android.gms.auth.api.signin.GoogleSignIn
import com.google.android.gms.auth.api.signin.GoogleSignInAccount
import com.google.android.gms.auth.api.signin.GoogleSignInClient
import com.google.android.gms.auth.api.signin.GoogleSignInOptions
import com.google.android.gms.common.api.Scope
import com.google.api.client.googleapis.extensions.android.gms.auth.GoogleAccountCredential
import com.google.api.client.http.javanet.NetHttpTransport
import com.google.api.client.json.gson.GsonFactory
import com.google.api.services.drive.Drive
import com.google.api.services.drive.DriveScopes
import com.google.api.services.drive.model.File as DriveFile
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.FileInputStream
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

data class DriveFolder(val id: String, val name: String)

data class DriveToggles(
    val keystoreConf: Boolean = false,
    val apiKeys: Boolean = false,
    val normalYedek: Boolean = false
)

object DriveUploadManager {

    private const val CLIENT_ID = "948452396802-2i2ta0lcglcbfrqkvhjt4np02o41r0rv.apps.googleusercontent.com"

    private const val ROOT_FOLDER       = "APKFactory"
    private const val SUB_KEYSTORE_CONF = "keystore-conf"
    private const val SUB_API_KEYS      = "api-keys"
    private const val SUB_YEDEKLER      = "yedekler"

    private const val SISTEM_DIR = "/storage/emulated/0/termux-otonom-sistem"

    // ─── Auth ──────────────────────────────────────────────────────────────

    fun getSignInClient(context: Context): GoogleSignInClient {
        val options = GoogleSignInOptions.Builder(GoogleSignInOptions.DEFAULT_SIGN_IN)
            .requestEmail()
            .requestScopes(Scope(DriveScopes.DRIVE_FILE))
            .build()
        return GoogleSignIn.getClient(context, options)
    }

    fun getSignedInAccount(context: Context): GoogleSignInAccount? =
        GoogleSignIn.getLastSignedInAccount(context)

    fun isSignedIn(context: Context): Boolean {
        val account = getSignedInAccount(context) ?: return false
        return GoogleSignIn.hasPermissions(account, Scope(DriveScopes.DRIVE_FILE))
    }

    fun signIn(launcher: ActivityResultLauncher<Intent>, context: Context) {
        launcher.launch(getSignInClient(context).signInIntent)
    }

    fun signOut(context: Context) {
        getSignInClient(context).signOut()
    }

    // ─── Drive bağlantısı ──────────────────────────────────────────────────

    private fun buildDrive(context: Context): Drive {
        val account = getSignedInAccount(context)
            ?: throw Exception("Google hesabına giriş yapılmamış")
        val credential = GoogleAccountCredential.usingOAuth2(
            context, listOf(DriveScopes.DRIVE_FILE)
        ).apply { selectedAccount = account.account }
        return Drive.Builder(NetHttpTransport(), GsonFactory.getDefaultInstance(), credential)
            .setApplicationName("APK Factory").build()
    }

    // ─── Klasör yönetimi ───────────────────────────────────────────────────

    private fun getOrCreateFolder(drive: Drive, name: String, parentId: String): String {
        val q = "name='$name' and mimeType='application/vnd.google-apps.folder' " +
                "and '$parentId' in parents and trashed=false"
        val existing = drive.files().list().setQ(q).setFields("files(id)").execute()
        return existing.files?.firstOrNull()?.id ?: run {
            val meta = DriveFile().apply {
                this.name = name
                mimeType = "application/vnd.google-apps.folder"
                parents = listOf(parentId)
            }
            drive.files().create(meta).setFields("id").execute().id
        }
    }

    // ─── Yükleme yardımcıları ──────────────────────────────────────────────

    /**
     * Akıllı yükleme: Drive'da aynı isim + aynı boyut varsa atla.
     * Farklıysa eskiyi sil, yenisini yükle.
     * Keystore, conf, api-keys için kullanılır.
     */
    private fun uploadIfChanged(
        drive: Drive,
        localFile: java.io.File,
        folderId: String,
        onProgress: (Int) -> Unit = {}
    ): String {
        val q = "name='${localFile.name}' and '$folderId' in parents and trashed=false"
        val existing = drive.files().list()
            .setQ(q).setFields("files(id, size)").execute().files

        val driveSize = existing?.firstOrNull()?.getSize()
        if (driveSize != null && driveSize == localFile.length()) {
            onProgress(100)
            return "✓ ${localFile.name} (değişmedi)"
        }

        existing?.forEach { drive.files().delete(it.id).execute() }
        onProgress(30)
        val meta = DriveFile().apply {
            name = localFile.name
            parents = listOf(folderId)
        }
        val media = com.google.api.client.http.InputStreamContent(
            getMimeType(localFile.name), FileInputStream(localFile)
        ).apply { length = localFile.length() }
        onProgress(70)
        drive.files().create(meta, media).setFields("id, name").execute()
        onProgress(100)
        return localFile.name
    }

    /**
     * Yedekler için: Drive'da aynı isim varsa atla (timestamp zaten unique).
     * Yoksa yükle.
     */
    private fun uploadIfNotExists(
        drive: Drive,
        localFile: java.io.File,
        folderId: String,
        onProgress: (Int) -> Unit = {}
    ): String {
        val q = "name='${localFile.name}' and '$folderId' in parents and trashed=false"
        val exists = drive.files().list()
            .setQ(q).setFields("files(id)").execute().files?.isNotEmpty() == true

        if (exists) {
            onProgress(100)
            return "✓ ${localFile.name} (zaten var)"
        }

        onProgress(30)
        val meta = DriveFile().apply {
            name = localFile.name
            parents = listOf(folderId)
        }
        val media = com.google.api.client.http.InputStreamContent(
            getMimeType(localFile.name), FileInputStream(localFile)
        ).apply { length = localFile.length() }
        onProgress(70)
        drive.files().create(meta, media).setFields("id, name").execute()
        onProgress(100)
        return localFile.name
    }

    // ─── Toggle bazlı ana yükleme ──────────────────────────────────────────

    suspend fun syncByToggles(
        context: Context,
        toggles: DriveToggles,
        yedekDosyalari: List<java.io.File> = emptyList(),
        projectName: String = "genel",
        onProgress: (String) -> Unit = {}
    ): Result<List<String>> = withContext(Dispatchers.IO) {
        runCatching {
            val drive = buildDrive(context)
            val uploaded = mutableListOf<String>()

            // 🔑 Keystore & projeler.conf
            if (toggles.keystoreConf) {
                val rootId   = getOrCreateFolder(drive, ROOT_FOLDER, "root")
                val folderId = getOrCreateFolder(drive, SUB_KEYSTORE_CONF, rootId)

                val keystoreDir = java.io.File("$SISTEM_DIR/keystores").also { it.mkdirs() }
                keystoreDir.listFiles()
                    ?.filter { it.name.endsWith(".keystore") || it.name.endsWith(".jks") }
                    ?.forEach { ks ->
                        onProgress("⏳ ${ks.name} kontrol ediliyor...")
                        uploaded += uploadIfChanged(drive, ks, folderId)
                    }

                val conf = java.io.File("$SISTEM_DIR/projeler.conf")
                if (conf.exists()) {
                    onProgress("⏳ projeler.conf kontrol ediliyor...")
                    uploaded += uploadIfChanged(drive, conf, folderId)
                }
            }

            // 🔐 API key'ler
            if (toggles.apiKeys) {
                val rootId   = getOrCreateFolder(drive, ROOT_FOLDER, "root")
                val folderId = getOrCreateFolder(drive, SUB_API_KEYS, rootId)

                val apilerDir = java.io.File("$SISTEM_DIR/apiler").also { it.mkdirs() }
                apilerDir.listFiles()
                    ?.filter { it.name.endsWith(".conf") }
                    ?.forEach { apiConf ->
                        onProgress("⏳ ${apiConf.name} kontrol ediliyor...")
                        uploaded += uploadIfChanged(drive, apiConf, folderId)
                    }
            }

            // 💾 Normal yedekler (sadece -yedek.tar.gz, -hizli ve -tam atlanır)
            if (toggles.normalYedek && yedekDosyalari.isNotEmpty()) {
                val rootId     = getOrCreateFolder(drive, ROOT_FOLDER, "root")
                val yedeklerId = getOrCreateFolder(drive, SUB_YEDEKLER, rootId)

                yedekDosyalari
                    .filter { it.name.endsWith("-yedek.tar.gz") }
                    .forEach { dosya ->
                        val projAdi = dosya.name.split("-202").firstOrNull() ?: projectName
                        val folderId = getOrCreateFolder(drive, projAdi, yedeklerId)
                        onProgress("⏳ ${dosya.name} kontrol ediliyor...")
                        // Timestamp'li isim → Drive'da varsa atla, yoksa yükle
                        uploaded += uploadIfNotExists(drive, dosya, folderId)
                    }
            }

            uploaded
        }
    }

    // ─── Geri yükleme ──────────────────────────────────────────────────────

    suspend fun restoreAll(
        context: Context,
        projectName: String = "",          // boş → tüm projelerin yedekleri
        onProgress: (String) -> Unit = {}
    ): Result<List<String>> = withContext(Dispatchers.IO) {
        runCatching {
            listOf(
                SISTEM_DIR,
                "$SISTEM_DIR/keystores",
                "$SISTEM_DIR/prompts",
                "$SISTEM_DIR/apiler",
                "$SISTEM_DIR/yedekler",
                "$SISTEM_DIR/setup/gradle/wrapper"
            ).forEach { java.io.File(it).mkdirs() }

            val drive    = buildDrive(context)
            val rootId   = getOrCreateFolder(drive, ROOT_FOLDER, "root")
            val restored = mutableListOf<String>()

            // 🔑 keystore-conf → SISTEM_DIR/keystores/ + projeler.conf
            val kcFolderId = getOrCreateFolder(drive, SUB_KEYSTORE_CONF, rootId)
            drive.files().list()
                .setQ("'$kcFolderId' in parents and trashed=false")
                .setFields("files(id, name)").execute().files
                ?.forEach { f ->
                    val dest = when {
                        f.name == "projeler.conf"                                -> "$SISTEM_DIR/projeler.conf"
                        f.name.endsWith(".keystore") || f.name.endsWith(".jks") -> "$SISTEM_DIR/keystores/${f.name}"
                        else -> null
                    }
                    if (dest != null) {
                        onProgress("⏳ ${f.name} indiriliyor...")
                        drive.files().get(f.id)
                            .executeMediaAndDownloadTo(java.io.File(dest).outputStream())
                        restored += f.name
                    }
                }

            // 🔐 api-keys → SISTEM_DIR/apiler/
            val apiFolderId = getOrCreateFolder(drive, SUB_API_KEYS, rootId)
            drive.files().list()
                .setQ("'$apiFolderId' in parents and trashed=false")
                .setFields("files(id, name)").execute().files
                ?.forEach { f ->
                    if (f.name.endsWith(".conf")) {
                        onProgress("⏳ ${f.name} indiriliyor...")
                        drive.files().get(f.id)
                            .executeMediaAndDownloadTo(
                                java.io.File("$SISTEM_DIR/apiler/${f.name}").outputStream()
                            )
                        restored += f.name
                    }
                }

            // 💾 yedekler → SISTEM_DIR/yedekler/
            // ws_bridge zaten buradan okuyup tar -xzf ile açıyor
            val yedeklerId = getOrCreateFolder(drive, SUB_YEDEKLER, rootId)

            // projectName verilmişse sadece o projenin alt klasörü, yoksa tüm alt klasörler
            val projectFolders = drive.files().list()
                .setQ("'$yedeklerId' in parents and mimeType='application/vnd.google-apps.folder' and trashed=false")
                .setFields("files(id, name)").execute().files ?: emptyList()

            projectFolders
                .filter { f -> projectName.isEmpty() || f.name == projectName }
                .forEach { folder ->
                    val tarFiles = drive.files().list()
                        .setQ("'${folder.id}' in parents and trashed=false")
                        .setFields("files(id, name)").execute().files ?: emptyList()

                    tarFiles
                        .filter { it.name.endsWith(".tar.gz") }
                        .forEach { f ->
                            val dest = java.io.File("$SISTEM_DIR/yedekler/${f.name}")
                            if (!dest.exists()) {   // zaten varsa tekrar indirme
                                onProgress("⏳ ${f.name} indiriliyor...")
                                drive.files().get(f.id)
                                    .executeMediaAndDownloadTo(dest.outputStream())
                                restored += f.name
                            } else {
                                onProgress("✓ ${f.name} zaten var, atlandı")
                            }
                        }
                }

            restored
        }
    }

    // ─── Eski uyumluluk: tekil dosya yükle ────────────────────────────────

    suspend fun uploadFile(
        context: Context,
        filePath: String,
        onProgress: (Int) -> Unit = {}
    ): Result<String> = withContext(Dispatchers.IO) {
        runCatching {
            val drive    = buildDrive(context)
            val rootId   = getOrCreateFolder(drive, ROOT_FOLDER, "root")
            val folderId = getOrCreateFolder(drive, SUB_YEDEKLER, rootId)
            uploadIfNotExists(drive, java.io.File(filePath), folderId, onProgress)
        }
    }

    // ─── Yardımcı ──────────────────────────────────────────────────────────

    private fun getMimeType(path: String): String =
        when (path.substringAfterLast('.').lowercase()) {
            "keystore", "jks" -> "application/octet-stream"
            "txt", "conf"     -> "text/plain"
            "zip"             -> "application/zip"
            else              -> "application/octet-stream"
        }
}
