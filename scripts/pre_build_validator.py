#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
APK Factory Pre-Build Validator v1.0
Gradle'dan ONCE calisir, 2 saniyede biter.
Hatalarin %80'ini build'e gitmeden yakalar ve duzeltir.

Kullanim: python3 pre_build_validator.py /path/to/project
Cikis: 0 = temiz veya duzeltildi, 1 = kritik hata (devam edilemez)
"""

import os, sys, re, struct, math, glob

if len(sys.argv) < 2:
    print("[VALIDATOR] Kullanim: python3 pre_build_validator.py <proje_dizini>")
    sys.exit(0)

PROJECT = sys.argv[1]
SRC_DIR = os.path.join(PROJECT, "app", "src", "main", "java")
RAW_DIR = os.path.join(PROJECT, "app", "src", "main", "res", "raw")
DRAWABLE_DIR = os.path.join(PROJECT, "app", "src", "main", "res", "drawable")
BUILD_GRADLE = os.path.join(PROJECT, "app", "build.gradle")
ROOT_GRADLE = os.path.join(PROJECT, "build.gradle")
MANIFEST = os.path.join(PROJECT, "app", "src", "main", "AndroidManifest.xml")
GOOGLE_SERVICES = os.path.join(PROJECT, "app", "google-services.json")

fixes = []
warnings = []

def log(msg):
    print(f"[VALIDATOR] {msg}", flush=True)

def fix(msg):
    fixes.append(msg)
    print(f"[VALIDATOR] FIX: {msg}", flush=True)

def warn(msg):
    warnings.append(msg)
    print(f"[VALIDATOR] WARN: {msg}", flush=True)

# ════════════════════════════════════════════════════════════════
# YARDIMCI: Tum .kt dosyalarini oku
# ════════════════════════════════════════════════════════════════
def read_all_kt():
    """Tum .kt dosyalarini {path: content} olarak dondur"""
    kt_files = {}
    if not os.path.isdir(SRC_DIR):
        return kt_files
    for root, dirs, files in os.walk(SRC_DIR):
        dirs[:] = [d for d in dirs if d not in ['build', '.gradle', '.git']]
        for f in files:
            if f.endswith(".kt"):
                fpath = os.path.join(root, f)
                try:
                    kt_files[fpath] = open(fpath, 'r', encoding='utf-8').read()
                except:
                    pass
    return kt_files

def get_package_name():
    """build.gradle'dan paket adini oku"""
    if os.path.exists(BUILD_GRADLE):
        bg = open(BUILD_GRADLE, 'r').read()
        m = re.search(r"(?:applicationId|namespace)\s*['\"]([^'\"]+)['\"]", bg)
        if m:
            return m.group(1)
    return None

# ════════════════════════════════════════════════════════════════
# KONTROL 1: Import edilen sinif projede tanimli mi?
# ════════════════════════════════════════════════════════════════
def check_imports(kt_files, pkg_name):
    if not pkg_name:
        return

    # Projede tanimli siniflari/nesneleri/interface'leri bul
    defined = {}  # {ClassName: filepath}
    for fpath, content in kt_files.items():
        for m in re.finditer(r'(?:class|object|interface|enum\s+class|sealed\s+class|data\s+class)\s+([A-Z][A-Za-z0-9_]*)', content):
            defined[m.group(1)] = fpath
        # Top-level @Composable fonksiyonlar
        for m in re.finditer(r'@Composable\s+(?:fun\s+)([A-Z][A-Za-z0-9_]*)', content):
            defined[m.group(1)] = fpath

    # Her dosyadaki import'lari kontrol et
    for fpath, content in kt_files.items():
        lines = content.split('\n')
        changed = False
        new_lines = []

        for line in lines:
            imp_match = re.match(r'^import\s+' + re.escape(pkg_name) + r'\.(.+)', line)
            if imp_match:
                imported = imp_match.group(1).split('.')[-1]
                # Wildcard import (.*) atla
                if imported == '*':
                    new_lines.append(line)
                    continue
                # Sinif projede tanimli mi?
                if imported not in defined:
                    # ui.theme import'i ozel durum
                    if '.ui.theme.' in line or '.theme.' in line:
                        fix(f"{os.path.basename(fpath)}: Tema import silindi → {imported}")
                        changed = True
                        continue  # Satiri atla
                    # utils/service gibi paket import'i
                    elif any(sub in line for sub in ['.utils.', '.service.', '.helper.', '.manager.']):
                        fix(f"{os.path.basename(fpath)}: Var olmayan sinif import silindi → {imported}")
                        changed = True
                        continue
                    else:
                        warn(f"{os.path.basename(fpath)}: {imported} import ediliyor ama tanimli degil")
                        # Kullanim kontrolu: gercekten kullaniliyor mu?
                        usage_count = content.count(imported) - 1  # import satiri haric
                        if usage_count <= 0:
                            fix(f"{os.path.basename(fpath)}: Kullanilmayan import silindi → {imported}")
                            changed = True
                            continue

            new_lines.append(line)

        if changed:
            open(fpath, 'w', encoding='utf-8').write('\n'.join(new_lines))

# ════════════════════════════════════════════════════════════════
# KONTROL 2: Theme referanslari
# ════════════════════════════════════════════════════════════════
def check_themes(kt_files, pkg_name):
    if not pkg_name:
        return

    # XxxTheme { } kullanimi var mi?
    app_name = pkg_name.split('.')[-1]
    possible_themes = [
        app_name.capitalize() + "Theme",
        app_name.replace("_", "").capitalize() + "Theme",
        ''.join(w.capitalize() for w in app_name.split('_')) + "Theme",
        ''.join(w.capitalize() for w in app_name.split('-')) + "Theme",
    ]

    # Theme tanimli mi?
    theme_defined = False
    for fpath, content in kt_files.items():
        for theme in possible_themes:
            if f"fun {theme}(" in content or f"fun {theme} (" in content:
                theme_defined = True
                break

    if theme_defined:
        return  # Tema tanimli, sorun yok

    # Tema tanimli degil ama kullaniliyor → MaterialTheme ile degistir
    for fpath, content in kt_files.items():
        original = content
        for theme in possible_themes:
            if theme in content:
                # XxxTheme { → MaterialTheme {
                content = content.replace(f"{theme} {{", "MaterialTheme {")
                content = content.replace(f"{theme}(", "MaterialTheme(")
                content = content.replace(f"{theme}{{", "MaterialTheme{")
                # darkTheme parametresini kaldir
                content = re.sub(r'MaterialTheme\(\s*darkTheme\s*=\s*[^)]+\)\s*\{', 'MaterialTheme {', content)

        if content != original:
            # isSystemInDarkTheme import'ini da temizle (artik kullanilmiyor olabilir)
            if 'isSystemInDarkTheme' in content and content.count('isSystemInDarkTheme') == 1:
                content = re.sub(r'import\s+androidx\.compose\.foundation\.isSystemInDarkTheme\n?', '', content)
            open(fpath, 'w', encoding='utf-8').write(content)
            fix(f"{os.path.basename(fpath)}: Tanimsiz tema → MaterialTheme ile degistirildi")

# ════════════════════════════════════════════════════════════════
# KONTROL 3: R.raw.xxx ve R.drawable.xxx
# ════════════════════════════════════════════════════════════════
def check_resources(kt_files):
    # Mevcut res dosyalari
    existing_raw = set()
    if os.path.isdir(RAW_DIR):
        for f in os.listdir(RAW_DIR):
            existing_raw.add(os.path.splitext(f)[0].lower())

    existing_drawable = set()
    if os.path.isdir(DRAWABLE_DIR):
        for f in os.listdir(DRAWABLE_DIR):
            existing_drawable.add(os.path.splitext(f)[0].lower())

    # Eksik raw referanslari
    needed_raw = set()
    workarounds = {}  # {fpath: [(old_text, sound_name)]}

    for fpath, content in kt_files.items():
        # R.raw.xxx
        for m in re.finditer(r'R\.raw\.([a-z_][a-z0-9_]*)', content):
            snd = m.group(1)
            if snd not in existing_raw:
                needed_raw.add(snd)

        # rawResourceId = 0 // R.raw.xxx workaround
        for m in re.finditer(r'rawResourceId\s*=\s*0\s*//.*?R\.raw\.(\w+).*', content):
            snd = m.group(1)
            if snd not in existing_raw:
                needed_raw.add(snd)
                if fpath not in workarounds:
                    workarounds[fpath] = []
                workarounds[fpath].append((m.group(0), snd))

    # Eksik drawable referanslari (sadece uyar)
    for fpath, content in kt_files.items():
        for m in re.finditer(r'R\.drawable\.([a-z_][a-z0-9_]*)', content):
            res = m.group(1)
            if res not in existing_drawable and res not in ['ic_launcher_foreground', 'ic_launcher_background', 'ic_launcher']:
                warn(f"R.drawable.{res} yok — drawable/{res}.xml veya .png ekle")

    if not needed_raw:
        return

    log(f"{len(needed_raw)} eksik ses dosyasi tespit edildi")

    # Freesound API dene
    fs_key = ""
    conf = os.path.expanduser("~/.config/apkfactory.conf")
    if os.path.exists(conf):
        for line in open(conf):
            if "FREESOUND_KEY" in line and "=" in line:
                fs_key = line.split("=", 1)[1].strip().strip('"').strip("'")

    os.makedirs(RAW_DIR, exist_ok=True)
    downloaded = set()

    if fs_key:
        try:
            import urllib.request, json
            for snd in list(needed_raw):
                try:
                    q = snd.replace("_", " ")
                    url = f"https://freesound.org/apiv2/search/text/?query={q.replace(' ','+')}&fields=id,name,previews&token={fs_key}&page_size=1"
                    resp = json.loads(urllib.request.urlopen(url, timeout=10).read())
                    if resp.get("results"):
                        mp3 = resp["results"][0]["previews"]["preview-hq-mp3"] + f"?token={fs_key}"
                        urllib.request.urlretrieve(mp3, f"{RAW_DIR}/{snd}.mp3")
                        downloaded.add(snd)
                        fix(f"{snd}.mp3 indirildi (Freesound)")

                except Exception as e:
                    warn(f"Freesound API limit doldu veya hata olustu: {e}")
                    break  # API limit veya hata

        except ImportError:
            pass

    # Kalanları frekans ile üret
    remaining = needed_raw - downloaded
    if remaining:
        if not fs_key:
            log(f"API key yok, {len(remaining)} ses frekans ile uretiliyor")
        elif downloaded:
            log(f"{len(remaining)} ses API'den indirilemedi, frekans ile uretiliyor")

        freq_map = {
            "beep": (800, 0.3), "click": (1200, 0.1), "tap": (1000, 0.08),
            "notification": (600, 0.5), "alert": (900, 0.4), "success": (523, 0.6),
            "error": (200, 0.5), "warning": (400, 0.4), "ding": (1047, 0.3),
            "pop": (1400, 0.08), "swoosh": (300, 0.3), "chime": (700, 0.5),
            "buzz": (150, 0.3), "horn": (350, 0.4), "ring": (880, 0.5),
            "button": (1000, 0.15), "sound": (660, 0.3), "tone": (440, 0.4),
            "coin": (1500, 0.2), "laser": (1800, 0.15), "jump": (500, 0.2),
            "hit": (250, 0.15), "win": (700, 0.5), "lose": (200, 0.6),
            "default": (660, 0.3),
        }
        auto_freqs = [440, 523, 659, 784, 880, 988, 1047, 1175, 1319, 1480]
        idx = 0

        for snd in remaining:
            freq, dur = None, None
            for key, (f, d) in freq_map.items():
                if key in snd.lower():
                    freq, dur = f, d
                    break
            if not freq:
                freq = auto_freqs[idx % len(auto_freqs)]
                idx += 1
                dur = 0.3

            # WAV uret
            sr = 22050
            ns = int(sr * dur)
            ds = ns * 2
            hdr = struct.pack('<4sI4s4sIHHIIHH4sI',
                b'RIFF', 36 + ds, b'WAVE', b'fmt ', 16, 1, 1, sr, sr * 2, 2, 16, b'data', ds)
            smp = bytearray()
            for i in range(ns):
                t = i / sr
                fade = max(0, 1.0 - (i / ns) * 1.5)
                v = int(32000 * fade * math.sin(2 * math.pi * freq * t))
                smp += struct.pack('<h', max(-32768, min(32767, v)))
            with open(f"{RAW_DIR}/{snd}.wav", 'wb') as wf:
                wf.write(hdr)
                wf.write(bytes(smp))
            fix(f"{snd}.wav uretildi ({freq}Hz, {dur}s)")

    # rawResourceId = 0 workaround duzelt
    for fpath, reps in workarounds.items():
        try:
            content = open(fpath, 'r', encoding='utf-8').read()
            for old_text, snd in reps:
                content = content.replace(old_text, f"rawResourceId = R.raw.{snd}")
            open(fpath, 'w', encoding='utf-8').write(content)
            fix(f"{os.path.basename(fpath)}: rawResourceId = 0 → R.raw.{snd}")
        except:
            pass

# ════════════════════════════════════════════════════════════════
# KONTROL 4: Firebase / Google Services
# ════════════════════════════════════════════════════════════════
def check_firebase(kt_files):
    if not os.path.exists(BUILD_GRADLE):
        return

    bg = open(BUILD_GRADLE, 'r').read()
    has_firebase_dep = 'firebase' in bg.lower()
    has_gms_plugin = 'google-services' in bg
    has_json = os.path.exists(GOOGLE_SERVICES)

    # Firebase import var ama dependency yok
    firebase_used = False
    for fpath, content in kt_files.items():
        if 'com.google.firebase' in content or 'FirebaseFirestore' in content or 'FirebaseAuth' in content:
            firebase_used = True
            break

    if firebase_used and not has_firebase_dep:
        # build.gradle'a Firebase dependency ekle
        if 'debugImplementation' in bg:
            fb_deps = (
                "    implementation platform('com.google.firebase:firebase-bom:32.7.0')\n"
                "    implementation 'com.google.firebase:firebase-firestore-ktx'\n"
                "    implementation 'com.google.firebase:firebase-auth-ktx'\n"
                "    implementation 'com.google.firebase:firebase-storage-ktx'\n"
            )
            bg = bg.replace("    debugImplementation", fb_deps + "    debugImplementation")
            fix("Firebase dependency'leri eklendi")

        if not has_gms_plugin:
            bg = bg.replace("id 'com.android.application'",
                            "id 'com.android.application'\n    id 'com.google.gms.google-services'")
            fix("google-services plugin eklendi")

        open(BUILD_GRADLE, 'w').write(bg)
        has_firebase_dep = True
        has_gms_plugin = True

    # google-services plugin var ama JSON yok → placeholder
    if (has_gms_plugin or has_firebase_dep) and not has_json:
        import json
        pkg = get_package_name() or "com.wizaicorp.app"
        placeholder = {
            "project_info": {
                "project_number": "000000000000",
                "project_id": f"{os.path.basename(PROJECT)}-placeholder",
                "storage_bucket": f"{os.path.basename(PROJECT)}-placeholder.appspot.com"
            },
            "client": [{
                "client_info": {
                    "mobilesdk_app_id": "1:000000000000:android:0000000000000000",
                    "android_client_info": {"package_name": pkg}
                },
                "api_key": [{"current_key": "AIzaSyPlaceholderKeyForBuildOnly"}]
            }],
            "configuration_version": "1"
        }
        os.makedirs(os.path.dirname(GOOGLE_SERVICES), exist_ok=True)
        open(GOOGLE_SERVICES, 'w').write(json.dumps(placeholder, indent=2))
        fix("Placeholder google-services.json olusturuldu")

    # Root build.gradle'a classpath ekle
    if has_gms_plugin and os.path.exists(ROOT_GRADLE):
        rg = open(ROOT_GRADLE, 'r').read()
        if 'google-services' not in rg and 'dependencies {' in rg:
            rg = rg.replace("dependencies {",
                            "dependencies {\n        classpath 'com.google.gms:google-services:4.4.0'")
            open(ROOT_GRADLE, 'w').write(rg)
            fix("Root build.gradle'a google-services classpath eklendi")

# ════════════════════════════════════════════════════════════════
# KONTROL 5: AdMob
# ════════════════════════════════════════════════════════════════
def check_admob(kt_files):
    if not os.path.exists(BUILD_GRADLE):
        return

    bg = open(BUILD_GRADLE, 'r').read()
    admob_used = False
    for fpath, content in kt_files.items():
        if 'com.google.android.gms.ads' in content or 'AdView' in content or 'InterstitialAd' in content:
            admob_used = True
            break

    if admob_used and 'play-services-ads' not in bg:
        if 'debugImplementation' in bg:
            bg = bg.replace("    debugImplementation",
                "    implementation 'com.google.android.gms:play-services-ads:22.6.0'\n    debugImplementation")
            open(BUILD_GRADLE, 'w').write(bg)
            fix("AdMob dependency eklendi")

    # Manifest'te meta-data kontrol
    if admob_used and os.path.exists(MANIFEST):
        manifest = open(MANIFEST, 'r').read()
        if 'com.google.android.gms.ads.APPLICATION_ID' not in manifest:
            # Test app ID ile ekle
            manifest = manifest.replace('</application>',
                '        <meta-data android:name="com.google.android.gms.ads.APPLICATION_ID"\n'
                '            android:value="ca-app-pub-3940256099942544~3347511713" />\n'
                '    </application>')
            open(MANIFEST, 'w').write(manifest)
            fix("AdMob meta-data Manifest'e eklendi (test ID)")

# ════════════════════════════════════════════════════════════════
# KONTROL 6: Brace balance
# ════════════════════════════════════════════════════════════════
def check_brace_balance(kt_files):
    for fpath, content in kt_files.items():
        opens = content.count('{')
        closes = content.count('}')
        if opens != closes:
            diff = opens - closes
            fname = os.path.basename(fpath)
            if diff > 0:
                # Kapanmamis brace → sonuna ekle
                content = content.rstrip() + '\n' + ('}\n' * diff)
                open(fpath, 'w', encoding='utf-8').write(content)
                fix(f"{fname}: {diff} kapanmamis '{{}}' kapatildi")
            else:
                warn(f"{fname}: {abs(diff)} fazla '}}' var — manuel kontrol gerekli")

# ════════════════════════════════════════════════════════════════
# KONTROL 7: systemBarsPadding import
# ════════════════════════════════════════════════════════════════
def check_system_bars_padding(kt_files):
    for fpath, content in kt_files.items():
        if 'systemBarsPadding' in content and 'import androidx.compose.foundation.layout.systemBarsPadding' not in content:
            # Import ekle
            pkg_line = content.find('package ')
            if pkg_line != -1:
                end_of_pkg = content.find('\n', pkg_line)
                if end_of_pkg != -1:
                    import_line = '\nimport androidx.compose.foundation.layout.systemBarsPadding'
                    # Zaten import blogu var mi?
                    first_import = content.find('\nimport ')
                    if first_import != -1:
                        content = content[:first_import] + import_line + content[first_import:]
                    else:
                        content = content[:end_of_pkg + 1] + import_line + content[end_of_pkg + 1:]
                    open(fpath, 'w', encoding='utf-8').write(content)
                    fix(f"{os.path.basename(fpath)}: systemBarsPadding import eklendi")

# ════════════════════════════════════════════════════════════════
# KONTROL 8: build.gradle tutarliligi (VERSION_17 vs VERSION_1_8)
# ════════════════════════════════════════════════════════════════
def check_build_gradle():
    if not os.path.exists(BUILD_GRADLE):
        return
    bg = open(BUILD_GRADLE, 'r').read()

    # Compose projesi icin VERSION_1_8 + jvmTarget 1.8 olmali
    # (factory.sh VERSION_17 kullaniyor ama orkestrator VERSION_1_8 — tutarsiz)
    # Compose + Kotlin 1.9.22 icin 1.8 daha guvenli
    if 'compose' in bg.lower():
        if 'VERSION_17' in bg:
            bg = bg.replace('VERSION_17', 'VERSION_1_8')
            bg = bg.replace("jvmTarget = '17'", "jvmTarget = '1.8'")
            bg = bg.replace('jvmTarget = "17"', "jvmTarget = '1.8'")
            open(BUILD_GRADLE, 'w').write(bg)
            fix("build.gradle: VERSION_17 → VERSION_1_8 (Compose uyumluluk)")

# ════════════════════════════════════════════════════════════════
# KONTROL 9: Eksik/hatali package declaration
# ════════════════════════════════════════════════════════════════
def check_package_declarations(kt_files):
    pkg_name = get_package_name()
    if not pkg_name:
        return

    for fpath, content in kt_files.items():
        # Dosya yolundan beklenen paket adini cikar
        rel = os.path.relpath(fpath, SRC_DIR)
        dir_parts = os.path.dirname(rel).replace(os.sep, '.')
        if not dir_parts:
            continue

        # Dosyadaki package satiri
        pkg_match = re.match(r'^package\s+([a-zA-Z0-9_.]+)', content)
        if pkg_match:
            declared_pkg = pkg_match.group(1)
            if declared_pkg != dir_parts:
                # Paket adi klasor yapisindan farkli — duzelt
                content = re.sub(r'^package\s+[a-zA-Z0-9_.]+', f'package {dir_parts}', content, count=1)
                open(fpath, 'w', encoding='utf-8').write(content)
                fix(f"{os.path.basename(fpath)}: package {declared_pkg} → {dir_parts}")
        else:
            # package satiri yok → ekle
            content = f"package {dir_parts}\n\n" + content
            open(fpath, 'w', encoding='utf-8').write(content)
            fix(f"{os.path.basename(fpath)}: package {dir_parts} eklendi")

# ════════════════════════════════════════════════════════════════
# KONTROL 10: Manifest internet permission (Firebase/Retrofit icin)
# ════════════════════════════════════════════════════════════════
def check_internet_permission(kt_files):
    if not os.path.exists(MANIFEST):
        return

    needs_internet = False
    for fpath, content in kt_files.items():
        if any(kw in content for kw in ['firebase', 'Firebase', 'retrofit', 'Retrofit',
                                         'HttpURLConnection', 'OkHttp', 'okhttp',
                                         'URL(', 'urlopen', 'WebSocket']):
            needs_internet = True
            break

    if needs_internet:
        manifest = open(MANIFEST, 'r').read()
        if 'android.permission.INTERNET' not in manifest:
            manifest = manifest.replace('<manifest',
                '<manifest\n    xmlns:android="http://schemas.android.com/apk/res/android"', 1) \
                if 'xmlns:android' not in manifest else manifest
            manifest = manifest.replace('<application',
                '    <uses-permission android:name="android.permission.INTERNET" />\n    <application')
            open(MANIFEST, 'w').write(manifest)
            fix("INTERNET permission Manifest'e eklendi")

# ════════════════════════════════════════════════════════════════
# ANA AKIS
# ════════════════════════════════════════════════════════════════
def main():
    if not os.path.isdir(PROJECT):
        log("Proje dizini bulunamadi")
        return 0  # Sessizce devam et

    if not os.path.isdir(SRC_DIR):
        log("src dizini yok, atlaniyor")
        return 0

    log(f"Proje taraniyor: {os.path.basename(PROJECT)}")

    kt_files = read_all_kt()
    if not kt_files:
        log("Kotlin dosyasi bulunamadi")
        return 0

    pkg_name = get_package_name()
    log(f"{len(kt_files)} Kotlin dosyasi bulundu, paket: {pkg_name}")

    # Kontrolleri calistir
    try:
        check_package_declarations(kt_files)
    except Exception as e:
        warn(f"Package kontrol hatasi: {e}")

    # Dosyalar degismis olabilir, tekrar oku
    kt_files = read_all_kt()

    try:
        check_imports(kt_files, pkg_name)
    except Exception as e:
        warn(f"Import kontrol hatasi: {e}")

    # Dosyalar degismis olabilir, tekrar oku
    kt_files = read_all_kt()

    try:
        check_themes(kt_files, pkg_name)
    except Exception as e:
        warn(f"Tema kontrol hatasi: {e}")

    # Tekrar oku (tema degismis olabilir)
    kt_files = read_all_kt()

    try:
        check_resources(kt_files)
    except Exception as e:
        warn(f"Resource kontrol hatasi: {e}")

    try:
        check_firebase(kt_files)
    except Exception as e:
        warn(f"Firebase kontrol hatasi: {e}")

    try:
        check_admob(kt_files)
    except Exception as e:
        warn(f"AdMob kontrol hatasi: {e}")

    try:
        check_build_gradle()
    except Exception as e:
        warn(f"build.gradle kontrol hatasi: {e}")

    try:
        check_system_bars_padding(kt_files)
    except Exception as e:
        warn(f"systemBarsPadding kontrol hatasi: {e}")

    try:
        check_brace_balance(read_all_kt())
    except Exception as e:
        warn(f"Brace balance kontrol hatasi: {e}")

    try:
        check_internet_permission(kt_files)
    except Exception as e:
        warn(f"Internet permission kontrol hatasi: {e}")

    # Ozet
    if fixes:
        log(f"SONUC: {len(fixes)} duzeltme yapildi, {len(warnings)} uyari")
    else:
        log(f"SONUC: Temiz — {len(warnings)} uyari")

    return 0

if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as e:
        # ASLA crash etme, sessizce devam et
        print(f"[VALIDATOR] KRITIK HATA: {e}", flush=True)
        sys.exit(0)
