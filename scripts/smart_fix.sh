#!/data/data/com.termux/files/usr/bin/bash
# smart_fix.sh v5 — Tam Düzeltilmiş
# Kullanım: bash smart_fix.sh <proje_dizini> <hata_log> [görev] [loop] [max_loops]

set -euo pipefail

PROJECT_ROOT="${1:-}"
ERROR_LOG="${2:-}"
TASK="${3:-}"
CURRENT_LOOP="${4:-1}"
MAX_LOOPS="${5:-5}"

[[ -z "$PROJECT_ROOT" || ! -d "$PROJECT_ROOT" ]] && { echo "HATA: Proje dizini gerekli"; exit 1; }
[[ -z "$ERROR_LOG"    || ! -f "$ERROR_LOG"    ]] && { echo "HATA: Hata log dosyası gerekli"; exit 1; }

SISTEM_DIR="/storage/emulated/0/termux-otonom-sistem"
APILER_DIR="$SISTEM_DIR/apiler"
TMP_DIR="$HOME/.autofix_tmp"
SNAPSHOT_FILE="$TMP_DIR/sf_snapshot_${RANDOM}.tar.gz"
mkdir -p "$TMP_DIR"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; NC='\033[0m'
log()  { echo -e "${CYAN}[sf]${NC} $*"; }
ok()   { echo -e "${GREEN}✅ $*${NC}"; }
warn() { echo -e "${YELLOW}⚠️  $*${NC}"; }
err()  { echo -e "${RED}❌ $*${NC}"; }

# ── Hata Sayım Fonksiyonu ──────────────────────────────────────────────────────
count_errors() {
    local log_file="$1"
    grep -cE "(^e: |error:|Exception|What went wrong|Could not find|AAPT|Unresolved reference)" \
        "$log_file" 2>/dev/null || echo 0
}

# ── Snapshot (Tam Yedek) ───────────────────────────────────────────────────────
take_snapshot() {
    log "Snapshot alınıyor..."
    tar -czf "$SNAPSHOT_FILE" -C "$PROJECT_ROOT" app/ 2>/dev/null && \
        ok "Snapshot alındı: $SNAPSHOT_FILE" || \
        warn "Snapshot alınamadı (devam ediliyor)"
}

restore_snapshot() {
    if [[ -f "$SNAPSHOT_FILE" ]]; then
        log "Snapshot'tan geri dönülüyor..."
        tar -xzf "$SNAPSHOT_FILE" -C "$PROJECT_ROOT" 2>/dev/null && \
            ok "Snapshot geri yüklendi." || \
            err "Snapshot geri yükleme başarısız!"
    else
        warn "Snapshot dosyası bulunamadı, rollback yapılamadı."
    fi
}

# ── Provider ──────────────────────────────────────────────────────────────────
load_provider() {
    local default_prov
    default_prov=$(grep "^DEFAULT_PROVIDER=" ~/.config/autofix.conf 2>/dev/null | cut -d'"' -f2 || echo "")
    local conf_file=""
    [[ -n "$default_prov" ]] && conf_file="$APILER_DIR/$(echo "$default_prov" | tr '[:upper:]' '[:lower:]').conf"
    [[ -z "$conf_file" || ! -f "$conf_file" ]] && conf_file=$(ls "$APILER_DIR"/*.conf 2>/dev/null | head -1 || "")
    [[ -z "$conf_file" || ! -f "$conf_file" ]] && { err "Provider conf bulunamadı"; exit 1; }

    SF_NAME=$(grep  "^NAME="      "$conf_file" | cut -d'"' -f2)
    SF_URL=$(grep   "^API_URL="   "$conf_file" | cut -d'"' -f2)
    SF_KEY=$(grep   "^API_KEY="   "$conf_file" | cut -d'"' -f2)
    SF_MODEL=$(grep "^MODEL="     "$conf_file" | cut -d'"' -f2)
    SF_TOKENS=$(grep "^MAX_TOKENS=" "$conf_file" 2>/dev/null | cut -d= -f2 || echo 8000)
}

load_system_prompt() {
    cat << 'PROMPT'
Sen nokta atışı Kotlin/Android hata düzelten bir uzmansın.

KURALLAR:
1. Önce CMD ile dosyayı oku (cat, grep, sed). Build sayılmaz.
2. REPLACE_BLOCK ile sadece değişen kısımı yaz.
3. <<<SEARCH bloğu DOSYADA AYNEN OLAN satırları içermeli — indent, boşluk, hepsi birebir.
4. Tüm dosyayı ASLA yazma.
5. REPLACE başarısız olunca AI CMD ile kontrol eder: grep ile SEARCH bloğundaki kritik satırı dosyada ara, tam eşleşen halini bul, sonra tekrar REPLACE_BLOCK ver.

FORMAT:
CMD: <komut>

veya:

REPLACE_BLOCK: app/src/main/java/.../.../Dosya.kt
<<<SEARCH
[dosyada AYNEN olan satırlar — boşluk/indent dahil]
===
[yeni hali]
>>>END
PROMPT
}

# ── API çağrısı ───────────────────────────────────────────────────────────────
call_ai() {
    local sp="$1" um="$2" out="$TMP_DIR/sf_response.json"
    local payload
    payload=$(python3 -c "
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
        hc=$(curl -s -w "%{http_code}" -X POST \
            "https://generativelanguage.googleapis.com/v1beta/models/${SF_MODEL}:generateContent?key=${SF_KEY}" \
            -H "Content-Type: application/json" -d "$payload" -o "$out" \
            --connect-timeout 30 2>/dev/null)
    elif [[ "$SF_NAME" == "Claude" ]]; then
        hc=$(curl -s -w "%{http_code}" -X POST "$SF_URL" \
            -H "Content-Type: application/json" \
            -H "x-api-key: $SF_KEY" \
            -H "anthropic-version: 2023-06-01" \
            -d "$payload" -o "$out" --connect-timeout 30 2>/dev/null)
    else
        hc=$(curl -s -w "%{http_code}" -X POST "$SF_URL" \
            -H "Content-Type: application/json" \
            -H "Authorization: Bearer $SF_KEY" \
            -d "$payload" -o "$out" --connect-timeout 30 2>/dev/null)
    fi

    [[ "$hc" != "200" ]] && return 1
    if   [[ "$SF_NAME" == "Claude" ]]; then jq -r '.content[0].text'                        "$out" 2>/dev/null
    elif [[ "$SF_NAME" == "Gemini" ]]; then jq -r '.candidates[0].content.parts[0].text'    "$out" 2>/dev/null
    else                                    jq -r '.choices[0].message.content'              "$out" 2>/dev/null
    fi
}

is_safe_cmd() {
    echo "$1" | grep -qE '(>>|\brm\b|\bmv\b|\bchmod\b|\bsed\s.*-i\b|gradlew)' && return 1 || return 0
}

# ── SEARCH/REPLACE — Fuzzy Eşleşme ───────────────────────────────────────────
# SORUN: AI doğru kodu yazsa bile dosyadaki satırlar farklı indent/whitespace ile
# kaydedilmiş olabilir. Bu yüzden hem tam eşleşme hem de normalize eşleşme deneniyor.
# Normalize eşleşmede dosyadaki orijinal indent korunuyor (replace ile değil, python ile).
apply_search_replace() {
    local rel_path="$1" search_text="$2" replace_text="$3"
    local abs_path="$PROJECT_ROOT/$rel_path"

    [[ ! -f "$abs_path" ]] && { echo "HATA: Dosya yok: $abs_path"; return 1; }

    python3 - "$abs_path" "$search_text" "$replace_text" << 'PYEOF'
import sys, re

path = sys.argv[1]
search_text = sys.argv[2]
replace_text = sys.argv[3]

content = open(path, encoding='utf-8').read()
lines = content.splitlines(keepends=True)

# ── Strateji 1: Tam eşleşme ──────────────────────────────────────────────────
if search_text in content:
    # Parantez denge kontrolü
    old_bal = search_text.count('{') - search_text.count('}')
    new_bal = replace_text.count('{') - replace_text.count('}')
    if old_bal != new_bal:
        print(f"HATA: Parantez dengesizligi! Eski: {old_bal:+d}, Yeni: {new_bal:+d}")
        sys.exit(1)
    new_content = content.replace(search_text, replace_text, 1)
    open(path, 'w', encoding='utf-8').write(new_content)
    print(f"REPLACE (tam eslesme): {len(content.splitlines())} -> {len(new_content.splitlines())} satir")
    sys.exit(0)

# ── Strateji 2: Satır bazlı fuzzy eşleşme (indent görmezden gel) ─────────────
# Her satırı strip() ederek arar, dosyadaki orijinal indent'i korur
search_lines = [l.strip() for l in search_text.splitlines() if l.strip()]
file_lines_stripped = [l.rstrip().strip() for l in lines]

# Arama bloğunu dosyada bul
match_start = -1
for i in range(len(file_lines_stripped)):
    if len(search_lines) == 0:
        break
    if file_lines_stripped[i] == search_lines[0]:
        # Tam bloğu kontrol et
        matched = True
        for j, sl in enumerate(search_lines):
            idx = i + j
            if idx >= len(file_lines_stripped) or file_lines_stripped[idx] != sl:
                matched = False
                break
        if matched:
            match_start = i
            break

if match_start == -1:
    # Hiç bulunamadı — AI'ya bilgi ver
    # Aranan ilk satırın dosyada hangi satırlarda geçtiğini göster (debug)
    hints = []
    if search_lines:
        for idx, sl in enumerate(file_lines_stripped):
            if search_lines[0] in sl or sl in search_lines[0]:
                hints.append(f"  satir {idx+1}: {lines[idx].rstrip()}")
    hint_text = "\n".join(hints[:5]) if hints else "  (hic bulunamadi)"
    print(f"HATA: Aranan kod dosyada bulunamadi.\nAranan ilk satir: '{search_lines[0] if search_lines else '?'}'\nBenzer satirlar:\n{hint_text}")
    sys.exit(1)

# Parantez denge kontrolü
match_end = match_start + len(search_lines)
old_bal = search_text.count('{') - search_text.count('}')
new_bal = replace_text.count('{') - replace_text.count('}')
if old_bal != new_bal:
    print(f"HATA: Parantez dengesizligi! Eski: {old_bal:+d}, Yeni: {new_bal:+d}")
    sys.exit(1)

# İlk eşleşen satırın indent'ini al — replace bloğuna uygula
base_indent = ''
first_orig = lines[match_start] if match_start < len(lines) else ''
for ch in first_orig:
    if ch in (' ', '\t'):
        base_indent += ch
    else:
        break

# Replace satırlarını orijinal indent ile yeniden yaz
replace_lines = replace_text.splitlines()
indented_replace = []
for rl in replace_lines:
    stripped_rl = rl.strip()
    if stripped_rl:
        # Eğer replace satırının kendi indent'i varsa koru, yoksa base_indent ekle
        orig_indent = ''
        for ch in rl:
            if ch in (' ', '\t'): orig_indent += ch
            else: break
        if orig_indent:
            indented_replace.append(rl + '\n')
        else:
            indented_replace.append(base_indent + stripped_rl + '\n')
    else:
        indented_replace.append('\n')

new_lines = lines[:match_start] + indented_replace + lines[match_end:]
new_content = ''.join(new_lines)

open(path, 'w', encoding='utf-8').write(new_content)
print(f"REPLACE (fuzzy eslesme, satir {match_start+1}-{match_end}): {len(lines)} -> {len(new_lines)} satir")
sys.exit(0)
PYEOF
}

# ── Ana Döngü ─────────────────────────────────────────────────────────────────
main() {
    load_provider
    local SYSTEM_PROMPT
    SYSTEM_PROMPT=$(load_system_prompt)

    # ── ADIM 1: Taze build al → güncel hata logu oluştur ──────────────────────
    log "Taze build alınıyor (güncel hata logu için)..."
    cd "$PROJECT_ROOT"
    ./gradlew assembleDebug --no-daemon > "$TMP_DIR/sf_initial_build.txt" 2>&1 || true
    ERROR_LOG="$TMP_DIR/sf_initial_build.txt"
    local INITIAL_ERRORS
    INITIAL_ERRORS=$(count_errors "$ERROR_LOG")
    log "Smart Fix başlatıldı. Toplam hata: $INITIAL_ERRORS"

    # ── ADIM 2: Snapshot al ───────────────────────────────────────────────────
    take_snapshot

    # ── ADIM 3: Hata metnini hazırla ─────────────────────────────────────────
    local error_text
    error_text=$(grep -E "^e:|error:|Unresolved|AAPT|Exception" "$ERROR_LOG" | head -40 || cat "$ERROR_LOG" | tail -40)
    local task_context=""
    [[ -n "$TASK" ]] && task_context="GÖREV: $TASK\n\n"

    local user_msg="Proje: $PROJECT_ROOT\n\n${task_context}BUILD HATALARI ($INITIAL_ERRORS adet):\n$error_text\n\nZORUNLU: Önce CMD ile dosyayı oku (cat), sonra REPLACE_BLOCK ver."
    local conversation=""

    local MAX_BUILD_ATTEMPTS=5
    local MAX_API_CALLS=35
    local build_attempts=0      # Sadece gerçek build alındığında artar
    local api_calls=0
    local replace_fail_streak=0 # Üst üste kaç kez REPLACE başarısız oldu

    while [[ $build_attempts -lt $MAX_BUILD_ATTEMPTS && $api_calls -lt $MAX_API_CALLS ]]; do
        api_calls=$((api_calls + 1))

        # Log mesajı: build alındıysa kaçıncı olduğunu göster
        if [[ $build_attempts -eq 0 ]]; then
            log "AI dosyaları tarıyor... (API: $api_calls)"
        else
            log "AI'ya gönderiliyor... (Build: $build_attempts/$MAX_BUILD_ATTEMPTS | API: $api_calls)"
        fi

        local full_msg="$user_msg"
        [[ -n "$conversation" ]] && full_msg="$conversation\n\n---\n$user_msg"

        local ai_response
        ai_response=$(call_ai "$SYSTEM_PROMPT" "$full_msg") || { err "API yanıt vermedi."; sleep 2; continue; }
        [[ -z "$ai_response" ]] && { err "API boş yanıt döndü."; continue; }
        conversation="$full_msg\n\nAI: $ai_response"

        # ── CMD ────────────────────────────────────────────────────────────────
        if echo "$ai_response" | grep -q "^CMD:" && ! echo "$ai_response" | grep -q "^REPLACE_BLOCK:"; then
            local cmd
            cmd=$(echo "$ai_response" | grep "^CMD:" | head -1 | sed 's/^CMD: *//')
            if is_safe_cmd "$cmd"; then
                log "Komut çalıştırılıyor (Build sayılmaz): $cmd"
                cd "$PROJECT_ROOT"
                local cmd_out
                cmd_out=$(eval "$cmd" 2>&1 || true)
                cmd_out=$(echo "$cmd_out" | head -n 300)
                user_msg="KOMUT ÇIKTISI:\n$cmd_out\n\nDevam et. REPLACE_BLOCK üret. <<<SEARCH içine AYNEN dosyadaki satırları yaz (boşluk/indent dahil)."
                replace_fail_streak=0
            else
                user_msg="Güvensiz komut engellendi. Sadece cat, grep, sed (okuma) kullan."
            fi
            # build_attempts ARTMAZ
            continue
        fi

        # ── REPLACE_BLOCK ──────────────────────────────────────────────────────
        if echo "$ai_response" | grep -q "^REPLACE_BLOCK:"; then
            local rp
            rp=$(echo "$ai_response" | grep "^REPLACE_BLOCK:" | head -1 | cut -d: -f2- | xargs)
            local search_text
            search_text=$(echo "$ai_response" | awk '/^<<<SEARCH/{found=1; next} /^===/{found=0} found{print}')
            local replace_text
            replace_text=$(echo "$ai_response" | awk '/^>>>REPLACE/{found=1; next} /^>>>END/{found=0} found{print}')

            # REPLACE_BLOCK içinde >>>REPLACE yoksa === sonrasını al (eski format uyumu)
            if [[ -z "$replace_text" ]]; then
                replace_text=$(echo "$ai_response" | awk '/^===/{found=1; next} /^>>>END/{found=0} found{print}')
            fi

            log "REPLACE deneniyor: $rp"
            local replace_output
            if replace_output=$(apply_search_replace "$rp" "$search_text" "$replace_text" 2>&1); then
                ok "Kod değiştirildi: $replace_output"
                replace_fail_streak=0

                # ── AI kendi kontrolünü yapıyor ────────────────────────────────
                # Replace sonrası replace_text'in ilk anlamlı satırını grep ile ara
                local check_line
                check_line=$(echo "$replace_text" | grep -v '^\s*$' | head -1 | sed 's/^[[:space:]]*//' | cut -c1-60)
                if [[ -n "$check_line" ]]; then
                    local verify_out
                    verify_out=$(grep -n "$check_line" "$PROJECT_ROOT/$rp" 2>/dev/null | head -3 || echo "")
                    if [[ -z "$verify_out" ]]; then
                        warn "Kontrol: Yeni kod dosyada doğrulanamadı. Build alınmadan tekrar deneniyor..."
                        user_msg="KONTROL BAŞARISIZ: Replace uygulandı ancak yeni kod dosyada bulunamadı.\nDosya: $rp\nAranan: $check_line\nDosyayı tekrar oku ve REPLACE_BLOCK üret."
                        continue  # build_attempts ARTMAZ
                    else
                        log "Kontrol başarılı: Yeni kod dosyada bulundu (satır: $(echo "$verify_out" | head -1 | cut -d: -f1))"
                    fi
                fi

                # ── Build al ──────────────────────────────────────────────────
                build_attempts=$((build_attempts + 1))
                log "Build alınıyor... (Deneme $build_attempts/$MAX_BUILD_ATTEMPTS)"
                cd "$PROJECT_ROOT"
                ./gradlew assembleDebug --no-daemon > "$TMP_DIR/sf_build.txt" 2>&1 || true

                local new_errors
                new_errors=$(count_errors "$TMP_DIR/sf_build.txt")

                if grep -q "BUILD SUCCESSFUL" "$TMP_DIR/sf_build.txt"; then
                    ok "🎉 BUILD BAŞARILI! Hata çözüldü ($INITIAL_ERRORS → 0)."
                    cp "$TMP_DIR/sf_build.txt" "$ERROR_LOG"
                    exit 0
                elif [[ "$new_errors" -lt "$INITIAL_ERRORS" ]]; then
                    ok "Hatalar azaldı ($INITIAL_ERRORS → $new_errors). Devam ediliyor..."
                    cp "$TMP_DIR/sf_build.txt" "$ERROR_LOG"
                    INITIAL_ERRORS=$new_errors
                    local new_error_text
                    new_error_text=$(grep -E "^e:|error:|Unresolved|AAPT|Exception" "$TMP_DIR/sf_build.txt" | head -40 || cat "$TMP_DIR/sf_build.txt" | tail -40)
                    user_msg="Hatalar azaldı ($new_errors kaldı). Devam et.\nYENİ HATALAR:\n$new_error_text"
                else
                    warn "Build başarısız, hata sayısı aynı veya arttı ($INITIAL_ERRORS → $new_errors)."
                    local build_errors_short
                    build_errors_short=$(grep -E "^e:|error:|Unresolved" "$TMP_DIR/sf_build.txt" | head -20)
                    user_msg="BUILD BAŞARISIZ ($build_attempts/$MAX_BUILD_ATTEMPTS hak kullanıldı).\nHatalar: $INITIAL_ERRORS → $new_errors\nYENİ BUILD ÇIKTISI:\n$build_errors_short\n\nFarklı bir yaklaşım dene."
                fi
            else
                # REPLACE başarısız → build ALINMAZ, hak EKSİLMEZ
                replace_fail_streak=$((replace_fail_streak + 1))
                warn "Replace uygulanamadı (streak: $replace_fail_streak): $replace_output"

                # AI'ya hata + debug bilgisi gönder
                # Aranan ilk satırı dosyada manuel grep ile kontrol et
                local search_first_line
                search_first_line=$(echo "$search_text" | grep -v '^\s*$' | head -1 | sed 's/^[[:space:]]*//' | cut -c1-80)
                local grep_result=""
                if [[ -n "$search_first_line" && -f "$PROJECT_ROOT/$rp" ]]; then
                    grep_result=$(grep -n "$search_first_line" "$PROJECT_ROOT/$rp" 2>/dev/null | head -5 || echo "(bulunamadı)")
                fi

                user_msg="REPLACE BAŞARISIZ: $replace_output\n\nAranan ilk satır: '$search_first_line'\nDosyadaki eşleşmeler: $grep_result\n\nÖNEMLİ: <<<SEARCH bloğuna dosyada AYNEN olan satırları yaz — boşluk, indent, hepsi birebir olmalı.\nÖnce CMD: sed -n 'X,Yp' ile o satır aralığını oku, tam kopyala."
                # build_attempts ARTMAZ
                continue
            fi
            continue
        fi

        # ── Geçersiz format ────────────────────────────────────────────────────
        user_msg="Geçersiz format. Sadece CMD: veya REPLACE_BLOCK: kullan. Başka hiçbir şey yazma."
    done

    # ── 5 build hakkı bitti veya limit aşıldı → Snapshot'tan geri dön ─────────
    err "$MAX_BUILD_ATTEMPTS build denemesi tükendi, hata çözülemedi."
    restore_snapshot
    exit 1
}

main
