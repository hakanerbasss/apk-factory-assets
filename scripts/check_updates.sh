#!/bin/bash
exec >> /sdcard/Download/apkfactory_update.log 2>&1
date
GITHUB_RAW="https://raw.githubusercontent.com/hakanerbasss/apk-factory-assets/main"
SISTEM_DIR="/storage/emulated/0/termux-otonom-sistem"
APILER_DIR="$SISTEM_DIR/apiler"
PROMPTS_DIR="$SISTEM_DIR/prompts"
VER_FILE="$SISTEM_DIR/prompt_version.txt"
SCRIPT_VER_FILE="$SISTEM_DIR/script_version.txt"
WS_BRIDGE="/data/data/com.termux/files/home/apk-factory-ws/ws_bridge.py"

remote=$(curl -sf --max-time 5 "$GITHUB_RAW/version.json" || echo '{}')
remote_prompt=$(echo "$remote" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("prompt_version","0"))' 2>/dev/null)
remote_script=$(echo "$remote" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("script_version","0"))' 2>/dev/null)
local_prompt=$(cat "$VER_FILE" 2>/dev/null || echo "0")
local_script=$(cat "$SCRIPT_VER_FILE" 2>/dev/null || echo "0")

# API conf - her zaman güncelle (key korunarak)
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

# Scriptler - dosya yoksa indir, 🔄 butonunda her zaman indir
FORCE="${1:-}"
for f in autofix.sh prj.sh factory.sh check_updates.sh; do
    if [ ! -f "$SISTEM_DIR/$f" ] || [ "$FORCE" = "force" ]; then
        curl -sf --max-time 30 "$GITHUB_RAW/scripts/$f" -o "$SISTEM_DIR/$f" && chmod +x "$SISTEM_DIR/$f" && echo "$f güncellendi"
    fi
done
if [ ! -f "$WS_BRIDGE" ] || [ "$FORCE" = "force" ]; then
    curl -sf --max-time 30 "$GITHUB_RAW/scripts/ws_bridge.py" -o "$WS_BRIDGE" && echo "ws_bridge güncellendi"
fi

# Promptlar - dosya yoksa indir, 🔄 butonunda her zaman indir
mkdir -p "$PROMPTS_DIR"
for pf in autofix_system.txt autofix_task.txt; do
    if [ ! -f "$PROMPTS_DIR/$pf" ] || [ "$FORCE" = "force" ]; then
        curl -sf --max-time 15 "$GITHUB_RAW/prompts/$pf" -o "$PROMPTS_DIR/$pf" && echo "$pf güncellendi"
    fi
done

echo "check_updates tamamlandı"
