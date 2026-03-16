#!/data/data/com.termux/files/usr/bin/bash
# ═══════════════════════════════════════════════════════════════
#  autofix.sh v5.1 — Tam Otonom Yapay Zeka Ajanı (Gölge Yedekli)
# ═══════════════════════════════════════════════════════════════

set -uo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

SISTEM_DIR="/storage/emulated/0/termux-otonom-sistem"
GITHUB_RAW="https://raw.githubusercontent.com/hakanerbasss/apk-factory-assets/main"
APILER_DIR="$SISTEM_DIR/apiler"
PROMPTS_DIR="$SISTEM_DIR/prompts"
CONF_FILE="$HOME/.config/autofix.conf"
TMP_DIR="${TMPDIR:-$PREFIX/tmp}/autofix_$$"
LOG_FILE="$TMP_DIR/autofix.log"
MAX_LOOPS=$(grep "^MAX_LOOPS=" ~/.config/autofix.conf 2>/dev/null | cut -d= -f2 || echo 8)

# --- YENİ: Gölge Yedekleme Sistemi ---
AGENT_YEDEK_DIR="$SISTEM_DIR/agent_yedekler"
BACKUP_MAP="$AGENT_YEDEK_DIR/backup_map.txt"

cleanup() { rm -rf "$TMP_DIR" 2>/dev/null; }
trap cleanup EXIT
mkdir -p "$TMP_DIR" "$AGENT_YEDEK_DIR"

log()   { echo -e "${CYAN}[$(date +%H:%M:%S)]${NC} $*" | tee -a "$LOG_FILE"; }
ok()    { echo -e "${GREEN}✅ $*${NC}" | tee -a "$LOG_FILE"; }
warn()  { echo -e "${YELLOW}⚠️  $*${NC}" | tee -a "$LOG_FILE"; }
err()   { echo -e "${RED}❌ $*${NC}" | tee -a "$LOG_FILE"; }
title() { echo -e "\n${BOLD}${BLUE}══ $* ══${NC}\n"; }

check_deps() {
    local missing=()
    for dep in curl jq python3; do
        command -v "$dep" &>/dev/null || missing+=("$dep")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        err "Eksik: ${missing[*]}"; echo "  pkg install ${missing[*]}"; exit 1
    fi
}

select_provider() {
    mkdir -p "$APILER_DIR"
    local providers=(); local confs=()
    for conf in "$APILER_DIR"/*.conf; do
        [[ -f "$conf" ]] || continue
        local n; n=$(grep "^NAME=" "$conf" | cut -d'"' -f2)
        providers+=("$n"); confs+=("$conf")
    done

    if [[ ${#providers[@]} -eq 0 ]]; then
        err "Hiç provider yok: $APILER_DIR"; echo "  autofix install ile kur"; exit 1
    fi

    local default_provider=""
    [[ -f "$CONF_FILE" ]] && default_provider=$(grep "^DEFAULT_PROVIDER=" "$CONF_FILE" 2>/dev/null | cut -d'"' -f2)

    # Varsayılan provider varsa direkt seç
    if [[ -n "$default_provider" ]]; then
        for i in "${!providers[@]}"; do
            if [[ "${providers[$i]}" == "$default_provider" ]]; then
                PROVIDER_CONF="${confs[$i]}"
                NAME=$(grep "^NAME=" "$PROVIDER_CONF" | cut -d'"' -f2)
                API_URL=$(grep "^API_URL=" "$PROVIDER_CONF" | cut -d'"' -f2)
                API_KEY=$(grep "^API_KEY=" "$PROVIDER_CONF" | cut -d'"' -f2)
                MODEL=$(grep "^MODEL=" "$PROVIDER_CONF" | cut -d'"' -f2)
                MAX_TOKENS=$(grep "^MAX_TOKENS=" "$PROVIDER_CONF" | cut -d'=' -f2)
                return
            fi
        done
    fi

    title "Hangi AI ile çalışalım?"
    for i in "${!providers[@]}"; do
        local kv; kv=$(grep "^API_KEY=" "${confs[$i]}" | cut -d'"' -f2)
        local ks; [[ -z "$kv" ]] && ks="${RED}(key yok)${NC}" || ks="${GREEN}✓${NC}"
        local dm=""; [[ "${providers[$i]}" == "$default_provider" ]] && dm=" ${DIM}[varsayılan]${NC}"
        echo -e "  ${BOLD}$((i+1)))${NC} ${providers[$i]} $ks$dm"
    done
    echo

    local prompt_txt="  Seçim (1-${#providers[@]})"
    [[ -n "$default_provider" ]] && prompt_txt+=" [Enter=$default_provider]"
    read -r -p "$(echo -e "${YELLOW}${prompt_txt}:${NC} ")" choice

    if [[ -z "$choice" && -n "$default_provider" ]]; then
        for i in "${!providers[@]}"; do
            [[ "${providers[$i]}" == "$default_provider" ]] && choice=$((i+1)) && break
        done
    fi

    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [[ $choice -lt 1 ]] || [[ $choice -gt ${#providers[@]} ]]; then
        err "Geçersiz seçim"; exit 1
    fi

    PROVIDER_CONF="${confs[$((choice-1))]}"
    NAME=$(grep "^NAME="      "$PROVIDER_CONF" | cut -d'"' -f2)
    API_URL=$(grep "^API_URL=" "$PROVIDER_CONF" | cut -d'"' -f2)
    API_KEY=$(grep "^API_KEY=" "$PROVIDER_CONF" | cut -d'"' -f2)
    MODEL=$(grep "^MODEL="    "$PROVIDER_CONF" | cut -d'"' -f2)
    MAX_TOKENS=$(grep "^MAX_TOKENS=" "$PROVIDER_CONF" | cut -d'=' -f2)
    MAX_TOKENS=$(grep "^MAX_TOKENS=" ~/.config/autofix.conf 2>/dev/null | cut -d= -f2 || echo 8000)

    # --- CLAUDE TÜM MODELLER MENÜSÜ ---
    if [[ "$NAME" == "Claude" ]]; then
        title "Claude Modeli Seçin (Tüm Nesiller)"
        echo -e "  ${BOLD}1) 4.5 Opus${NC}    - [\$\$\$] En Güçlü (Mimari/Ağır Bug)      | \$15/\$75"
        echo -e "  ${BOLD}2) 4.5 Sonnet${NC}  - [\$\$ ] Dengeli (UI/UX Tasarımı)     | \$3/\$15"
        echo -e "  ${BOLD}3) 4.5 Haiku${NC}   - [\$  ] Hızlı (Genel Hatalar)          | \$1/\$5"
        echo -e "  ${BOLD}4) 3.5 Sonnet${NC}  - [\$  ] Kararlı LTS                     | \$3/\$15"
        echo -e "  ${BOLD}5) 3.5 Haiku${NC}   - [¢  ] En Ucuz & Seri                  | \$0.25/\$1.25"
        echo
        read -r -p "$(echo -e "${YELLOW}  Seçim yap (1-5) [Enter=$MODEL]: ${NC}")" m_choice
        
        case "$m_choice" in
            1) MODEL="claude-opus-4-5-20251101" ;;
            2) MODEL="claude-sonnet-4-5-20250929" ;;
            3) MODEL="claude-haiku-4-5-20251001" ;;
            4) MODEL="claude-3-5-sonnet-20241022" ;;
            5) MODEL="claude-3-5-haiku-20241022" ;;
        esac
        
                # Seçilen modeli Claude.conf dosyasına kalıcı olarak yazar
        sed -i "s|MODEL=.*|MODEL=\"$MODEL\"|" "$PROVIDER_CONF"

        # Modele göre MAX_TOKENS değerini otomatik ayarla
        if [[ "$MODEL" == *"haiku-20240307"* ]]; then
            sed -i "s|MAX_TOKENS=.*|MAX_TOKENS=4096|" "$PROVIDER_CONF"
            MAX_TOKENS=4096
        else
            sed -i "s|MAX_TOKENS=.*|MAX_TOKENS=8000|" "$PROVIDER_CONF"
            MAX_TOKENS=8000
        fi

        ok "Model güncellendi: $MODEL"


    fi

    if [[ -z "$API_KEY" ]]; then
        err "$NAME için API key yok!"
        read -r -p "Key gir: " new_key
        [[ -z "$new_key" ]] && exit 1
        sed -i "s|API_KEY=.*|API_KEY=\"$new_key\"|" "$PROVIDER_CONF"
        API_KEY="$new_key"; ok "Key kaydedildi"
    fi
    ok "Aktif Provider: $NAME | Model: $MODEL"
}

create_default_prompt() {
    mkdir -p "$PROMPTS_DIR"
    # Dosya zaten varsa kullanıcı kurallarını koru, üzerine yazma
    [[ -f "$PROMPTS_DIR/autofix_system.txt" ]] && return 0
    cat > "$PROMPTS_DIR/autofix_system.txt" << 'PROMPT'
Sen bir Kotlin/Android uzmanısın. Sana build hataları ve kaynak dosyalar verilecek.

KRİTİK KURAL — BÜYÜK DOSYALAR: Eğer bir dosyaya 30+ satır kod yazman gerekiyorsa "original"/"replacement" yerine "full_content" kullan. full_content = dosyanın TAM yeni içeriği.
Örnek: {"path": "MainActivity.kt", "full_content": "package com.x\nimport ...\nclass MainActivity : ComponentActivity() {...}"}

AGENTIC KURAL — DOSYA OKUMA: Eğer bir hatayı düzeltmek için dosyanın belirli satırlarını görmek istersen, önce "commands" listesi döndür. Sistem komutu çalıştırır ve sonucu sana geri gönderir, sonra "changes" yazarsın.
Örnek: {"commands": ["sed -n '160,180p' app/src/main/java/com/wizaicorp/proje/MainActivity.kt"]}
Desteklenen komutlar: cat, sed -n, grep, find, ls, wc, stat, head, tail, file
Komutları PROJECT_ROOT'a göreceli yaz.

ÇIKTI FORMATI - SADECE JSON, BAŞKA HİÇBİR ŞEY YAZMA:
{
  "explanation": "Hatayı buldum, x satırını y ile değiştiriyorum.",
  "changes": [
    {
      "path": "app/build.gradle",
      "original": "    implemntation 'com.example:library:1.0'",
      "replacement": "    implementation 'com.example:library:1.0'"
    }
  ]
}

KURALLAR:
- "original" alanı için devasa bloklar yerine, SADECE hatanın olduğu 1-2 satırı ve değişecek yeri yaz. Çok satır yazarsan eşleşme başarısız olur.
- "original" kod, dosyadakiyle harfi harfine aynı olmalı.
- JSON dışında hiçbir şey yazma.

ANDROID KURALLARI:
- targetSdk ve compileSdk her zaman 35 olmalı, 34 kullanma.
- Paket adı com.wizaicorp.* formatında olmalı, com.fileexplorer veya com.example kullanma.
- @OptIn hatası: @OptIn(ExperimentalFoundationApi::class) fonksiyon ÜSTÜNE yaz, statement olarak yazma.
- İkon: SADECE Material Icons kullan, drawable XML ikonu oluşturma.
- NativeAdView: adView.mediaView MUTLAKA set et. MediaView en az 120x120dp olmalı. visibility=GONE YAPMA, alpha=0f kullan, reklam gelince alpha=1f yap.
- LazyColumn veya LazyRow asla verticalScroll/horizontalScroll içine koyma.
- Eğer dosyada setContent { Text("AI Kodluyor...") } görürsen, "original" olarak "setContent { Text(\"AI Kodluyor...\") }" satırını kullan ve "replacement" olarak oyunun TÜM yeni setContent bloğunu ve importlarını yaz. Paket adını değiştirmeye çalışma.
- KRİTİK IMPORT KURALI: "import androidx.activity.compose.setContent" ve "import androidx.activity.ComponentActivity" ASLA silinmez.
- TEMA KURALI: Özel tema sınıfı (YourAppTheme, AppTheme, MyTheme vb.) KULLANMA. ui.theme.* paketi yoksa import etme. Sadece MaterialTheme kullan.
- DUPLICATE IMPORT KURALI: Import satırı eklemeden önce dosyadaki mevcut importları kontrol et. Aynı import zaten varsa tekrar ekleme.
- YENİ PROJE KURALI: factory.sh tarafından oluşturulan yeni projelerde ui/theme/ klasörü YOKTUR. Theme.kt dosyası oluşturma, sadece MaterialTheme kullan.
- AndroidManifest.xml içindeki android:theme değerini ASLA değiştirme.
- BÜYÜK KOD KURALI: Eğer bir dosyaya 50 satırdan fazla kod yazman gerekiyorsa "original"/"replacement" yerine "full_content" alanını kullan. full_content dosyanın TAM içeriğini içerir. Bu JSON escape sorununu önler.
  Örnek: {"path": "MainActivity.kt", "full_content": "package com.x\nimport ...\nclass MainActivity..."}
PROMPT
}

find_project_root() {
    local dir="$1"
    while [[ "$dir" != "/" ]]; do
        [[ -f "$dir/gradlew" ]] && echo "$dir" && return 0
        dir="$(dirname "$dir")"
    done; return 1
}

detect_project() {
    PROJECT_ROOT=""
    [[ -n "${1:-}" && -d "$1" && -f "$1/gradlew" ]] && PROJECT_ROOT="$1"
    [[ -z "$PROJECT_ROOT" ]] && PROJECT_ROOT=$(find_project_root "$(pwd)") || true
    if [[ -z "$PROJECT_ROOT" ]] || [[ ! -f "$PROJECT_ROOT/gradlew" ]]; then
        err "Gradle projesi bulunamadı. Proje klasöründen çalıştırın."; exit 1
    fi
    SRC_ROOT="$PROJECT_ROOT/app/src/main/java"
    ok "Proje: $PROJECT_ROOT"
}

run_build() {
    log "Build başlatılıyor..."
    echo -e "${CYAN}────────────────────────────────────────${NC}"
    local build_out="$TMP_DIR/build_output.txt"
    local result_file="$TMP_DIR/build_result.txt"
    cd "$PROJECT_ROOT"
    ./gradlew assembleDebug 2>&1 | tee "$build_out" | while IFS= read -r line; do
        if   [[ "$line" == *"> Task"* ]];           then echo -e "${CYAN}  ⚙  ${line#*> Task }${NC}"
        elif [[ "$line" == *"e: file://"* ]];       then echo -e "${RED}  ✗  $line${NC}"
        elif [[ "$line" == *"error:"* ]];           then echo -e "${RED}  ✗  $line${NC}"
        elif [[ "$line" == *"Could not find"* ]];   then echo -e "${RED}  ✗  $line${NC}"
        elif [[ "$line" == *"BUILD SUCCESSFUL"* ]]; then echo -e "${GREEN}  ✅  BUILD SUCCESSFUL${NC}"
        elif [[ "$line" == *"BUILD FAILED"* ]];     then echo -e "${RED}  ❌  BUILD FAILED${NC}"
        elif [[ "$line" == *"warning:"* ]];         then echo -e "${YELLOW}  ⚠  $line${NC}"
        fi
    done
    echo -e "${CYAN}────────────────────────────────────────${NC}"
    if grep -q "BUILD SUCCESSFUL" "$build_out"; then
        echo "SUCCESS" > "$result_file"
    else
        echo "FAILED" > "$result_file"
    fi
}

parse_errors() {
    local build_out="$TMP_DIR/build_output.txt"
    local errors_file="$TMP_DIR/errors.txt"
    local files_file="$TMP_DIR/error_files.txt"

    # Geniş pattern — Kotlin, Java, XML, AAPT, Gradle, Manifest hataları
    grep -E "^e: file://|^w: file://|error:|^ERROR|AAPT:|AAPT2|Could not find|Could not resolve|unresolved|FAILED|Exception|Manifest|AndroidManifest|resource|attribute"         "$build_out" | head -n 6 > "$errors_file" 2>/dev/null || true

    # Hata veren dosya yollarını çıkar — uzantıdan bağımsız
    # Önce tam yol formatı: /path/to/file.ext
    grep -oE '/[^ :]+\.[a-zA-Z0-9]+' "$errors_file"         | grep -v "\.class$\|\.jar$\|\.apk$\|\.aab$"         | head -n 3 | sort -u > "$files_file" 2>/dev/null || true

    # Bulunamazsa: paket yolundan dosya bul (Kotlin/Java için)
    if [[ ! -s "$files_file" ]]; then
        grep -oE 'com/[a-zA-Z0-9_/]+\.[a-zA-Z]+' "$build_out"         | while read -r rel; do
            find "$PROJECT_ROOT" -path "*$rel" 2>/dev/null | head -1
        done | head -n 3 | sort -u > "$files_file"
    fi

    # Hala boşsa: build çıktısının tamamından dosya adı ara
    if [[ ! -s "$files_file" ]]; then
        grep -oE '[A-Za-z][A-Za-z0-9_]+\.(kt|java|xml|gradle|kts|toml|json|properties)' "$build_out"         | while read -r fname; do
            find "$PROJECT_ROOT" -name "$fname" -not -path "*/build/*" 2>/dev/null | head -1
        done | head -n 3 | sort -u > "$files_file"
    fi

    # Manifest/resource hatası varsa AndroidManifest.xml'i ekle
    if grep -qE "processDebugResources|AndroidManifest|package.*keyword|not a valid Java" "$errors_file" 2>/dev/null; then
        local manifest="$PROJECT_ROOT/app/src/main/AndroidManifest.xml"
        [[ -f "$manifest" ]] && echo "$manifest" >> "$files_file"
    fi
    echo "$errors_file"
}

collect_source_files() {
    local error_files_list="$TMP_DIR/error_files.txt"
    local collected="$TMP_DIR/collected_sources.txt"
    local max_chars
    max_chars=$(grep "^MAX_CHARS=" ~/.config/autofix.conf 2>/dev/null | cut -d= -f2 || echo 60000)
    > "$collected"

    add_file() {
        local fpath="$1"
        [[ -f "$fpath" ]] || return
        # Binary dosyaları atla (file komutu ile MIME kontrol)
        file "$fpath" 2>/dev/null | grep -qiE "text|ASCII|UTF|script|source" || return
        # 100KB üstünü atla
        [[ $(stat -c%s "$fpath" 2>/dev/null || echo 0) -gt 102400 ]] && return
        # Zaten eklendiyse atla
        grep -qF "=== FILE: ${fpath#$PROJECT_ROOT/} ===" "$collected" 2>/dev/null && return
        echo "=== FILE: ${fpath#$PROJECT_ROOT/} ===" >> "$collected"
        cat "$fpath" >> "$collected"
        echo "" >> "$collected"
    }

    # 1. Hata veren dosyaları ekle (öncelik)
    while IFS= read -r fpath; do
        add_file "$fpath"
    done < "$error_files_list"

    # 2. Bağlam dosyaları — her zaman ekle (build config)
    for gf in         "$PROJECT_ROOT/app/build.gradle"         "$PROJECT_ROOT/app/build.gradle.kts"         "$PROJECT_ROOT/build.gradle"         "$PROJECT_ROOT/build.gradle.kts"         "$PROJECT_ROOT/settings.gradle"         "$PROJECT_ROOT/settings.gradle.kts"         "$PROJECT_ROOT/app/src/main/AndroidManifest.xml"; do
        add_file "$gf"
    done

    # 3. Hiç dosya yoksa — projedeki tüm metin dosyalarını tara (fallback)
    if [[ ! -s "$collected" ]]; then
        warn "Hatalı dosya tespit edilemedi, proje taranıyor..." >&2
        find "$PROJECT_ROOT"             -not -path "*/build/*"             -not -path "*/.gradle/*"             -not -path "*/.git/*"             -not -path "*/outputs/*"             -type f | while read -r fpath; do
            add_file "$fpath"
            # Char limitine ulaştıysa dur
            [[ $(wc -c < "$collected" 2>/dev/null || echo 0) -gt $max_chars ]] && break
        done
    fi

    echo "$collected"
}

_call_active_ai() {
    local sp="$1" um="$2"
    case "$NAME" in
        "Gemini") _call_gemini "$sp" "$um" ;;
        "Claude") _call_claude "$sp" "$um" ;;
        *)        _call_openai "$sp" "$um" ;;
    esac
}

# Agentic: AI'nın "commands" isteklerini çalıştır, çıktıyı geri ver
run_ai_commands() {
    local cmd_file="$TMP_DIR/ai_commands.txt"
    local cmd_output="$TMP_DIR/cmd_output.txt"
    > "$cmd_output"

    python3 -c "
import json, os, sys, re
t = open('$TMP_DIR/ai_content.txt').read()
# Backtick ve markdown temizle
t = re.sub(r'\`\`\`json\s*', '', t, flags=re.MULTILINE)
t = re.sub(r'\`\`\`\s*', '', t, flags=re.MULTILINE)
t = re.sub(r'^\`+json\s*','',t,flags=re.MULTILINE)
t = re.sub(r'^\`+\s*','',t,flags=re.MULTILINE)
t = t.strip()
# { ... } bloğunu bul
s = t.find('{'); e = t.rfind('}')+1
if s >= 0 and e > s: t = t[s:e]
try:
    d = json.loads(t)
    cmds = d.get('commands', [])
    for c in cmds: print(c)
except: pass
" > "$cmd_file" 2>/dev/null

    local cmd_count; cmd_count=$(wc -l < "$cmd_file" || echo 0)
    [[ $cmd_count -eq 0 ]] && return 1

    log "🔍 AI $cmd_count keşif komutu çalıştırıyor..."
    while IFS= read -r cmd; do
        [[ -z "$cmd" ]] && continue
        echo "=== KOMUT: $cmd ===" >> "$cmd_output"
        # Güvenli komutlar: sadece okuma izni (cd, cat, sed, find, grep, ls, wc, stat)
        if echo "$cmd" | grep -qE "^(cat|sed -n|grep|find|ls|wc|stat|head|tail|file) "; then
            cd "$PROJECT_ROOT" && eval "$cmd" >> "$cmd_output" 2>&1 || true
        else
            echo "// Güvenlik: sadece okuma komutları çalıştırılır" >> "$cmd_output"
        fi
        echo "" >> "$cmd_output"
    done < "$cmd_file"
    return 0
}

call_ai() {
    local errors="$1" sources="$2"
    local error_text; error_text=$(cat "$errors")
    local source_text; source_text=$(cat "$sources")
    local max_chars
    max_chars=$(grep "^MAX_CHARS=" ~/.config/autofix.conf 2>/dev/null | cut -d= -f2 || echo 60000)
    [[ ${#source_text} -gt $max_chars ]] && source_text="${source_text:0:$max_chars}"

    local system_prompt
    local pf="$PROMPTS_DIR/autofix_system.txt"
    [[ ! -f "$pf" ]] && create_default_prompt
    system_prompt=$(cat "$pf")

    local user_msg="BUILD HATALARI:\n\`\`\`\n${error_text}\n\`\`\`\n\nKAYNAK DOSYALAR:\n${source_text}"

    log "$NAME'e gönderiliyor... (${#source_text} karakter)"
    echo -e "${YELLOW}  ⏳ API yanıtı bekleniyor (Max 600sn)...${NC}"

    # Agentic loop — max 3 tur, AI komut isteyebilir
    local tour=0
    while [[ $tour -lt 3 ]]; do
        tour=$((tour+1))
        _call_active_ai "$system_prompt" "$user_msg"

        # AI commands istedi mi?
        if run_ai_commands; then
            local cmd_output; cmd_output=$(cat "$TMP_DIR/cmd_output.txt")
            log "🔍 Keşif tur $tour tamamlandı ($(echo "$cmd_output" | wc -c) karakter)"
            echo -e "${YELLOW}  ⏳ API yanıtı bekleniyor (Max 600sn)...${NC}"
            user_msg="BUILD HATALARI:\n\`\`\`\n${error_text}\n\`\`\`\n\nKAYNAK DOSYALAR:\n${source_text}\n\nKEŞİF SONUÇLARI (istediğin satırlar):\n${cmd_output}\n\nŞimdi \"changes\" formatında düzeltmeyi yaz."
            continue
        fi
        # commands yok → changes var, döngüden çık
        break
    done
}

_call_openai() {
    local sp="$1" um="$2" rf="$TMP_DIR/api_response.json"
    local payload; payload=$(python3 -c "
import json,sys
print(json.dumps({'model':'${MODEL}','max_tokens':${MAX_TOKENS},'temperature':0.1,
'messages':[{'role':'system','content':sys.argv[1]},{'role':'user','content':sys.argv[2]}]}))" "$sp" "$um")
    local hc; hc=$(curl -s -w "%{http_code}" -X POST "$API_URL" \
        -H "Content-Type: application/json" -H "Authorization: Bearer $API_KEY" \
        -d "$payload" -o "$rf" --connect-timeout 30 --max-time 600 2>/dev/null)
    [[ "$hc" != "200" ]] && { err "API hatası: HTTP $hc"; cat "$rf" 2>/dev/null; return 1; }
    local c; c=$(jq -r '.choices[0].message.content' "$rf" 2>/dev/null)
    [[ -z "$c" || "$c" == "null" ]] && { err "Boş yanıt"; return 1; }
    echo "$c" > "$TMP_DIR/ai_content.txt"
    echo "=== GEMINI RAW ===" >> /sdcard/Download/gemini_debug.log
    echo "$c" >> /sdcard/Download/gemini_debug.log
}

_call_gemini() {
    local sp="$1" um="$2" rf="$TMP_DIR/api_response.json"
    local gemini_base="https://generativelanguage.googleapis.com/v1beta/models"
    local url="${gemini_base}/${MODEL}:generateContent?key=${API_KEY}"
    # Görev modunda (büyük kod) MAX_TOKENS en az 16000 olsun
    local effective_tokens=${MAX_TOKENS}
    [[ $effective_tokens -lt 16000 ]] && effective_tokens=16000
    local payload; payload=$(python3 -c "
import json,sys
# systemInstruction ayrı gönder — Gemini bunu daha iyi anlıyor
print(json.dumps({
    'systemInstruction':{'parts':[{'text':sys.argv[1]}]},
    'contents':[{'parts':[{'text':sys.argv[2]}]}],
    'generationConfig':{
        'maxOutputTokens':${effective_tokens},
        'temperature':0.1,
        'responseMimeType':'application/json'
    }
}))" "$sp" "$um")
    local hc; hc=$(curl -s -w "%{http_code}" -X POST "$url" \
        -H "Content-Type: application/json" -d "$payload" \
        -o "$rf" --connect-timeout 30 --max-time 600 2>/dev/null)
    [[ "$hc" != "200" ]] && { err "Gemini HTTP $hc"; cat "$rf" 2>/dev/null; return 1; }
    local c; c=$(jq -r '.candidates[0].content.parts[0].text' "$rf" 2>/dev/null)
    [[ -z "$c" || "$c" == "null" ]] && { err "Boş yanıt"; return 1; }
    echo "$c" > "$TMP_DIR/ai_content.txt"
    echo "=== GEMINI RAW ===" >> /sdcard/Download/gemini_debug.log
    echo "$c" >> /sdcard/Download/gemini_debug.log
}

_call_claude() {
    local sp="$1" um="$2" rf="$TMP_DIR/api_response.json"
    local payload; payload=$(python3 -c "
import json,sys
print(json.dumps({'model':'${MODEL}','max_tokens':${MAX_TOKENS},
'system':sys.argv[1],'messages':[{'role':'user','content':sys.argv[2]}]}))" "$sp" "$um")
    local hc; hc=$(curl -s -w "%{http_code}" -X POST "$API_URL" \
        -H "Content-Type: application/json" -H "x-api-key: $API_KEY" \
        -H "anthropic-version: 2023-06-01" -d "$payload" \
        -o "$rf" --connect-timeout 30 --max-time 600 2>/dev/null)
    [[ "$hc" != "200" ]] && { err "Claude HTTP $hc"; cat "$rf" 2>/dev/null; return 1; }
    local c; c=$(jq -r '.content[0].text' "$rf" 2>/dev/null)
    [[ -z "$c" || "$c" == "null" ]] && { err "Boş yanıt"; return 1; }
    echo "$c" > "$TMP_DIR/ai_content.txt"
    echo "=== GEMINI RAW ===" >> /sdcard/Download/gemini_debug.log
    echo "$c" >> /sdcard/Download/gemini_debug.log
}

# --- YENİ: Yedek Geri Yükleme ---
restore_agent_backups() {
    if [[ -f "$BACKUP_MAP" ]]; then
        while IFS='|' read -r bak_path asil_path; do
            [[ -f "$bak_path" ]] && cp "$bak_path" "$asil_path"
        done < "$BACKUP_MAP"
        ok "Otonom gölge yedekten geri dönüldü."
    fi
}

# --- YENİ: Yedekleri Temizleme ---
clean_agent_backups() {
    rm -rf "$AGENT_YEDEK_DIR"/* 2>/dev/null
    > "$BACKUP_MAP"
}

apply_fixes() {
    local clean_file="$TMP_DIR/clean_response.txt"
    python3 -c "
import re
t=open('$TMP_DIR/ai_content.txt').read()
t=re.sub(r'```json','',t)
t=re.sub(r'```','',t)
t=re.sub(r'^\`+json\s*','',t,flags=re.MULTILINE)
t=re.sub(r'^\`+\s*$','',t,flags=re.MULTILINE)
t=t.strip()
s=t.find('{');e=t.rfind('}')+1
if s>=0 and e>s:t=t[s:e]
open('$clean_file','w').write(t)"

    local py_script="$TMP_DIR/patch_apply.py"
    cat > "$py_script" << 'PYEOF'
import json, os, shutil

def try_parse_json(t):
    """JSON parse et — bozuksa en uzun geçerli bloğu bul"""
    # Önce direkt parse
    try: return json.loads(t)
    except: pass
    # { ... } bloğunu bul
    s = t.find('{'); e = t.rfind('}')+1
    if s >= 0 and e > s:
        try: return json.loads(t[s:e])
        except: pass
    # Truncated JSON — eksik kapanış parantezlerini tamamla
    try:
        depth = 0; last_valid = 0
        for i, ch in enumerate(t):
            if ch == '{': depth += 1
            elif ch == '}': depth -= 1; last_valid = i
        if last_valid > 0:
            candidate = t[t.find('{'):last_valid+1]
            return json.loads(candidate)
    except: pass
    return None

with open(os.environ['CLEAN_FILE']) as f: t = f.read()
data = try_parse_json(t)
if data is None:
    print("JSON_ERROR"); exit(1)

explanation = data.get('explanation', 'Açıklama belirtilmedi.')
print(f"EXPLANATION:{explanation}")

changes = data.get('changes', [])
count = 0
bak_dir = os.environ['AGENT_YEDEK_DIR']
map_file = os.environ['BACKUP_MAP']
project_root = os.environ['PROJECT_ROOT']

def backup_file(full, path):
    safe_name = path.replace('/', '_') + '.bak'
    bak_path = os.path.join(bak_dir, safe_name)
    if not os.path.exists(bak_path):
        shutil.copy2(full, bak_path)
        with open(map_file, 'a') as map_f:
            map_f.write(f"{bak_path}|{full}\n")

for c in changes:
    path = c.get('path', '').strip()
    if not path: continue
    full = path if path.startswith('/') else os.path.join(project_root, path)
    if not os.path.exists(full): continue

    # full_content: dosyanın tamamını yaz (büyük kod için JSON escape sorunu yok)
    full_content = c.get('full_content', '')
    if full_content:
        backup_file(full, path)
        old_lines = len(open(full).readlines())
        with open(full, 'w', encoding='utf-8') as f: f.write(full_content)
        new_lines = len(full_content.splitlines())
        print(f"MODIFIED:{path}|{old_lines}|{new_lines}")
        count += 1
        continue

    # original/replacement: patch modu
    orig = c.get('original', '').replace('\r\n', '\n')
    repl = c.get('replacement', '').replace('\r\n', '\n')
    if not orig: continue

    with open(full, 'r', encoding='utf-8') as f: file_content = f.read().replace('\r\n', '\n')

    match_found = False
    if orig in file_content:
        match_found = True
    elif orig.strip() in file_content:
        orig = orig.strip(); repl = repl.strip()
        match_found = True

    if not match_found:
        print(f"MATCH_FAILED:{path}")
        continue

    backup_file(full, path)
    old_lines = len(file_content.splitlines())
    new_content = file_content.replace(orig, repl, 1)
    new_lines = len(new_content.splitlines())
    
    with open(full, 'w', encoding='utf-8') as f: f.write(new_content)
    print(f"MODIFIED:{path}|{old_lines}|{new_lines}")
    count += 1
print(f"COUNT:{count}")
PYEOF

    export CLEAN_FILE="$clean_file"
    export PROJECT_ROOT="$PROJECT_ROOT"
    export AGENT_YEDEK_DIR="$AGENT_YEDEK_DIR"
    export BACKUP_MAP="$BACKUP_MAP"
    
    local wr; wr=$(python3 "$py_script")
    echo "$wr" | grep -q "JSON_ERROR\|JSON_NOT_FOUND" && { err "Yapay zeka geçersiz format döndürdü."; return 1; }
    
    local expl; expl=$(echo "$wr" | grep "^EXPLANATION:" | cut -d: -f2-)
    local count; count=$(echo "$wr" | grep "^COUNT:" | cut -d: -f2)
    
    echo -e "\n${BOLD}${CYAN}🤖 YAPAY ZEKA RAPORU${NC}"
    echo -e "${YELLOW}Açıklama:${NC} $expl"
    
    if [[ "${count:-0}" -eq 0 ]]; then
        err "Değişiklik yapılamadı (Kod eşleşmedi veya dosya bulunamadı)"
        return 1
    fi
    
    echo "$wr" | grep "^MODIFIED:" | while IFS='|' read -r prefix path old new; do
        local p="${path#$PROJECT_ROOT/}"
        echo -e "  ${GREEN}→${NC} $p (Satır: $old ${YELLOW}→${NC} $new)"
    done
    
    # Auto-confirm: ws_bridge veya conf'tan kontrol et
    local auto_confirm
    auto_confirm=$(grep "^AUTO_CONFIRM=" ~/.config/autofix.conf 2>/dev/null | cut -d= -f2 || echo "0")
    
    if [[ "$auto_confirm" != "1" ]]; then
        echo
        read -r -p "$(echo -e "${YELLOW}Değişiklikleri uygula ve derle [Enter=Devam / İ=İptal]: ${NC}")" confirm
        if [[ "$confirm" == "i" || "$confirm" == "İ" ]]; then
            restore_agent_backups
            clean_agent_backups
            err "İşlem iptal edildi, orijinal koda dönüldü."
            return 1
        fi
    fi

    ok "$count dosya güncellendi, build testine geçiliyor..."
}

show_advanced_diff() {
    echo -e "\n${BOLD}${CYAN}🔍 YAPILAN DEĞİŞİKLİKLERİN KONTROLÜ:${NC}"
    local diff_script="$TMP_DIR/diff_show.py"
    cat > "$diff_script" << 'PYEOF'
import sys, difflib
try:
    with open(sys.argv[1]) as f1, open(sys.argv[2]) as f2:
        diff = list(difflib.unified_diff(f1.readlines(), f2.readlines(), n=1))
        for line in diff[2:]:
            if line.startswith('+'): print('\033[0;32m' + line.strip() + '\033[0m')
            elif line.startswith('-'): print('\033[0;31m' + line.strip() + '\033[0m')
            elif line.startswith('@@'): print('\033[0;36m' + line.strip() + '\033[0m')
except BrokenPipeError:
    pass
PYEOF

    # --- YENİ: Diff'i gölge yedekten okuma ---
    if [[ -f "$BACKUP_MAP" ]]; then
        while IFS='|' read -r bak asil; do
            echo -e "${YELLOW}Dosya:${NC} ${asil#$PROJECT_ROOT/}"
            python3 "$diff_script" "$bak" "$asil" | head -n 30
            echo "----------------------------------------"
        done < "$BACKUP_MAP"
    fi
}

run_autofix() {
    title "AutoFix Döngüsü — $NAME"
    log "Proje: $PROJECT_ROOT | Model: $MODEL"
    echo

    local loop=0
    local start=$SECONDS

    while [[ $loop -lt $MAX_LOOPS ]]; do
        loop=$((loop + 1))
        title "Deneme $loop / $MAX_LOOPS"

        run_build
        local result; result=$(cat "$TMP_DIR/build_result.txt" 2>/dev/null || echo "FAILED")

        if [[ "$result" == "SUCCESS" ]]; then
            show_advanced_diff
            local elapsed=$((SECONDS - start))
            ok "BUILD BAŞARILI! 🎉  (${elapsed}s)"
            
            local apk; apk=$(find "$PROJECT_ROOT/app/build/outputs/apk" -name "*.apk" 2>/dev/null | head -1)
            [[ -n "$apk" ]] && mkdir -p "/sdcard/Download/apk-cikti" && rm -f "/sdcard/Download/apk-cikti/${P_NAME:-$(basename $PROJECT_ROOT)}"*.apk "/sdcard/Download/apk-cikti/${P_NAME:-$(basename $PROJECT_ROOT)}"*.aab 2>/dev/null && cp "$apk" "/sdcard/Download/apk-cikti/$(basename "$apk")" 2>/dev/null && touch "/sdcard/Download/apk-cikti/$(basename "$apk")" && ok "APK → Download/apk-cikti"

            read -r -p "$(echo -e "\n${YELLOW}Değişiklikleri kalıcı yap veya Yedeğe dön [Enter=Kalıcı Yap / B=Yedeğe Dön]: ${NC}")" res
            if [[ "$res" == "b" || "$res" == "B" ]]; then
                restore_agent_backups
                clean_agent_backups
                ok "Yedeğe dönüldü."
            else
                clean_agent_backups
                ok "Değişiklikler kalıcı yapıldı (Yedekler silindi)."
            fi
            exit 0
        fi

        err "Build başarısız"

        # --- YENİ: Yedek varsa ve bot bozduysa iptal etme şansı ---
        if [[ -f "$BACKUP_MAP" && -s "$BACKUP_MAP" ]]; then
            show_advanced_diff
            echo -e "\n${RED}⚠️ AI bir şeyler değiştirdi ama build yine başarısız!${NC}"
            read -r -p "$(echo -e "Seçim [ ${BOLD}b${NC}: Yedeğe Dön / ${BOLD}Enter${NC}: Hata çözmeye devam et ]: ")" choice
            if [[ "$choice" == "b" || "$choice" == "B" ]]; then
                restore_agent_backups
                clean_agent_backups
                ok "Yedeğe dönüldü ve işlem durduruldu."
                exit 0
            fi
        fi

        local ef; ef=$(parse_errors)
        [[ ! -s "$ef" ]] && cp "$TMP_DIR/build_output.txt" "$ef"
        log "Hata Logu Oku: $(wc -l < "$ef") satır"
        head -100 "$ef"; echo

        # Aynı hata 2 kez üst üste gelince full_content moduna geç
        local cur_err; cur_err=$(head -1 "$ef" | md5sum | cut -d' ' -f1)
        if [[ "$cur_err" == "${LAST_ERR:-}" ]]; then
            SAME_ERR_COUNT=$((${SAME_ERR_COUNT:-0}+1))
        else
            SAME_ERR_COUNT=0
        fi
        LAST_ERR="$cur_err"
        if [[ ${SAME_ERR_COUNT:-0} -ge 2 ]]; then
            warn "Aynı hata tekrar ediyor — dosyayı baştan yaz moduna geçiliyor..."
            local hata_dosya; hata_dosya=$(head -1 "$TMP_DIR/error_files.txt" 2>/dev/null)
            if [[ -n "$hata_dosya" && -f "$hata_dosya" ]]; then
                local rewrite_msg="BU DOSYAYI BAŞTAN YAZ. Mevcut kod çalışmıyor. full_content ile sıfırdan temiz kod üret.\n\nHATA:\n$(cat "$ef")\n\nMEVCUT KOD:\n$(cat "$hata_dosya")"
                local sys_p; sys_p=$(cat "$PROMPTS_DIR/autofix_system.txt" 2>/dev/null || echo "")
                _call_active_ai "$sys_p" "$rewrite_msg"
                apply_fixes
                SAME_ERR_COUNT=0
                continue
            fi
        fi

        local src; src=$(collect_source_files)
        
        if ! call_ai "$ef" "$src"; then
            err "API hatası — $((MAX_LOOPS - loop)) deneme kaldı"; sleep 3; continue
        fi
        if ! apply_fixes; then
            err "Düzeltme başarısız — $((MAX_LOOPS - loop)) deneme kaldı"; sleep 2; continue
        fi
    done

    err "BAŞARISIZ: $MAX_LOOPS denemede düzeltilemedi"
    return 1
}

# ═══════════════════════════════════════════════════════════════
# GÖREV (FEATURE) MODU
# ═══════════════════════════════════════════════════════════════
run_task() {
    local user_task="$1"
    if [[ -z "$user_task" ]]; then
        err "Görev belirtilmedi. Örnek: autofix task 'PreviewScreen.kt içine conf ekle'"
        exit 1
    fi

    # --- YENİ: Her yeni görevde eski yedekleri temizle ---
    clean_agent_backups

    title "AutoFix Görev Modu (AI Agent)"
    log "Görev: $user_task"

    local tree_file="$TMP_DIR/tree.txt"
    cd "$PROJECT_ROOT"
    # Tüm dosya türlerini listele — binary değil, build hariç
    find . -maxdepth 6 -type f \
        -not -path "*/.*" \
        -not -path "*/build/*" \
        -not -path "*/.gradle/*" \
        -not -path "*/outputs/*" \
        -not -path "*/bin/*" \
        | sort > "$tree_file"

    local pkg=$(grep "applicationId" "$PROJECT_ROOT/app/build.gradle" 2>/dev/null | head -1 | grep -oE '"[^"]+"' | head -1 | tr -d '"')
    local max_chars
    max_chars=$(grep "^MAX_CHARS=" ~/.config/autofix.conf 2>/dev/null | cut -d= -f2 || echo 60000)

    # Adım 1: Sadece dosya ağacını gönder — içerik yok
    local collected="$TMP_DIR/collected_sources.txt"
    > "$collected"
    echo "=== PROJE DOSYA AĞACI ===" >> "$collected"
    echo "Paket: $pkg" >> "$collected"
    echo "Proje: $PROJECT_ROOT" >> "$collected"
    echo "" >> "$collected"
    # Her dosyanın adı + boyutu
    while IFS= read -r f; do
        local fsize; fsize=$(stat -c%s "$PROJECT_ROOT/$f" 2>/dev/null || echo 0)
        echo "$f ($fsize bytes)" >> "$collected"
    done < "$tree_file"
    echo "" >> "$collected"
    echo "Not: Dosya içeriklerini görmek için 'commands' ile iste." >> "$collected"
    # MainActivity.kt her zaman ekle — AI boş şablonu görsün
    local main_kt; main_kt=$(find "$PROJECT_ROOT/app/src/main/java" -name "MainActivity.kt" 2>/dev/null | head -1)
    if [[ -n "$main_kt" ]]; then
        echo "" >> "$collected"
        echo "=== MEVCUT KOD: ${main_kt#$PROJECT_ROOT/} ===" >> "$collected"
        cat "$main_kt" >> "$collected"
    fi

    ok "Dosya ağacı hazır: $(wc -l < "$tree_file") dosya"
    echo -e "${YELLOW}⚙️ Yapay Zeka analiz ediyor...${NC}"
    local task_sp_file="$PROMPTS_DIR/autofix_task.txt"
    # Dosya yoksa varsayılan oluştur, varsa kullanıcı kurallarını koru
    if [[ ! -f "$task_sp_file" ]]; then
        cat > "$task_sp_file" << 'PROMPT'
Sen bir Kotlin/Android uzmanısın. Sana kullanıcının GÖREVİ ve ilgili KAYNAK DOSYALAR verilecek.

KRİTİK KURAL — BÜYÜK DOSYALAR: Eğer bir dosyaya 30+ satır kod yazman gerekiyorsa "original"/"replacement" yerine "full_content" kullan. full_content = dosyanın TAM yeni içeriği.
Örnek: {"path": "MainActivity.kt", "full_content": "package com.x\nimport ...\nclass MainActivity : ComponentActivity() {...}"}

AGENTIC KURAL — DOSYA OKUMA: Eğer bir hatayı düzeltmek için dosyanın belirli satırlarını görmek istersen, önce "commands" listesi döndür. Sistem komutu çalıştırır ve sonucu sana geri gönderir, sonra "changes" yazarsın.
Örnek: {"commands": ["sed -n '160,180p' app/src/main/java/com/wizaicorp/proje/MainActivity.kt"]}
Desteklenen komutlar: cat, sed -n, grep, find, ls, wc, stat, head, tail, file
Komutları PROJECT_ROOT'a göreceli yaz.

ÇIKTI FORMATI - SADECE JSON, BAŞKA HİÇBİR ŞEY YAZMA:
{
  "explanation": "Görev için şu dosyada şu değişikliği yapıyorum...",
  "changes": [
    {
      "path": "app/src/.../Dosya.kt",
      "original": "eski kodun değişecek 1-2 satırı",
      "replacement": "yeni kod"
    }
  ]
}

KURALLAR:
- "original" alanı, dosyadaki hedef metinle harfi harfine aynı olmalı.
- Dev bloklar yerine sadece değişecek kritik satırları seç.
- JSON dışında hiçbir şey yazma.

ANDROID KURALLARI:
- targetSdk ve compileSdk her zaman 35 olmalı, 34 kullanma.
- Paket adı com.wizaicorp.* formatında olmalı, com.fileexplorer veya com.example kullanma.
- @OptIn hatası: @OptIn(ExperimentalFoundationApi::class) fonksiyon ÜSTÜNE yaz, statement olarak yazma.
- İkon: SADECE Material Icons kullan, drawable XML ikonu oluşturma.
- NativeAdView: adView.mediaView MUTLAKA set et. MediaView en az 120x120dp olmalı. visibility=GONE YAPMA, alpha=0f kullan, reklam gelince alpha=1f yap.
- LazyColumn veya LazyRow asla verticalScroll/horizontalScroll içine koyma.
- Eğer dosyada setContent { Text("AI Kodluyor...") } görürsen, "original" olarak "setContent { Text(\"AI Kodluyor...\") }" satırını kullan ve "replacement" olarak oyunun TÜM yeni setContent bloğunu ve importlarını yaz. Paket adını değiştirmeye çalışma.
- KRİTİK IMPORT KURALI: "import androidx.activity.compose.setContent" ve "import androidx.activity.ComponentActivity" ASLA silinmez. Import bloğunu yeniden yazarken bu iki satırın mutlaka korunduğunu kontrol et.
- Import bloğunu yeniden yazarken mevcut importları SİLME, sadece eksik olanları EKLE.
- TEMA KURALI: Özel tema sınıfı (YourAppTheme, AppTheme, MyTheme vb.) KULLANMA. ui.theme.* paketi yoksa import etme. Sadece MaterialTheme kullan.
- DUPLICATE IMPORT KURALI: Import satırı eklemeden önce dosyadaki mevcut importları kontrol et. Aynı import zaten varsa tekrar ekleme.
- YENİ PROJE KURALI: factory.sh tarafından oluşturulan yeni projelerde ui/theme/ klasörü YOKTUR. Theme.kt dosyası oluşturma, sadece MaterialTheme kullan.
- setContent bloğunu değiştirirken fonksiyon tanımları (fun ...) ASLA setContent bloğu içine yazma. Composable fonksiyonlar her zaman Activity sınıfının DIŞINDA tanımlanır.
- Yeni Composable fonksiyon eklerken önce Activity sınıfının kapanış parantezini bul, onun DIŞINA yaz.
- AndroidManifest.xml içindeki android:theme değerini ASLA değiştirme.
- BÜYÜK KOD KURALI: Eğer bir dosyaya 50 satırdan fazla kod yazman gerekiyorsa "original"/"replacement" yerine "full_content" alanını kullan. full_content dosyanın TAM içeriğini içerir.
  Örnek: {"path": "MainActivity.kt", "full_content": "package com.x\nimport ...\nclass MainActivity..."}
PROMPT
    fi
    local patch_sp=$(cat "$task_sp_file")
    local patch_um="GÖREV: $user_task\n\n$(cat "$collected")"

    # Adım 2: İlk tur ZORUNLU commands, sonra changes
    local tour=0
    while [[ $tour -lt 3 ]]; do
        tour=$((tour+1))
        if ! _call_active_ai "$patch_sp" "$patch_um"; then
            err "Kod üretilemedi."; return 1
        fi

        # commands var mı?
        if run_ai_commands; then
            local cmd_output; cmd_output=$(cat "$TMP_DIR/cmd_output.txt")
            log "📂 AI $(echo "$cmd_output" | wc -c) karakter dosya içeriği aldı (tur $tour)"
            patch_um="GÖREV: $user_task\n\nOKUNAN DOSYALAR:\n${cmd_output}\n\nŞimdi sadece değişiklik yapılacak yerleri \"changes\" ile yaz. Dosyaları tekrar okuma."
            continue
        fi

        # commands yok → changes var
        if apply_fixes; then
            break
        fi
        err "Görev koda uygulanamadı."; return 1
    done

    echo -e "\n${BOLD}${BLUE}🚀 Görev koda entegre edildi, otomatik derleme (Build & Fix) devralınıyor...${NC}"
    run_autofix
}

main() {
    check_deps
    case "${1:-run}" in
        task|e)
            detect_project "${3:-}"
            select_provider
            run_task "$2"
            ;;
        apiler|api|a)  apiler_menu ;;
        prompts|p)     prompts_menu ;;
        install|kur)
            cp "$0" "$SISTEM_DIR/autofix.sh"
            chmod +x "$SISTEM_DIR/autofix.sh"
            mkdir -p "$APILER_DIR" "$PROMPTS_DIR"
            create_default_prompt
            grep -qF "alias autofix=" "$HOME/.bashrc" 2>/dev/null || \
                echo "alias autofix='bash $SISTEM_DIR/autofix.sh'" >> "$HOME/.bashrc"
            ok "Kuruldu | alias: autofix"
            ;;
        run|*)
            detect_project "${2:-}"
            select_provider
            
            # --- YENİ: Normal hata çözmede de yedekleri temizle ---
            clean_agent_backups
            run_autofix
            ;;
    esac
}

main "$@"







