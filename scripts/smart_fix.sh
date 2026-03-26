#!/data/data/com.termux/files/usr/bin/bash
# smart_fix.sh v3 — Nokta Atışı Düzeltme & Doğrulama & Rollback
# Kullanım: bash smart_fix.sh <proje_dizini> <hata_log> [görev]

set -euo pipefail

PROJECT_ROOT="${1:-}"
ERROR_LOG="${2:-}"
TASK="${3:-}"

[[ -z "$PROJECT_ROOT" || ! -d "$PROJECT_ROOT" ]] && { echo "HATA: Proje dizini gerekli"; exit 1; }
[[ -z "$ERROR_LOG"    || ! -f "$ERROR_LOG"    ]] && { echo "HATA: Hata log dosyası gerekli"; exit 1; }

SISTEM_DIR="/storage/emulated/0/termux-otonom-sistem"
APILER_DIR="$SISTEM_DIR/apiler"
PROMPTS_DIR="$SISTEM_DIR/prompts"
TMP_DIR="$HOME/.autofix_tmp"
mkdir -p "$TMP_DIR"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; NC='\033[0m'
log()  { echo -e "${CYAN}[sf]${NC} $*"; }
ok()   { echo -e "${GREEN}✅ $*${NC}"; }
warn() { echo -e "${YELLOW}⚠️  $*${NC}"; }
err()  { echo -e "${RED}❌ $*${NC}"; }

# ── Hata Sayım Fonksiyonu (Tüm Hatalar) ───────────────────────────────────────
count_all_errors() {
    local log_file="$1"
    grep -cE "(^e: |error:|Exception|What went wrong|Could not find|AAPT|Unresolved reference)" "$log_file" 2>/dev/null || echo 0
}

INITIAL_ERRORS=$(count_all_errors "$ERROR_LOG")

# ── Rollback (Yedekleme) Sistemi ──────────────────────────────────────────────
RESTORE_LIST="$TMP_DIR/sf_restore_list.txt"
> "$RESTORE_LIST"

backup_file() {
    local file="$1"
    local bak_file="$TMP_DIR/$(basename "$file").bak_sf_${RANDOM}"
    cp "$file" "$bak_file"
    echo "$file|$bak_file" >> "$RESTORE_LIST"
}

rollback_all() {
    if [[ -s "$RESTORE_LIST" ]]; then
        log "Değişiklikler başarısız oldu. Orijinal koda dönülüyor (Rollback)..."
        while IFS='|' read -r orig bak; do
            cp "$bak" "$orig" 2>/dev/null || true
        done < "$RESTORE_LIST"
        > "$RESTORE_LIST"
    fi
}

# ── Provider ──────────────────────────────────────────────────────────────────
load_provider() {
    local conf_file=$(ls "$APILER_DIR"/*.conf 2>/dev/null | head -1 || "")
    local default_prov=$(grep "^DEFAULT_PROVIDER=" ~/.config/autofix.conf 2>/dev/null | cut -d'"' -f2 || echo "")
    [[ -n "$default_prov" ]] && conf_file="$APILER_DIR/$(echo "$default_prov" | tr '[:upper:]' '[:lower:]').conf"
    [[ -z "$conf_file" || ! -f "$conf_file" ]] && { err "Provider conf bulunamadı"; exit 1; }

    SF_NAME=$(grep "^NAME="    "$conf_file" | cut -d'"' -f2)
    SF_URL=$(grep  "^API_URL=" "$conf_file" | cut -d'"' -f2)
    SF_KEY=$(grep  "^API_KEY=" "$conf_file" | cut -d'"' -f2)
    SF_MODEL=$(grep "^MODEL="  "$conf_file" | cut -d'"' -f2)
    SF_TOKENS=$(grep "^MAX_TOKENS=" "$conf_file" 2>/dev/null | cut -d= -f2 || echo 8000)
}

load_system_prompt() {
    echo 'Sen nokta atışı düzeltme yapan bir uzmansın. SADECE tek bir hatayı çözmeye odaklan. Tüm dosyayı ASLA yazma. Sadece REPLACE_BLOCK veya CMD kullan.'
}

# ── API çağrısı ───────────────────────────────────────────────────────────────
call_ai() {
    local sp="$1" um="$2" out="$TMP_DIR/sf_response.json"
    local payload=$(python3 -c "
import json, sys
sp, um, name, model, tokens = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], int(sys.argv[5])
if name == 'Claude':
    print(json.dumps({'model': model, 'max_tokens': tokens, 'system': sp, 'messages': [{'role': 'user', 'content': um}]}))
elif name == 'Gemini':
    print(json.dumps({'systemInstruction': {'parts': [{'text': sp}]}, 'contents': [{'parts': [{'text': um}]}], 'generationConfig': {'maxOutputTokens': tokens, 'temperature': 0.1}}))
else:
    print(json.dumps({'model': model, 'max_tokens': tokens, 'temperature': 0.1, 'messages': [{'role': 'system', 'content': sp}, {'role': 'user', 'content': um}]}))
" "$sp" "$um" "$SF_NAME" "$SF_MODEL" "$SF_TOKENS")

    local hc
    if [[ "$SF_NAME" == "Gemini" ]]; then
        hc=$(curl -s -w "%{http_code}" -X POST "https://generativelanguage.googleapis.com/v1beta/models/${SF_MODEL}:generateContent?key=${SF_KEY}" -H "Content-Type: application/json" -d "$payload" -o "$out" --connect-timeout 30 2>/dev/null)
    elif [[ "$SF_NAME" == "Claude" ]]; then
        hc=$(curl -s -w "%{http_code}" -X POST "$SF_URL" -H "Content-Type: application/json" -H "x-api-key: $SF_KEY" -H "anthropic-version: 2023-06-01" -d "$payload" -o "$out" --connect-timeout 30 2>/dev/null)
    else
        hc=$(curl -s -w "%{http_code}" -X POST "$SF_URL" -H "Content-Type: application/json" -H "Authorization: Bearer $SF_KEY" -d "$payload" -o "$out" --connect-timeout 30 2>/dev/null)
    fi

    [[ "$hc" != "200" ]] && return 1
    if [[ "$SF_NAME" == "Claude" ]]; then jq -r '.content[0].text' "$out" 2>/dev/null
    elif [[ "$SF_NAME" == "Gemini" ]]; then jq -r '.candidates[0].content.parts[0].text' "$out" 2>/dev/null
    else jq -r '.choices[0].message.content' "$out" 2>/dev/null; fi
}

is_safe_cmd() {
    echo "$1" | grep -qE '(>(?!&)|>>|\brm\b|\bmv\b|\bcp\b|\bchmod\b|\bsed\s.*-i\b|gradlew)' && return 1 || return 0
}

# ── SEARCH/REPLACE Uygula ve DOĞRULA ──────────────────────────────────────────
apply_search_replace() {
    local rel_path="$1" search_text="$2" replace_text="$3"
    local abs_path="$PROJECT_ROOT/$rel_path"
    
    [[ ! -f "$abs_path" ]] && { echo "HATA: Dosya yok: $abs_path"; return 1; }
    backup_file "$abs_path"

    python3 - "$abs_path" "$search_text" "$replace_text" << 'PYEOF'
import sys
path, search_text, replace_text = sys.argv[1], sys.argv[2], sys.argv[3]
content = open(path, encoding='utf-8').read()

def normalize(s): return "\n".join(line.strip() for line in s.splitlines() if line.strip())

norm_content = normalize(content)
norm_search = normalize(search_text)

if norm_search not in norm_content and search_text not in content:
    print("HATA: Aranan kod dosyada bulunamadi. Tam esleme yok.")
    sys.exit(1)

# Parantez denge kontrolü
old_bal = search_text.count('{') - search_text.count('}')
new_bal = replace_text.count('{') - replace_text.count('}')
if old_bal != new_bal:
    print(f"HATA: Parantez dengesizligi! Eski: {old_bal:+d}, Yeni: {new_bal:+d}")
    sys.exit(1)

new_content = content.replace(search_text, replace_text, 1)

# DOĞRULAMA (VERIFICATION): Yeni kod dosyaya gerçekten eklendi mi?
if normalize(replace_text) not in normalize(new_content):
    print("HATA: Degisiklik uygulandi ancak dogrulama basarisiz (Yeni kod dosyada bulunamadi).")
    sys.exit(1)

open(path, 'w', encoding='utf-8').write(new_content)
print(f"REPLACE uygulandi ve DOGRULANDI: {len(content.splitlines())} -> {len(new_content.splitlines())} satir")
PYEOF
}

# ── Ana Döngü (Maksimum 5 Deneme) ─────────────────────────────────────────────
main() {
    load_provider
    local SYSTEM_PROMPT=$(load_system_prompt)
    local error_text=$(cat "$ERROR_LOG")
    local user_msg="Proje: $PROJECT_ROOT\n\nBUILD HATALARI ($INITIAL_ERRORS adet):\n$error_text\n\nZORUNLU: Önce CMD: cat ile dosyayı oku, sonra REPLACE_BLOCK ver."
    local conversation=""
    local MAX_ATTEMPTS=5

    log "Smart Fix başlatıldı. Toplam hata: $INITIAL_ERRORS"

    for (( round=1; round<=MAX_ATTEMPTS; round++ )); do
        log "Deneme $round / $MAX_ATTEMPTS — AI'ya gönderiliyor..."

        local full_msg="$user_msg"
        [[ -n "$conversation" ]] && full_msg="$conversation\n\n---\n$user_msg"

        local ai_response=$(call_ai "$SYSTEM_PROMPT" "$full_msg")
        [[ -z "$ai_response" ]] && { err "API yanıt vermedi."; continue; }
        conversation="$full_msg\n\nAI: $ai_response"

        # ── CMD ────────────────────────────────────────────────────────────
        if echo "$ai_response" | grep -q "^CMD:" && ! echo "$ai_response" | grep -q "^REPLACE_BLOCK:"; then
            local cmd=$(echo "$ai_response" | grep "^CMD:" | head -1 | sed 's/^CMD: *//')
            if is_safe_cmd "$cmd"; then
                log "Komut çalıştırılıyor: $cmd"
                cd "$PROJECT_ROOT"; local cmd_out=$(eval "$cmd" 2>&1 || true)
                user_msg="KOMUT ÇIKTISI:\n$cmd_out\nDevam et ve REPLACE_BLOCK üret."
            else
                user_msg="Güvensiz komut engellendi. cat, grep kullan."
            fi
            continue
        fi

        # ── REPLACE_BLOCK ──────────────────────────────────────────────────
        if echo "$ai_response" | grep -q "^REPLACE_BLOCK:"; then
            local rp=$(echo "$ai_response" | grep "^REPLACE_BLOCK:" | head -1 | cut -d: -f2- | xargs)
            local search_text=$(echo "$ai_response" | awk '/^<<<SEARCH/{found=1; next} /^===/{found=0} found{print}')
            local replace_text=$(echo "$ai_response" | awk '/^>>>REPLACE/{found=1; next} /^>>>END/{found=0} found{print}')

            log "REPLACE deneniyor: $rp"
            local replace_output
            if replace_output=$(apply_search_replace "$rp" "$search_text" "$replace_text" 2>&1); then
                ok "Kod doğrulandı ve değiştirildi."
                
                # Çözüm uygulandı, gerçek build al ve test et
                log "Build alınıyor ve test ediliyor..."
                cd "$PROJECT_ROOT"
                ./gradlew assembleDebug --no-daemon > "$TMP_DIR/sf_build.txt" 2>&1 || true
                
                local new_errors=$(count_all_errors "$TMP_DIR/sf_build.txt")
                
                if grep -q "BUILD SUCCESSFUL" "$TMP_DIR/sf_build.txt" || [[ "$new_errors" -lt "$INITIAL_ERRORS" ]]; then
                    ok "🎉 Başarılı! Hatalar azaldı ($INITIAL_ERRORS -> $new_errors)."
                    cp "$TMP_DIR/sf_build.txt" "$ERROR_LOG"
                    exit 0 # Başarıyla Autofix'e dön
                else
                    warn "Kod değişti ama hata sayısı artmış veya aynı kalmış ($INITIAL_ERRORS -> $new_errors)."
                    rollback_all # İşe yaramayan çözümü geri al
                    user_msg="Yazdığın kod hataları azaltmadı. Rollback yapıldı. Farklı bir çözüm düşün.\nYENİ BUILD ÇIKTISI:\n$(head -60 "$TMP_DIR/sf_build.txt")"
                fi
            else
                warn "Replace uygulanamadı veya doğrulanamadı."
                user_msg="HATA: $replace_output\nKodu tam olarak eşleştirip tekrar dene."
            fi
            continue
        fi
        
        user_msg="Geçerli bir CMD veya REPLACE_BLOCK formatı bulunamadı. Lütfen kurallara uy."
    done

    err "$MAX_ATTEMPTS denemede hata çözülemedi."
    rollback_all
    exit 1 # Başarısız, Autofix'e orijinal haliyle teslim et
}

main
