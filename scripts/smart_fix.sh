#!/data/data/com.termux/files/usr/bin/bash
# smart_fix.sh v6
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
ok()   { echo -e "${GREEN}[sf] OK: $*${NC}"; }
warn() { echo -e "${YELLOW}[sf] WARN: $*${NC}"; }
err()  { echo -e "${RED}[sf] ERR: $*${NC}"; }

# ── Hata sayım ────────────────────────────────────────────────────────────────
count_errors() {
    grep -cE "(^e: |error:|Exception|What went wrong|Could not find|AAPT|Unresolved reference)" \
        "$1" 2>/dev/null || echo 0
}

# ── Snapshot ──────────────────────────────────────────────────────────────────
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
        warn "Snapshot bulunamadı, rollback yapılamadı."
    fi
}

# ── Provider ──────────────────────────────────────────────────────────────────
load_provider() {
    local default_prov conf_file=""
    default_prov=$(grep "^DEFAULT_PROVIDER=" ~/.config/autofix.conf 2>/dev/null | cut -d'"' -f2 || echo "")
    [[ -n "$default_prov" ]] && conf_file="$APILER_DIR/$(echo "$default_prov" | tr '[:upper:]' '[:lower:]').conf"
    [[ -z "$conf_file" || ! -f "$conf_file" ]] && conf_file=$(ls "$APILER_DIR"/*.conf 2>/dev/null | head -1 || true)
    [[ -z "$conf_file" || ! -f "$conf_file" ]] && { err "Provider conf bulunamadı"; exit 1; }

    SF_NAME=$(grep  "^NAME="        "$conf_file" | cut -d'"' -f2)
    SF_URL=$(grep   "^API_URL="     "$conf_file" | cut -d'"' -f2)
    SF_KEY=$(grep   "^API_KEY="     "$conf_file" | cut -d'"' -f2)
    SF_MODEL=$(grep "^MODEL="       "$conf_file" | cut -d'"' -f2)
    SF_TOKENS=$(grep "^MAX_TOKENS=" "$conf_file" 2>/dev/null | cut -d= -f2 || echo 8000)
}

# ── Sistem Prompt ─────────────────────────────────────────────────────────────
load_system_prompt() {
    local prompt_file="/storage/emulated/0/termux-otonom-sistem/prompts/smart_fix_system.txt"
    if [[ -f "$prompt_file" ]]; then
        cat "$prompt_file"
    else
        echo "HATA: Prompt dosyası bulunamadı: $prompt_file" >&2
        exit 1
    fi
}

# ── API çağrısı ───────────────────────────────────────────────────────────────
call_ai() {
    local sp="$1" um="$2" out="$TMP_DIR/sf_response.json"
    local payload
    payload=$(python3 -c "
import json, sys
sp, um, name, model, tokens = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], int(sys.argv[5])
if name == 'Claude':
    print(json.dumps({'model': model, 'max_tokens': tokens, 'system': sp,
        'messages': [{'role': 'user', 'content': um}]}))
elif name == 'Gemini':
    print(json.dumps({'systemInstruction': {'parts': [{'text': sp}]},
        'contents': [{'parts': [{'text': um}]}],
        'generationConfig': {'maxOutputTokens': tokens, 'temperature': 0.1}}))
else:
    print(json.dumps({'model': model, 'max_tokens': tokens, 'temperature': 0.1,
        'messages': [{'role': 'system', 'content': sp}, {'role': 'user', 'content': um}]}))
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
    if   [[ "$SF_NAME" == "Claude" ]]; then jq -r '.content[0].text'                     "$out" 2>/dev/null
    elif [[ "$SF_NAME" == "Gemini" ]]; then jq -r '.candidates[0].content.parts[0].text' "$out" 2>/dev/null
    else                                    jq -r '.choices[0].message.content'           "$out" 2>/dev/null
    fi
}

is_safe_cmd() {
    echo "$1" | grep -qE '(>>|\brm\b|\bmv\b|\bchmod\b|\bsed\s.*-i\b|gradlew)' && return 1 || return 0
}

# ── Build logundaki hatalı dosyaların içeriklerini topla ─────────────────────
collect_error_file_contents() {
    local build_log="$1"
    local output=""
    local seen=()

    while IFS= read -r fpath; do
        [[ -z "$fpath" || ! -f "$fpath" ]] && continue
        local already=0
        for s in "${seen[@]:-}"; do [[ "$s" == "$fpath" ]] && already=1 && break; done
        [[ $already -eq 1 ]] && continue
        seen+=("$fpath")

        local line_count
        line_count=$(wc -l < "$fpath" 2>/dev/null || echo 0)
        output+="\n=== DOSYA: ${fpath#$PROJECT_ROOT/} ($line_count satır) ===\n"
        if [[ $line_count -le 150 ]]; then
            output+=$(cat "$fpath")
        else
            output+=$(head -n 80 "$fpath")
            output+="\n... (orta atlandı) ...\n"
            output+=$(tail -n 20 "$fpath")
        fi
        output+="\n"
    done < <(grep -oE 'file:///[^ :]+\.(kt|java|xml)' "$build_log" 2>/dev/null \
                | sed 's|file:///||' | sort -u | head -4)

    echo -e "$output"
}

# ── SEARCH/REPLACE Python motoru ─────────────────────────────────────────────
apply_search_replace() {
    local rel_path="$1" search_text="$2" replace_text="$3"
    local abs_path="$PROJECT_ROOT/$rel_path"
    [[ ! -f "$abs_path" ]] && { echo "HATA: Dosya yok: $abs_path"; return 1; }

    python3 - "$abs_path" "$search_text" "$replace_text" << 'PYEOF'
import sys

path         = sys.argv[1]
search_text  = sys.argv[2]
replace_text = sys.argv[3]

content = open(path, encoding='utf-8').read()
lines   = content.splitlines(keepends=True)

# Strateji 1: Tam eşleşme
if search_text in content:
    ob = search_text.count('{') - search_text.count('}')
    nb = replace_text.count('{') - replace_text.count('}')
    if ob != nb:
        print(f"HATA: Parantez dengesizligi! Eski:{ob:+d} Yeni:{nb:+d}")
        sys.exit(1)
    new_content = content.replace(search_text, replace_text, 1)
    open(path, 'w', encoding='utf-8').write(new_content)
    print(f"REPLACE OK (tam): {len(lines)} -> {len(new_content.splitlines())} satir")
    sys.exit(0)

# Strateji 2: Satır bazlı fuzzy (indent görmezden gel)
search_lines     = [l.strip() for l in search_text.splitlines() if l.strip()]
file_bare        = [l.strip() for l in lines]

if not search_lines:
    print("HATA: SEARCH blogu bos")
    sys.exit(1)

match_start = -1
for i in range(len(file_bare)):
    if file_bare[i] != search_lines[0]:
        continue
    if i + len(search_lines) > len(file_bare):
        continue
    if all(file_bare[i+j] == search_lines[j] for j in range(len(search_lines))):
        match_start = i
        break

if match_start == -1:
    # Debug: aranan ilk satırın gerçek dosya içeriğiyle hint'i göster
    first = search_lines[0]
    hints = []
    for idx, bare in enumerate(file_bare):
        if first in bare or bare in first:
            real = lines[idx].rstrip() if idx < len(lines) else ''
            hints.append(f"  satir {idx+1}: {repr(real)}")
    hint_text = "\n".join(hints[:6]) if hints else "  (hic bulunamadi — fonksiyon dosyada yok olabilir)"
    print(f"HATA: Aranan kod dosyada bulunamadi.\nAranan (strip): '{first}'\nGercek eslesme adaylari:\n{hint_text}")
    sys.exit(1)

match_end = match_start + len(search_lines)
ob = search_text.count('{') - search_text.count('}')
nb = replace_text.count('{') - replace_text.count('}')
if ob != nb:
    print(f"HATA: Parantez dengesizligi! Eski:{ob:+d} Yeni:{nb:+d}")
    sys.exit(1)

# Orijinal satırın indent'ini al
orig_indent = ''
for ch in (lines[match_start] if match_start < len(lines) else ''):
    if ch in (' ', '\t'): orig_indent += ch
    else: break

# Replace satırlarını indent'le
indented = []
for rl in replace_text.splitlines():
    stripped = rl.strip()
    if not stripped:
        indented.append('\n')
        continue
    own = ''
    for ch in rl:
        if ch in (' ', '\t'): own += ch
        else: break
    indented.append((rl if own else orig_indent + stripped) + '\n')

new_lines = lines[:match_start] + indented + lines[match_end:]
open(path, 'w', encoding='utf-8').write(''.join(new_lines))
print(f"REPLACE OK (fuzzy satir {match_start+1}-{match_end}): {len(lines)} -> {len(new_lines)} satir")
sys.exit(0)
PYEOF
}

# ═════════════════════════════════════════════════════════════════════════════
main() {
    load_provider
    local SYSTEM_PROMPT
    SYSTEM_PROMPT=$(load_system_prompt)

    # 1. Taze build → güncel hata logu
    log "Taze build alınıyor..."
    cd "$PROJECT_ROOT"
    ./gradlew assembleDebug --no-daemon > "$TMP_DIR/sf_initial_build.txt" 2>&1 || true
    ERROR_LOG="$TMP_DIR/sf_initial_build.txt"
    local INITIAL_ERRORS
    INITIAL_ERRORS=$(count_errors "$ERROR_LOG")
    log "Smart Fix başlatıldı. Toplam hata: $INITIAL_ERRORS"

    # 2. Snapshot
    take_snapshot

    # 3. İlk mesaj: hata + hatalı dosya içerikleri birlikte
    local error_text
    error_text=$(grep -E "^e:|error:|Unresolved|AAPT|Exception" "$ERROR_LOG" | head -40 \
                    || tail -40 "$ERROR_LOG")
    local file_contents
    file_contents=$(collect_error_file_contents "$ERROR_LOG")
    local task_context=""
    [[ -n "$TASK" ]] && task_context="GÖREV: $TASK\n\n"

    local user_msg="${task_context}BUILD HATALARI ($INITIAL_ERRORS adet):\n${error_text}\n\nHATALI DOSYALARIN İÇERİĞİ (referans):\n${file_contents}\n\nİLK ADIMIN CMD OLMALI — dosyayı oku, sonra REPLACE_BLOCK ver."
    local conversation=""

    local MAX_BUILD_ATTEMPTS=5
    local MAX_API_CALLS=35
    local MAX_CMD_WITHOUT_REPLACE=5   # Art arda bu kadar CMD sonrası REPLACE zorla
    local build_attempts=0
    local api_calls=0
    local replace_fail_streak=0
    local has_read_file=0             # AI en az bir CMD verdiyse 1
    local cmd_streak=0                # Build olmadan art arda kaç CMD verildi
    local last_cmd=""                 # Tekrar eden CMD tespiti

    while [[ $build_attempts -lt $MAX_BUILD_ATTEMPTS && $api_calls -lt $MAX_API_CALLS ]]; do
        api_calls=$((api_calls + 1))

        if [[ $build_attempts -eq 0 ]]; then
            log "AI dosyaları tarıyor... (API: $api_calls | CMD streak: $cmd_streak/$MAX_CMD_WITHOUT_REPLACE)"
        else
            log "AI'ya gönderiliyor... (Build: $build_attempts/$MAX_BUILD_ATTEMPTS | API: $api_calls)"
        fi

        local full_msg="$user_msg"
        [[ -n "$conversation" ]] && full_msg="${conversation}\n\n---\n${user_msg}"

        local ai_response
        ai_response=$(call_ai "$SYSTEM_PROMPT" "$full_msg") || { err "API yanıt vermedi."; sleep 2; continue; }
        [[ -z "$ai_response" ]] && { err "API boş yanıt döndü."; continue; }
        conversation="${full_msg}\n\nAI: ${ai_response}"

        # ── REPLACE_BLOCK, hiç dosya okumadan geldi → reddet + otomatik oku ──
        if echo "$ai_response" | grep -q "^REPLACE_BLOCK:" && [[ $has_read_file -eq 0 ]]; then
            warn "AI dosya okumadan REPLACE_BLOCK verdi — reddedildi."
            local rp_early
            rp_early=$(echo "$ai_response" | grep "^REPLACE_BLOCK:" | head -1 | cut -d: -f2- | xargs)
            local auto_read=""
            if [[ -n "$rp_early" && -f "$PROJECT_ROOT/$rp_early" ]]; then
                auto_read=$(cat "$PROJECT_ROOT/$rp_early" 2>/dev/null | head -n 200)
                log "Otomatik okunuyor: $rp_early"
            fi
            has_read_file=1
            user_msg="KURAL İHLALİ: Önce CMD ver. Dosya otomatik okundu:\n\n=== $rp_early ===\n${auto_read}\n\nYukarıdaki dosyayı esas alarak REPLACE_BLOCK ver. <<<SEARCH içine AYNEN dosyadan kopyala."
            continue
        fi

        # ── CMD ───────────────────────────────────────────────────────────────
        if echo "$ai_response" | grep -q "^CMD:" && ! echo "$ai_response" | grep -q "^REPLACE_BLOCK:"; then
            local cmd
            cmd=$(echo "$ai_response" | grep "^CMD:" | head -1 | sed 's/^CMD: *//')

            # Aynı komutu tekrar veriyor mu? → engelle + tüm dosyayı gönder
            if [[ -n "$last_cmd" && "$cmd" == "$last_cmd" ]]; then
                warn "Tekrar eden CMD engellendi: '$cmd'"
                local dup_file
                dup_file=$(echo "$cmd" | grep -oE '[a-zA-Z0-9_./-]+\.kt' | head -1 || echo "")
                local dup_content=""
                if [[ -n "$dup_file" && -f "$PROJECT_ROOT/$dup_file" ]]; then
                    dup_content=$(cat "$PROJECT_ROOT/$dup_file" | head -n 200 | cat -n)
                fi
                user_msg="TEKRAR EDEN CMD ENGELLENDİ: Bu komutu zaten çalıştırdın, aynı çıktıyı alırsın.\n\nDOSYA TAM İÇERİK (satır numaralı):\n${dup_content}\n\nARTIK REPLACE_BLOCK ver. Daha fazla CMD verme."
                cmd_streak=$((cmd_streak + 1))
                continue
            fi

            # CMD streak limiti aşıldı → tüm hatalı dosyaları gönder, REPLACE zorla
            if [[ $cmd_streak -ge $MAX_CMD_WITHOUT_REPLACE ]]; then
                warn "CMD limiti aşıldı ($cmd_streak/$MAX_CMD_WITHOUT_REPLACE) — REPLACE_BLOCK zorlanıyor."
                local forced_contents
                forced_contents=$(collect_error_file_contents "$ERROR_LOG")
                user_msg="CMD LİMİTİ AŞILDI: $cmd_streak komut çalıştırdın, hâlâ REPLACE_BLOCK vermedin.\n\nTÜM HATALI DOSYALAR (satır numaralı):\n${forced_contents}\n\nARTIK SADECE REPLACE_BLOCK ver. CMD yasak bu turda."
                cmd_streak=0
                last_cmd=""
                continue
            fi

            if is_safe_cmd "$cmd"; then
                last_cmd="$cmd"
                cmd_streak=$((cmd_streak + 1))
                log "Komut çalıştırılıyor (Build sayılmaz, streak: $cmd_streak/$MAX_CMD_WITHOUT_REPLACE): $cmd"
                cd "$PROJECT_ROOT"
                local cmd_out
                cmd_out=$(eval "$cmd" 2>&1 || true)
                # Satır numarası ekle — AI dosyadaki pozisyonu anlasın
                cmd_out=$(echo "$cmd_out" | head -n 300 | cat -n)
                has_read_file=1
                replace_fail_streak=0

                # Streak 3+ olunca baskı mesajı ekle
                local cmd_pressure=""
                if [[ $cmd_streak -ge 3 ]]; then
                    cmd_pressure="\n\n⚠️ UYARI: $cmd_streak CMD kullandın (limit: $MAX_CMD_WITHOUT_REPLACE). Bir sonraki adımın REPLACE_BLOCK OLMALI."
                fi
                user_msg="KOMUT ÇIKTISI (satır numaralı):\n${cmd_out}\n\nBu çıktıdan <<<SEARCH için AYNEN kopyala (boşluk/indent dahil). REPLACE_BLOCK ver.${cmd_pressure}"
            else
                user_msg="Güvensiz komut engellendi: '${cmd}'\nSadece cat, grep, sed (okuma), find kullan."
            fi
            continue
        fi

        # ── REPLACE_BLOCK ama streak>=2 → önce otomatik dosya oku ─────────────
        if echo "$ai_response" | grep -q "^REPLACE_BLOCK:" && [[ $replace_fail_streak -ge 2 ]]; then
            local rp_lock
            rp_lock=$(echo "$ai_response" | grep "^REPLACE_BLOCK:" | head -1 | cut -d: -f2- | xargs)
            warn "REPLACE $replace_fail_streak kez başarısız — dosya otomatik okunuyor: $rp_lock"

            local err_line
            err_line=$(grep -oE "${rp_lock##*/}:[0-9]+" "$ERROR_LOG" 2>/dev/null \
                        | head -1 | cut -d: -f2 || echo "")
            local auto_ctx=""
            if [[ -n "$err_line" && -f "$PROJECT_ROOT/$rp_lock" ]]; then
                local from=$(( err_line > 20 ? err_line - 20 : 1 ))
                local to=$(( err_line + 20 ))
                auto_ctx=$(sed -n "${from},${to}p" "$PROJECT_ROOT/$rp_lock" 2>/dev/null)
                log "Hata çevresi okunuyor (satır $from-$to)"
            elif [[ -f "$PROJECT_ROOT/$rp_lock" ]]; then
                auto_ctx=$(cat "$PROJECT_ROOT/$rp_lock" | head -n 150)
            fi
            has_read_file=1
            user_msg="REPLACE $replace_fail_streak KER BAŞARISIZ.\n\nDOSYA ($rp_lock):\n${auto_ctx}\n\nYukarıdan <<<SEARCH için AYNEN kopyala."
            continue
        fi

        # ── REPLACE_BLOCK işlemi ──────────────────────────────────────────────
        if echo "$ai_response" | grep -q "^REPLACE_BLOCK:"; then
            local rp
            rp=$(echo "$ai_response" | grep "^REPLACE_BLOCK:" | head -1 | cut -d: -f2- | xargs)
            local search_text
            search_text=$(echo "$ai_response" | awk '/^<<<SEARCH/{f=1;next} /^===/{f=0} f{print}')
            local replace_text
            replace_text=$(echo "$ai_response" | awk '/^===/{f=1;next} /^>>>END/{f=0} f{print}')

            # CMD streak + last_cmd sıfırla — REPLACE denendi
            cmd_streak=0
            last_cmd=""

            log "REPLACE deneniyor: $rp"
            local replace_output
            if replace_output=$(apply_search_replace "$rp" "$search_text" "$replace_text" 2>&1); then
                ok "Kod değiştirildi: $replace_output"
                replace_fail_streak=0

                # Kontrol: yeni kod dosyada var mı?
                local check_line
                check_line=$(echo "$replace_text" | grep -v '^\s*$' | head -1 \
                                | sed 's/^[[:space:]]*//' | cut -c1-60)
                if [[ -n "$check_line" ]]; then
                    local verify_out
                    verify_out=$(grep -Fn "$check_line" "$PROJECT_ROOT/$rp" 2>/dev/null | head -3 || echo "")
                    if [[ -z "$verify_out" ]]; then
                        warn "Kontrol başarısız: yeni kod dosyada bulunamadı. Build alınmıyor."
                        user_msg="KONTROL BAŞARISIZ: '${check_line}' dosyada yok.\nDosyayı tekrar oku ve doğru REPLACE_BLOCK ver."
                        has_read_file=0
                        continue
                    else
                        log "Kontrol OK → satır $(echo "$verify_out" | head -1 | cut -d: -f1)"
                    fi
                fi

                # Build al
                build_attempts=$((build_attempts + 1))
                log "Build alınıyor... ($build_attempts/$MAX_BUILD_ATTEMPTS)"
                cd "$PROJECT_ROOT"
                ./gradlew assembleDebug --no-daemon > "$TMP_DIR/sf_build.txt" 2>&1 || true

                local new_errors
                new_errors=$(count_errors "$TMP_DIR/sf_build.txt")

                if grep -q "BUILD SUCCESSFUL" "$TMP_DIR/sf_build.txt"; then
                    ok "BUILD BAŞARILI! ($INITIAL_ERRORS hata → 0)"
                    cp "$TMP_DIR/sf_build.txt" "$ERROR_LOG"
                    exit 0
                elif [[ "$new_errors" -lt "$INITIAL_ERRORS" ]]; then
                    ok "Hatalar azaldı ($INITIAL_ERRORS → $new_errors). Devam..."
                    cp "$TMP_DIR/sf_build.txt" "$ERROR_LOG"
                    INITIAL_ERRORS=$new_errors
                    local new_err_text
                    new_err_text=$(grep -E "^e:|error:|Unresolved|AAPT|Exception" \
                                    "$TMP_DIR/sf_build.txt" | head -30)
                    local new_file_contents
                    new_file_contents=$(collect_error_file_contents "$TMP_DIR/sf_build.txt")
                    has_read_file=0
                    user_msg="Hatalar azaldı ($new_errors kaldı).\nYENİ HATALAR:\n${new_err_text}\n\nHATALI DOSYALAR:\n${new_file_contents}\n\nİLK ADIMIN CMD OLMALI."
                else
                    warn "Build başarısız ($INITIAL_ERRORS → $new_errors)."
                    local build_err_short
                    build_err_short=$(grep -E "^e:|error:|Unresolved" "$TMP_DIR/sf_build.txt" | head -20)
                    has_read_file=0
                    user_msg="BUILD BAŞARISIZ ($build_attempts/$MAX_BUILD_ATTEMPTS hak).\nHatalar: $INITIAL_ERRORS → $new_errors\n${build_err_short}\n\nFarklı yaklaşım dene. Önce CMD ile dosyayı oku."
                fi
            else
                # REPLACE başarısız — build alınmaz, hak eksilmez
                replace_fail_streak=$((replace_fail_streak + 1))
                warn "Replace başarısız (streak: $replace_fail_streak)"

                local s_first
                s_first=$(echo "$search_text" | grep -v '^\s*$' | head -1 \
                            | sed 's/^[[:space:]]*//' | cut -c1-80)

                # Dosyadaki gerçek içerikle hint göster (boş satır değil)
                local grep_hits=""
                if [[ -n "$s_first" && -f "$PROJECT_ROOT/$rp" ]]; then
                    grep_hits=$(grep -n "$s_first" "$PROJECT_ROOT/$rp" 2>/dev/null | head -5 || true)
                fi

                # Eşleşme yoksa hata satırı çevresini otomatik gönder
                local auto_context=""
                if [[ -z "$grep_hits" ]]; then
                    local err_line
                    err_line=$(grep -oE "${rp##*/}:[0-9]+" "$ERROR_LOG" 2>/dev/null \
                                | head -1 | cut -d: -f2 || echo "")
                    if [[ -n "$err_line" && -f "$PROJECT_ROOT/$rp" ]]; then
                        local from=$(( err_line > 20 ? err_line - 20 : 1 ))
                        local to=$(( err_line + 20 ))
                        auto_context=$(sed -n "${from},${to}p" "$PROJECT_ROOT/$rp" 2>/dev/null)
                        log "Hata çevresi eklendi: satır $from-$to"
                    else
                        auto_context=$(cat "$PROJECT_ROOT/$rp" 2>/dev/null | head -n 120)
                    fi
                fi

                user_msg="REPLACE BAŞARISIZ (streak: $replace_fail_streak).\nHata: ${replace_output}\n\nAranan: '${s_first}'\nDosyadaki eşleşmeler: ${grep_hits:-yok}\n\nDOSYA BÖLÜMÜ:\n${auto_context}\n\nYUKARIDAKİ DOSYADAN AYNEN KOPYALA. <<<SEARCH birebir aynı olmalı."
            fi
            continue
        fi

        # ── Geçersiz format ───────────────────────────────────────────────────
        user_msg="Geçersiz format. Sadece 'CMD: <komut>' veya 'REPLACE_BLOCK: ...' yaz."
    done

    err "$MAX_BUILD_ATTEMPTS build denemesi tükendi, hata çözülemedi."
    restore_snapshot
    exit 1
}

main
