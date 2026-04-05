#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════════
# PRJ — Android Proje Kısayolları v1.0
# Kullanım: proje klasöründeyken  d / t / dd / b / c / h  yaz
# ═══════════════════════════════════════════════════════════════════════════════

set +e

G='\033[0;32m'; Y='\033[1;33m'; B='\033[0;34m'; R='\033[0;31m'
C='\033[0;36m'; M='\033[0;35m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

DOWNLOAD="/sdcard/Download"
SISTEM_DIR="/storage/emulated/0/termux-otonom-sistem"
CONF_FILE="$SISTEM_DIR/projeler.conf"

# ── Mevcut dizinden proje bul ───────────────────────────────────────────────
detect_project() {
    CWD=$(pwd -P)

    # projeler.conf varsa karşılaştır
    if [ -f "$CONF_FILE" ]; then
        while IFS='|' read -r name dir ks alias pass pkg; do
            [[ "$name" =~ ^#.*$ ]] && continue
            [[ -z "$name" ]] && continue
            EXPANDED="${dir/#\~/$HOME}"
            EXPANDED=$(realpath "$EXPANDED" 2>/dev/null || echo "$EXPANDED")
            if [[ "$CWD" == "$EXPANDED"* ]]; then
                P_NAME="$name"; P_DIR="$EXPANDED"; P_KEYSTORE="$ks"
                P_ALIAS="$alias"; P_PASS="$pass"; P_PKG="$pkg"
                GRADLE_FILE="$P_DIR/app/build.gradle"
                return 0
            fi
        done < "$CONF_FILE"
    fi

    # gradlew var mı? (conf'da kayıtlı olmayan projeler için)
    SEARCH="$CWD"
    for i in 1 2 3; do
        if [ -f "$SEARCH/gradlew" ] && [ -f "$SEARCH/settings.gradle" ]; then
            P_DIR="$SEARCH"
            P_NAME=$(basename "$SEARCH")
            GRADLE_FILE="$P_DIR/app/build.gradle"
            P_KEYSTORE=""; P_ALIAS=""; P_PASS=""; P_PKG=""
            return 0
        fi
        SEARCH=$(dirname "$SEARCH")
    done

    return 1
}

# ── Versiyon oku ────────────────────────────────────────────────────────────
get_version() {
    # 1. V_CODE: Rakamı bul ve boruyu izle
    V_CODE_RAW=$(grep "versionCode" "$GRADLE_FILE" | \
                 grep -v "//" | \
                 head -1 | \
                 grep -oP '\d+' | \
                 head -1; \
                 exit ${PIPESTATUS[0]})
    
    if [ $? -eq 141 ]; then
        echo -e "${Y}[DEBUG] 🛠️ Boru [PRJ-VCode] hattında kesildi.${NC}"
    fi
    V_CODE=$V_CODE_RAW

    # 2. V_NAME: Metni temizle ve boruyu izle
    V_NAME_RAW=$(grep "versionName" "$GRADLE_FILE" | \
                 grep -v "//" | \
                 head -1 | \
                 tr -d '"\n\r ' | \
                 grep -oP '[\d\.]+' | \
                 head -1; \
                 exit ${PIPESTATUS[0]})

    if [ $? -eq 141 ]; then
        echo -e "${Y}[DEBUG] 🛠️ Boru [PRJ-VName] hattında kesildi.${NC}"
    fi
    V_NAME=$V_NAME_RAW

    # Varsayılan değerler
    [ -z "$V_CODE" ] && V_CODE=1
    [ -z "$V_NAME" ] && V_NAME="1.0"
}


# ── Versiyon arttır ─────────────────────────────────────────────────────────
bump_version() {
    get_version
    NEW_CODE=$((V_CODE + 1))
    MAJOR=$(echo "$V_NAME" | cut -d. -f1)
    MINOR=$(echo "$V_NAME" | cut -d. -f2)
    
    # Eğer MINOR boş dönerse matematik hatası vermemesi için sıfırla
    [ -z "$MINOR" ] && MINOR=0
    NEW_NAME="$MAJOR.$((MINOR + 1))"
    
    # Format ne olursa olsun temiz bir şekilde yenisiyle değiştir
    sed -i "s/versionCode [0-9]*/versionCode $NEW_CODE/" "$GRADLE_FILE"
    sed -i "s/versionName \"[^\"]*\"/versionName \"$NEW_NAME\"/" "$GRADLE_FILE"
    
    V_CODE=$NEW_CODE; V_NAME=$NEW_NAME
    echo -e "  ${DIM}v$V_NAME ($V_CODE)${NC}"
}

# ── AI Öncesi Otomatik Yedek (Zaman Kapsülü) ──────────────────────────────
take_pre_ai_backup() {
    local TASK_MSG="$1"
    local BKP_DIR="$SISTEM_DIR/yedekler"
    mkdir -p "$BKP_DIR"
    local TIMESTAMP=$(date +%Y%m%d-%H%M)
    
    # Python scriptinin orijinal dışlama parametreleri
    local EXCLUDE_FLAGS="--exclude=*/build --exclude=*/.gradle"

    if [ -n "$TASK_MSG" ]; then
        # Promptun ilk 4 kelimesinden güvenli not üret
        local SAFE_NOTE=$(echo "$TASK_MSG" | awk '{print $1"_"$2"_"$3"_"$4}' | tr '[:upper:]' '[:lower:]' | tr -dc 'a-z0-9_')
        [ -z "$SAFE_NOTE" ] && SAFE_NOTE="otonom_gorev"
        
        # Tam metni proje içine yaz ki tar komutu onu da içine alsın
        echo "$TASK_MSG" > "$P_DIR/otonom_gorev_prompt.txt"
        
        # ws_bridge.py ile %100 aynı isim formatı
        local BKP_FILE="$BKP_DIR/${P_NAME}-not(${SAFE_NOTE})-${TIMESTAMP}-yedek.tar.gz"
        echo -e "  ${DIM}🛡️ Otonom görev öncesi orijinal yedek alınıyor...${NC}"
        
        # ws_bridge.py ile %100 aynı paketleme (Üst klasörden paketleme)
        tar -czf "$BKP_FILE" $EXCLUDE_FLAGS -C "$(dirname "$P_DIR")" "$(basename "$P_DIR")" 2>/dev/null
        
        # Operasyon sonrası TXT dosyasını sil ki ortalık kirlenmesin
        rm -f "$P_DIR/otonom_gorev_prompt.txt"
    else
        # AutoFix modu için not
        local BKP_FILE="$BKP_DIR/${P_NAME}-not(autofix_hata_cozumu)-${TIMESTAMP}-yedek.tar.gz"
        echo -e "  ${DIM}🛡️ AutoFix hata çözümü öncesi orijinal yedek alınıyor...${NC}"
        
        tar -czf "$BKP_FILE" $EXCLUDE_FLAGS -C "$(dirname "$P_DIR")" "$(basename "$P_DIR")" 2>/dev/null
    fi

    echo -e "  ${G}✅ Orijinal Kod Güvende:${NC} $(basename "$BKP_FILE")"
}

# ══════════════════════════════════════════════════════════════════
# d  — Build debug APK
# ══════════════════════════════════════════════════════════════════
cmd_build() {
    echo -e "\n${BOLD}${B}⏳ Build alınıyor...${NC}"
    bump_version
    cd "$P_DIR"
    OUTPUT=$(./gradlew assembleDebug --no-daemon 2>&1)
    if echo "$OUTPUT" | grep -q "BUILD SUCCESSFUL"; then
        APK=$(find "$P_DIR/app/build/outputs/apk/debug/" -name "*.apk" 2>/dev/null | head -1)
        if [ -n "$APK" ]; then
            rm -f "$DOWNLOAD/apk-cikti/${P_NAME}"*.apk 2>/dev/null
            mkdir -p "$DOWNLOAD/apk-cikti"
            BUILD_TIME=$(date +%H%M)
            DEST="$DOWNLOAD/apk-cikti/${P_NAME}-v${V_NAME}(${V_CODE})-${BUILD_TIME}-debug.apk"
            cp "$APK" "$DEST" && touch "$DEST"
            SIZE=$(ls -lh "$DEST" | awk '{print $5}')
            echo -e "  ${G}✅ APK hazır!${NC}  $SIZE"
            echo -e "  📁 ${DIM}$DEST${NC}"
        fi
    else
        echo -e "  ${R}❌ Build başarısız!${NC}"
        ERRORS=$(echo "$OUTPUT" | grep -E "^e: " | head -5)
        [ -n "$ERRORS" ] && echo "$ERRORS" | while read l; do echo -e "  ${R}→${NC} $(echo $l | sed 's|e: file:///.*\.kt||')"; done
        echo -e "  ${DIM}dd yazarak hata dosyalarını indirebilirsin${NC}"
        exit 1
    fi
}

# ══════════════════════════════════════════════════════════════════
# t  — APK'yı Download'a taşı (build almadan)
# ══════════════════════════════════════════════════════════════════
cmd_transfer() {
    APK=$(find "$P_DIR/app/build/outputs/apk/debug/" -name "*.apk" 2>/dev/null | head -1)
    if [ -z "$APK" ]; then
        echo -e "  ${R}❌ APK bulunamadı. Önce build al (d).${NC}"; return
    fi
    get_version
    rm -f "$DOWNLOAD/apk-cikti/${P_NAME}"*.apk 2>/dev/null
    mkdir -p "$DOWNLOAD/apk-cikti"
    BUILD_TIME=$(date +%H%M)
            DEST="$DOWNLOAD/apk-cikti/${P_NAME}-v${V_NAME}(${V_CODE})-${BUILD_TIME}-debug.apk"
    cp "$APK" "$DEST"
    SIZE=$(ls -lh "$DEST" | awk '{print $5}')
    echo -e "  ${G}✅ APK taşındı!${NC}  $SIZE"
    echo -e "  📁 ${DIM}$DEST${NC}"
}

# ══════════════════════════════════════════════════════════════════
# dd — Build + hata dosyalarını indir
# ══════════════════════════════════════════════════════════════════
cmd_build_errors() {
    echo -e "\n${BOLD}${B}⏳ Build alınıyor...${NC}"
    cd "$P_DIR"
    OUTPUT=$(./gradlew assembleDebug --no-daemon 2>&1)

    if echo "$OUTPUT" | grep -q "BUILD SUCCESSFUL"; then
        APK=$(find "$P_DIR/app/build/outputs/apk/debug/" -name "*.apk" 2>/dev/null | head -1)
        if [ -n "$APK" ]; then
            get_version
            rm -f "$DOWNLOAD/apk-cikti/${P_NAME}"*.apk 2>/dev/null
            mkdir -p "$DOWNLOAD/apk-cikti"
            BUILD_TIME=$(date +%H%M)
            DEST="$DOWNLOAD/apk-cikti/${P_NAME}-v${V_NAME}(${V_CODE})-${BUILD_TIME}-debug.apk"
            cp "$APK" "$DEST"
            SIZE=$(ls -lh "$DEST" | awk '{print $5}')
            echo -e "  ${G}✅ Build başarılı! APK hazır.${NC}  $SIZE"
            echo -e "  📁 ${DIM}$DEST${NC}"
        fi
        return
    fi

    ERROR_LINES=$(echo "$OUTPUT" | grep -E "^e: file:///|^ERROR: .*\.xml|error: resource|AAPT: error" || true)

    if [ -z "$ERROR_LINES" ]; then
        echo -e "  ${R}❌ BUILD FAILED — Hata detayı:${NC}"
        echo "$OUTPUT" | grep -A 25 "What went wrong:" | head -30
        echo ""
        echo -e "  ${DIM}Tam log için: cd $P_DIR && ./gradlew assembleDebug 2>&1 | tail -40${NC}"
        return
    fi

    # Format seç
    echo -e "\n  ${G}1.${NC} 📦 ZIP  ${DIM}(Claude'a direkt atılır — varsayılan)${NC}"
    echo -e "  ${G}2.${NC} 📁 Klasör"
    printf "  Format (enter=zip): "
    read fmt; fmt=${fmt:-1}

    TIMESTAMP=$(date +%Y%m%d-%H%M)
    PKG_NAME="${P_NAME}-hatali-${TIMESTAMP}"
    TMP_DIR="$HOME/${PKG_NAME}"
    mkdir -p "$TMP_DIR"
    SRC_DIR="$P_DIR/app/src/main/java"

    # Hatalı dosyaları topla
    DIRECT_FILES=$(echo "$ERROR_LINES" \
        | sed 's|^e: file://||' \
        | sed 's|: ([0-9].*||' \
        | sed 's|:[0-9]*:[0-9]*.*||' \
        | sort -u)

    # Unresolved referans dosyalarını otomatik bul
    UNRESOLVED=$(echo "$ERROR_LINES" | grep -oP 'Unresolved reference: \K\w+' | sort -u || true)
    declare -A RELATED_MAP
    if [ -n "$UNRESOLVED" ]; then
        while IFS= read -r ref; do
            [ -z "$ref" ] && continue
            DEFINING=$(grep -rl \
                -e "class $ref" -e "fun $ref(" \
                -e "object $ref" -e "interface $ref" \
                -e "typealias $ref" \
                "$SRC_DIR" 2>/dev/null | head -1 || true)
            [ -n "$DEFINING" ] && RELATED_MAP["$DEFINING"]=1
        done <<< "$UNRESOLVED"
    fi

    # HATALAR.txt
    {
        echo "HATA RAPORU — $(date '+%d.%m.%Y %H:%M')  |  Proje: $P_NAME"
        echo "══════════════════════════════════════════════"
        echo ""
        echo "$ERROR_LINES" | while IFS= read -r line; do
            BNAME=$(echo "$line" | sed 's|^e: file:///||' | sed 's|:[0-9]*:[0-9]*.*||' | xargs basename 2>/dev/null)
            LINE_INFO=$(echo "$line" | grep -oP ':\d+:\d+' | head -1 | tr ':' ' ' | awk '{print "satır "$2", sütun "$3}')
            MSG=$(echo "$line" | sed 's|.*[0-9]: ||')
            echo "📄 $BNAME ($LINE_INFO)"
            echo "   $MSG"
            echo ""
        done
        echo "Toplam hata: $(echo "$ERROR_LINES" | wc -l)"
    } > "$TMP_DIR/HATALAR.txt"

    # Dosya kopyala
    COPIED=0
    echo ""
    echo -e "  ${Y}Hatalı dosyalar:${NC}"
    while IFS= read -r fpath; do
        fpath=$(echo "$fpath" | tr -d '\r' | xargs)
        [ -z "$fpath" ] || [ ! -f "$fpath" ] && continue
        cp "$fpath" "$TMP_DIR/$(basename $fpath)"
        echo -e "  ${R}→${NC} $(basename $fpath)"
        COPIED=$((COPIED+1))
    done <<< "$DIRECT_FILES"

    if [ ${#RELATED_MAP[@]} -gt 0 ]; then
        echo -e "\n  ${Y}İlgili dosyalar:${NC}"
        for rfile in "${!RELATED_MAP[@]}"; do
            BNAME=$(basename "$rfile")
            [ ! -f "$TMP_DIR/$BNAME" ] && cp "$rfile" "$TMP_DIR/$BNAME" && \
                echo -e "  ${C}→${NC} $BNAME" && COPIED=$((COPIED+1))
        done
    fi

    # README ekle
    [ -f "$SISTEM_DIR/CLAUDE_README.md" ] && cp "$SISTEM_DIR/CLAUDE_README.md" "$TMP_DIR/CLAUDE_README.md"

    echo ""
    if [ "$fmt" = "1" ]; then
        ZIP_PATH="$DOWNLOAD/${PKG_NAME}.zip"
        (cd "$HOME" && zip -r "$ZIP_PATH" "$PKG_NAME" > /dev/null 2>&1)
        rm -rf "$TMP_DIR"
        [ -f "$ZIP_PATH" ] && SIZE=$(ls -lh "$ZIP_PATH" | awk '{print $5}') && \
            echo -e "  ${G}✅ ZIP: $ZIP_PATH  ($SIZE)${NC}" || \
            echo -e "  ${R}❌ ZIP oluşturulamadı${NC}"
    else
        mv "$TMP_DIR" "$DOWNLOAD/"
        echo -e "  ${G}✅ Klasör: $DOWNLOAD/$PKG_NAME${NC}"
    fi
}

# ══════════════════════════════════════════════════════════════════
# b  — AAB üret + imzala
# ══════════════════════════════════════════════════════════════════
cmd_bundle() {
    echo -e "\n${BOLD}${B}⏳ AAB build ediliyor...${NC}"
    bump_version
    cd "$P_DIR"
    ./gradlew bundleRelease --no-daemon 2>&1 | tail -4
    AAB="$P_DIR/app/build/outputs/bundle/release/app-release.aab"
    if [ ! -f "$AAB" ]; then
        echo -e "  ${R}❌ AAB oluşturulamadı!${NC}"; return
    fi
    # Keystore
    KS_PATH="$SISTEM_DIR/keystores/$P_KEYSTORE"
    if [ -n "$P_KEYSTORE" ] && [ -f "$KS_PATH" ] && [ -n "$P_ALIAS" ] && [ -n "$P_PASS" ]; then
        jarsigner -sigalg SHA256withRSA -digestalg SHA256 \
            -keystore "$KS_PATH" -storepass "$P_PASS" -keypass "$P_PASS" \
            "$AAB" "$P_ALIAS" 2>&1 | tail -2
        echo -e "  ${G}✅ İmzalandı${NC}"
    else
        echo -e "  ${Y}⚠️  Keystore bulunamadı, imzalanmadı${NC}"
    fi
    mkdir -p "$DOWNLOAD/apk-cikti"
    rm -f "$DOWNLOAD/apk-cikti/${P_NAME}"*.aab 2>/dev/null
    DEST="$DOWNLOAD/apk-cikti/${P_NAME}-v${V_NAME}(${V_CODE}).aab"
    cp "$AAB" "$DEST" && touch "$DEST"
    SIZE=$(ls -lh "$DEST" | awk '{print $5}')
    echo -e "  ${G}✅ AAB hazır!${NC}  $SIZE"
    echo -e "  📁 ${DIM}$DEST${NC}"
}

# ══════════════════════════════════════════════════════════════════
# c  — Tüm kodları .txt olarak indir
# ══════════════════════════════════════════════════════════════════
cmd_code() {
    TIMESTAMP=$(date +%Y%m%d-%H%M)
    OUTPUT="$DOWNLOAD/${P_NAME}-tum-kod-${TIMESTAMP}.txt"
    find "$P_DIR/app/src/main/java" -name "*.kt" \
        -exec echo "// ═══ FILE: {} ═══" \; -exec cat {} \; > "$OUTPUT"
    FILES=$(grep -c "^// ═══ FILE:" "$OUTPUT")
    SIZE=$(ls -lh "$OUTPUT" | awk '{print $5}')
    echo -e "  ${G}✅ $FILES dosya → $OUTPUT  ($SIZE)${NC}"
}

# ══════════════════════════════════════════════════════════════════
# cl — Clean
# ══════════════════════════════════════════════════════════════════
cmd_clean() {
    echo -e "\n${Y}⏳ Clean...${NC}"
    cd "$P_DIR"
    ./gradlew clean --no-daemon 2>&1 | tail -3
    echo -e "  ${G}✅ Temizlendi${NC}"
}

# ══════════════════════════════════════════════════════════════════
# h  — Yardım
# ══════════════════════════════════════════════════════════════════
cmd_help() {
    echo ""
    echo -e "${BOLD}${B}╔══════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${B}║   PRJ Kısayolları                           ║${NC}"
    echo -e "${BOLD}${B}╚══════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  ${G}d${NC}   🔨 Build debug APK → Download'a taşı"
    echo -e "  ${G}t${NC}   📲 Son APK'yı Download'a taşı (build yok)"
    echo -e "  ${G}dd${NC}  🐛 Build + hata varsa dosyaları zip/klasör indir"
    echo -e "  ${G}b${NC}   📦 AAB build + imzala → Download"
    echo -e "  ${G}c${NC}   📋 Tüm .kt kodlarını .txt olarak indir"
    echo -e "  ${G}cl${NC}  🧹 Clean (build cache sil)"
    echo -e "  ${G}af${NC}  🤖 Build + hata varsa DeepSeek ile otomatik düzelt"
    echo -e "  ${G}e${NC}   ✨ Görev ver, yapay zeka kodlasın ve derlesin (AI Agent)"
    echo -e "  ${G}s${NC}   🔄 sistem.sh'a geç (tam menü)"
    echo -e "  ${G}log${NC}  📋 Build geçmişini göster"
    echo -e "  ${G}builds${NC} 📦 Test APK arşivini göster"
    echo -e "  ${G}h${NC}   ❓ Bu yardım ekranı"
    echo -e "  ${G}install${NC} 🔧 Kendini kur (alias + doğru konuma kopyala)"
    echo -e "  ${G}q${NC}   🚪 Çıkış"
    echo ""
}


# ══════════════════════════════════════════════════════════════════
# install  — Kendini kur (alias + doğru konuma kopyala)
# ══════════════════════════════════════════════════════════════════
cmd_install() {
    SISTEM_DIR="/storage/emulated/0/termux-otonom-sistem"
    PRJ_TARGET="$SISTEM_DIR/prj.sh"
    SELF=$(realpath "$0")
    
    echo -e "\n${BOLD}${B}╔══════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${B}║   PRJ Kurulumu                          ║${NC}"
    echo -e "${BOLD}${B}╚══════════════════════════════════════════╝${NC}\n"
    
    mkdir -p "$SISTEM_DIR"
    
    # Kendini hedef konuma kopyala (zaten orada değilse)
    if [ "$SELF" != "$PRJ_TARGET" ]; then
        cp "$SELF" "$PRJ_TARGET"
        chmod +x "$PRJ_TARGET"
        echo -e "  ${G}✅ Kopyalandı: $PRJ_TARGET${NC}"
    else
        echo -e "  ${G}✅ Zaten doğru konumda: $PRJ_TARGET${NC}"
    fi
    
    # Alias
    if grep -q "alias prj=" ~/.bashrc 2>/dev/null; then
        sed -i "/alias prj=/d" ~/.bashrc
    fi
    echo "alias prj=\"bash $SISTEM_DIR/prj.sh\"" >> ~/.bashrc
    source ~/.bashrc 2>/dev/null || true
    
    echo -e "  ${G}✅ alias 'prj' ~/.bashrc'e eklendi${NC}"
    echo ""
    echo -e "  ${DIM}Kullanım:${NC}"
    echo -e "  ${G}prj${NC}        interaktif mod"
    echo -e "  ${G}prj d${NC}      build APK"
    echo -e "  ${G}prj dd${NC}     build + hata zip"
    echo -e "  ${G}prj t${NC}      APK taşı"
    echo -e "  ${G}prj e${NC}      görev yap"
    echo -e "  ${G}prj h${NC}      tüm komutlar"
    echo ""
    echo -e "  ${Y}Yeni terminal oturumunda aktif olur.${NC}"
    echo -e "  ${DIM}Şu an için: source ~/.bashrc${NC}"
}

# ══════════════════════════════════════════════════════════════════
# log  — Build geçmişini göster
# ══════════════════════════════════════════════════════════════════
cmd_log() {
    local log_file="$SISTEM_DIR/build-logs/${P_NAME}.log"
    if [[ ! -f "$log_file" ]]; then
        echo -e "  ${Y}⚠️  Henüz build geçmişi yok.${NC}"
        echo -e "  ${DIM}İlk başarılı build'den sonra burada görünür.${NC}"
        return
    fi
    local count; count=$(wc -l < "$log_file")
    echo -e "\n  ${BOLD}${B}📋 BUILD GEÇMİŞİ — $P_NAME  (son $count build)${NC}\n"
    cat "$log_file" | while IFS= read -r line; do
        if [[ "$line" == *"✅"* ]]; then
            echo -e "  ${G}$line${NC}"
        elif [[ "$line" == *"❌"* ]]; then
            echo -e "  ${R}$line${NC}"
        elif [[ "$line" == *"↩️"* ]]; then
            echo -e "  ${Y}$line${NC}"
        else
            echo -e "  $line"
        fi
    done
    echo ""
    echo -e "  ${DIM}Log dosyası: $log_file${NC}"
}

# ══════════════════════════════════════════════════════════════════
# builds  — Test APK arşivini göster
# ══════════════════════════════════════════════════════════════════
cmd_builds() {
    local archive_dir="$SISTEM_DIR/test-builds/$P_NAME"
    if [[ ! -d "$archive_dir" ]] || [[ -z "$(ls -A "$archive_dir" 2>/dev/null)" ]]; then
        echo -e "  ${Y}⚠️  Henüz arşivlenmiş APK yok.${NC}"
        return
    fi
    echo -e "\n  ${BOLD}${B}📦 TEST APK ARŞİVİ — $P_NAME${NC}\n"
    local total=0
    ls -lt "$archive_dir"/*.apk 2>/dev/null | while read -r perm _ _ _ size month day time fname; do
        ts=$(basename "$fname" .apk)
        echo -e "  ${G}→${NC} ${ts}  ${DIM}($size)${NC}"
        total=$((total+1))
    done
    local apk_count; apk_count=$(ls "$archive_dir"/*.apk 2>/dev/null | wc -l)
    echo -e "\n  ${DIM}Toplam: $apk_count APK | $archive_dir${NC}"
    echo ""
    echo -e "  ${Y}Son APK'yı Download'a kopyalamak için:${NC}"
    echo -e "  ${DIM}cp $archive_dir/\$(ls -t $archive_dir/*.apk | head -1) /sdcard/Download/${NC}"
}

# ══════════════════════════════════════════════════════════════════
# BAŞLANGIÇ
# ══════════════════════════════════════════════════════════════════
if ! detect_project; then
    echo -e "${R}❌ Android projesi bulunamadı.${NC}"
    echo -e "${DIM}Proje klasörünün içinde olduğundan emin ol.${NC}"
    exit 1
fi

echo -e "\n${BOLD}${G}◆ ${P_NAME}${NC}  ${DIM}$P_DIR${NC}"

# Argüman ile çalıştırma: prj d / prj dd / prj t
if [ -n "$1" ]; then
    case "$1" in
        d)   cmd_build ;;
        t)   cmd_transfer ;;
        af|autofix)
            AUTOFIX_SCRIPT="/storage/emulated/0/termux-otonom-sistem/autofix.sh"
            if [[ ! -f "$AUTOFIX_SCRIPT" ]]; then
                echo "autofix.sh bulunamadı. Önce: bash /sdcard/Download/autofix.sh install"
            else
                export P_PKG="$P_PKG"; export P_NAME="$P_NAME"
                bash "$AUTOFIX_SCRIPT" run "$P_DIR"
            fi
            ;;
        e)
            AUTOFIX_SCRIPT="/storage/emulated/0/termux-otonom-sistem/autofix.sh"
            if [[ -z "$2" ]]; then
                echo -e "${R}❌ Görev belirtmedin! Örnek: prj e \"görev metni\"${NC}"
            else
                export P_PKG="$P_PKG"; export P_NAME="$P_NAME"
                take_pre_ai_backup "$2"
                bash "$AUTOFIX_SCRIPT" task "$2" "$P_DIR"
            fi
            ;;
        ef)
            AUTOFIX_SCRIPT="/storage/emulated/0/termux-otonom-sistem/autofix.sh"
            if [[ -f "$2" ]]; then
                TASK_FROM_FILE=$(cat "$2")
                export P_PKG="$P_PKG"; export P_NAME="$P_NAME"
                bash "$AUTOFIX_SCRIPT" task "$TASK_FROM_FILE" "$P_DIR"
            fi
            ;;
        dd)  cmd_build_errors ;;
        b)   cmd_bundle ;;
        c)   cmd_code ;;
        cl)  cmd_clean ;;
        h)   cmd_help ;;
        log) cmd_log ;;
        builds) cmd_builds ;;
        install) cmd_install ;;
        s)   bash "$SISTEM_DIR/sistem.sh" ;;
        *)   echo -e "${R}Bilinmeyen komut: $1${NC}"; cmd_help ;;
    esac
    exit 0
fi

# Argümansız: interaktif döngü
cmd_help
while true; do
    printf "  ${BOLD}→${NC} "
    read cmd
    case "$cmd" in
        d)   cmd_build ;;
        t)   cmd_transfer ;;
        dd)  cmd_build_errors ;;
        b)   cmd_bundle ;;
        c)   cmd_code ;;
        cl)  cmd_clean ;;
        af|autofix)
            AUTOFIX_SCRIPT="/storage/emulated/0/termux-otonom-sistem/autofix.sh"
            if [[ ! -f "$AUTOFIX_SCRIPT" ]]; then
                echo "autofix.sh bulunamadı. Önce: bash /sdcard/Download/autofix.sh install"
            else
                export P_PKG="$P_PKG"; export P_NAME="$P_NAME"
                take_pre_ai_backup ""
                bash "$AUTOFIX_SCRIPT" run "$P_DIR"
            fi
            ;;
        e)
            AUTOFIX_SCRIPT="/storage/emulated/0/termux-otonom-sistem/autofix.sh"
            read -p "Görev nedir?: " user_task
            if [[ -n "$user_task" ]]; then
                take_pre_ai_backup "$user_task"
                bash "$AUTOFIX_SCRIPT" task "$user_task" "$P_DIR"
            fi
            ;;
        h)   cmd_help ;;
        log) cmd_log ;;
        builds) cmd_builds ;;
        install) cmd_install ;;
        s)   bash "$SISTEM_DIR/sistem.sh"; break ;;
        q|Q|"") echo -e "${G}Görüşürüz!${NC}"; exit 0 ;;
        *)   echo -e "  ${DIM}? → h yazarak komutları gör${NC}" ;;
    esac
    echo ""
done
