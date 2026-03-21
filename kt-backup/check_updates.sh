#!/bin/bash
exec >> /sdcard/Download/apkfactory_update.log 2>&1
date
GITHUB_RAW="https://raw.githubusercontent.com/hakanerbasss/apk-factory-assets/main"
SISTEM_DIR="/storage/emulated/0/termux-otonom-sistem"
APILER_DIR="$SISTEM_DIR/apiler"
WS_BRIDGE="/data/data/com.termux/files/home/apk-factory-ws/ws_bridge.py"

# ── Sadece ws_bridge güncellenir ────────────────────────────────────────────
# Diğer her şey (scriptler, promptlar, setup) kurulumda bir kez indirilir,
# sonraki güncellemelerde dokunulmaz. Kullanıcı değişiklikleri korunur.
curl -sf --max-time 30 "$GITHUB_RAW/scripts/ws_bridge.py" -o "$WS_BRIDGE" \
    && echo "ws_bridge güncellendi" \
    && bash ~/restart_bridge.sh \
    || echo "ws_bridge güncellenemedi"

# ── API conf - key korunarak güncelle ────────────────────────────────────────
mkdir -p "$APILER_DIR"
for conf in deepseek gemini openai claude groq qwen; do
    tmp="$APILER_DIR/${conf}.tmp"
    dst="$APILER_DIR/${conf}.conf"
    if curl -sf --max-time 10 "$GITHUB_RAW/apiler/${conf}.conf" -o "$tmp"; then
        if [ -f "$dst" ]; then
            key=$(grep "^API_KEY=" "$dst" | cut -d= -f2- | tr -d '"')
            [ -n "$key" ] && sed -i "s|^API_KEY=.*|API_KEY=\"$key\"|" "$tmp"
        fi
        mv "$tmp" "$dst"
        echo "$conf.conf güncellendi"
    fi
done

# ── Setup klasörü - sadece yoksa indir ───────────────────────────────────────
SETUP_DIR="$SISTEM_DIR/setup"
if [ ! -f "$SETUP_DIR/gradlew" ]; then
    curl -sf --max-time 60 "$GITHUB_RAW/setup.zip" -o "$SISTEM_DIR/setup.zip" && \
    unzip -qo "$SISTEM_DIR/setup.zip" -d "$SISTEM_DIR/" && \
    rm -f "$SISTEM_DIR/setup.zip" && echo "setup klasörü geri yüklendi"
fi

echo "check_updates tamamlandı"
