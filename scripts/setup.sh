#!/bin/bash
# ═══════════════════════════════════════════════════════
#  APK Factory — Bootstrap
#  Bu dosya uygulamanın içinde gömülü gelir.
#  GitHub'dan güncel setup.sh'ı indirir ve çalıştırır.
# ═══════════════════════════════════════════════════════

GITHUB_RAW="https://raw.githubusercontent.com/hakanerbasss/apk-factory-assets/main"
LOG_FILE="LOG_PATH_PLACEHOLDER"
STATUS_FILE="STATUS_PATH_PLACEHOLDER"
SETUP_CACHE="$HOME/.cache/apkfactory_setup.sh"

echo '{"done":false,"step":"indiriliyor"}' > "$STATUS_FILE"

mkdir -p "$(dirname "$SETUP_CACHE")"

# GitHub'dan güncel setup.sh'ı indir
if curl -sf --max-time 30 "$GITHUB_RAW/scripts/setup_full.sh" -o "$SETUP_CACHE"; then
    # Log ve status yollarını yerleştir
    sed -i "s|LOG_FILE=.*|LOG_FILE=\"$LOG_FILE\"|" "$SETUP_CACHE"
    sed -i "s|STATUS_FILE=.*|STATUS_FILE=\"$STATUS_FILE\"|" "$SETUP_CACHE"
    sed -i "s|GITHUB_RAW=.*|GITHUB_RAW=\"$GITHUB_RAW\"|" "$SETUP_CACHE"
    chmod +x "$SETUP_CACHE"
    bash "$SETUP_CACHE"
else
    # İnternet yoksa veya GitHub'a ulaşılamazsa: bu dosyanın yanındaki setup_full.sh
    echo '{"done":false,"step":"offline kurulum"}' > "$STATUS_FILE"
    SELF_DIR="$(dirname "$(realpath "$0")")"
    if [ -f "$SELF_DIR/setup_full.sh" ]; then
        bash "$SELF_DIR/setup_full.sh"
    else
        echo '{"done":false,"step":"hata: internet yok"}' > "$STATUS_FILE"
        echo "❌ GitHub'a ulaşılamadı ve offline kurulum bulunamadı."
        exit 1
    fi
fi
