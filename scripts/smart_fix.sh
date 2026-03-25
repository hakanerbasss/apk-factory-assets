#!/data/data/com.termux/files/usr/bin/bash
# smart_fix.sh v2 — Görev veya hata alır, REPLACE_BLOCK ile cerrahi düzeltme yapar
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

# ── Provider ──────────────────────────────────────────────────────────────────
load_provider() {
    local conf_file=""
    local default_prov
    default_prov=$(grep "^DEFAULT_PROVIDER=" ~/.config/autofix.conf 2>/dev/null | cut -d'"' -f2 || echo "")
    if [[ -n "$default_prov" ]]; then
        local prov_lower; prov_lower=$(echo "$default_prov" | tr '[:upper:]' '[:lower:]')
        conf_file="$APILER_DIR/${prov_lower}.conf"
    fi
    [[ -z "$conf_file" || ! -f "$conf_file" ]] && conf_file=$(ls "$APILER_DIR"/*.conf 2>/dev/null | head -1 || "")
    [[ -z "$conf_file" || ! -f "$conf_file" ]] && { err "Provider conf bulunamadı"; exit 1; }

    SF_NAME=$(grep "^NAME="    "$conf_file" | cut -d'"' -f2)
    SF_URL=$(grep  "^API_URL=" "$conf_file" | cut -d'"' -f2)
    SF_KEY=$(grep  "^API_KEY=" "$conf_file" | cut -d'"' -f2)
    SF_MODEL=$(grep "^MODEL="  "$conf_file" | cut -d'"' -f2)
    SF_TOKENS=$(grep "^MAX_TOKENS=" "$conf_file" 2>/dev/null | cut -d= -f2)
    SF_TOKENS=${SF_TOKENS:-8000}
    [[ -z "$SF_KEY" ]] && { err "$SF_NAME için API key yok"; exit 1; }
    log "Provider: $SF_NAME / $SF_MODEL"
}

# ── System prompt yükle ───────────────────────────────────────────────────────
load_system_prompt() {
    local prompt_file="$PROMPTS_DIR/smart_fix_system.txt"
    if [[ -f "$prompt_file" ]]; then
        cat "$prompt_file"
    else
        # Fallback — temel prompt
        echo 'Sen bir Android/Kotlin uzmanısın. REPLACE_BLOCK formatında sadece değişen bölümü yaz. Tüm dosyayı asla yeniden yazma.'
    fi
}

# ── API çağrısı ───────────────────────────────────────────────────────────────
call_ai() {
    local system_prompt="$1"
    local user_msg="$2"
    local out_file="$TMP_DIR/sf_response.json"

    local payload
    payload=$(python3 -c "
import json, sys
sp = sys.argv[1]; um = sys.argv[2]
name = sys.argv[3]; model = sys.argv[4]; tokens = int(sys.argv[5])
if name == 'Claude':
    print(json.dumps({'model': model, 'max_tokens': tokens,
        'system': sp, 'messages': [{'role': 'user', 'content': um}]}))
elif name == 'Gemini':
    print(json.dumps({'systemInstruction': {'parts': [{'text': sp}]},
        'contents': [{'parts': [{'text': um}]}],
        'generationConfig': {'maxOutputTokens': tokens, 'temperature': 0.1}}))
else:
    print(json.dumps({'model': model, 'max_tokens': tokens, 'temperature': 0.1,
        'messages': [{'role': 'system', 'content': sp}, {'role': 'user', 'content': um}]}))
" "$system_prompt" "$user_msg" "$SF_NAME" "$SF_MODEL" "$SF_TOKENS")

    local hc
    case "$SF_NAME" in
        Claude)
            hc=$(curl -s -w "%{http_code}" -X POST "$SF_URL" \
                -H "Content-Type: application/json" \
                -H "x-api-key: $SF_KEY" \
                -H "anthropic-version: 2023-06-01" \
                -d "$payload" -o "$out_file" \
                --connect-timeout 30 --max-time 600 2>/dev/null) ;;
        Gemini)
            hc=$(curl -s -w "%{http_code}" -X POST \
                "https://generativelanguage.googleapis.com/v1beta/models/${SF_MODEL}:generateContent?key=${SF_KEY}" \
                -H "Content-Type: application/json" \
                -d "$payload" -o "$out_file" \
                --connect-timeout 30 --max-time 600 2>/dev/null) ;;
        *)
            hc=$(curl -s -w "%{http_code}" -X POST "$SF_URL" \
                -H "Content-Type: application/json" \
                -H "Authorization: Bearer $SF_KEY" \
                -d "$payload" -o "$out_file" \
                --connect-timeout 30 --max-time 600 2>/dev/null) ;;
    esac

    [[ "$hc" != "200" ]] && { err "API HTTP $hc"; cat "$out_file" 2>/dev/null; return 1; }

    local content
    case "$SF_NAME" in
        Claude) content=$(jq -r '.content[0].text' "$out_file" 2>/dev/null) ;;
        Gemini) content=$(jq -r '.candidates[0].content.parts[0].text' "$out_file" 2>/dev/null) ;;
        *)      content=$(jq -r '.choices[0].message.content' "$out_file" 2>/dev/null) ;;
    esac

    [[ -z "$content" || "$content" == "null" ]] && { err "Boş yanıt"; return 1; }
    echo "$content"
}

# ── Güvenli komut (sadece okuma) ──────────────────────────────────────────────
is_safe_cmd() {
    local cmd="$1"
    echo "$cmd" | grep -qE '(>(?!&)|>>|\brm\b|\bmv\b|\bcp\b|\bchmod\b|\bsed\s.*-i\b|gradlew|gradle|compile|assemble)' && return 1
    local first; first=$(echo "$cmd" | awk '{print $1}')
    case "$first" in
        sed|cat|grep|head|tail|wc|ls|find|awk|cut|sort|uniq|echo|python3) return 0 ;;
        *) return 1 ;;
    esac
}

# ── SEARCH/REPLACE uygula ─────────────────────────────────────────────────────
apply_search_replace() {
    local rel_path="$1"
    local search_text="$2"
    local replace_text="$3"

    local abs_path="$PROJECT_ROOT/$rel_path"
    [[ ! -f "$abs_path" ]] && { echo "HATA: Dosya yok: $abs_path"; return 1; }

    cp "$abs_path" "$TMP_DIR/$(basename "$abs_path").bak_sf"

    python3 - "$abs_path" "$search_text" "$replace_text" << 'PYEOF'
import sys

path         = sys.argv[1]
search_text  = sys.argv[2]
replace_text = sys.argv[3]

content = open(path, encoding='utf-8').read()

if search_text not in content:
    print("HATA: Aranan kod dosyada bulunamadi. Tam esleme yok.")
    print("Aranan:")
    print(search_text[:300])
    sys.exit(1)

count = content.count(search_text)
if count > 1:
    print(f"UYARI: Kod {count} kez geciyor — ilki degistiriliyor")

old_bal = search_text.count('{') - search_text.count('}')
new_bal = replace_text.count('{') - replace_text.count('}')
if old_bal != new_bal:
    print(f"HATA: Parantez dengesizligi! Eski: {old_bal:+d}, Yeni: {new_bal:+d}")
    print("Kapanislari eksik yazdin. Duzelt ve tekrar gonder.")
    sys.exit(1)

new_content = content.replace(search_text, replace_text, 1)
open(path, 'w', encoding='utf-8').write(new_content)
old_lines = len(content.splitlines())
new_lines = len(new_content.splitlines())
print(f"REPLACE uygulandi: {old_lines} -> {new_lines} satir")
PYEOF
}

# ── Yeni dosya oluştur ────────────────────────────────────────────────────────
apply_new_file() {
    local rel_path="$1"
    local content="$2"

    local abs_path="$PROJECT_ROOT/$rel_path"
    mkdir -p "$(dirname "$abs_path")"

    if [[ -f "$abs_path" ]]; then
        cp "$abs_path" "$TMP_DIR/$(basename "$abs_path").bak_sf"
        warn "Dosya zaten var, üzerine yazılıyor: $rel_path"
    fi

    echo "$content" > "$abs_path"
    local lines; lines=$(echo "$content" | wc -l)
    echo "NEW_FILE oluşturuldu: $rel_path ($lines satır)"
}

# ── Build ─────────────────────────────────────────────────────────────────────
run_build() {
    log "Build başlatılıyor..."
    local build_out="$TMP_DIR/sf_build.txt"
    cd "$PROJECT_ROOT"
    ./gradlew assembleDebug --no-daemon 2>&1 | tee "$build_out" > /dev/null || true
    if grep -q "BUILD SUCCESSFUL" "$build_out"; then
        return 0
    else
        cp "$build_out" "$ERROR_LOG"
        return 1
    fi
}

# ── Ana döngü ─────────────────────────────────────────────────────────────────
main() {
    load_provider

    local error_text
    error_text=$(cat "$ERROR_LOG")
    log "Hata logu: $(wc -l < "$ERROR_LOG") satır"
    [[ -n "$TASK" ]] && log "Görev: ${TASK:0:60}..."

    local SYSTEM_PROMPT
    SYSTEM_PROMPT=$(load_system_prompt)

    local conversation=""

    # İlk mesajı oluştur
    local user_msg
    if [[ -n "$TASK" ]]; then
        user_msg="Proje: $PROJECT_ROOT
GÖREV: $TASK

BUILD HATALARI:
$error_text

ZORUNLU: Önce CMD: cat -n ile ilgili dosyaları oku, sonra REPLACE_BLOCK ver."
    else
        user_msg="Proje: $PROJECT_ROOT

BUILD HATALARI:
$error_text

ZORUNLU: Önce CMD: cat -n ile hatalı dosyayı oku, sonra REPLACE_BLOCK ver."
    fi

    local round=0

    while true; do
        round=$((round + 1))
        log "Tur $round — AI'ya gönderiliyor..."

        local full_msg
        if [[ -n "$conversation" ]]; then
            full_msg="$conversation

---
$user_msg"
        else
            full_msg="$user_msg"
        fi

        local ai_response
        if ! ai_response=$(call_ai "$SYSTEM_PROMPT" "$full_msg"); then
            err "API çağrısı başarısız (tur $round)"
            exit 1
        fi

        echo ""
        log "AI yanıtı:"
        echo "$ai_response"
        echo ""

        conversation="$full_msg

AI: $ai_response"

        # ── DONE ───────────────────────────────────────────────────────────
        if echo "$ai_response" | grep -q "^DONE"; then
            ok "Tamamlandı."
            exit 0
        fi

        # ── NEW_FILE ───────────────────────────────────────────────────────
        if echo "$ai_response" | grep -q "^NEW_FILE:"; then
            local nf_line
            nf_line=$(echo "$ai_response" | grep "^NEW_FILE:" | head -1)
            local nf_path
            nf_path=$(echo "$nf_line" | cut -d: -f2- | xargs)

            local nf_content
            nf_content=$(echo "$ai_response" | awk '/^<<<CONTENT/{found=1; next} /^>>>END/{found=0} found{print}')

            if [[ -z "$nf_content" ]]; then
                warn "NEW_FILE için <<<CONTENT bloğu boş"
                user_msg="<<<CONTENT bloğu eksik. Format:
NEW_FILE: path/to/File.kt
<<<CONTENT
dosya içeriği
>>>END"
                continue
            fi

            local nf_output
            if nf_output=$(apply_new_file "$nf_path" "$nf_content" 2>&1); then
                ok "$nf_output"
                user_msg="$nf_output

Devam et — build için DONE yaz veya başka değişiklik yap."
            else
                warn "NEW_FILE oluşturulamadı: $nf_output"
                user_msg="Dosya oluşturulamadı: $nf_output
Tekrar dene."
            fi
            continue
        fi

        # ── REPLACE_BLOCK ──────────────────────────────────────────────────
        if echo "$ai_response" | grep -q "^REPLACE_BLOCK:"; then
            local rb_line
            rb_line=$(echo "$ai_response" | grep "^REPLACE_BLOCK:" | head -1)
            local rp
            rp=$(echo "$rb_line" | cut -d: -f2- | xargs)

            local search_text replace_text
            search_text=$(echo "$ai_response" | awk '/^<<<SEARCH/{found=1; next} /^===/{found=0} found{print}')
            replace_text=$(echo "$ai_response" | awk '/^>>>REPLACE/{found=1; next} /^>>>END/{found=0} found{print}')

            if [[ -z "$search_text" ]]; then
                warn "<<<SEARCH bloğu boş veya eksik"
                user_msg="<<<SEARCH bloğu eksik. Formatı eksiksiz gönder:
REPLACE_BLOCK: dosya/yolu
<<<SEARCH
eski kod
===
>>>REPLACE
yeni kod
>>>END"
                continue
            fi

            log "REPLACE uygulanıyor: $rp"
            local replace_output
            if replace_output=$(apply_search_replace "$rp" "$search_text" "$replace_text" 2>&1); then
                ok "$replace_output"

                local prev_count
                prev_count=$(grep -c "^e: " "$ERROR_LOG" 2>/dev/null || echo 0)

                if run_build; then
                    ok "✅ BUILD BAŞARILI — smart_fix tamamlandı"
                    exit 0
                else
                    local new_count
                    new_count=$(grep -c "^e: " "$ERROR_LOG" 2>/dev/null || echo 0)
                    local trend=""
                    [[ "$new_count" -lt "$prev_count" ]] && trend="📉 Azaldı ($prev_count → $new_count)"
                    [[ "$new_count" -gt "$prev_count" ]] && trend="📈 Arttı ($prev_count → $new_count)"
                    [[ "$new_count" -eq "$prev_count" ]] && trend="➡️ Değişmedi ($new_count hata)"
                    warn "Build başarısız. $trend"
                    user_msg="Replace uygulandı ama build başarısız.
$trend

BUILD ÇIKTISI:
$(cat "$ERROR_LOG" | head -60)

Devam et."
                fi
            else
                warn "Replace uygulanamadı"
                user_msg="Replace uygulanamadı.
HATA: $replace_output

<<<SEARCH bloğunu dosyadaki kodla BIREBIR eşleştir.
CMD: cat -n $rp ile dosyayı tekrar oku."
            fi
            continue
        fi

        # ── CMD + REPLACE_BLOCK aynı yanıtta ──────────────────────────────
        # Önce CMD'yi çalıştır, sonra REPLACE_BLOCK varsa onu da işle
        if echo "$ai_response" | grep -q "^CMD:" && echo "$ai_response" | grep -q "^REPLACE_BLOCK:"; then
            local cmd
            cmd=$(echo "$ai_response" | grep "^CMD:" | head -1 | sed 's/^CMD: *//')
            if is_safe_cmd "$cmd"; then
                sleep 1
                log "Komut (önce): $cmd"
                local cmd_out
                cd "$PROJECT_ROOT"
                cmd="${cmd//\~/$HOME}"
                cmd_out=$(eval "$cmd" 2>&1) || true
                log "Çıktı: $(echo "$cmd_out" | wc -l) satır"
                # CMD çıktısını conversation'a ekle, sonra REPLACE_BLOCK işlensin
                conversation="$full_msg

AI: $ai_response

KOMUT: $cmd
ÇIKTI:
$cmd_out"
            fi
            # REPLACE_BLOCK işlemeye devam et — aşağıda yakalanacak
        fi

        # ── CMD ────────────────────────────────────────────────────────────
        if echo "$ai_response" | grep -q "^CMD:" && ! echo "$ai_response" | grep -q "^REPLACE_BLOCK:"; then
            local cmd
            cmd=$(echo "$ai_response" | grep "^CMD:" | head -1 | sed 's/^CMD: *//')

            # cat -n satır numarası ekler, SEARCH bloğunda eşleşmez — reddet
            if echo "$cmd" | grep -qE "cat\s+-n"; then
                warn "cat -n reddedildi: satır numaraları SEARCH bloğunu bozar"
                user_msg="cat -n KULLANMA. Satır numaraları <<<SEARCH bloğunda eşleşmeyi bozar.
Sadece: CMD: cat dosya/yolu"
                continue
            fi
            if ! is_safe_cmd "$cmd"; then
                warn "Güvensiz komut reddedildi: $cmd"
                user_msg="Komut reddedildi: $cmd
Sadece okuma: cat, grep, head, tail, wc, ls, sed -n"
                continue
            fi

            sleep 1
            log "Komut: $cmd"
            local cmd_output
            cd "$PROJECT_ROOT"
            cmd="${cmd//\~/$HOME}"
            if cmd_output=$(eval "$cmd" 2>&1); then
                local lc; lc=$(echo "$cmd_output" | wc -l)
                log "Çıktı: $lc satır"
                user_msg="KOMUT: $cmd

ÇIKTI:
$cmd_output

Devam et."
            else
                warn "Komut başarısız: $cmd"
                user_msg="Komut başarısız: $cmd
Hata: $cmd_output
Farklı komut dene."
            fi
            continue
        fi

        # ── Format yok ─────────────────────────────────────────────────────
        warn "Geçerli format yok"
        user_msg="Yanıt formatı yanlış. Sadece şunları kullan:
- CMD: <okuma komutu>
- REPLACE_BLOCK: ile düzeltme
- NEW_FILE: ile yeni dosya
- DONE
Tekrar dene."

        [[ $round -gt 40 ]] && { err "Maksimum tur aşıldı"; exit 1; }
    done
}

main
