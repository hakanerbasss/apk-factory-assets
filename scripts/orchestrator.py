#!/data/data/com.termux/files/usr/bin/python3
# -*- coding: utf-8 -*-
"""
APK Factory Orkestratör v1.0
Tek büyük API çağrısı yerine: Plan → Dosya dosya yaz → Birleştir

Kullanım (autofix.sh tarafından çağrılır):
  python3 orchestrator.py \
    --task "IQ testi yap..." \
    --project-root ~/q \
    --package "com.wizaicorp.q" \
    --provider Claude \
    --api-url "https://api.anthropic.com/v1/messages" \
    --api-key "sk-..." \
    --model "claude-haiku-4-5-20251001" \
    --max-tokens 8192 \
    --output /tmp/ai_content.txt \
    --collected /tmp/collected_sources.txt
"""

import argparse, json, os, sys, time
import urllib.request, urllib.error

def log(msg):
    print(f"\033[0;36m[ork]\033[0m {msg}", flush=True)

def ok(msg):
    print(f"\033[0;32m✅ {msg}\033[0m", flush=True)

def warn(msg):
    print(f"\033[1;33m⚠️  {msg}\033[0m", flush=True)

def err(msg):
    print(f"\033[0;31m❌ {msg}\033[0m", flush=True)


def call_api(provider, api_url, api_key, model, max_tokens, system_prompt, user_msg):
    """Tek bir API çağrısı yapar, yanıt metnini döndürür."""
    headers = {"Content-Type": "application/json"}
    
    if provider == "Claude":
        headers["x-api-key"] = api_key
        headers["anthropic-version"] = "2023-06-01"
        payload = json.dumps({
            "model": model,
            "max_tokens": max_tokens,
            "temperature": 0.1,
            "system": system_prompt,
            "messages": [{"role": "user", "content": user_msg}]
        }).encode()
    elif provider == "Gemini":
        api_url = f"https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent?key={api_key}"
        payload = json.dumps({
            "systemInstruction": {"parts": [{"text": system_prompt}]},
            "contents": [{"parts": [{"text": user_msg}]}],
            "generationConfig": {"maxOutputTokens": max_tokens, "temperature": 0.1}
        }).encode()
    else:  # OpenAI uyumlu (DeepSeek vs)
        headers["Authorization"] = f"Bearer {api_key}"
        payload = json.dumps({
            "model": model,
            "max_tokens": max_tokens,
            "temperature": 0.1,
            "messages": [
                {"role": "system", "content": system_prompt},
                {"role": "user", "content": user_msg}
            ]
        }).encode()
    
    req = urllib.request.Request(api_url, data=payload, headers=headers, method="POST")
    
    MAX_RETRY = 3
    for attempt in range(1, MAX_RETRY + 1):
        try:
            with urllib.request.urlopen(req, timeout=300) as resp:
                data = json.loads(resp.read().decode())
            break
        except urllib.error.HTTPError as e:
            body = e.read().decode(errors="replace")[:300]
            if e.code == 429 and attempt < MAX_RETRY:
                warn(f"⏳ Rate limit (429) — 60s bekleniyor... ({attempt}/{MAX_RETRY})")
                time.sleep(60)
                continue
            err(f"API HTTP {e.code}: {body}")
            return None
        except Exception as e:
            if attempt < MAX_RETRY:
                warn(f"⏳ Bağlantı hatası ({e}) — 10s sonra tekrar... ({attempt}/{MAX_RETRY})")
                time.sleep(10)
                continue
            err(f"API hata: {e}")
            return None
    
    # Yanıtı çıkar
    if provider == "Claude":
        return data.get("content", [{}])[0].get("text", "")
    elif provider == "Gemini":
        return data.get("candidates", [{}])[0].get("content", {}).get("parts", [{}])[0].get("text", "")
    else:
        return data.get("choices", [{}])[0].get("message", {}).get("content", "")


def phase1_plan(args, existing_files):
    """Faz 1: Proje planı al — hangi dosyalar oluşturulacak."""
    log("📐 FAZ 1: Proje planı oluşturuluyor...")
    
    system = """Sen bir Android/Kotlin proje planlayıcısın.
Sana bir görev verilecek. Projenin dosya planını JSON olarak döndür.
SADECE JSON döndür, başka hiçbir şey yazma (açıklama, markdown, backtick yok).

JSON formatı:
{
  "files": [
    {
      "path": "app/src/main/java/com/wizaicorp/PAKET/DosyaAdi.kt",
      "description": "Bu dosya ne yapıyor (1 cümle)",
      "depends_on": ["DigerDosya.kt"],
      "estimated_lines": 150
    }
  ],
  "dependencies": ["androidx.navigation:navigation-compose:2.7.7"],
  "notes": "Tek cümle genel not"
}

!!! KRITIK DOSYA BOLME KURALI !!!
HER DOSYA MAKSIMUM 200 SATIR. 200 SATIRDAN BUYUK DOSYA YASAKTIR.
Tek dosyaya her seyi koyan plan REDDEDILIR.

ZORUNLU DOSYA YAPISI (minimum 4-5 dosya):
1. MainActivity.kt — SADECE Activity + setContent + tema (MAX 60 satir)
2. Screens.kt VEYA her ekran ayri dosya (HomeScreen.kt, QuizScreen.kt vs)
3. Data.kt — data class'lar + soru havuzu + sabit veriler
4. Utils.kt — hesaplama fonksiyonlari, helper'lar
5. AndroidManifest.xml

ORNEK PLAN (IQ Testi):
- MainActivity.kt (60 satir): Activity + sealed class Screen + tema
- QuizData.kt (150 satir): data class IQQuestion + 30 soru havuzu + generateQuestions()
- HomeScreen.kt (80 satir): Giris ekrani composable
- QuizScreen.kt (150 satir): Test ekrani + timer + soru gosterim
- ResultScreen.kt (100 satir): Sonuc + paylasim + IQ seviye aciklamasi
- IQCalculator.kt (50 satir): calculateIQScore + calculateIQLevel fonksiyonlari

- build.gradle ve AndroidManifest.xml her zaman dahil et (ama bunlari dosya listesine KOYMA, otomatik olusturulur)
- Paket adi: com.wizaicorp.PROJE_ADI (altcizgi ile)
- Navigation KULLANMA (sealed class Screen + mutableStateOf)
- ui/theme klasoru OLUSTURMA
- Her Kotlin dosyasi AYNI pakette olsun (alt paket OLUSTURMA)"""

    pkg_path = args.package.replace(".", "/")
    user = f"""GÖREV: {args.task}

PAKET ADI: {args.package}
DOSYA YOLU: app/src/main/java/{pkg_path}/
PROJE KÖKÜ: {args.project_root}

MEVCUT DOSYALAR:
{existing_files}

Bu görev için gereken tüm dosyaların planını JSON olarak ver."""

    response = call_api(
        args.provider, args.api_url, args.api_key, args.model,
        2000,  # Plan için 2K token yeter
        system, user
    )
    
    if not response:
        return None
    
    # JSON parse
    try:
        # Markdown backtick temizle
        clean = response.strip()
        if clean.startswith("```"):
            clean = clean.split("\n", 1)[1] if "\n" in clean else clean[3:]
        if clean.endswith("```"):
            clean = clean[:-3]
        clean = clean.strip()
        
        plan = json.loads(clean)
        return plan
    except json.JSONDecodeError as e:
        err(f"Plan JSON parse hatası: {e}")
        err(f"Yanıt: {response[:500]}")
        return None


def phase2_write_file(args, file_info, plan, all_interfaces):
    """Faz 2: Tek bir dosyayı yaz."""
    path = file_info["path"]
    desc = file_info.get("description", "")
    deps = file_info.get("depends_on", [])
    
    log(f"📝 Yazılıyor: {os.path.basename(path)} ({file_info.get('estimated_lines', '?')} satır)")
    
    # Bağımlılık bilgisi oluştur
    dep_info = ""
    if deps:
        dep_info = "\n\nBU DOSYANIN BAĞIMLILIKLARI (import edeceksin):\n"
        for d in deps:
            if d in all_interfaces:
                dep_info += f"\n--- {d} ---\n{all_interfaces[d]}\n"
    
    # Diğer dosyaların arayüzleri
    other_files = ""
    for f in plan.get("files", []):
        if f["path"] != path:
            other_files += f"- {os.path.basename(f['path'])}: {f.get('description','')}\n"

    system = f"""Sen bir Kotlin/Android uzmanısın. SADECE TEK BİR DOSYA yazacaksın.
Fenced markdown formatında yaz:

Dosya: {path}
```kotlin
// dosya içeriği
```

KURALLAR:
- SADECE bu dosyayı yaz, başka dosya yazma
- Dosyayı TAM yaz, yarıda bırakma
- String ve parantezleri KAPAT
- ASLA soru sorma
- Paket adı: {args.package}
- Navigation KULLANMA (sealed class Screen + mutableStateOf ile ekran geçişi)
- ui/theme klasörü OLUŞTURMA
- compileSdk/targetSdk = 35
- isSystemInDarkTheme (isSystemInDarkMode DEĞİL)
- LazyColumn/LazyVerticalGrid'e .verticalScroll() EKLEME
- Modifier.systemBarsPadding() kullan"""

    user = f"""GÖREV: {args.task}

YAZACAĞIN DOSYA: {path}
AÇIKLAMA: {desc}

PROJEDEKİ DİĞER DOSYALAR:
{other_files}
{dep_info}

Sadece {os.path.basename(path)} dosyasını TAM olarak yaz. Başka dosya yazma."""

    response = call_api(
        args.provider, args.api_url, args.api_key, args.model,
        args.max_tokens,
        system, user
    )
    
    return response


def phase3_build_gradle(args, plan):
    """build.gradle'ı ŞABLON olarak oluştur (AI'a bırakmıyoruz, paket adı kesin)."""
    deps = plan.get("dependencies", [])
    
    log(f"📝 Yazılıyor: app/build.gradle (şablon, paket={args.package})")
    
    dep_lines = ""
    for d in deps:
        dep_lines += f"    implementation '{d}'\n"
    
    # Sabit şablon — Groovy DSL (Kotlin DSL DEĞİL!)
    gradle_content = f"""Dosya: app/build.gradle
```groovy
plugins {{
    id 'com.android.application'
    id 'org.jetbrains.kotlin.android'
}}

android {{
    namespace '{args.package}'
    compileSdk 35

    defaultConfig {{
        applicationId '{args.package}'
        minSdk 24
        targetSdk 35
        versionCode 1
        versionName '1.0'
    }}

    buildTypes {{
        release {{
            minifyEnabled false
            proguardFiles getDefaultProguardFile('proguard-android-optimize.txt'), 'proguard-rules.pro'
        }}
    }}
    compileOptions {{
        sourceCompatibility JavaVersion.VERSION_1_8
        targetCompatibility JavaVersion.VERSION_1_8
    }}
    kotlinOptions {{
        jvmTarget = '1.8'
    }}
    buildFeatures {{
        compose true
    }}
    composeOptions {{
        kotlinCompilerExtensionVersion '1.5.8'
    }}
}}

dependencies {{
    implementation 'androidx.core:core-ktx:1.12.0'
    implementation 'androidx.lifecycle:lifecycle-runtime-ktx:2.7.0'
    implementation 'androidx.activity:activity-compose:1.8.0'
    implementation platform('androidx.compose:compose-bom:2023.10.01')
    implementation 'androidx.compose.ui:ui'
    implementation 'androidx.compose.ui:ui-graphics'
    implementation 'androidx.compose.ui:ui-tooling-preview'
    implementation 'androidx.compose.material3:material3'
    implementation 'androidx.compose.material:material-icons-extended:1.5.4'
    implementation 'androidx.compose.foundation:foundation:1.5.4'
{dep_lines}    debugImplementation 'androidx.compose.ui:ui-tooling'
}}
```

auto_continue: false"""
    
    return gradle_content


def phase1_plan_retry(args, existing_files):
    """Plan tekrar — tek dosya planını parçala."""
    log("📐 Plan yeniden oluşturuluyor (dosya bölme zorunlu)...")
    
    system = """Sen bir Android/Kotlin proje planlayıcısın.
SADECE JSON döndür, başka hiçbir şey yazma.
!!! KRITIK: HER DOSYA MAKSIMUM 150 SATIR. TEK DOSYAYA HERSEYI KOYMA !!!

JSON formatı:
{
  "files": [
    {"path": "app/src/main/java/PKG/DosyaAdi.kt", "description": "...", "depends_on": [], "estimated_lines": 100}
  ],
  "dependencies": []
}

ZORUNLU: Minimum 4 Kotlin dosyası! MainActivity.kt MAX 60 satır!"""

    pkg_path = args.package.replace(".", "/")
    user = f"""GÖREV: {args.task}
PAKET: {args.package}
DOSYA YOLU: app/src/main/java/{pkg_path}/

ÖNCEKİ PLAN TEK DOSYAYDII — REDDEDILDI.
Şimdi minimum 4 Kotlin dosyası ile yeni plan ver.
SADECE JSON döndür."""

    response = call_api(
        args.provider, args.api_url, args.api_key, args.model,
        2000, system, user
    )
    
    if not response:
        return None
    try:
        clean = response.strip()
        if clean.startswith("```"): clean = clean.split("\n", 1)[1]
        if clean.endswith("```"): clean = clean[:-3]
        return json.loads(clean.strip())
    except:
        return None


def detect_missing_dependencies(all_content):
    """Yazılan kodlardaki import'ları tarayıp eksik dependency'leri bulur."""
    combined_code = "\n".join(all_content)
    
    IMPORT_TO_DEP = {
        "androidx.room": "    implementation 'androidx.room:room-runtime:2.6.1'\n    implementation 'androidx.room:room-ktx:2.6.1'\n    kapt 'androidx.room:room-compiler:2.6.1'",
        "androidx.navigation.compose": "    implementation 'androidx.navigation:navigation-compose:2.7.7'",
        "kotlinx.coroutines": "    implementation 'org.jetbrains.kotlinx:kotlinx-coroutines-android:1.7.3'",
        "kotlinx.serialization": "    implementation 'org.jetbrains.kotlinx:kotlinx-serialization-json:1.6.2'",
        "coil.compose": "    implementation 'io.coil-kt:coil-compose:2.5.0'",
        "retrofit2": "    implementation 'com.squareup.retrofit2:retrofit:2.9.0'\n    implementation 'com.squareup.retrofit2:converter-gson:2.9.0'",
        "com.google.gson": "    implementation 'com.google.code.gson:gson:2.10.1'",
        "androidx.datastore": "    implementation 'androidx.datastore:datastore-preferences:1.0.0'",
        "androidx.work": "    implementation 'androidx.work:work-runtime-ktx:2.9.0'",
        "com.google.accompanist": "    implementation 'com.google.accompanist:accompanist-systemuicontroller:0.32.0'",
    }
    
    needed = []
    for import_prefix, dep_line in IMPORT_TO_DEP.items():
        if f"import {import_prefix}" in combined_code:
            needed.append((import_prefix, dep_line))
    
    return needed


def inject_dependencies(all_content, needed_deps):
    """build.gradle icindeki eksik dependency'leri ekler."""
    if not needed_deps:
        return all_content
    
    new_content = []
    for content in all_content:
        if "app/build.gradle" in content and "dependencies {" in content:
            needs_kapt = any("room" in dep for _, dep in needed_deps)
            if needs_kapt and "kapt" not in content:
                content = content.replace(
                    "    id 'org.jetbrains.kotlin.android'",
                    "    id 'org.jetbrains.kotlin.android'\n    id 'kotlin-kapt'"
                )
            dep_lines = "\n".join(dep for _, dep in needed_deps)
            content = content.replace(
                "    debugImplementation",
                f"{dep_lines}\n    debugImplementation"
            )
            log(f"\U0001f4e6 Otomatik dependency eklendi: {', '.join(imp for imp, _ in needed_deps)}")
        new_content.append(content)
    
    return new_content



def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--task", required=True)
    parser.add_argument("--project-root", required=True)
    parser.add_argument("--package", required=True)
    parser.add_argument("--provider", required=True)
    parser.add_argument("--api-url", required=True)
    parser.add_argument("--api-key", required=True)
    parser.add_argument("--model", required=True)
    parser.add_argument("--max-tokens", type=int, default=8192)
    parser.add_argument("--output", required=True)
    parser.add_argument("--collected", default="")
    args = parser.parse_args()
    
    # Mevcut dosya listesi
    existing = ""
    if args.collected and os.path.exists(args.collected):
        existing = open(args.collected, 'r', errors='replace').read()[:5000]
    
    total_start = time.time()
    
    # ═══ FAZ 1: PLAN ═══
    faz1_start = time.time()
    plan = phase1_plan(args, existing)
    if not plan or "files" not in plan:
        err("Plan oluşturulamadı! Tek-geçiş moduna düşülüyor.")
        return 1
    
    files = plan["files"]
    
    # Plan doğrulama: 200+ satır dosya varsa uyar
    for f in files:
        est = f.get("estimated_lines", 0)
        if est > 300:
            warn(f"{f['path']} çok büyük ({est} satır)! Bölünmeli ama devam ediliyor...")
    
    # Tek dosya planı varsa ve büyükse → zorlayarak böl
    kt_files = [f for f in files if f["path"].endswith(".kt")]
    if len(kt_files) == 1 and kt_files[0].get("estimated_lines", 0) > 250:
        warn("Tek Kotlin dosyası planlandı — otomatik bölme uygulanıyor!")
        # Plan yetersiz, tekrar iste ama daha zorla
        plan2 = phase1_plan_retry(args, existing)
        if plan2 and "files" in plan2:
            kt2 = [f for f in plan2["files"] if f["path"].endswith(".kt")]
            if len(kt2) > 1:
                plan = plan2
                files = plan["files"]
                ok(f"Bölünmüş plan: {len(files)} dosya")
    ok(f"Plan hazır: {len(files)} dosya ({time.time()-faz1_start:.1f}s)")
    for f in files:
        print(f"  📄 {f['path']} (~{f.get('estimated_lines','?')} satır) — {f.get('description','')}")
    
    # ═══ FAZ 2: HER DOSYAYI YAZ ═══
    faz2_start = time.time()
    print(f"\n\033[1;34m{'='*50}\033[0m")
    log(f"📝 FAZ 2: {len(files)} dosya yazılıyor (her biri ayrı API çağrısı)")
    print(f"\033[1;34m{'='*50}\033[0m\n")
    
    all_content = []
    all_interfaces = {}  # dosya adı → arayüz bilgisi (sonraki dosyalar için)
    
    # Önce build.gradle
    bg_response = phase3_build_gradle(args, plan)
    if bg_response:
        all_content.append(bg_response)
        ok("app/build.gradle yazıldı")
    
    # Sonra her dosya
    for i, file_info in enumerate(files):
        path = file_info["path"]
        
        # build.gradle zaten yazıldı
        if "build.gradle" in path:
            continue
        
        file_start = time.time()
        response = phase2_write_file(args, file_info, plan, all_interfaces)
        file_elapsed = time.time() - file_start
        
        if response:
            all_content.append(response)
            # Arayüz bilgisini kaydet (data class, sealed class, fun signature)
            iface_lines = []
            for line in response.split("\n"):
                stripped = line.strip()
                if any(stripped.startswith(kw) for kw in ["data class", "sealed class", "fun ", "object ", "interface ", "enum class"]):
                    iface_lines.append(stripped)
            if iface_lines:
                all_interfaces[os.path.basename(path)] = "\n".join(iface_lines)
            
            ok(f"{os.path.basename(path)} yazıldı ({i+1}/{len(files)}) [{file_elapsed:.1f}s]")
            time.sleep(5)  # Rate limit koruması — 30s bekleme
        else:
            err(f"{os.path.basename(path)} yazılamadı! [{file_elapsed:.1f}s]")
    
    # ═══ FAZ 3: BİRLEŞTİR ═══
    if not all_content:
        err("Hiçbir dosya yazılamadı!")
        return 1
    
    # Otomatik dependency tarama ve ekleme
    needed = detect_missing_dependencies(all_content)
    if needed:
        all_content = inject_dependencies(all_content, needed)
    
    combined = "\n\n".join(all_content)
    
    # auto_continue: false ekle (tüm dosyalar yazıldı)
    # AI'ın auto_continue:true satirlarini temizle (zincir tetiklemesin)
    import re as _re
    combined = _re.sub(r'auto_continue\s*:\s*true', 'auto_continue: false', combined)
    combined += "\n\nauto_continue: false\n"
    
    # Çıktı dosyasına yaz
    with open(args.output, 'w', encoding='utf-8') as f:
        f.write(combined)
    
    ok(f"Orkestratör tamamlandı: {len(all_content)} dosya → {args.output}")
    
    # İstatistik + Zamanlama
    total_elapsed = time.time() - total_start
    faz2_elapsed = time.time() - faz2_start
    total_lines = combined.count("\n")
    log(f"Toplam: ~{total_lines} satır, {len(combined)} karakter")
    log(f"API çağrıları: 1 plan + {len(all_content)} dosya = {1 + len(all_content)} çağrı")
    log(f"⏱️  Süre: Plan {faz2_start-faz1_start:.0f}s + Dosyalar {faz2_elapsed:.0f}s = Toplam {total_elapsed:.0f}s ({total_elapsed/60:.1f}dk)")
    
    return 0


if __name__ == "__main__":
    sys.exit(main())
