#!/bin/bash
# ═══════════════════════════════════════════════════════════════
#  APK Factory — Tam Kurulum Scripti
#  Bu dosya uygulamanın assets/ klasöründe gömülü gelir.
#  Termux'a kopyalanıp çalıştırılır, gerisini kendisi halleder.
# ═══════════════════════════════════════════════════════════════

set +e

# ── Renkler ─────────────────────────────────────────────────────
G='\033[0;32m'; Y='\033[1;33m'; R='\033[0;31m'
C='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

ok()  { echo -e "${G}✅ $*${NC}";  echo "$(date '+%H:%M:%S') ✅ $*" >> "$LOG_FILE"; }
err() { echo -e "${R}❌ $*${NC}";  echo "$(date '+%H:%M:%S') ❌ $*" >> "$LOG_FILE"; }
log() { echo -e "${C}▶  $*${NC}";  echo "$(date '+%H:%M:%S') ▶  $*" >> "$LOG_FILE"; }

# ── Yollar ──────────────────────────────────────────────────────
SISTEM_DIR="/storage/emulated/0/termux-otonom-sistem"
PROMPTS_DIR="$SISTEM_DIR/prompts"
APILER_DIR="$SISTEM_DIR/apiler"
KEYSTORE_DIR="$SISTEM_DIR/keystores"
SETUP_DIR="$SISTEM_DIR/setup"
WS_DIR="$HOME/apk-factory-ws"
BASHRC="$HOME/.bashrc"

# LOG ve STATUS — uygulama tarafından izlenir
# (Uygulama bu değerleri kendi filesDir yoluyla değiştirecek)
LOG_FILE="/sdcard/Download/apkfactory_setup.log"
STATUS_FILE="/sdcard/Download/apkfactory_status.json"

# ── GitHub ──────────────────────────────────────────────────────
# NOT: Uygulama bu satırı kendi GITHUB_RAW değeriyle değiştirir
GITHUB_RAW="https://raw.githubusercontent.com/GITHUB_USER/GITHUB_REPO/main"

# ── Başlat ──────────────────────────────────────────────────────
mkdir -p "$(dirname "$LOG_FILE")"
echo "" > "$LOG_FILE"
echo '{"done":false,"step":"başlıyor"}' > "$STATUS_FILE"

echo -e "\n${BOLD}${C}════════════════════════════════${NC}"
echo -e "${BOLD}${C}  APK Factory Kurulum Başlıyor  ${NC}"
echo -e "${BOLD}${C}════════════════════════════════${NC}\n"

set_status() {
    echo "{\"done\":${1:-false},\"step\":\"$2\"}" > "$STATUS_FILE"
}

# ════════════════════════════════════════════════════════════════
# ADIM 1: Paket listesi güncelle
# ════════════════════════════════════════════════════════════════
log "Paket listesi güncelleniyor..."
set_status false "paketler"
pkg update -y -o Dpkg::Options::="--force-confnew" >> "$LOG_FILE" 2>&1
ok "Paket listesi güncellendi"

# ════════════════════════════════════════════════════════════════
# ADIM 2: Temel araçlar
# ════════════════════════════════════════════════════════════════
log "Temel araçlar kuruluyor..."
pkg install -y curl wget git unzip zip tar >> "$LOG_FILE" 2>&1
ok "Temel araçlar kuruldu"

# ════════════════════════════════════════════════════════════════
# ADIM 3: Python + WebSocket
# ════════════════════════════════════════════════════════════════
log "Python + WebSocket kuruluyor..."
set_status false "python"
pkg install -y python python-pip >> "$LOG_FILE" 2>&1
pip install websockets >> "$LOG_FILE" 2>&1
ok "Python + WebSocket hazır"

# ════════════════════════════════════════════════════════════════
# ADIM 4: Java (OpenJDK 17)
# ════════════════════════════════════════════════════════════════
log "Java (OpenJDK 17) kuruluyor..."
set_status false "java"
pkg install -y openjdk-17 >> "$LOG_FILE" 2>&1
ok "Java kuruldu"

# ════════════════════════════════════════════════════════════════
# ADIM 5: Android SDK
# ════════════════════════════════════════════════════════════════
log "Android SDK indiriliyor..."
set_status false "sdk"
SDK_DIR="$HOME/android-sdk"
CMDLINE_URL="https://dl.google.com/android/repository/commandlinetools-linux-9477386_latest.zip"

mkdir -p "$SDK_DIR/cmdline-tools"
wget -q "$CMDLINE_URL" -O /tmp/cmdtools.zip >> "$LOG_FILE" 2>&1
unzip -q /tmp/cmdtools.zip -d /tmp/cmdtools >> "$LOG_FILE" 2>&1
mv /tmp/cmdtools/cmdline-tools "$SDK_DIR/cmdline-tools/latest" 2>/dev/null || \
    mv /tmp/cmdtools/* "$SDK_DIR/cmdline-tools/latest" 2>/dev/null || true
rm -f /tmp/cmdtools.zip
ok "SDK araçları indirildi"

# ════════════════════════════════════════════════════════════════
# ADIM 6: Lisanslar
# ════════════════════════════════════════════════════════════════
log "Lisanslar kabul ediliyor..."
set_status false "lisanslar"
SDKMANAGER="$SDK_DIR/cmdline-tools/latest/bin/sdkmanager"
export ANDROID_SDK_ROOT="$SDK_DIR"
yes | "$SDKMANAGER" --licenses >> "$LOG_FILE" 2>&1
ok "Lisanslar kabul edildi"

# ════════════════════════════════════════════════════════════════
# ADIM 7: Build Tools
# ════════════════════════════════════════════════════════════════
log "Build Tools kuruluyor..."
set_status false "buildtools"
LATEST_BT=$("$SDKMANAGER" --list 2>/dev/null | grep "build-tools;" | grep -v "rc\|beta\|alpha" | tail -1 | awk '{print $1}' | tr -d ' ')
LATEST_PLAT=$("$SDKMANAGER" --list 2>/dev/null | grep "platforms;android-" | grep -v "rc\|beta\|alpha" | tail -1 | awk '{print $1}' | tr -d ' ')
[ -z "$LATEST_BT" ]   && LATEST_BT="build-tools;34.0.0"
[ -z "$LATEST_PLAT" ] && LATEST_PLAT="platforms;android-35"
"$SDKMANAGER" "$LATEST_BT" "$LATEST_PLAT" >> "$LOG_FILE" 2>&1
ok "Build Tools kuruldu"

# ════════════════════════════════════════════════════════════════
# ADIM 8: aapt2 düzelt
# Termux'ta SDK'nın kendi aapt2'si çalışmaz.
# Çözüm: Termux'un aapt2'sini kullan (gradle.properties ile).
# ════════════════════════════════════════════════════════════════
log "aapt2 düzeltiliyor..."
set_status false "aapt2"

# Termux aapt2'yi kur
pkg install -y aapt2 >> "$LOG_FILE" 2>&1 || pkg install -y aapt >> "$LOG_FILE" 2>&1

# Termux aapt2 yolunu kontrol et
TERMUX_AAPT2=$(which aapt2 2>/dev/null || echo "$PREFIX/bin/aapt2")

# Tüm mevcut projelerin gradle.properties'ine aapt2 override ekle
for gp in "$HOME"/*/gradle.properties; do
    [ -f "$gp" ] || continue
    if ! grep -q "aapt2FromMavenOverride" "$gp"; then
        echo "android.aapt2FromMavenOverride=$TERMUX_AAPT2" >> "$gp"
        echo "  ✅ aapt2 override → $(dirname $gp | xargs basename)" >> "$LOG_FILE"
    fi
done

# factory.sh'ın oluşturduğu yeni projelere de otomatik eklensin diye
# SISTEM_DIR'e şablon gradle.properties yaz
cat > "$SISTEM_DIR/setup/gradle.properties.template" << TMPL
android.useAndroidX=true
android.enableJetifier=true
android.aapt2FromMavenOverride=$TERMUX_AAPT2
org.gradle.jvmargs=-Xmx512m -XX:MaxMetaspaceSize=256m
org.gradle.daemon=false
TMPL

ok "aapt2 hazır"

# ════════════════════════════════════════════════════════════════
# ADIM 9: Factory scriptler — GitHub'dan indir
# ════════════════════════════════════════════════════════════════
log "Factory scriptler indiriliyor..."
set_status false "scriptler"

mkdir -p "$SISTEM_DIR" "$PROMPTS_DIR" "$APILER_DIR" "$KEYSTORE_DIR" "$SETUP_DIR"

# GitHub'dan scriptleri indir
download_file() {
    local url="$GITHUB_RAW/$1"
    local dest="$2"
    mkdir -p "$(dirname "$dest")"
    if curl -sf --max-time 30 "$url" -o "$dest"; then
        chmod +x "$dest" 2>/dev/null || true
        echo "  ✅ $(basename $dest)" >> "$LOG_FILE"
        return 0
    else
        echo "  ❌ $(basename $dest) indirilemedi: $url" >> "$LOG_FILE"
        return 1
    fi
}

# Ana scriptler
download_file "scripts/autofix.sh"  "$SISTEM_DIR/autofix.sh"
download_file "scripts/prj.sh"      "$SISTEM_DIR/prj.sh"
download_file "scripts/factory.sh"  "$SISTEM_DIR/factory.sh"
download_file "scripts/ws_bridge.py" "$WS_DIR/ws_bridge.py"

# Promptlar
download_file "prompts/autofix_system.txt" "$PROMPTS_DIR/autofix_system.txt"
download_file "prompts/autofix_task.txt"   "$PROMPTS_DIR/autofix_task.txt"

# Versiyon dosyası
curl -sf --max-time 10 "$GITHUB_RAW/version.json" -o "$SISTEM_DIR/prompt_version_remote.json" 2>/dev/null || true
if [ -f "$SISTEM_DIR/prompt_version_remote.json" ]; then
    python3 -c "
import json
d = json.load(open('$SISTEM_DIR/prompt_version_remote.json'))
open('$SISTEM_DIR/prompt_version.txt','w').write(d.get('prompt_version','1.0'))
" 2>/dev/null || true
fi

ok "Factory scriptler hazır"

# ════════════════════════════════════════════════════════════════
# ADIM 10: Gradle wrapper indir
# ════════════════════════════════════════════════════════════════
log "Gradle wrapper hazırlanıyor..."
GRADLE_VER="8.2"
SETUP_DIR="$SISTEM_DIR/setup"

mkdir -p "$SETUP_DIR/gradle/wrapper"

# gradlew — senin Termux'undakiyle birebir aynı
cat > "$SETUP_DIR/gradlew" << 'GRADLEW'
#!/bin/sh
APP_HOME=`pwd -P`
CLASSPATH=$APP_HOME/gradle/wrapper/gradle-wrapper.jar
exec java -classpath "$CLASSPATH" org.gradle.wrapper.GradleWrapperMain "$@"
GRADLEW
chmod +x "$SETUP_DIR/gradlew"

# gradle-wrapper.properties
cat > "$SETUP_DIR/gradle/wrapper/gradle-wrapper.properties" << PROPS
distributionBase=GRADLE_USER_HOME
distributionPath=wrapper/dists
distributionUrl=https\://services.gradle.org/distributions/gradle-${GRADLE_VER}-bin.zip
zipStoreBase=GRADLE_USER_HOME
zipStorePath=wrapper/dists
PROPS

# gradle-wrapper.jar — GitHub'dan indir (base64 değil, raw binary)
if [ ! -f "$SETUP_DIR/gradle/wrapper/gradle-wrapper.jar" ]; then
    log "gradle-wrapper.jar indiriliyor..."
    curl -sf --max-time 60 \
        "https://raw.githubusercontent.com/hakanerbasss/apk-factory-assets/main/setup/gradle-wrapper.jar" \
        -o "$SETUP_DIR/gradle/wrapper/gradle-wrapper.jar" >> "$LOG_FILE" 2>&1
    # Yoksa Gradle dağıtımından çıkar
    if [ ! -s "$SETUP_DIR/gradle/wrapper/gradle-wrapper.jar" ]; then
        warn "gradle-wrapper.jar GitHub'dan alınamadı — Gradle dağıtımından çıkarılacak"
        GRADLE_ZIP="/tmp/gradle-${GRADLE_VER}-bin.zip"
        wget -q "https://services.gradle.org/distributions/gradle-${GRADLE_VER}-bin.zip" \
            -O "$GRADLE_ZIP" >> "$LOG_FILE" 2>&1
        unzip -p "$GRADLE_ZIP" \
            "gradle-${GRADLE_VER}/lib/gradle-wrapper-*.jar" \
            > "$SETUP_DIR/gradle/wrapper/gradle-wrapper.jar" 2>/dev/null || \
        unzip -j "$GRADLE_ZIP" \
            "gradle-${GRADLE_VER}/lib/gradle-launcher-*.jar" \
            -d "$SETUP_DIR/gradle/wrapper/" >> "$LOG_FILE" 2>&1
        rm -f "$GRADLE_ZIP"
    fi
fi

ok "Gradle wrapper hazır"

# ════════════════════════════════════════════════════════════════
# ADIM 11: Alias'lar ve .bashrc
# ════════════════════════════════════════════════════════════════
log "Alias'lar ekleniyor..."

# Eski alias'ları temizle
grep -v "alias prj=\|alias autofix=\|alias factory=\|alias af=" "$BASHRC" > "$HOME/.bashrc_clean" 2>/dev/null
cp "$HOME/.bashrc_clean" "$BASHRC" 2>/dev/null || true
rm -f "$HOME/.bashrc_clean"

cat >> "$BASHRC" << ALIASES

# APK Factory
alias prj='bash $SISTEM_DIR/prj.sh'
alias autofix='bash $SISTEM_DIR/autofix.sh'
alias factory='bash $SISTEM_DIR/factory.sh'
alias af='bash $SISTEM_DIR/autofix.sh'
ALIASES

# projeler.conf yoksa oluştur
[ ! -f "$SISTEM_DIR/projeler.conf" ] && touch "$SISTEM_DIR/projeler.conf"

ok "Alias'lar eklendi"

# ════════════════════════════════════════════════════════════════
# ADIM 12: WebSocket bridge'i başlat
# ════════════════════════════════════════════════════════════════
log "WebSocket sunucusu başlatılıyor..."
set_status false "websocket"

mkdir -p "$WS_DIR"

# ws_bridge.py indirilemediyse basit bir versiyon oluştur
if [ ! -f "$WS_DIR/ws_bridge.py" ]; then
    cat > "$WS_DIR/ws_bridge.py" << 'PYEOF'
import asyncio, websockets, json, subprocess, os

SISTEM_DIR = "/storage/emulated/0/termux-otonom-sistem"

async def handler(websocket):
    await websocket.send(json.dumps({"type":"connected","text":"APK Factory bağlandı"}))
    async for message in websocket:
        try:
            msg = json.loads(message)
            t = msg.get("type","")
            if t == "list_projects":
                conf = os.path.join(SISTEM_DIR,"projeler.conf")
                projects = []
                if os.path.exists(conf):
                    for line in open(conf):
                        line=line.strip()
                        if not line or line.startswith("#"): continue
                        parts=line.split("|")
                        if len(parts)>=2:
                            projects.append({"name":parts[0],"package":parts[5] if len(parts)>5 else ""})
                await websocket.send(json.dumps({"type":"projects","data":projects}))
        except Exception as e:
            await websocket.send(json.dumps({"type":"error","text":str(e)}))

async def main():
    async with websockets.serve(handler,"127.0.0.1",8765):
        await asyncio.Future()

asyncio.run(main())
PYEOF
fi

# Eski bridge'i öldür
pkill -f ws_bridge.py 2>/dev/null || true
sleep 1

# Termux:Boot klasörüne dayanıklı start script yaz
BOOT_DIR="$HOME/.termux/boot"
mkdir -p "$BOOT_DIR"

cat > "$BOOT_DIR/start_ws_bridge.sh" << 'BOOT'
#!/bin/bash
# APK Factory — Dayanıklı WS Bridge Başlatıcı
# Her telefon açılışında çalışır, eksikleri onarır

GITHUB_RAW="https://raw.githubusercontent.com/hakanerbasss/apk-factory-assets/main"
WS_DIR="$HOME/apk-factory-ws"
WS_FILE="$WS_DIR/ws_bridge.py"
SISTEM_DIR="/storage/emulated/0/termux-otonom-sistem"
PROMPTS_DIR="$SISTEM_DIR/prompts"
APILER_DIR="$SISTEM_DIR/apiler"

sleep 3

# 1. Klasörleri oluştur
mkdir -p "$WS_DIR" "$SISTEM_DIR" "$PROMPTS_DIR" "$APILER_DIR"          "$SISTEM_DIR/keystores" "$SISTEM_DIR/setup/gradle/wrapper"

# 2. projeler.conf yoksa oluştur
[ ! -f "$SISTEM_DIR/projeler.conf" ] && touch "$SISTEM_DIR/projeler.conf"

# 3. websockets modülü kontrol + kur
python3 -c "import websockets" 2>/dev/null || {
    pkg install -y python python-pip 2>/dev/null
    pip install websockets 2>/dev/null
}

# 4. ws_bridge.py yoksa GitHub'dan indir
if [ ! -f "$WS_FILE" ]; then
    curl -sf --max-time 30 "$GITHUB_RAW/scripts/ws_bridge.py" -o "$WS_FILE" || true
fi

# 5. Scriptler eksikse indir
for script in autofix.sh prj.sh factory.sh; do
    if [ ! -f "$SISTEM_DIR/$script" ]; then
        curl -sf --max-time 30 "$GITHUB_RAW/scripts/$script" -o "$SISTEM_DIR/$script" &&             chmod +x "$SISTEM_DIR/$script" || true
    fi
done

# 6. gradle-wrapper.jar yoksa setup'tan kopyala
WRAPPER="$SISTEM_DIR/setup/gradle/wrapper/gradle-wrapper.jar"
if [ ! -f "$WRAPPER" ]; then
    curl -sf --max-time 30 "$GITHUB_RAW/setup/gradle/wrapper/gradle-wrapper.jar" -o "$WRAPPER" || true
fi

# 7. Eski bridge'i öldür ve yeniden başlat
pkill -f ws_bridge.py 2>/dev/null || true
sleep 1

if [ -f "$WS_FILE" ]; then
    nohup python3 "$WS_FILE" >> "$WS_DIR/ws_bridge.log" 2>&1 &
fi
BOOT
chmod +x "$BOOT_DIR/start_ws_bridge.sh"

# Şimdi de çalıştır (boot bekleme olmadan)
pkill -f ws_bridge.py 2>/dev/null || true
sleep 1
nohup python3 "$WS_DIR/ws_bridge.py" >> "$WS_DIR/ws_bridge.log" 2>&1 &
sleep 2

if pgrep -f ws_bridge.py > /dev/null; then
    ok "WebSocket bridge başlatıldı"
else
    err "WebSocket bridge başlatılamadı — boot script telefon yeniden başlatılınca dener"
fi

# ════════════════════════════════════════════════════════════════
# BİTİŞ
# ════════════════════════════════════════════════════════════════
echo ""
echo -e "${BOLD}${G}════════════════════════════════${NC}"
echo -e "${BOLD}${G}  ✅ KURULUM TAMAMLANDI!         ${NC}"
echo -e "${BOLD}${G}════════════════════════════════${NC}"
echo ""
echo -e "${DIM}Yüklenen scriptler:${NC}"
echo -e "  ${G}autofix${NC}  → AI build düzeltici"
echo -e "  ${G}prj${NC}      → Proje kısayolları"
echo -e "  ${G}factory${NC}  → Yeni proje oluştur"
echo ""
echo -e "${DIM}Şimdi yapabilirsin:${NC}"
echo -e "  ${C}source ~/.bashrc${NC}  → alias'ları aktif et"
echo -e "  ${C}factory${NC}           → yeni proje oluştur"
echo ""

set_status true "tamamlandı"
