#!/data/data/com.termux/files/usr/bin/bash
# smart_task.sh v2.0 — smart_fix temel alınarak yazıldı
# Kullanım: bash smart_task.sh <proje_dizini> <kullanici_gorevi>
# apply_fixes ile run_autofix arasında çalışır.
# Build ALMAZ. Eksikleri cerrahi doldurur → sessizce çıkar.

set +e

PROJECT_ROOT="${1:-}"
USER_TASK="${2:-}"

[[ -z "$PROJECT_ROOT" || ! -d "$PROJECT_ROOT" ]] && { echo "[st] Proje dizini yok, atlanıyor."; exit 0; }
[[ -z "$USER_TASK" ]] && { echo "[st] Görev yok, atlanıyor."; exit 0; }

SISTEM_DIR="/storage/emulated/0/termux-otonom-sistem"
APILER_DIR="$SISTEM_DIR/apiler"
TMP_DIR="$HOME/.autofix_tmp"
SNAPSHOT_FILE="$TMP_DIR/st_snapshot_${RANDOM}.tar.gz"
mkdir -p "$TMP_DIR"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
log()  { echo -e "${CYAN}[st]${NC} $*"; }
ok()   { echo -e "${GREEN}[st] ✅ $*${NC}"; }
warn() { echo -e "${YELLOW}[st] ⚠️  $*${NC}"; }
err()  { echo -e "${RED}[st] ❌ $*${NC}"; }
title(){ echo -e "\n${BOLD}${CYAN}══ [SmartTask] $* ══${NC}\n"; }

load_provider() {
    local default_prov conf_file=""
    default_prov=$(grep "^DEFAULT_PROVIDER=" ~/.config/autofix.conf 2>/dev/null | cut -d'"' -f2 || echo "")
    [[ -n "$default_prov" ]] && conf_file="$APILER_DIR/$(echo "$default_prov" | tr '[:upper:]' '[:lower:]').conf"
    [[ -z "$conf_file" || ! -f "$conf_file" ]] && conf_file=$(ls "$APILER_DIR"/*.conf 2>/dev/null | head -1 || true)
    [[ -z "$conf_file" || ! -f "$conf_file" ]] && { err "Provider conf bulunamadı, atlanıyor."; exit 0; }
    SF_NAME=$(grep  "^NAME="        "$conf_file" | cut -d'"' -f2)
    SF_URL=$(grep   "^API_URL="     "$conf_file" | cut -d'"' -f2)
    SF_KEY=$(grep   "^API_KEY="     "$conf_file" | cut -d'"' -f2)
    SF_MODEL=$(grep "^MODEL="       "$conf_file" | cut -d'"' -f2)
    SF_TOKENS=$(grep "^MAX_TOKENS=" "$conf_file" 2>/dev/null | cut -d= -f2 || echo 8000)
}

call_ai() {
    local sp="$1" um="$2" out="$TMP_DIR/st_response.json"
    local payload
    echo "$sp" > "$TMP_DIR/st_sp.txt"
    echo "$um" > "$TMP_DIR/st_um.txt"
    local payload
    payload=$(python3 -c "
import json, sys
name, model, tokens = sys.argv[1], sys.argv[2], int(sys.argv[3])
sp = open('$TMP_DIR/st_sp.txt', encoding='utf-8').read()
um = open('$TMP_DIR/st_um.txt', encoding='utf-8').read()
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
" "$SF_NAME" "$SF_MODEL" "$SF_TOKENS")

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

apply_search_replace() {
    local rel_path="$1" search_text="$2" replace_text="$3"
    local abs_path="$rel_path"
    [[ "$rel_path" != /* ]] && abs_path="$PROJECT_ROOT/$rel_path"
    [[ ! -f "$abs_path" ]] && { echo "HATA: Dosya yok: $abs_path"; return 1; }

    python3 - "$abs_path" "$search_text" "$replace_text" << 'PYEOF'
import sys
path         = sys.argv[1]
search_text  = sys.argv[2]
replace_text = sys.argv[3]
content = open(path, encoding='utf-8').read()
lines   = content.splitlines(keepends=True)

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

search_lines = [l.strip() for l in search_text.splitlines() if l.strip()]
file_bare    = [l.strip() for l in lines]
if not search_lines:
    print("HATA: SEARCH blogu bos"); sys.exit(1)

match_start = -1
for i in range(len(file_bare)):
    if file_bare[i] != search_lines[0]: continue
    if i + len(search_lines) > len(file_bare): continue
    if all(file_bare[i+j] == search_lines[j] for j in range(len(search_lines))):
        match_start = i; break

if match_start == -1:
    first = search_lines[0]
    hints = []
    for idx, bare in enumerate(file_bare):
        if first in bare or bare in first:
            hints.append(f"  satir {idx+1}: {repr(lines[idx].rstrip() if idx < len(lines) else '')}")
    hint_text = "\n".join(hints[:4]) if hints else "  (bulunamadi)"
    print(f"HATA: Kod dosyada bulunamadi.\nAranan: '{first}'\nAdaylar:\n{hint_text}")
    sys.exit(1)

match_end = match_start + len(search_lines)
ob = search_text.count('{') - search_text.count('}')
nb = replace_text.count('{') - replace_text.count('}')
if ob != nb:
    print(f"HATA: Parantez dengesizligi! Eski:{ob:+d} Yeni:{nb:+d}"); sys.exit(1)

orig_indent = ''
for ch in (lines[match_start] if match_start < len(lines) else ''):
    if ch in (' ', '\t'): orig_indent += ch
    else: break

indented = []
for rl in replace_text.splitlines():
    stripped = rl.strip()
    if not stripped: indented.append('\n'); continue
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

take_snapshot() {
    tar -czf "$SNAPSHOT_FILE" -C "$PROJECT_ROOT" app/ 2>/dev/null || true
}

build_project_map() {
    local map_file="$TMP_DIR/st_map.txt"
    echo "=== KT DOSYALARI ===" > "$map_file"
    while IFS= read -r f; do
        local rel="${f#$PROJECT_ROOT/}"
        local lines; lines=$(wc -l < "$f" 2>/dev/null || echo 0)
        echo "--- $rel ($lines satır) ---" >> "$map_file"
        head -n 20 "$f" >> "$map_file"
        echo "" >> "$map_file"
    done < <(find "$PROJECT_ROOT/app/src/main" -name "*.kt" -not -path "*/build/*" 2>/dev/null)
    echo "$map_file"
}

run_checker() {
    local map_file="$1"
    local checker_sp="Sen Android kod denetçisisin. SADECE eksik KOD yapılarını raporla.

RAPOR FORMATI:
Eksik yoksa tek satır: TEMİZ

Eksik varsa her biri için (birer satır):
EKSIK: <dosya_yolu> | <ne eksik>
IMPORT_EKSIK: <dosya_yolu> | <eksik import satırı>
BAGIMLILIK_EKSIK: app/build.gradle | <eksik dependency satırı>

SAYMA:
- Ses/resim/font dosyası eksikleri (validator halleder)
- Gradle build hataları (autofix halleder)
- Sadece placeholder/boş composable/eksik ekran/eksik navigasyon say"

    local checker_um="KULLANICI GÖREVİ: $USER_TASK

PROJE DURUMU:
$(cat "$map_file")

Raporla."

    call_ai "$checker_sp" "$checker_um"
}

fix_one_missing() {
    local target_file="$1"
    local missing_desc="$2"

    log "Gideriliyor: $target_file — $missing_desc"

    local fixer_sp
    fixer_sp=$(cat "$SISTEM_DIR/prompts/smart_task_system.txt" 2>/dev/null || echo "Sen Android uzmanısın. REPLACE_BLOCK formatında cerrahi düzelt.")

    local file_content
    file_content=$(cat "$PROJECT_ROOT/$target_file" 2>/dev/null | head -n 300 || echo "DOSYA YOK")

    local user_msg="GÖREV: $USER_TASK

EKSİKLİK: $missing_desc

DOSYA ($target_file):
$file_content

Bu eksikliği REPLACE_BLOCK ile cerrahi olarak doldur. İLK ADIMIN CMD OLMALI."

    local conversation=""
    local api_calls=0
    local MAX_API_CALLS=15
    local replace_fail_streak=0
    local has_read_file=0
    local cmd_streak=0
    local last_cmd=""
    local api_fail_streak=0

    while [[ $api_calls -lt $MAX_API_CALLS ]]; do
        api_calls=$((api_calls+1))

        local full_msg="$user_msg"
        [[ -n "$conversation" ]] && full_msg="${conversation}\n\n---\n${user_msg}"

        local ai_response
        if ! ai_response=$(call_ai "$fixer_sp" "$full_msg"); then
            api_fail_streak=$((api_fail_streak+1))
            [[ $api_fail_streak -ge 3 ]] && { err "API sürekli hata, vazgeçildi."; return 1; }
            sleep 2; continue
        fi
        [[ -z "$ai_response" ]] && { err "Boş yanıt."; continue; }
        conversation="${full_msg}\n\nAI: ${ai_response}"
        api_fail_streak=0

        local ai_reasoning
        ai_reasoning=$(echo "$ai_response" | grep -vE "^CMD:|^REPLACE_BLOCK:|^<<<|^===|^>>>|^NEW_FILE:" | grep -v '^\s*$' 2>/dev/null | head -n 2 || true)
        [[ -n "$ai_reasoning" ]] && echo -e "\033[2m🤖 ${ai_reasoning:0:120}\033[0m"

        if echo "$ai_response" | grep -q "^REPLACE_BLOCK:" && [[ $has_read_file -eq 0 ]]; then
            local rp_early
            rp_early=$(echo "$ai_response" | grep "^REPLACE_BLOCK:" | head -1 | cut -d: -f2- | tr -d " " | tr -d "\r" | tr -d "\n")
            local auto_read=""
            [[ -f "$PROJECT_ROOT/$rp_early" ]] && auto_read=$(cat "$PROJECT_ROOT/$rp_early" | head -n 200)
            has_read_file=1
            user_msg="KURAL İHLALİ: Önce CMD ver. Dosya otomatik okundu:\n=== $rp_early ===\n${auto_read}\n\nREPLACE_BLOCK ver."
            continue
        fi

        if echo "$ai_response" | grep -q "^CMD:" && ! echo "$ai_response" | grep -q "^REPLACE_BLOCK:"; then
            local cmd
            cmd=$(echo "$ai_response" | grep "^CMD:" | head -1 | sed 's/^CMD: *//')

            if [[ $cmd_streak -ge 5 ]]; then
                warn "CMD limiti aşıldı, REPLACE_BLOCK zorlanıyor."
                user_msg="CMD LİMİTİ: $cmd_streak komut çalıştırdın. Artık REPLACE_BLOCK ver.\n\nDOSYA:\n$(cat "$PROJECT_ROOT/$target_file" 2>/dev/null | head -n 200)"
                cmd_streak=0; last_cmd=""; conversation=""
                continue
            fi

            if [[ -n "$last_cmd" && "$cmd" == "$last_cmd" ]]; then
                warn "Tekrar eden CMD engellendi."
                user_msg="TEKRAR EDEN CMD. Direkt REPLACE_BLOCK ver.\n\nDOSYA:\n$(cat "$PROJECT_ROOT/$target_file" 2>/dev/null | head -n 200)"
                last_cmd=""; cmd_streak=$((cmd_streak+1))
                continue
            fi

            if is_safe_cmd "$cmd"; then
                last_cmd="$cmd"; cmd_streak=$((cmd_streak+1))
                log "CMD ($cmd_streak/5): $cmd"
                cd "$PROJECT_ROOT"
                local cmd_out
                cmd_out=$(eval "$cmd" 2>&1 | head -n 300 || true)
                local clean_out
                clean_out=$(echo "$cmd_out" | grep -v '^\s*$' 2>/dev/null | head -2 || true)
                echo -e "\033[2m   ↳ ${clean_out:0:100}\033[0m"
                has_read_file=1; replace_fail_streak=0
                local pressure=""
                [[ $cmd_streak -ge 3 ]] && pressure="\n\n⚠️ $cmd_streak CMD kullandın. Sonraki adımın REPLACE_BLOCK olmalı."
                user_msg="CMD ÇIKTISI:\n${cmd_out}\n\nBu çıktıdan <<<SEARCH için AYNEN kopyala.${pressure}"
            else
                user_msg="Güvensiz komut: '${cmd}'. Sadece cat, grep, find, head, tail kullan."
            fi
            continue
        fi

        if echo "$ai_response" | grep -q "^REPLACE_BLOCK:" && [[ $replace_fail_streak -ge 2 ]]; then
            local rp_lock
            rp_lock=$(echo "$ai_response" | grep "^REPLACE_BLOCK:" | head -1 | cut -d: -f2- | tr -d " " | tr -d "\r" | tr -d "\n")
            warn "REPLACE $replace_fail_streak kez başarısız — otomatik okunuyor: $rp_lock"
            local auto_ctx
            auto_ctx=$(cat "$PROJECT_ROOT/$rp_lock" 2>/dev/null | head -n 150)
            has_read_file=1
            user_msg="REPLACE $replace_fail_streak KER BAŞARISIZ.\n\nDOSYA ($rp_lock):\n${auto_ctx}\n\nAYNEN kopyala."
            continue
        fi

        if echo "$ai_response" | grep -q "^NEW_FILE:"; then
            local nf_path
            nf_path=$(echo "$ai_response" | grep "^NEW_FILE:" | head -1 | cut -d: -f2- | tr -d " " | tr -d "\r" | tr -d "\n")
            local nf_content
            nf_content=$(echo "$ai_response" | awk '/^<<<CONTENT/{f=1;next} /^>>>END/{f=0} f{print}')
            if [[ -n "$nf_path" && -n "$nf_content" ]]; then
                mkdir -p "$PROJECT_ROOT/$(dirname "$nf_path")"
                echo "$nf_content" > "$PROJECT_ROOT/$nf_path"
                ok "Yeni dosya: $nf_path"
                return 0
            fi
            continue
        fi

        if echo "$ai_response" | grep -q "^REPLACE_BLOCK:"; then
            local rp
            rp=$(echo "$ai_response" | grep "^REPLACE_BLOCK:" | head -1 | cut -d: -f2- | tr -d " " | tr -d "\r" | tr -d "\n")
            local search_text
            search_text=$(echo "$ai_response" | awk '/^<<<SEARCH/{f=1;next} /^===/{f=0} f{print}')
            local replace_text
            replace_text=$(echo "$ai_response" | awk '/^===/{f=1;next} /^>>>END/{f=0} f{print}')

            local s_head; s_head=$(echo "$search_text" | grep -v '^\s*$' 2>/dev/null | head -1 || true)
            local r_head; r_head=$(echo "$replace_text" | grep -v '^\s*$' 2>/dev/null | head -1 || true)
            echo -e "\033[0;31m   - ${s_head:0:80}\033[0m"
            echo -e "\033[0;32m   + ${r_head:0:80}\033[0m"

            cmd_streak=0; last_cmd=""

            if [[ "$search_text" == "$replace_text" ]]; then
                warn "AI hiçbir şey değiştirmedi."
                replace_fail_streak=$((replace_fail_streak+1))
                user_msg="HATA: SEARCH ve REPLACE aynı! Gerçekten değiştir."
                continue
            fi
            # --- ANTI-BLOAT (KOD ŞİŞİRME) KONTROLÜ ---
            local file_lines=$(wc -l < "$PROJECT_ROOT/$rp" 2>/dev/null || echo 0)
            local replace_lines=$(echo "$replace_text" | wc -l)
            local search_lines=$(echo "$search_text" | wc -l)

            # Eğer REPLACE bloğu tüm dosya boyutuna eşit/büyükse ve SEARCH bloğu çok küçükse AI tüm dosyayı kopyalamıştır!
            if [[ $replace_lines -ge $file_lines && $file_lines -gt 30 && $search_lines -lt $((file_lines / 2)) ]]; then
                warn "ŞİŞİRME TESPİTİ: AI tüm dosyayı REPLACE bloğuna kopyaladı."
                replace_fail_streak=$((replace_fail_streak+1))
                user_msg="HATA: KOD ŞİŞİRME TESPİT EDİLDİ! \nBütün dosyayı REPLACE bloğunun içine kopyaladın. Bu kurnazlık dosyada aynı kodların 2 kez yazılmasına (duplicate) sebep olur.\nTüm dosyayı ASLA kopyalama! SADECE değiştireceğin veya ekleyeceğin kısmı (cerrahi olarak) ver!"
                continue
            fi

            local replace_output
            if replace_output=$(apply_search_replace "$rp" "$search_text" "$replace_text" 2>&1); then
                ok "Düzeltme uygulandı: $replace_output"
                return 0
            else
                replace_fail_streak=$((replace_fail_streak+1))
                warn "REPLACE başarısız ($replace_fail_streak): $replace_output"
                local s_first
                s_first=$(echo "$search_text" | grep -v '^\s*$' 2>/dev/null | head -1 | sed 's/^[[:space:]]*//' | cut -c1-80)
                local grep_hits
                grep_hits=$(grep -n "$s_first" "$PROJECT_ROOT/$rp" 2>/dev/null | head -5 || true)
                local auto_ctx
                auto_ctx=$(cat "$PROJECT_ROOT/$rp" 2>/dev/null | head -n 150)
                user_msg="REPLACE BAŞARISIZ.\nHata: ${replace_output}\nAranan: '${s_first}'\nEşleşmeler: ${grep_hits:-yok}\n\nDOSYA:\n${auto_ctx}\n\nAYNEN kopyala."
            fi
            continue
        fi

        user_msg="Geçersiz format. CMD: veya REPLACE_BLOCK: kullan."
    done

    warn "Max deneme doldu: $missing_desc"
    return 1
}

main() {
    load_provider
    title "Smart Task Kalite Kontrolü"
    log "Görev: $USER_TASK"
    log "Proje: $PROJECT_ROOT"

    take_snapshot

    local MAX_ROUNDS=8
    local round=0
    local total_fixed=0

    while [[ $round -lt $MAX_ROUNDS ]]; do
        round=$((round+1))
        title "Kontrol Turu $round / $MAX_ROUNDS"

        local map_file
        map_file=$(build_project_map)

        log "🔍 Checker AI analiz ediyor..."
        local checker_result
        if ! checker_result=$(run_checker "$map_file"); then
            warn "Checker API hatası, tur atlanıyor..."
            continue
        fi

        echo -e "\033[2m📋 Checker:\n$checker_result\033[0m"

        if echo "$checker_result" | grep -q "^TEMİZ"; then
            ok "Proje temiz! $total_fixed eksiklik giderildi."
            exit 0
        fi

        local eksikler=()
        while IFS= read -r line; do
            [[ "$line" == EKSIK:* || "$line" == IMPORT_EKSIK:* || "$line" == BAGIMLILIK_EKSIK:* ]] && eksikler+=("$line")
        done <<< "$checker_result"

        if [[ ${#eksikler[@]} -eq 0 ]]; then
            ok "Raporlanacak eksiklik yok."
            exit 0
        fi

        log "${#eksikler[@]} eksiklik tespit edildi."
        local round_fixed=0

        for eksik in "${eksikler[@]}"; do
            local target_file
            target_file=$(echo "$eksik" | cut -d'|' -f1 | sed 's/^EKSIK: //;s/^IMPORT_EKSIK: //;s/^BAGIMLILIK_EKSIK: //')
            local missing_desc
            missing_desc=$(echo "$eksik" | cut -d'|' -f2)

            if fix_one_missing "$target_file" "$missing_desc"; then
                total_fixed=$((total_fixed+1))
                round_fixed=$((round_fixed+1))
            else
                warn "Giderilemedi: $missing_desc"
            fi
        done

        if [[ $round_fixed -gt 0 ]]; then
            local p_name=$(basename "$PROJECT_ROOT")
            tar -czf "$SISTEM_DIR/yedekler/${p_name}-SmartTask_AraYedek-$(date +%H%M).tar.gz" --exclude=*/build --exclude=*/.gradle -C "$(dirname "$PROJECT_ROOT")" "$p_name" 2>/dev/null
            ok "🛡️ Tur başarıyla tamamlandı, Ara Yedek alındı!"
        fi

        if [[ $round_fixed -eq 0 ]]; then
            warn "Bu turda hiçbir eksiklik giderilemedi. Çıkılıyor."
            exit 0
        fi
    done

    warn "Max tur ($MAX_ROUNDS) doldu."
    exit 0
}

main
