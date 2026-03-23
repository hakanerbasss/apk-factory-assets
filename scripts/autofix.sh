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
TMP_DIR="$HOME/.autofix_tmp"
LOG_FILE="$TMP_DIR/autofix.log"
MAX_LOOPS=$(grep "^MAX_LOOPS=" ~/.config/autofix.conf 2>/dev/null | cut -d= -f2 || echo 8)

# --- YENİ: Gölge Yedekleme Sistemi ---
AGENT_YEDEK_DIR="$SISTEM_DIR/agent_yedekler"
BACKUP_MAP="$AGENT_YEDEK_DIR/backup_map.txt"

cleanup() { rm -f "$TMP_DIR"/*.txt "$TMP_DIR"/*.json "$TMP_DIR"/*.py 2>/dev/null; }
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
       # --- YENİ: OTOMATİK TOKEN YÜKSELTİCİ ---
    # Büyük modeller seçildiyse kullanıcının düşük ayarını ez ve sınırları zorla
    if [[ "$NAME" == "Claude" && $MAX_TOKENS -lt 8192 ]]; then
        MAX_TOKENS=8192
        warn "Token limiti Claude icin otomatik olarak 8192'ye yukseltildi."
    fi
    # AKILLI TOKEN: Kaynak dosya buyukse Claude icin max token'i zirveye cikar
    if [[ "$NAME" == "Claude" ]]; then
        local model_lower=$(echo "$MODEL" | tr '[:upper:]' '[:lower:]')
        if [[ "$model_lower" == *"haiku"* ]]; then
            MAX_TOKENS=8192
        elif [[ "$model_lower" == *"sonnet"* ]]; then
            MAX_TOKENS=16384
        elif [[ "$model_lower" == *"opus"* ]]; then
            MAX_TOKENS=16384
        fi
    elif [[ "$NAME" == "Gemini" && $MAX_TOKENS -lt 16384 ]]; then
        MAX_TOKENS=16384
        warn "Token limiti Gemini için otomatik olarak 16384'e yükseltildi."
    fi

     ok "Aktif Provider: $NAME | Model: $MODEL"
}

create_default_prompt() {
    [[ ! -f "$PROMPTS_DIR/autofix_system.txt" ]] && err "HATA: autofix_system.txt bulunamadı!" && exit 1
}

find_project_root() {
    local dir="$1"
    while [[ "$dir" != "/" ]]; do
        [[ -f "$dir/gradlew" || -f "$dir/build.gradle" || -f "$dir/build.gradle.kts" || -d "$dir/app" ]] && echo "$dir" && return 0
        dir="$(dirname "$dir")"
    done; return 1
}

detect_project() {
    PROJECT_ROOT=""
    [[ -n "${1:-}" && -d "$1" && -f "$1/gradlew" ]] && PROJECT_ROOT="$1"
    [[ -z "$PROJECT_ROOT" ]] && PROJECT_ROOT=$(find_project_root "$(pwd)") || PROJECT_ROOT=$(pwd)
    if [[ -z "$PROJECT_ROOT" ]]; then
        err "Gradle projesi bulunamadı. Proje klasöründen çalıştırın."; exit 1
    fi
    SRC_ROOT="$PROJECT_ROOT/app/src/main/java"
    ok "Proje: $PROJECT_ROOT"
}

run_build() {
    log "Build başlatılıyor..."
    echo -e "${CYAN}────────────────────────────────────────${NC}"
    local build_out="$TMP_DIR/build_output.txt"
    mkdir -p "$TMP_DIR"
    local result_file="$TMP_DIR/build_result.txt"
    cd "$PROJECT_ROOT"

    # --- YENİ: ZIP İLE GELEN EKSİK PROJELER İÇİN OTOMATİK MOTOR AŞILAMA ---
    if [[ ! -f "gradlew" ]]; then
        warn "Motor (gradlew) eksik! Setup klasöründen otomatik aşılanıyor..."
        cp -r "/storage/emulated/0/termux-otonom-sistem/setup/gradle" . 2>/dev/null || true
        cp "/storage/emulated/0/termux-otonom-sistem/setup/gradlew" . 2>/dev/null || true
        # Ekran görüntüsündeki "template" dosyasını gerçek gradle.properties olarak kopyala
        [[ ! -f "gradle.properties" ]] && cp "/storage/emulated/0/termux-otonom-sistem/setup/gradle.properties.template" ./gradle.properties 2>/dev/null || true
        chmod +x gradlew 2>/dev/null || true
        # build.gradle dosyalarını da aşıla
        [[ ! -f "build.gradle" ]] && cp "/storage/emulated/0/termux-otonom-sistem/setup/build.gradle" . 2>/dev/null || true
        [[ ! -f "app/build.gradle" ]] && cp "/storage/emulated/0/termux-otonom-sistem/setup/app/build.gradle" "app/" 2>/dev/null || true
        [[ ! -f "settings.gradle" ]] && cp "/storage/emulated/0/termux-otonom-sistem/setup/settings.gradle" . 2>/dev/null || true
        ok "Motor ve Kalp (build.gradle) başarıyla takıldı!" 
    fi
    # -------------------------------------------------------------------

    # FIX: pipe chain yerine dosyaya yaz (Broken Pipe onleme)
    mkdir -p "$TMP_DIR"
    ./gradlew assembleDebug --no-daemon > "$build_out" 2>&1
    # Ekrana ozet bas
    while IFS= read -r line; do
        if   [[ "$line" == *"> Task"* ]];           then echo -e "${CYAN}  ⚙  ${line#*> Task }${NC}"
        elif [[ "$line" == *"e: "* ]];              then echo -e "${RED}  ✗  $line${NC}"
        elif [[ "$line" == *"error:"* ]];           then echo -e "${RED}  ✗  $line${NC}"
        elif [[ "$line" == *"Could not find"* ]];   then echo -e "${RED}  ✗  $line${NC}"
        elif [[ "$line" == *"BUILD SUCCESSFUL"* ]]; then echo -e "${GREEN}  ✅  BUILD SUCCESSFUL${NC}"
        elif [[ "$line" == *"BUILD FAILED"* ]];     then echo -e "${RED}  ❌  BUILD FAILED${NC}"
        elif [[ "$line" == *"warning:"* ]];         then echo -e "${YELLOW}  ⚠  $line${NC}"
        fi
    done < "$build_out"
    echo -e "${CYAN}────────────────────────────────────────${NC}"
    if grep -q "BUILD SUCCESSFUL" "$build_out"; then
        echo "SUCCESS" > "$result_file"
    else
        echo "FAILED" > "$result_file"
    fi
}

parse_errors() {
    local build_out="$TMP_DIR/build_output.txt"
    mkdir -p "$TMP_DIR"
    local errors_file="$TMP_DIR/errors.txt"
    local files_file="$TMP_DIR/error_files.txt"

    # Sadece ilk 6'yı değil, ilk 20 satırı al ama BENZERSİZ (sort -u) olanları seç. 
    # Uyarıları (w:) eliyoruz, sadece gerçek hatalara (e:, error, Exception) odaklanıyoruz.
    # ONCELIK 1: Kotlin compile hatalarini yakala (^e: ile baslayanlar)
    grep "^e:" "$build_out" | head -n 30 > "$errors_file" 2>/dev/null || true
    # ONCELIK 2: ^e: yoksa diger hata pattern'lerini dene
    if [[ ! -s "$errors_file" ]]; then
        grep -E "error:|^ERROR|AAPT|Could not find|Could not resolve|What went wrong" \
            "$build_out" | grep -v "Caching disabled\|Thread\[\|Resolve mutations\|Skipping task\|started\.$\|Tasks to be" \
            | head -n 20 | sort -u > "$errors_file" 2>/dev/null || true
    fi
    # ONCELIK 3: Hic yoksa son 30 satir (ama noise filtreli)
    if [[ ! -s "$errors_file" ]]; then
        tail -n 50 "$build_out" | grep -v "UP-TO-DATE\|NO-SOURCE\|Caching disabled\|Thread\[\|Resolve mutations\|Skipping task\|started\.$\|Tasks to be" | tail -n 20 > "$errors_file"
    fi

    # Hata veren dosya yollarını çıkar
    grep -oE '/[^ :]+\.[a-zA-Z0-9]+' "$errors_file" \
        | grep -v "\.class$\|\.jar$\|\.apk$\|\.aab$" \
        | head -n 5 | sort -u > "$files_file" 2>/dev/null || true

    # Bulunamazsa: paket yolundan dosya bul
    if [[ ! -s "$files_file" ]]; then
        grep -oE 'com/[a-zA-Z0-9_/]+\.[a-zA-Z]+' "$build_out" \
        | while read -r rel; do
            find "$PROJECT_ROOT" -path "*$rel" 2>/dev/null | head -1
        done | head -n 3 | sort -u > "$files_file"
    fi

    # Hala boşsa: build çıktısının tamamından dosya adı ara
    if [[ ! -s "$files_file" ]]; then
        grep -oE '[A-Za-z][A-Za-z0-9_]+\.(kt|java|xml|gradle|kts|toml|json|properties)' "$build_out" \
        | while read -r fname; do
            find "$PROJECT_ROOT" -name "$fname" -not -path "*/build/*" 2>/dev/null | head -1
        done | head -n 3 | sort -u > "$files_file"
    fi

    echo "$errors_file"
}


collect_source_files() {
    local error_files_list="$TMP_DIR/error_files.txt"
    local collected="$TMP_DIR/collected_sources.txt"
    local max_chars
    max_chars=$(grep "^MAX_CHARS=" ~/.config/autofix.conf 2>/dev/null | cut -d= -f2 || echo 60000)
    > "$collected"
    echo "=== PROJE DOSYA AGACI ===" >> "$collected"
    find "$PROJECT_ROOT" -maxdepth 4 -not -path "*/.*" -not -path "*/build/*" >> "$collected"
    echo "=========================" >> "$collected" 

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

    # --- YENİ: BAĞLILIKLARI (DEPENDENCIES) AKILLICA İÇERİ AL ---
    # Hata veren dosyaların içindeki projeye ait "import" edilen sınıfları bul ve onları da gönder
    local pkg_base=$(grep "applicationId" "$PROJECT_ROOT/app/build.gradle" 2>/dev/null | grep -oE '"[^"]+"' | tr -d '"' | head -1)
    if [[ -n "$pkg_base" ]]; then
        while IFS= read -r fpath; do
            [[ ! -f "$fpath" ]] && continue
            grep -E "^import $pkg_base" "$fpath" | while read -r imp_line; do
                # import com.wizaicorp.app.data.Model -> data/Model.kt
                local rel_path=$(echo "$imp_line" | awk '{print $2}' | tr '.' '/')
                local dep_file=$(find "$PROJECT_ROOT/app/src/main/java" -path "*${rel_path}.kt" 2>/dev/null | head -1)
                [[ -n "$dep_file" ]] && add_file "$dep_file"
            done
        done < "$error_files_list"
    fi

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


# ─── SENIOR (GÖZLEMCI) AI ───────────────────────────────────────────────────
call_senior_ai() {
    local errors="$1" sources="$2"
    # Senior'a sadece ^e: satirlari gonder, --info gurultusu degil
    local error_text; error_text=$(grep "^e:" "$errors" 2>/dev/null)
    [[ -z "$error_text" ]] && error_text=$(cat "$errors")
    local source_text; source_text=$(cat "$sources")
    local original_task="${3:-}"
    local next_task_content=""
    local ntf="$SISTEM_DIR/chain_task.txt"
    [[ -f "$ntf" ]] && next_task_content=$(cat "$ntf")

    # Ayarlardan Senior provider ve model oku
    local senior_prov_name; senior_prov_name=$(grep "^SENIOR_PROVIDER=" ~/.config/autofix.conf 2>/dev/null | cut -d'"' -f2)
    local senior_model_name; senior_model_name=$(grep "^SENIOR_MODEL=" ~/.config/autofix.conf 2>/dev/null | cut -d'"' -f2)
    local senior_conf="" senior_name="" senior_url="" senior_key="" senior_model=""

    if [[ -n "$senior_prov_name" ]]; then
        local prov_lower; prov_lower=$(python3 -c "print(open('/dev/stdin').read().strip().lower())" <<< "$senior_prov_name")
        local cf="$APILER_DIR/${prov_lower}.conf"
        if [[ -f "$cf" ]]; then
            senior_conf="$cf"
            senior_name="$senior_prov_name"
            senior_url=$(grep "^API_URL=" "$cf" | cut -d'"' -f2)
            senior_key=$(grep "^API_KEY=" "$cf" | cut -d'"' -f2)
            senior_model="${senior_model_name:-$(grep "^MODEL=" "$cf" | cut -d'"' -f2)}"
        fi
    fi

    if [[ -z "$senior_conf" ]]; then
        warn "Gözlemci AI için başka provider bulunamadı, atlanıyor."
        return 1
    fi

    log "🎓 SENIOR GÖZLEMCİ devreye giriyor: $senior_name"

    local senior_prompt="Sen Termux ortaminda calisan kidemli Android/Kotlin Mimari.\nJunior AI ayni hatada donguye girmis. Asagidaki GERCEK hata satirlarini analiz et.\nKod YAZMA. Sadece Junior AI\'a 3-5 maddede net talimat ver:\n- Hangi dosyada hangi import eksik\n- Hangi sinif adi yanlis yazilmis (ornegin isSystemInDarkMode yerine isSystemInDarkTheme)\n- Hangi dependency eksik (artifact adi ver)\n- Unresolved reference varsa: import satirini VER\nKRITIK: Genel tavsiye verme (cache temizle, aapt2 ekle gibi). SOMUT HATA SATIRINA SOMUT COZUM ver.\nTurkce yaz."

    # Geçmiş AI yanıtlarını topla (son 3 yanıt)
    local history_text=""
    if [[ -f "/sdcard/Download/last_ai_response.txt" ]]; then
        history_text=$(tail -c 5000 /sdcard/Download/last_ai_response.txt 2>/dev/null)
    fi

    # Aktif prompt dosyasını oku
    local active_prompt_content=""
    [[ -f "$PROMPTS_DIR/autofix_task.txt" ]] && active_prompt_content=$(cat "$PROMPTS_DIR/autofix_task.txt")

    local senior_user="ORIJINAL KULLANICI İSTEĞİ:
${original_task}

ÇALIŞMA MODU: ${4:-bilinmiyor} (prj af=hata düzeltme, prj e=yeni görev)
MEVCUT DENEME: ${5:-?} / $MAX_LOOPS

JUNIOR AI'IN KULLANDIĞI PROMPT (autofix_task.txt):
${active_prompt_content:0:2000}

JUNIOR AI'IN BOZUK KODU:
${source_text:0:25000}

BUILD HATALARI:
${error_text}

JUNIOR AI'IN SON YANITI (döngüye girmiş olabilir):
${history_text:0:5000}

POSTA KUTUSUNDA BEKLEYEN SONRAKI GÖREV:
${next_task_content:-Yok}

Bu verileri analiz et:
- Junior AI döngüye girmiş mi? Kaçıncı denemede?
- Mod ne? (af=mevcut kodu düzelt, e=yeni özellik ekle, mevcut kodu bozma)
- Neden aynı hatayı tekrarlıyor?
3-5 maddede net talimat ver. Sadece TAVSİYE yaz, KOD YAZMA."

    local senior_resp="$TMP_DIR/senior_advice.txt"

    # Provider tipine göre çağır
    local advice=""
    # Payload dosyaya yaz (özel karakter sorunu önleme)
    local senior_payload_file="$TMP_DIR/senior_payload.json"
    if [[ "$senior_name" == "Claude" ]]; then
        python3 -c "
import json,sys
print(json.dumps({'model':sys.argv[1],'max_tokens':2000,'temperature':0.1,
'system':sys.argv[2],'messages':[{'role':'user','content':sys.argv[3]}]}))" \
            "$senior_model" "$senior_prompt" "$senior_user" > "$senior_payload_file" 2>/dev/null
        local hc; hc=$(curl -s -w "%{http_code}" -X POST "$senior_url"             -H "Content-Type: application/json"             -H "x-api-key: $senior_key"             -H "anthropic-version: 2023-06-01"             -d "@$senior_payload_file" -o "$TMP_DIR/senior_response.json"             --connect-timeout 30 --max-time 120 2>/dev/null)
        [[ "$hc" == "200" ]] && advice=$(jq -r '.content[0].text' "$TMP_DIR/senior_response.json" 2>/dev/null)
    else
        python3 -c "
import json,sys
sp=open(sys.argv[1]).read(); um=open(sys.argv[2]).read()
print(json.dumps({'model':sys.argv[3],'max_tokens':2000,'temperature':0.1,
'messages':[{'role':'system','content':sp},{'role':'user','content':um}]}))"             <(echo "$senior_prompt") <(echo "$senior_user") "$senior_model" > "$senior_payload_file" 2>/dev/null
        local hc; hc=$(curl -s -w "%{http_code}" -X POST "$senior_url"             -H "Content-Type: application/json" -H "Authorization: Bearer $senior_key"             -d "@$senior_payload_file" -o "$TMP_DIR/senior_response.json"             --connect-timeout 30 --max-time 120 2>/dev/null)
        [[ "$hc" == "200" ]] && advice=$(jq -r '.choices[0].message.content' "$TMP_DIR/senior_response.json" 2>/dev/null)
    fi

    if [[ -n "$advice" && "$advice" != "null" ]]; then
        local advice_save="$advice"
        echo "$advice_save" > "$senior_resp"
        ok "🎓 Senior tavsiyesi alındı ($senior_name)"
        echo -e "${CYAN}━━━ SENIOR TAVSİYESİ ━━━${NC}"
        echo "$advice_save"
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        return 0
    fi
    warn "Senior AI yanıt veremedi (HTTP $hc), devam ediliyor."
    return 1
}


# ─── BUILD SONRASI KULLANICI AKSİYON KONTROLÜ ───────────────────────────────
check_user_actions() {
    # Kaynak dosyaları direkt topla (TMP_DIR bağımsız)
    local src_text=""
    while IFS= read -r -d '' f; do
        src_text+="\n=== $f ===\n$(head -c 5000 "$f")\n"
        [[ ${#src_text} -gt 30000 ]] && break
    done < <(find "$PROJECT_ROOT/app/src/main/java" -name "*.kt" -print0 2>/dev/null)

    local check_prompt="Sen bir Android/Kotlin kod analistsin. Verilen kaynak kodunu incele ve kullanıcının manuel olarak yapması gereken işlemler var mı tespit et. Sadece gerçekten gerekli olan şeyleri listele. Yoksa hiçbir şey yazma. Kısa ve net ol. Örnekler: google-services.json eksikse Firebase SHA-1 talimatı, AdMob ID placeholder varsa, API key placeholder varsa, özel izin veya sertifika gerekiyorsa. Tespit ettiklerini madde madde yaz. Hiçbir şey yoksa sadece 'YOK' yaz."

    local payload; payload=$(python3 -c "
import json,sys
print(json.dumps({'model':'${MODEL}','max_tokens':500,'temperature':0.1,
'system':sys.argv[1],
'messages':[{'role':'user','content':sys.argv[2]}]}))" "$check_prompt" "$src_text" 2>/dev/null)

    local result=""
    mkdir -p "$TMP_DIR" 2>/dev/null
    if [[ "$NAME" == "Claude" ]]; then
        local hc; hc=$(curl -s -w "%{http_code}" -X POST "$API_URL"             -H "Content-Type: application/json"             -H "x-api-key: $API_KEY"             -H "anthropic-version: 2023-06-01"             -d "$payload" -o "$TMP_DIR/action_check.json"             --connect-timeout 30 --max-time 60 2>/dev/null)
        [[ "$hc" == "200" ]] && result=$(jq -r '.content[0].text' "$TMP_DIR/action_check.json" 2>/dev/null)
    else
        local payload2; payload2=$(python3 -c "
import json,sys
print(json.dumps({'model':'${MODEL}','max_tokens':500,'temperature':0.1,
'messages':[{'role':'system','content':sys.argv[1]},{'role':'user','content':sys.argv[2]}]}))" "$check_prompt" "$src_text" 2>/dev/null)
        local hc; hc=$(curl -s -w "%{http_code}" -X POST "$API_URL"             -H "Content-Type: application/json" -H "Authorization: Bearer $API_KEY"             -d "$payload2" -o "$TMP_DIR/action_check.json"             --connect-timeout 30 --max-time 60 2>/dev/null)
        if [[ "$hc" == "200" ]]; then
            result=$(jq -r '.choices[0].message.content' "$TMP_DIR/action_check.json" 2>/dev/null)
            # DeepSeek reasoning model - content bossa reasoning_content dene
            [[ -z "$result" || "$result" == "null" ]] && result=$(jq -r '.choices[0].message.reasoning_content' "$TMP_DIR/action_check.json" 2>/dev/null)
        fi
    fi

    if [[ -n "$result" && "$result" != "null" && "$result" != "YOK" ]]; then
        echo "USER_ACTION_REQUIRED:${result}"
    fi
}

call_ai() {
    local errors="$1" sources="$2"
    local error_text; error_text=$(cat "$errors")
    local source_text; source_text=$(cat "$sources")
    local max_chars
    max_chars=$(grep "^MAX_CHARS=" ~/.config/autofix.conf 2>/dev/null | cut -d= -f2 || echo 60000)
    # AKILLI TOKEN: Buyuk dosyalarda input kirp, output icin yer birak
    local source_len=${#source_text}
    if [[ $source_len -gt 25000 ]]; then
        max_chars=20000
        warn "Buyuk kaynak ($source_len char) → input $max_chars'e kirpildi (output icin yer aciliyor)"
    fi
    [[ ${#source_text} -gt $max_chars ]] && source_text="${source_text:0:$max_chars}"

    local system_prompt
    local pf="$PROMPTS_DIR/autofix_system.txt"
    [[ ! -f "$pf" ]] && create_default_prompt
    system_prompt=$(cat "$pf")

    # Global dersler (tum projelerden birikmis)
    local global_lessons="$SISTEM_DIR/global_lessons.md"
    if [[ -f "$global_lessons" ]]; then
        local glessons; glessons=$(tail -c 3000 "$global_lessons")
        system_prompt="${system_prompt}

=== GLOBAL ANDROID/KOTLIN DERSLERI (TUM PROJELERDEN) ===
${glessons}
=== GLOBAL DERSLER SONU ==="
    fi

    # Proje derslerini ekle
    local lessons_file="$PROJECT_ROOT/lessons.md"
    if [[ -f "$lessons_file" ]]; then
        local lessons; lessons=$(cat "$lessons_file")
        system_prompt="${system_prompt}

=== BU PROJEDEN ÖNCEKI DERSLER (AYNI HATALARI TEKRARLAMA) ===
${lessons}
=== DERSLER SONU ==="
    fi
    local tree_content=$(find "$PROJECT_ROOT" -maxdepth 4 -not -path "*/.*" -not -path "*/build/*")
    # AKILLI TOKEN: Buyuk dosyalarda auto_continue hatirlat
    local size_warning=""
    if [[ ${#source_text} -gt 15000 ]]; then
        size_warning="\n\n!!! BUYUK DOSYA UYARISI !!!\nBu dosya cok buyuk. Tek seferde yazamazsan auto_continue: true kullan.\nDosyayi ASLA yarida birakma. Yarim kalan string YASAKTIR.\nEger dosya token limitine sigmazsa, onceki kod yapisini koru ve sadece HATALI SATIRLARI duzelt.\nTum dosyayi bastan yazma — sadece hatali fonksiyonu yeniden yaz."
    fi
    # ═══ AKILLI TOKEN HESAPLAYICI ═══
    local input_chars=${#source_text}
    local input_tokens=$((input_chars / 4))
    
    # Model output limitleri (API SABIT - degistirilemez)
    local model_max_output=8192
    local model_lower=$(echo "$MODEL" | tr '[:upper:]' '[:lower:]')
    [[ "$model_lower" == *"sonnet"* || "$model_lower" == *"opus"* ]] && model_max_output=16384
    [[ "$model_lower" == *"gemini"* ]] && model_max_output=16384
    local max_output_lines=$((model_max_output * 4 / 80))
    
    # En buyuk hatali dosyanin satir sayisi
    local biggest_file_lines=0
    local biggest_file_name=""
    while IFS= read -r ef; do
        [[ -f "$ef" ]] || continue
        local fl=$(wc -l < "$ef" 2>/dev/null || echo 0)
        if [[ $fl -gt $biggest_file_lines ]]; then
            biggest_file_lines=$fl
            biggest_file_name=$(basename "$ef")
        fi
    done < "$TMP_DIR/error_files.txt" 2>/dev/null
    
    local size_warning=""
    if [[ $biggest_file_lines -gt $max_output_lines ]]; then
        size_warning="\n\n!!! KRITIK: PARCALI DUZELTME MODU !!!\nDosya: ${biggest_file_name} (${biggest_file_lines} satir) > Senin limitin (~${max_output_lines} satir)\nTUM DOSYAYI YAZMA! Sadece HATALI fonksiyonu yaz.\nDiger fonksiyonlara DOKUNMA. Ornek:\nDosya: app/.../MainActivity.kt\n\\`\\`\\`kotlin\n// ... onceki kod aynen ...\nfun hataliFonksiyon() {\n    // SADECE BU DUZELTILDI\n}\n// ... sonraki kod aynen ...\n\\`\\`\\`\nASLA string/parantez ACIK BIRAKMA!"
    elif [[ $biggest_file_lines -gt $((max_output_lines / 2)) ]]; then
        size_warning="\n\n!!! UYARI: Dosya buyuk (${biggest_file_lines} satir, limit ~${max_output_lines})\nDikkatli yaz. Sigmazsa auto_continue: true kullan. YARIM BIRAKMA!"
    fi
    
    log "Token: input=${input_tokens}tok model_limit=${model_max_output} max_satir=~${max_output_lines} dosya=${biggest_file_lines}satir"
    local user_msg="!!! MEVCUT PROJE DOSYA YAPISI (BUNLARI SILME) !!!\n${tree_content}\n\nBUILD HATALARI:\n\`\`\`\n${error_text}\n\`\`\`${size_warning}\n\nKAYNAK DOSYALAR:\n${source_text}"

    log "$NAME'e gönderiliyor... (${#source_text} karakter)"
    echo -e "${YELLOW}  ⏳ API yanıtı bekleniyor (Max 600sn)...${NC}"

    _call_active_ai "$system_prompt" "$user_msg"
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
    cp "$TMP_DIR/ai_content.txt" "/sdcard/Download/last_ai_response.txt" # BU SATIRI EKLE

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
    cp "$TMP_DIR/ai_content.txt" "/sdcard/Download/last_ai_response.txt" # BU SATIRI EKLE

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
    cp "$TMP_DIR/ai_content.txt" "/sdcard/Download/last_ai_response.txt" # BU SATIRI EKLE

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
    local py_script="$TMP_DIR/markdown_parser.py"

    # Markdown parser'ı oluştur
    cat > "$py_script" << 'PYEOF'
import re, os, shutil, sys

def parse_markdown_files(text):
    results = []
    pattern = re.compile(
        r'(?:Dosya|File|=== FILE)\s*[:\s]*\s*((?:app/|\./|/data/)[^\n]{3,200})\s*(?:===)?\n'
        r'[ \t]*\n?'
        r'(?:[ \t]*```[^\n]*\n)?' 
        r'(.*?)'
        r'(?:^[ \t]*```[ \t]*$|(?=(?:Dosya|File)\s*:)|\Z)',
        re.MULTILINE | re.DOTALL
    )
    for m in pattern.finditer(text):
        path = m.group(1).strip()
        code = m.group(2).rstrip('\n')
        results.append((path, code))
    return results

def apply_markdown_fixes(content_file, project_root, backup_map_file):
    text = open(content_file, encoding='utf-8', errors='replace').read()
    files = parse_markdown_files(text)
    if not files:
        print("PARSE_ERROR: Markdown formatinda dosya bulunamadi")
        return False
    backup_map = {}
    for rel_path, new_content in files:
        rel_path = rel_path.lstrip('/')
        abs_path = os.path.join(project_root, rel_path)
        os.makedirs(os.path.dirname(abs_path), exist_ok=True)
        if os.path.exists(abs_path):
            bak = os.path.join('/storage/emulated/0/termux-otonom-sistem/agent_yedekler', rel_path.replace('/', '_') + '.bak_agent')
            shutil.copy2(abs_path, bak)
            backup_map[abs_path] = bak
            old_lines = len(open(abs_path).readlines())
            if abs_path.endswith('build.gradle'):
                from re import sub
                # Versiyon satırlarını prj scriptinin okuyabileceği alt alta formata zorla
                new_content = sub(r'([;{])\s*(versionCode|versionName)', r'\1\n        \2', new_content)
                new_content = sub(r'(versionCode \d+|versionName ".*?")\s*([;}])', r'\1\n    \2', new_content)
            open(abs_path, 'w', encoding='utf-8').write(new_content + '\n')
            print(f"MODIFIED:{rel_path}|{old_lines}|{len(new_content.splitlines())}")
        else:
            if abs_path.endswith('build.gradle'):
                from re import sub
                # Versiyon satırlarını prj scriptinin okuyabileceği alt alta formata zorla
                new_content = sub(r'([;{])\s*(versionCode|versionName)', r'\1\n        \2', new_content)
                new_content = sub(r'(versionCode \d+|versionName ".*?")\s*([;}])', r'\1\n    \2', new_content)
            open(abs_path, 'w', encoding='utf-8').write(new_content + '\n')
            print(f"CREATED:{rel_path}|0|{len(new_content.splitlines())}")
    if backup_map_file and backup_map:
        with open(backup_map_file, 'w') as f:
            for orig, bak in backup_map.items():
                f.write(f"{orig}|{bak}\n")
    return True

def parse_auto_continue(text):
    """Yanitın sonundan auto_continue ve continue_prompt okur"""
    import re
    ac = re.search(r'auto_continue\s*:\s*(true|false)', text, re.IGNORECASE)
    cp = re.search(r'continue_prompt\s*:\s*(.+?)(?=\n(?:auto_continue|Dosya:|File:)|$)', text, re.IGNORECASE | re.DOTALL)
    lesson = re.search(r'lesson\s*:\s*(.+?)(?=\n(?:auto_continue|Dosya:|File:)|$)', text, re.IGNORECASE | re.DOTALL)
    auto_cont = ac.group(1).lower() == 'true' if ac else False
    cont_prompt = cp.group(1).strip() if cp else 'Goreve devam et.'
    lesson_text = lesson.group(1).strip() if lesson else None
    return auto_cont, cont_prompt, lesson_text

content_file = sys.argv[1]
project_root = sys.argv[2]
backup_map_file = sys.argv[3] if len(sys.argv) > 3 else ''
next_task_file = sys.argv[4] if len(sys.argv) > 4 else ''

text = open(content_file, encoding='utf-8', errors='replace').read()
auto_cont, cont_prompt, lesson_text = parse_auto_continue(text)

# Ders varsa lessons.md'ye ekle
if lesson_text:
    import datetime
    ts = datetime.datetime.now().strftime('%Y-%m-%d %H:%M')
    # Proje dersi
    lessons_file = os.path.join(project_root, 'lessons.md')
    with open(lessons_file, 'a', encoding='utf-8') as lf:
        lf.write(f'\n- [{ts}] {lesson_text}\n')
    # Global ders (dedup: ayni ders varsa tekrar ekleme)
    sistem_dir = os.environ.get('SISTEM_DIR', '/storage/emulated/0/termux-otonom-sistem')
    global_file = os.path.join(sistem_dir, 'global_lessons.md')
    proj_name = os.path.basename(project_root)
    existing = ''
    if os.path.exists(global_file):
        existing = open(global_file, 'r', encoding='utf-8', errors='replace').read()
    # Dersin ilk 50 karakteri zaten varsa ekleme (dedup)
    if lesson_text[:50] not in existing:
        with open(global_file, 'a', encoding='utf-8') as gf:
            gf.write(f'\n- [{ts}] [{proj_name}] {lesson_text}\n')
        # Global dosya 5000 karakteri gecerse eski dersleri kirp
        if len(existing) > 5000:
            lines = existing.strip().split('\n')
            trimmed = '\n'.join(lines[-30:])  # son 30 ders
            open(global_file, 'w', encoding='utf-8').write(trimmed + '\n')
    print(f"LESSON_SAVED:{lesson_text[:80]}")

ok = apply_markdown_fixes(content_file, project_root, backup_map_file)

if auto_cont and next_task_file:
    open(next_task_file, 'w').write(cont_prompt)
    print("AUTO_CONTINUE_FLAG:TRUE")
    print(f"POSTA_ICERIGI:{cont_prompt[:200]}")

sys.exit(0 if ok else 1)
PYEOF

    local next_task_file="$SISTEM_DIR/next_task_${P_PKG:-$(basename $PROJECT_ROOT)}.txt"
    python3 "$py_script" "$TMP_DIR/ai_content.txt" "$PROJECT_ROOT" "$BACKUP_MAP" "$next_task_file"
    local rc=$?

    if [[ $rc -ne 0 ]]; then
        # FIX: AI kod yerine soru sormussa, hata detayini artir
        local ai_text=$(cat "$TMP_DIR/ai_content.txt" 2>/dev/null)
        if echo "$ai_text" | grep -qiE "gonder|send|gönder|lütfen|please|bilgi ver"; then
            warn "AI soru sordu (kod vermedi). Stacktrace ile hata detayi arttiriliyor..."
            cd "$PROJECT_ROOT"
            ./gradlew compileDebugKotlin --no-daemon --stacktrace 2>&1 | grep -E "^e:|error:|Exception|Caused by" | head -30 > "$TMP_DIR/errors.txt"
            if [[ -s "$TMP_DIR/errors.txt" ]]; then
                log "Detayli hata bulundu: $(wc -l < \"$TMP_DIR/errors.txt\") satir"
            fi
        fi
        # FIX: AI kod yerine soru sormussa, hata detayini artir
        local ai_text=$(cat "$TMP_DIR/ai_content.txt" 2>/dev/null)
        if echo "$ai_text" | grep -qiE "gonder|send|gönder|lütfen|please|bilgi ver"; then
            warn "AI soru sordu (kod vermedi). Stacktrace ile hata detayi arttiriliyor..."
            cd "$PROJECT_ROOT"
            ./gradlew compileDebugKotlin --no-daemon --stacktrace 2>&1 | grep -E "^e:|error:|Exception|Caused by" | head -30 > "$TMP_DIR/errors.txt"
            if [[ -s "$TMP_DIR/errors.txt" ]]; then
                log "Detayli hata bulundu: $(wc -l < \"$TMP_DIR/errors.txt\") satir"
            fi
        fi
        err "Markdown parser başarısız — dosya güncellenemedi"
        return 1
    fi

    # Değişiklik sayısını hesapla
    local count=0
    if [[ -f "$BACKUP_MAP" ]]; then
        count=$(wc -l < "$BACKUP_MAP" 2>/dev/null || echo 0)
    fi
    ok "$count dosya güncellendi, build testine geçiliyor..."
    return 0
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
            python3 "$diff_script" "$asil" "$bak" | head -n 30
            echo "----------------------------------------"
        done < "$BACKUP_MAP"
    fi
}

run_autofix() {
    local TASK_DESCRIPTION="${1:-}"
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
            check_user_actions
            
            local apk; apk=$(find "$PROJECT_ROOT/app/build/outputs/apk" -name "*.apk" 2>/dev/null | head -1)
            [[ -n "$apk" ]] && ok "APK → Build tamamlandi"

            # --- OTONOM ZİNCİRLEME: SADECE BAŞARI DURUMUNDA TETİKLE ---
            if [[ -f "$SISTEM_DIR/next_task_${P_NAME:-$(basename $PROJECT_ROOT)}.txt" ]]; then
                ok "📬 Posta kutusunda bekleyen görev var! Otonom devam ediliyor..."
                clean_agent_backups
                # Not: Dosyayı SİLMİYORUZ, ws_bridge.py okuyup silecek.
                exit 0 # Başarıyla çık ki ws_bridge tetiklensin
            fi
            # -------------------------------------------------------

            read -r -p "$(echo -e "
${YELLOW}Değişiklikleri kalıcı yap veya Yedeğe dön [Enter=Kalıcı Yap / B=Yedeğe Dön]: ${NC}")" res
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

        local src; src=$(collect_source_files)
        
        # Senior AI devreye girme noktası (MAX_LOOPS/2)
        local senior_threshold=$(( (MAX_LOOPS + 1) / 2 ))
        [[ $senior_threshold -lt 2 ]] && senior_threshold=2
        local senior_prov; senior_prov=$(grep "^SENIOR_PROVIDER=" ~/.config/autofix.conf 2>/dev/null | cut -d'"' -f2)
        local senior_model; senior_model=$(grep "^SENIOR_MODEL=" ~/.config/autofix.conf 2>/dev/null | cut -d'"' -f2)

        if [[ $loop -ge $senior_threshold && -n "$senior_prov" ]]; then
            warn "🎓 $loop. denemede Senior AI devreye giriyor: $senior_prov / $senior_model"
            if call_senior_ai "$ef" "$src" "${TASK_DESCRIPTION:-}" "af" "$loop"; then
                # Senior tavsiyesini bir sonraki call_ai'a ekle
                local advice_file="$TMP_DIR/senior_advice.txt"
                if [[ -f "$advice_file" ]]; then
                    local orig_task_prompt="$PROMPTS_DIR/autofix_task.txt"
                    local tmp_task="$TMP_DIR/task_with_senior.txt"
                    echo "=== SENIOR AI TAVSİYESİ ===" > "$tmp_task"
                    cat "$advice_file" >> "$tmp_task"
                    echo "=========================" >> "$tmp_task"
                    echo "" >> "$tmp_task"
                    cat "$orig_task_prompt" >> "$tmp_task"
                    # Geçici olarak task prompt'u değiştir
                    cp "$orig_task_prompt" "$TMP_DIR/autofix_task_backup.txt"
                    cp "$tmp_task" "$orig_task_prompt"
                    ok "Senior tavsiyesi task prompt'una eklendi"
                fi
            fi
        fi

        if ! call_ai "$ef" "$src"; then
            # Geçici prompt varsa geri yükle
            [[ -f "$TMP_DIR/autofix_task_backup.txt" ]] && cp "$TMP_DIR/autofix_task_backup.txt" "$PROMPTS_DIR/autofix_task.txt"
            err "API hatası — $((MAX_LOOPS - loop)) deneme kaldı"; sleep 3; continue
        fi
        # Geçici prompt varsa geri yükle
        [[ -f "$TMP_DIR/autofix_task_backup.txt" ]] && cp "$TMP_DIR/autofix_task_backup.txt" "$PROMPTS_DIR/autofix_task.txt" && rm "$TMP_DIR/autofix_task_backup.txt"
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
    find . -maxdepth 4 -type f \
        -not -path "*/.*" \
        -not -path "*/build/*" \
        -not -path "*/bin/*" \
        -not -path "*/outputs/*" \
        | while read -r file; do
            if grep -Iq . "$file" 2>/dev/null; then
                if [ $(stat -c%s "$file") -lt 102400 ]; then
                    echo "$file"
                fi
            fi
        done > "$tree_file"

    echo -e "${YELLOW}🔍 Görev için ilgili dosyalar keşfediliyor...${NC}"
    local sp="Sen uzman bir Android asistanısın. Sadece Markdown liste formatında dosya yollarını döndür."
    local pkg=$(grep "applicationId" "$PROJECT_ROOT/app/build.gradle" 2>/dev/null | head -1 | grep -oE '"[^"]+"'  | head -1 | tr -d '"')
    local um="PROJE DOSYALARI:\n$(cat "$tree_file")\n\nPROJE PAKET ADI: $pkg\n\nGÖREV: $user_task\n\nSadece bu görevi yapmak için okumam ve değiştirmem gereken dosyaların yollarını içeren bir Markdown liste döndür (- app/src/...). DOSYA YOLLARI MUTLAKA PROJE DOSYALARI LİSTESİNDEN SEÇİLMELİ, uydurma yol yazma.\nÖrnek:\n- app/src/main/java/com/.../MainActivity.kt"

    if ! _call_active_ai "$sp" "$um"; then
        err "Keşif başarısız oldu."; return 1
    fi

    local target_files="$TMP_DIR/target_files.txt"
    python3 -c "
import json, sys, re
t=open('$TMP_DIR/ai_content.txt').read()
t=re.sub(r'^\`+json\s*','',t,flags=re.MULTILINE)
t=re.sub(r'^\`+\s*$','',t,flags=re.MULTILINE)
# Markdown listesinden dosya yollarını ayıkla (- path/to/file)
import re
paths = re.findall(r'[-\*]\s+([a-zA-Z0-9_/.-]+\.[a-z]+)', t)
for p in set(paths):
    print(p.strip())
" > "$target_files"

    local file_count=$(wc -l < "$target_files" || echo 0)
    if [[ "$file_count" -eq 0 ]]; then
        warn "Keşif başarısız, MainActivity.kt varsayılan hedef alınıyor..."
        local main_kt=$(find "$PROJECT_ROOT/app/src/main" -name "MainActivity.kt" -o -name "MainActivity.java" 2>/dev/null | head -1)
        [[ -n "$main_kt" ]] && echo "${main_kt#$PROJECT_ROOT/}" >> "$target_files"
        file_count=$(wc -l < "$target_files" || echo 0)
        [[ "$file_count" -eq 0 ]] && { err "MainActivity bulunamadı."; return 1; }
    fi

    # MainActivity.kt her zaman ekle
    local main_kt=$(find "$PROJECT_ROOT/app/src/main" -name "MainActivity.kt" -o -name "MainActivity.java" 2>/dev/null | head -1)
    if [[ -n "$main_kt" ]]; then
        local rel="${main_kt#$PROJECT_ROOT/}"
        grep -qF "$rel" "$target_files" || echo "$rel" >> "$target_files"
    fi
    file_count=$(wc -l < "$target_files" || echo 0)
    ok "Hedef olarak $file_count dosya belirlendi:"
    cat "$target_files" | while read -r f; do echo -e "  ${DIM}-${NC} $f"; done

    local collected="$TMP_DIR/collected_sources.txt"
    > "$collected"
    echo "=== PROJE DOSYA AGACI ===" >> "$collected"
    find "$PROJECT_ROOT" -maxdepth 4 -not -path "*/.*" -not -path "*/build/*" >> "$collected"
    echo "=========================" >> "$collected" 
    while read -r f; do
        if [[ -f "$PROJECT_ROOT/$f" ]]; then
            echo "=== FILE: $f ===" >> "$collected"
            # --- YENİ: Resim veya arşiv dosyasıysa okuma (JSON Çökmesini Önler) ---
            if [[ "$f" =~ \.(png|jpg|jpeg|webp|gif|jar|keystore|aab|apk)$ ]]; then
                echo "// BINARY DOSYA (RESİM/ARŞİV) - İÇERİK METİN OLARAK OKUNAMAZ" >> "$collected"
            else
                cat "$PROJECT_ROOT/$f" >> "$collected"
            fi
            echo "" >> "$collected"
        fi
    done < "$target_files"

    # ═══ ORKESTRATÖR: Dosya dosya yaz (token taşması önleme) ═══
    local ork_script="$SISTEM_DIR/orchestrator.py"
    local ork_success=false
    
    if [[ -f "$ork_script" ]]; then
        echo -e "${YELLOW}🏗️ Orkestratör: Proje planlanıyor ve dosya dosya yazılıyor...${NC}"
        local ork_pkg="${P_PKG:-com.wizaicorp.$(basename $PROJECT_ROOT | tr '-' '_')}"
        
        mkdir -p "$TMP_DIR"
        if python3 "$ork_script" \
            --task "$user_task" \
            --project-root "$PROJECT_ROOT" \
            --package "$ork_pkg" \
            --provider "$NAME" \
            --api-url "$API_URL" \
            --api-key "$API_KEY" \
            --model "$MODEL" \
            --max-tokens "$MAX_TOKENS" \
            --output "$TMP_DIR/ai_content.txt" \
            --collected "$collected"; then
            ork_success=true
            ok "Orkestratör tamamlandı!"
        else
            warn "Orkestratör başarısız — eski yönteme düşülüyor..."
        fi
    else
        warn "orchestrator.py bulunamadı — eski yöntem kullanılıyor..."
    fi
    
    # Fallback: Eski tek-geçiş modu
    if [[ "$ork_success" != "true" ]]; then
        echo -e "${YELLOW}⚙️ Yapay Zeka kod yazıyor (Tek geçiş)...${NC}"
        local task_sp_file="$PROMPTS_DIR/autofix_task.txt"
        if [[ ! -f "$task_sp_file" ]]; then err "HATA: autofix_task.txt bulunamadı!"; exit 1; fi
        local patch_sp=$(cat "$task_sp_file")
        local patch_um="GÖREV: $user_task\n\nKAYNAK DOSYALAR:\n$(cat "$collected")"
        if ! _call_active_ai "$patch_sp" "$patch_um"; then
             err "Kod üretilemedi."; return 1
        fi
    fi

    if ! apply_fixes; then
         err "Görev koda uygulanamadı."; return 1
    fi

    echo -e "\n${BOLD}${BLUE}🚀 Görev koda entegre edildi, otomatik derleme (Build & Fix) devralınıyor...${NC}"
    run_autofix "$user_task"
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




