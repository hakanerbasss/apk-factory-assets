#!/bin/bash
# ══════════════════════════════════════════════════════════════════════════
# AI APK FABRİKASI — Otonom Proje Üretici
# ══════════════════════════════════════════════════════════════════════════

set +e
G='\033[0;32m'; Y='\033[1;33m'; B='\033[0;34m'; R='\033[0;31m'
C='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

SISTEM_DIR="/storage/emulated/0/termux-otonom-sistem"
CONF_FILE="$SISTEM_DIR/projeler.conf"
SETUP_DIR="$SISTEM_DIR/setup"
KEYSTORE_DIR="$SISTEM_DIR/keystores"


# 🛠️ KENDİ KENDİNİ ONARMA (Klasör silinmişse kurtar)
if [ ! -f "$SETUP_DIR/gradlew" ]; then
    echo -e "${Y}⚠️ Kritik bileşenler (setup) eksik! Otomatik kurtarma başlatılıyor...${NC}"
    GITHUB_RAW="https://raw.githubusercontent.com/hakanerbasss/apk-factory-assets/main"
    curl -sf "$GITHUB_RAW/setup.zip" -o "$SISTEM_DIR/setup.zip"
    if [ -f "$SISTEM_DIR/setup.zip" ]; then
        unzip -qo "$SISTEM_DIR/setup.zip" -d "$SISTEM_DIR/"
        rm -f "$SISTEM_DIR/setup.zip"
        echo -e "${G}✅ Eksik dosyalar başarıyla geri getirildi.${NC}"
    else
        echo -e "${R}❌ Kurtarma başarısız! Lütfen internet bağlantınızı kontrol edin.${NC}"
        exit 1
    fi
fi




echo -e "\n${BOLD}${B}╔══════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${B}║   🤖 OTONOM APK FABRİKASI               ║${NC}"
echo -e "${BOLD}${B}╚══════════════════════════════════════════╝${NC}\n"

# 1. GİRDİLERİ AL
read -p "$(echo -e "${C}Proje Adı (örn: hesap-makinesi): ${NC}")" P_NAME
P_NAME=$(python3 -c "import re,sys; s=sys.argv[1].lower().replace(' ','-'); print(re.sub(r'[^a-z0-9-]','',s))" "$P_NAME")
if [ -z "$P_NAME" ]; then echo -e "${R}Proje adı boş olamaz!${NC}"; exit 1; fi

P_DIR="$HOME/$P_NAME"
if [[ -d "$P_DIR" ]]; then
    echo -e "${R}❌ '$P_NAME' klasörü zaten var! Farklı isim deneyin.${NC}"
    sed -i "/^${P_NAME}|/d" "$CONF_FILE" 2>/dev/null
    exit 1
fi
if [ -d "$P_DIR" ]; then echo -e "${R}Bu isimde bir klasör zaten var!${NC}"; exit 1; fi

echo ""
read -p "$(echo -e "${Y}Yapay Zekaya Görevi Ver (Örn: Bilimsel hesap makinesi yap, koyu tema olsun): ${NC}\n→ ")" AI_PROMPT
if [ -z "$AI_PROMPT" ]; then echo -e "${R}Görev boş olamaz!${NC}"; exit 1; fi

# 2. OTOMATİK DEĞİŞKENLER (Arka planda uydurulur)
# Tireleri tamamen silerek wizaicorp paket adını oluştur (Sıfır Hata)
P_PKG="${PKG_OVERRIDE:-com.wizaicorp.$(echo $P_NAME | tr -d '-' | tr -d '_' | sed 's/^[0-9]/app&/')}"

# --- YENİ: KEYSTORE ŞİFRESİNİ AYARLARDAN ÇEK ---
SAVED_PASS=$(grep "^KEYSTORE_PASS=" ~/.config/autofix.conf 2>/dev/null | cut -d= -f2 | tr -d '"')
if [[ -n "$SAVED_PASS" ]]; then
    KS_PASS="$SAVED_PASS"
else
    # 1. Komutu bir alt kabukta çalıştırıp durumu dışarı sızdırıyoruz
    KS_PASS_RAW=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 12; exit ${PIPESTATUS[0]})
    STATUS=$? # tr komutunun (ilk boğumun) çıkış kodunu yakaladık

    if [ "$STATUS" -eq 141 ]; then
        echo -e "${Y}[DEBUG] 🛠️ Boru [FACTORY-Keystore] hattında kırıldı (Beklenen durum).${NC}"
    fi

    KS_PASS=$KS_PASS_RAW

#    KS_PASS=$(tr -dc 'a-zA-Z0-9' < /dev/urandom 2>/dev/null | head -c 12)
#    KS_PASS="KumsalTest123"
fi
# ------------------------------------------------
KS_ALIAS=$(python3 -c "import sys; s=sys.argv[1].replace('-',''); s=('app'+s) if s and s[0].isdigit() else s; print(s[:12])" "$P_NAME")
KS_FILE="${P_NAME}-release.keystore"

echo -e "\n${DIM}⚙️ Altyapı saniyeler içinde kuruluyor...${NC}"

# 3. KLASÖR SKELETON'U OLUŞTUR
SRC_PATH="$P_DIR/app/src/main/java/$(echo $P_PKG | tr '.' '/')"
RES_PATH="$P_DIR/app/src/main/res"
mkdir -p "$SRC_PATH" "$RES_PATH/values" "$RES_PATH/mipmap-mdpi" "$P_DIR/gradle/wrapper"

# AndroidManifest.xml
cat > "$P_DIR/app/src/main/AndroidManifest.xml" << XML
<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
    <uses-permission android:name="android.permission.VIBRATE" />
    <application android:allowBackup="true" android:label="$P_NAME" android:theme="@android:style/Theme.Material.Light.NoActionBar">
        <activity android:name=".MainActivity" android:exported="true">
            <intent-filter>
                <action android:name="android.intent.action.MAIN" />
                <category android:name="android.intent.category.LAUNCHER" />
            </intent-filter>
        </activity>
    </application>
</manifest>
XML

# MainActivity.kt (Boş Compose Şablonu - AI burayı dolduracak)
cat > "$SRC_PATH/MainActivity.kt" << KOTLIN
package $P_PKG
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.ui.Modifier

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent {
            MaterialTheme {
                Surface(
                    modifier = Modifier.fillMaxSize(),
                    color = MaterialTheme.colorScheme.background
                ) {
                    Box(modifier = Modifier.systemBarsPadding()) {
                        Text("AI Kodluyor...")
                    }
                }
            }
        }
    }
}
KOTLIN


# Build Gradle Dosyaları
cat > "$P_DIR/app/build.gradle" << GRADLE
plugins { id 'com.android.application'; id 'org.jetbrains.kotlin.android' }
android {
    namespace '$P_PKG'
    compileSdk 35
    defaultConfig { applicationId "$P_PKG"; minSdk 26; targetSdk 35; versionCode 1; versionName "1.0" }
    compileOptions { sourceCompatibility JavaVersion.VERSION_1_8; targetCompatibility JavaVersion.VERSION_1_8 }
    kotlinOptions { jvmTarget = '1.8' }
    buildFeatures { compose true }
    composeOptions { kotlinCompilerExtensionVersion '1.5.8' }
}
dependencies {
    implementation platform('androidx.compose:compose-bom:2024.02.00')
    implementation 'androidx.compose.ui:ui'
    implementation 'androidx.compose.material3:material3'
    implementation 'androidx.compose.material:material-icons-extended'
    implementation 'androidx.lifecycle:lifecycle-viewmodel-compose:2.7.0'
    implementation 'androidx.lifecycle:lifecycle-runtime-ktx:2.7.0'
    implementation 'androidx.compose.ui:ui-tooling-preview'
    debugImplementation 'androidx.compose.ui:ui-tooling'
    implementation 'androidx.activity:activity-compose:1.8.2'
}
GRADLE

cat > "$P_DIR/build.gradle" << GRADLE
plugins { id 'com.android.application' version '8.2.2' apply false; id 'org.jetbrains.kotlin.android' version '1.9.22' apply false }
GRADLE

cat > "$P_DIR/settings.gradle" << GRADLE
pluginManagement { repositories { google(); mavenCentral(); gradlePluginPortal() } }
dependencyResolutionManagement { repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS); repositories { google(); mavenCentral() } }
rootProject.name = "$P_NAME"
include ':app'
GRADLE

echo "android.useAndroidX=true
android.aapt2FromMavenOverride=/data/data/com.termux/files/usr/bin/aapt2
org.gradle.jvmargs=-Xmx512m -XX:MaxMetaspaceSize=256m" > "$P_DIR/gradle.properties"

echo "sdk.dir=/data/data/com.termux/files/home/android-sdk" > "$P_DIR/local.properties"

# Gradle Wrapper Kopyala
cp "$SETUP_DIR/gradlew" "$P_DIR/gradlew" 2>/dev/null || true
cp "$SETUP_DIR/gradle/wrapper/gradle-wrapper.jar" "$P_DIR/gradle/wrapper/" 2>/dev/null || true
cp "$SETUP_DIR/gradle/wrapper/gradle-wrapper.properties" "$P_DIR/gradle/wrapper/" 2>/dev/null || true
chmod +x "$P_DIR/gradlew"

# 4. KEYSTORE OLUŞTUR
keytool -genkeypair -keystore "$KEYSTORE_DIR/$KS_FILE" -alias "$KS_ALIAS" -keyalg RSA -keysize 2048 -validity 10000 -storepass "$KS_PASS" -keypass "$KS_PASS" -dname "CN=$P_NAME, OU=AI, O=AI, L=IST, S=IST, C=TR" 2>/dev/null

# 5. PROJELER.CONF'A EKLE
echo "$P_NAME|~/$P_NAME|$KS_FILE|$KS_ALIAS|$KS_PASS|$P_PKG" >> "$CONF_FILE"

echo -e "${G}✅ Altyapı hazır! Görev yapay zekaya devrediliyor...${NC}\n"

# 6. AUTOFIX AI SİSTEMİNİ TETİKLE
PROMPT_FULL="$AI_PROMPT. ÖNEMLİ: Tema için sadece MaterialTheme kullan, özel tema sınıfı oluşturma. Eğer görev oyun veya animasyon içeriyorsa Canvas API kullan, normal uygulama ise Jetpack Compose UI kullan."
