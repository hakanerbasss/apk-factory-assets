#!/data/data/com.termux/files/usr/bin/bash
# smart_task.sh v1.0
# Kullanım: bash smart_task.sh <proje_dizini> <kullanici_gorevi>
# Görev: apply_fixes ile run_autofix arasında çalışır.
# Projeyi okur, eksikleri tespit eder, cerrahi REPLACE ile doldurur.
# Build ALMAZ. Tüm eksikler biter → sessizce çıkar → run_autofix devam eder.

set +e

PROJECT_ROOT="${1:-}"
USER_TASK="${2:-}"

[[ -z "$PROJECT_ROOT" || ! -d "$PROJECT_ROOT" ]] && { echo "[st] HATA: Proje dizini gerekli"; exit 0; }
[[ -z "$USER_TASK" ]] && { echo "[st] Görev belirtilmedi, atlanıyor."; exit 0; }

SISTEM_DIR="/storage/emulated/0/termux-otonom-sistem"
APILER_DIR="$SISTEM_DIR/apiler"
PROMPTS_DIR="$SISTEM_DIR/prompts"
TMP_DIR="$HOME/.autofix_tmp"
ST_TMP="$TMP_DIR/smart_task"
mkdir -p "$ST_TMP"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
log()  { echo -e "${CYAN}[st]${NC} $*"; }
ok()   { echo -e "${GREEN}[st] ✅ $*${NC}"; }
warn() { echo -e "${YELLOW}[st] ⚠️  $*${NC}"; }
err()  { echo -e "${RED}[st] ❌ $*${NC}"; }
title(){ echo -e "\n${BOLD}${CYAN}══ [SmartTask] $* ══${NC}\n"; }

# ── Provider yükle ────────────────────────────────────────────────────────────
load_provider() {
    local default_prov conf_file=""
    default_prov=$(grep "^DEFAULT_PROVIDER=" ~/.config/autofix.conf 2>/dev/null | cut -d'"' -f2 || echo "")
    [[ -n "$default_prov" ]] && conf_file="$APILER_DIR/$(echo "$default_prov" | tr '[:upper:]' '[:lower:]').conf"
    [[ -z "$conf_file" || ! -f "$conf_file" ]] && conf_file=$(ls "$APILER_DIR"/*.conf 2>/dev/null | head -1 || true)
    [[ -z "$conf_file" || ! -f "$conf_file" ]] && { err "Provider conf bulunamadı, smart_task atlanıyor."; exit 0; }

    ST_NAME=$(grep  "^NAME="        "$conf_file" | cut -d'"' -f2)
    ST_URL=$(grep   "^API_URL="     "$conf_file" | cut -d'"' -f2)
    ST_KEY=$(grep   "^API_KEY="     "$conf_file" | cut -d'"' -f2)
    ST_MODEL=$(grep "^MODEL="       "$conf_file" | cut -d'"' -f2)
    ST_TOKENS=$(grep "^MAX_TOKENS=" "$conf_file" 2>/dev/null | cut -d= -f2 || echo 8000)
}

# ── API çağrısı ───────────────────────────────────────────────────────────────
call_ai() {
    local sp="$1" um="$2" out="$ST_TMP/response.json"
    local payload
    echo "$sp" > "$ST_TMP/sp.txt"
    echo "$um" > "$ST_TMP/um.txt"
    payload=$(python3 -c "
import json, sys
name, model, tokens = sys.argv[1], sys.argv[2], int(sys.argv[3])
sp = open('$ST_TMP/sp.txt').read()
um = open('$ST_TMP/um.txt').read()
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
" "$ST_NAME" "$ST_MODEL" "$ST_TOKENS" 2>/dev/null)

    local hc
    if [[ "$ST_NAME" == "Gemini" ]]; then
        hc=$(curl -s -w "%{http_code}" -X POST \
            "https://generativelanguage.googleapis.com/v1beta/models/${ST_MODEL}:generateContent?key=${ST_KEY}" \
            -H "Content-Type: application/json" -d "$payload" -o "$out" \
            --connect-timeout 30 --max-time 120 2>/dev/null)
    elif [[ "$ST_NAME" == "Claude" ]]; then
        hc=$(curl -s -w "%{http_code}" -X POST "$ST_URL" \
            -H "Content-Type: application/json" \
            -H "x-api-key: $ST_KEY" \
            -H "anthropic-version: 2023-06-01" \
            -d "$payload" -o "$out" --connect-timeout 30 --max-time 120 2>/dev/null)
    else
        hc=$(curl -s -w "%{http_code}" -X POST "$ST_URL" \
            -H "Content-Type: application/json" \
            -H "Authorization: Bearer $ST_KEY" \
            -d "$payload" -o "$out" --connect-timeout 30 --max-time 120 2>/dev/null)
    fi

    [[ "$hc" != "200" ]] && { err "API HTTP $hc"; return 1; }
    if   [[ "$ST_NAME" == "Claude" ]]; then jq -r '.content[0].text'                     "$out" 2>/dev/null
    elif [[ "$ST_NAME" == "Gemini" ]]; then jq -r '.candidates[0].content.parts[0].text' "$out" 2>/dev/null
    else                                    jq -r '.choices[0].message.content'           "$out" 2>/dev/null
    fi
}

# ── SEARCH/REPLACE motoru (smart_fix ile aynı) ────────────────────────────────
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

# Strateji 2: Fuzzy satır bazlı
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

# ── Yeni dosya oluşturma ──────────────────────────────────────────────────────
apply_new_file() {
    local rel_path="$1" content="$2"
    local abs_path="$PROJECT_ROOT/$rel_path"
    mkdir -p "$(dirname "$abs_path")"
    echo "$content" > "$abs_path"
    ok "Yeni dosya oluşturuldu: $rel_path"
}

# ── Proje haritası (bir kez alınır) ──────────────────────────────────────────
build_project_map() {
    local map_file="$ST_TMP/project_map.txt"
    echo "=== PROJE DOSYA AĞACI ===" > "$map_file"
    find "$PROJECT_ROOT" -maxdepth 5 \
        -not -path "*/build/*" \
        -not -path "*/.gradle/*" \
        -not -path "*/.git/*" \
        -not -path "*/outputs/*" \
        -type f -name "*.kt" >> "$map_file" 2>/dev/null
    find "$PROJECT_ROOT" -maxdepth 5 \
        -not -path "*/build/*" \
        -type f -name "*.gradle" >> "$map_file" 2>/dev/null
    echo "=========================" >> "$map_file"

    # Her kt dosyasının ilk 15 satırını ekle (harita için yeterli)
    echo "" >> "$map_file"
    echo "=== DOSYA ÖZETLERİ ===" >> "$map_file"
    while IFS= read -r f; do
        [[ "$f" == *".kt" && -f "$f" ]] || continue
        local rel="${f#$PROJECT_ROOT/}"
        local lines
        lines=$(wc -l < "$f" 2>/dev/null || echo 0)
        echo "--- $rel ($lines satır) ---" >> "$map_file"
        head -n 15 "$f" >> "$map_file"
        echo "" >> "$map_file"
    done < <(find "$PROJECT_ROOT/app/src/main" -name "*.kt" -not -path "*/build/*" 2>/dev/null)

    echo "$map_file"
}

# ── Checker: Eksikleri tespit et ─────────────────────────────────────────────
run_checker() {
    local map_file="$1"
    local checker_sp="Sen bir Android kod denetçisisin. Sadece kod eksiklerini raporla, kod yazma.

RAPOR FORMATI — SADECE BUNLARI YAZ:
Eksik yoksa tek satır yaz: TEMİZ

Eksik varsa her biri için:
EKSIK: <dosya_yolu> | <ne eksik>
IMPORT_EKSIK: <dosya_yolu> | <eksik import>
BAGIMLILIK_EKSIK: app/build.gradle | <eksik kütüphane>

KONTROL KURALLARI:
- Placeholder/Coming soon/TODO/Yapılacak içeren sayfaları işaretle
- Boş veya tek satır içerikli Composable fonksiyonları işaretle
- Kullanıcı görevinde isteyip kodda hiç olmayan özellikleri işaretle
- Ses/resim/font dosyası eksikliğini SAYMA (validator halleder)
- Gradle build hatalarını SAYMA (autofix halleder)
- Sadece KOD eksiklerini say"

    local checker_um="KULLANICI GÖREVİ: $USER_TASK

PROJE DURUMU:
$(cat "$map_file")

Yukarıdaki göreve göre kodda eksik olan şeyleri raporla."

    call_ai "$checker_sp" "$checker_um"
}

# ── Dosya içeriğini oku (tam) ─────────────────────────────────────────────────
read_file_content() {
    local rel_path="$1"
    local abs_path="$PROJECT_ROOT/$rel_path"
    [[ ! -f "$abs_path" ]] && { echo "DOSYA YOK: $rel_path"; return; }
    local lines
    lines=$(wc -l < "$abs_path" 2>/dev/null || echo 0)
    echo "=== $rel_path ($lines satır) ==="
    cat "$abs_path"
}

# ── Eksikliği doldur ──────────────────────────────────────────────────────────
fix_missing() {
    local target_file="$1"
    local missing_desc="$2"

    log "Eksiklik gideriliyor: $target_file — $missing_desc"

    local fixer_sp
    fixer_sp=$(cat "$PROMPTS_DIR/smart_fix_system.txt" 2>/dev/null || echo "Sen Android uzmanısın. REPLACE_BLOCK formatında cerrahi düzeltme yap.")

    local file_content
    file_content=$(read_file_content "$target_file")

    local fixer_um="GÖREV: $USER_TASK

EKSİKLİK: $missing_desc

DOSYA İÇERİĞİ:
$file_content

Bu eksikliği REPLACE_BLOCK formatında cerrahi olarak doldur.
Tüm dosyayı yeniden yazma. Sadece eksik olan kısmı doldur.
İLK ADIMIN CMD OLMALI."

    local conversation=""
    local attempts=0
    local max_attempts=8
    local last_cmd=""

    while [[ $attempts -lt $max_attempts ]]; do
        attempts=$((attempts + 1))

        local full_msg="$fixer_um"
        [[ -n "$conversation" ]] && full_msg="${conversation}\n\n---\n${fixer_um}"

        local ai_response
        if ! ai_response=$(call_ai "$fixer_sp" "$full_msg"); then
            err "API yanıt vermedi ($attempts/$max_attempts)"
            sleep 2; continue
        fi
        [[ -z "$ai_response" ]] && continue
        conversation="${full_msg}\n\nAI: ${ai_response}"

        # AI düşüncesini göster
        local reasoning
        reasoning=$(echo "$ai_response" | grep -vE "^CMD:|^REPLACE_BLOCK:|^<<<|^===|^>>>|^NEW_FILE:" | grep -v '^\s*$' | head -2 | xargs || true)
        [[ -n "$reasoning" ]] && echo -e "\033[2m🤖 $reasoning\033[0m"

        # ── CMD işle ──
        if echo "$ai_response" | grep -q "^CMD:" && ! echo "$ai_response" | grep -q "^REPLACE_BLOCK:"; then
            local cmd
            cmd=$(echo "$ai_response" | grep "^CMD:" | head -1 | sed 's/^CMD: *//')

            # Tekrar eden CMD engelle
            if [[ -n "$last_cmd" && "$cmd" == "$last_cmd" ]]; then
                warn "Tekrar eden CMD engellendi."
                fixer_um="TEKRAR EDEN CMD: Aynı komutu tekrar çalıştırdın. Direkt REPLACE_BLOCK ver."
                last_cmd=""
                continue
            fi

            # Güvenli CMD kontrolü
            if echo "$cmd" | grep -qE '(>>|\brm\b|\bmv\b|\bchmod\b|\bsed\s.*-i\b|gradlew)'; then
                fixer_um="GÜVENSİZ KOMUT: '$cmd' yasak. Sadece cat, grep, find, head, tail kullan."
                continue
            fi

            last_cmd="$cmd"
            log "CMD: $cmd"
            cd "$PROJECT_ROOT"
            local cmd_out
            cmd_out=$(eval "$cmd" 2>&1 | head -n 200 | cat -n || true)
            echo -e "\033[2m   ↳ $(echo "$cmd_out" | head -2 | xargs)\033[0m"
            fixer_um="CMD ÇIKTISI:\n${cmd_out}\n\nBu çıktıya göre REPLACE_BLOCK ver."
            continue
        fi

        # ── NEW_FILE işle ──
        if echo "$ai_response" | grep -q "^NEW_FILE:"; then
            local nf_path
            nf_path=$(echo "$ai_response" | grep "^NEW_FILE:" | head -1 | cut -d: -f2- | xargs)
            local nf_content
            nf_content=$(echo "$ai_response" | awk '/^<<<CONTENT/{f=1;next} /^>>>END/{f=0} f{print}')
            if [[ -n "$nf_path" && -n "$nf_content" ]]; then
                apply_new_file "$nf_path" "$nf_content"
                ok "Yeni dosya eklendi: $nf_path"
                return 0
            fi
            continue
        fi

        # ── REPLACE_BLOCK işle ──
        if echo "$ai_response" | grep -q "^REPLACE_BLOCK:"; then
            local rp
            rp=$(echo "$ai_response" | grep "^REPLACE_BLOCK:" | head -1 | cut -d: -f2- | xargs)
            local search_text
            search_text=$(echo "$ai_response" | awk '/^<<<SEARCH/{f=1;next} /^===/{f=0} f{print}')
            local replace_text
            replace_text=$(echo "$ai_response" | awk '/^===/{f=1;next} /^>>>END/{f=0} f{print}')

            if [[ "$search_text" == "$replace_text" ]]; then
                warn "AI hiçbir şeyi değiştirmedi."
                fixer_um="HATA: SEARCH ve REPLACE aynı! Gerçekten değişiklik yap."
                continue
            fi

            local replace_output
            if replace_output=$(apply_search_replace "$rp" "$search_text" "$replace_text" 2>&1); then
                ok "Düzeltme uygulandı: $replace_output"
                return 0
            else
                warn "REPLACE başarısız: $replace_output"
                local file_ctx
                file_ctx=$(read_file_content "$rp")
                fixer_um="REPLACE BAŞARISIZ.\nHata: $replace_output\n\nDOSYA:\n$file_ctx\n\nDosyadan AYNEN kopyala."
                last_cmd=""
                continue
            fi
        fi

        fixer_um="Geçersiz format. CMD: veya REPLACE_BLOCK: kullan."
    done

    warn "Eksiklik giderilemedi (max deneme): $missing_desc"
    return 1
}

# ── ANA DÖNGÜ ─────────────────────────────────────────────────────────────────
main() {
    load_provider
    title "Smart Task Kalite Kontrolü"
    log "Görev: $USER_TASK"
    log "Proje: $PROJECT_ROOT"

    local MAX_ROUNDS=10
    local round=0
    local total_fixed=0

    # Proje haritasını bir kez oluştur
    local map_file
    map_file=$(build_project_map)
    log "Proje haritası oluşturuldu."

    while [[ $round -lt $MAX_ROUNDS ]]; do
        round=$((round + 1))
        title "Kontrol Turu $round / $MAX_ROUNDS"

        # Checker çalıştır
        log "🔍 Checker AI projeyi analiz ediyor..."
        local checker_result
        if ! checker_result=$(run_checker "$map_file"); then
            warn "Checker API hatası, tur atlanıyor..."
            continue
        fi

        echo -e "\033[2m📋 Checker raporu:\n$checker_result\033[0m"

        # TEMİZ mi?
        if echo "$checker_result" | grep -q "^TEMİZ"; then
            ok "Proje temiz! Tüm görev özellikleri eksiksiz uygulanmış."
            ok "Toplam $total_fixed eksiklik giderildi."
            exit 0
        fi

        # Eksiklikleri parse et
        local eksikler=()
        while IFS= read -r line; do
            [[ "$line" == EKSIK:* || "$line" == IMPORT_EKSIK:* || "$line" == BAGIMLILIK_EKSIK:* ]] && eksikler+=("$line")
        done <<< "$checker_result"

        if [[ ${#eksikler[@]} -eq 0 ]]; then
            ok "Raporlanacak eksiklik yok, çıkılıyor."
            exit 0
        fi

        log "${#eksikler[@]} eksiklik tespit edildi, sırayla gideriliyor..."

        # Her eksikliği sırayla gider
        local round_fixed=0
        for eksik in "${eksikler[@]}"; do
            local target_file
            target_file=$(echo "$eksik" | cut -d'|' -f1 | sed 's/^EKSIK: //;s/^IMPORT_EKSIK: //;s/^BAGIMLILIK_EKSIK: //' | xargs)
            local missing_desc
            missing_desc=$(echo "$eksik" | cut -d'|' -f2 | xargs)

            log "Gideriliyor [$((round_fixed+1))/${#eksikler[@]}]: $target_file → $missing_desc"

            if fix_missing "$target_file" "$missing_desc"; then
                total_fixed=$((total_fixed + 1))
                round_fixed=$((round_fixed + 1))
                # Haritayı güncelle (değişen dosya için)
                map_file=$(build_project_map)
            else
                warn "Bu eksiklik giderilemedi, sonraki tura kalıyor: $missing_desc"
            fi
        done

        if [[ $round_fixed -eq 0 ]]; then
            warn "Bu turda hiçbir eksiklik giderilemedi. Çıkılıyor."
            exit 0
        fi
    done

    warn "Maksimum tur sayısına ulaşıldı ($MAX_ROUNDS). Kalan eksiklikler autofix'e kalıyor."
    exit 0
}

main
