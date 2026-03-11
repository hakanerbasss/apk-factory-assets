#!/bin/bash
# ═══════════════════════════════════════════════════════
#  APK Factory — Tam Kurulum Scripti
#  Bootstrap tarafından indirilip çalıştırılır.
# ═══════════════════════════════════════════════════════

GITHUB_RAW="https://raw.githubusercontent.com/hakanerbasss/apk-factory-assets/main"
LOG_FILE="/sdcard/apkfactory_setup.log"
STATUS_FILE="/sdcard/apkfactory_status.json"
SISTEM_DIR="/storage/emulated/0/termux-otonom-sistem"
WS_BRIDGE_DIR="$HOME/apk-factory-ws"

log() { echo "$(date '+%H:%M:%S') ► $1" >> "$LOG_FILE"; }
status() { echo "{\"done\":false,\"step\":\"$1\"}" > "$STATUS_FILE"; }
done_status() { echo '{"done":true,"step":"tamamlandı"}' > "$STATUS_FILE"; }

# ══════════════════════════════════════════════
# ADIM 1: Paket listesi güncelleniyor
# ══════════════════════════════════════════════
status "paket listesi güncelleniyor"
log "Paket listesi güncelleniyor..."
pkg update -y >> "$LOG_FILE" 2>&1
log "Paket listesi güncellendi"

# ══════════════════════════════════════════════
# ADIM 2: Temel araçlar
# ══════════════════════════════════════════════
status "temel araçlar kuruluyor"
log "Temel araçlar kuruluyor..."
pkg install -y curl wget git unzip zip tar nano >> "$LOG_FILE" 2>&1
log "Temel araçlar kuruldu"

# ══════════════════════════════════════════════
# ADIM 3: Python + WebSocket
# ══════════════════════════════════════════════
status "python websocket kuruluyor"
log "Python + WebSocket kuruluyor..."
pkg install -y python >> "$LOG_FILE" 2>&1
pip install websockets --quiet >> "$LOG_FILE" 2>&1
log "Python + WebSocket hazır"

# ══════════════════════════════════════════════
# ADIM 4: Java (OpenJDK 17)
# ══════════════════════════════════════════════
status "java kuruluyor"
log "Java (OpenJDK 17) kuruluyor..."
pkg install -y openjdk-17 >> "$LOG_FILE" 2>&1
log "Java kuruldu"

# ══════════════════════════════════════════════
# ADIM 5: Android SDK
# ══════════════════════════════════════════════
status "android sdk indiriliyor"
log "Android SDK indiriliyor..."
SDK_DIR="$HOME/android-sdk"
if [ ! -f "$SDK_DIR/platforms/android-34/android.jar" ]; then
    mkdir -p "$SDK_DIR" && cd "$SDK_DIR"
    wget -q --show-progress \
        https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip \
        -O cmdtools.zip >> "$LOG_FILE" 2>&1
    unzip -q cmdtools.zip >> "$LOG_FILE" 2>&1
    mkdir -p cmdline-tools/latest
    mv cmdline-tools/bin cmdline-tools/latest/ 2>/dev/null || true
    mv cmdline-tools/lib cmdline-tools/latest/ 2>/dev/null || true
    mv cmdline-tools/NOTICE.txt cmdline-tools/latest/ 2>/dev/null || true
    mv cmdline-tools/source.properties cmdline-tools/latest/ 2>/dev/null || true
    rm -f cmdtools.zip

    # ══════════════════════════════════════════════
    # ADIM 6: Lisanslar kabul ediliyor
    # ══════════════════════════════════════════════
    status "lisanslar kabul ediliyor"
    log "Lisanslar kabul ediliyor..."
    export ANDROID_SDK_ROOT="$SDK_DIR"
    export PATH="$SDK_DIR/cmdline-tools/latest/bin:$PATH"
    yes | sdkmanager --licenses >> "$LOG_FILE" 2>&1 || true
    log "Lisanslar kabul edildi"

    # ══════════════════════════════════════════════
    # ADIM 7: Build Tools
    # ══════════════════════════════════════════════
    status "build tools kuruluyor"
    log "Build Tools kuruluyor..."
    sdkmanager "build-tools;34.0.0" "platforms;android-34" >> "$LOG_FILE" 2>&1
    log "Build Tools kuruldu"
    cd "$HOME"
else
    log "SDK araçları indirildi"
    log "Lisanslar kabul edildi"
    log "Build Tools kuruldu"
fi
log "SDK araçları indirildi"

# ══════════════════════════════════════════════
# ADIM 8: aapt2 düzeltiliyor
# ══════════════════════════════════════════════
status "aapt2 düzeltiliyor"
log "aapt2 düzeltiliyor..."
AAPT2_PATH=$(find "$HOME/android-sdk/build-tools" -name "aapt2" 2>/dev/null | head -1)
if [ -n "$AAPT2_PATH" ]; then
    wget -q "https://github.com/lzhiyong/android-sdk-tools/releases/download/34.0.0/android-sdk-tools-aarch64.zip" \
        -O /tmp/sdk-tools.zip >> "$LOG_FILE" 2>&1
    unzip -qo /tmp/sdk-tools.zip aapt2 -d "$(dirname "$AAPT2_PATH")" >> "$LOG_FILE" 2>&1 || true
    chmod +x "$AAPT2_PATH" 2>/dev/null || true
    rm -f /tmp/sdk-tools.zip
fi
log "aapt2 hazır"

# ══════════════════════════════════════════════
# ADIM 9: Factory scriptler
# ══════════════════════════════════════════════
status "factory scriptler indiriliyor"
log "Factory scriptler indiriliyor..."
mkdir -p "$SISTEM_DIR/prompts" "$SISTEM_DIR/keystores" "$SISTEM_DIR/setup" "$SISTEM_DIR/apiler"

for f in sistem.sh prj.sh autofix.sh factory.sh; do
    curl -sf "$GITHUB_RAW/scripts/$f" -o "$SISTEM_DIR/$f" >> "$LOG_FILE" 2>&1 && chmod +x "$SISTEM_DIR/$f"
done

for f in autofix_system.txt autofix_task.txt; do
    curl -sf "$GITHUB_RAW/prompts/$f" -o "$SISTEM_DIR/prompts/$f" >> "$LOG_FILE" 2>&1 || true
done

touch "$SISTEM_DIR/projeler.conf"
log "Factory scriptler hazır"

# ══════════════════════════════════════════════
# ADIM 10: WebSocket sunucusu
# ══════════════════════════════════════════════
status "websocket sunucusu başlatılıyor"
log "WebSocket sunucusu indiriliyor..."
mkdir -p "$WS_BRIDGE_DIR"
curl -sf "$GITHUB_RAW/scripts/ws_bridge.py" -o "$WS_BRIDGE_DIR/ws_bridge.py" >> "$LOG_FILE" 2>&1
chmod +x "$WS_BRIDGE_DIR/ws_bridge.py"

pkill -9 -f ws_bridge.py 2>/dev/null || true
sleep 1
nohup python3 "$WS_BRIDGE_DIR/ws_bridge.py" >> "$WS_BRIDGE_DIR/ws_bridge.log" 2>&1 &
sleep 3

if pgrep -f ws_bridge.py > /dev/null; then
    log "WebSocket bridge yazıldı"
else
    log "❌ WebSocket başlatılamadı!"
fi

# ══════════════════════════════════════════════
# TAMAMLANDI
# ══════════════════════════════════════════════
log "✅ Kurulum tamamlandı!"
done_status
