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
    
    try:
        with urllib.request.urlopen(req, timeout=300) as resp:
            data = json.loads(resp.read().decode())
    except urllib.error.HTTPError as e:
        body = e.read().decode(errors="replace")[:500]
        err(f"API HTTP {e.code}: {body}")
        return None
    except Exception as e:
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

KURALLAR:
- Dosyaları küçük tut: her dosya MAX 200 satır
- MainActivity.kt: sadece Activity + setContent + tema (80 satır max)
- Data class'lar ayrı dosyada
- Her ekran ayrı dosyada
- build.gradle ve AndroidManifest.xml her zaman dahil et
- Paket adı: com.wizaicorp.PROJE_ADI (altçizgi ile)
- Navigation KULLANMA (sealed class Screen + mutableStateOf)
- ui/theme klasörü OLUŞTURMA"""

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
        dep_lines += f"    implementation \"{d}\"\n"
    
    # Sabit şablon — AI hatası IMKANSIZ
    gradle_content = f"""Dosya: app/build.gradle
```groovy
plugins {{
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}}

android {{
    namespace = "{args.package}"
    compileSdk = 35

    defaultConfig {{
        applicationId = "{args.package}"
        minSdk = 24
        targetSdk = 35
        versionCode = 1
        versionName = "1.0"
    }}

    buildTypes {{
        release {{
            isMinifyEnabled = false
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }}
    }}
    compileOptions {{
        sourceCompatibility = JavaVersion.VERSION_1_8
        targetCompatibility = JavaVersion.VERSION_1_8
    }}
    kotlinOptions {{
        jvmTarget = "1.8"
    }}
    buildFeatures {{
        compose = true
    }}
    composeOptions {{
        kotlinCompilerExtensionVersion = "1.5.8"
    }}
}}

dependencies {{
    implementation("androidx.core:core-ktx:1.12.0")
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.7.0")
    implementation("androidx.activity:activity-compose:1.8.0")
    implementation(platform("androidx.compose:compose-bom:2023.10.01"))
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.ui:ui-graphics")
    implementation("androidx.compose.ui:ui-tooling-preview")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-extended:1.5.4")
    implementation("androidx.compose.foundation:foundation:1.5.4")
{dep_lines}    debugImplementation("androidx.compose.ui:ui-tooling")
}}
```

auto_continue: false"""
    
    return gradle_content


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
    
    # ═══ FAZ 1: PLAN ═══
    plan = phase1_plan(args, existing)
    if not plan or "files" not in plan:
        err("Plan oluşturulamadı! Tek-geçiş moduna düşülüyor.")
        return 1
    
    files = plan["files"]
    ok(f"Plan hazır: {len(files)} dosya")
    for f in files:
        print(f"  📄 {f['path']} (~{f.get('estimated_lines','?')} satır) — {f.get('description','')}")
    
    # ═══ FAZ 2: HER DOSYAYI YAZ ═══
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
        
        response = phase2_write_file(args, file_info, plan, all_interfaces)
        
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
            
            ok(f"{os.path.basename(path)} yazıldı ({i+1}/{len(files)})")
            time.sleep(0.5)  # Rate limit koruması
        else:
            err(f"{os.path.basename(path)} yazılamadı!")
    
    # ═══ FAZ 3: BİRLEŞTİR ═══
    if not all_content:
        err("Hiçbir dosya yazılamadı!")
        return 1
    
    combined = "\n\n".join(all_content)
    
    # auto_continue: false ekle (tüm dosyalar yazıldı)
    combined += "\n\nauto_continue: false\n"
    
    # Çıktı dosyasına yaz
    with open(args.output, 'w', encoding='utf-8') as f:
        f.write(combined)
    
    ok(f"Orkestratör tamamlandı: {len(all_content)} dosya → {args.output}")
    
    # İstatistik
    total_lines = combined.count("\n")
    log(f"Toplam: ~{total_lines} satır, {len(combined)} karakter")
    log(f"API çağrıları: 1 plan + {len(all_content)} dosya = {1 + len(all_content)} çağrı")
    
    return 0


if __name__ == "__main__":
    sys.exit(main())
