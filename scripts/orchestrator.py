#!/data/data/com.termux/files/usr/bin/python3
# -*- coding: utf-8 -*-
"""
APK Factory Orkestratör v2.0
Data dosyaları önce yazılır, tam kodu sonraki dosyalara gönderilir.
Max 4 Kotlin dosyası. Ortak sözleşme sistemi.
"""

import argparse, json, os, sys, time
import urllib.request, urllib.error

def log(msg): print(f"\033[0;36m[ork]\033[0m {msg}", flush=True)
def ok(msg):  print(f"\033[0;32m\u2705 {msg}\033[0m", flush=True)
def warn(msg):print(f"\033[1;33m\u26a0\ufe0f  {msg}\033[0m", flush=True)
def err(msg): print(f"\033[0;31m\u274c {msg}\033[0m", flush=True)

def call_api(provider, api_url, api_key, model, max_tokens, system_prompt, user_msg):
    headers = {"Content-Type": "application/json"}
    if provider == "Claude":
        headers["x-api-key"] = api_key
        headers["anthropic-version"] = "2023-06-01"
        payload = json.dumps({"model": model, "max_tokens": max_tokens, "temperature": 0.1,
            "system": system_prompt, "messages": [{"role": "user", "content": user_msg}]}).encode()
    elif provider == "Gemini":
        api_url = f"https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent?key={api_key}"
        payload = json.dumps({"systemInstruction": {"parts": [{"text": system_prompt}]},
            "contents": [{"parts": [{"text": user_msg}]}],
            "generationConfig": {"maxOutputTokens": max_tokens, "temperature": 0.1}}).encode()
    else:
        headers["Authorization"] = f"Bearer {api_key}"
        payload = json.dumps({"model": model, "max_tokens": max_tokens, "temperature": 0.1,
            "messages": [{"role": "system", "content": system_prompt}, {"role": "user", "content": user_msg}]}).encode()
    
    MAX_RETRY = 3
    data = None
    for attempt in range(1, MAX_RETRY + 1):
        try:
            req = urllib.request.Request(api_url, data=payload, headers=headers, method="POST")
            with urllib.request.urlopen(req, timeout=300) as resp:
                data = json.loads(resp.read().decode())
            break
        except urllib.error.HTTPError as e:
            body = e.read().decode(errors="replace")[:300]
            if e.code == 429 and attempt < MAX_RETRY:
                warn(f"Rate limit (429) \u2014 60s bekleniyor... ({attempt}/{MAX_RETRY})")
                time.sleep(60); continue
            err(f"API HTTP {e.code}: {body}"); return None
        except Exception as e:
            if attempt < MAX_RETRY:
                warn(f"Ba\u011flant\u0131 hatas\u0131 ({e}) \u2014 10s sonra tekrar... ({attempt}/{MAX_RETRY})")
                time.sleep(10); continue
            err(f"API hata: {e}"); return None
    if data is None: return None
    if provider == "Claude":
        return data.get("content", [{}])[0].get("text", "")
    elif provider == "Gemini":
        return data.get("candidates", [{}])[0].get("content", {}).get("parts", [{}])[0].get("text", "")
    else:
        return data.get("choices", [{}])[0].get("message", {}).get("content", "")


def phase1_plan(args, existing_files):
    log("\U0001f4d0 FAZ 1: Proje plan\u0131 olu\u015fturuluyor...")
    system = """Sen bir Android/Kotlin proje planlay\u0131c\u0131s\u0131n.
SADECE JSON d\u00f6nd\u00fcr, ba\u015fka hi\u00e7bir \u015fey yazma.

JSON format\u0131:
{
  "files": [
    {
      "path": "app/src/main/java/PKG_PATH/DosyaAdi.kt",
      "type": "data|screen|main|util",
      "description": "1 c\u00fcmle",
      "classes": ["ClassName"],
      "functions": ["funName(param: Type): ReturnType"],
      "estimated_lines": 150
    }
  ],
  "dependencies": [],
  "shared_contracts": {
    "sealed_class_screen": "sealed class Screen { object Home : Screen(); object Game : Screen(); data class Result(val score: Int) : Screen() }",
    "data_classes": "data class GameItem(val id: Int, val content: String, val isActive: Boolean = true)"
  }
}

!!! KURALLAR !!!
- BASIT gorev (buton, hesap makinesi, timer, tek ekran) = MAKSIMUM 2 dosya (MainActivity.kt + 1 yardimci)
- ORTA gorev (liste, form, ayarlar) = MAKSIMUM 3 dosya
- KARMASIK gorev (database, API, coklu ekran) = MAKSIMUM 4 dosya
- SADECE ihtiyac olan dosyalari olustur, gereksiz parcalama YAPMA
- Tek dosyada yazilabilecek kodu 3 dosyaya bolme
- MAKSIMUM 4 Kotlin dosyas\u0131
- MainActivity.kt: SADECE Activity + setContent (MAX 50 sat\u0131r)
- 1 Data dosyas\u0131: t\u00fcm data class + model + sabit veri (type: "data")
- 1-2 Screen dosyas\u0131: composable'lar (type: "screen")
- shared_contracts: T\u00dcM dosyalar\u0131n kullanaca\u011f\u0131 ortak s\u0131n\u0131f tan\u0131mlar\u0131
- Navigation KULLANMA \u2014 sealed class Screen + mutableStateOf
- ui/theme klas\u00f6r\u00fc OLU\u015eTURMA
- Her dosya MAX 200 sat\u0131r"""

    pkg_path = args.package.replace(".", "/")
    user = f"""G\u00d6REV: {args.task}

PAKET ADI: {args.package}
DOSYA YOLU: app/src/main/java/{pkg_path}/

Bu g\u00f6rev i\u00e7in gereken dosyalar\u0131n plan\u0131n\u0131 JSON olarak ver.
MAXIMUM 4 Kotlin dosyas\u0131. shared_contracts MUTLAKA doldur."""

    response = call_api(args.provider, args.api_url, args.api_key, args.model, 2000, system, user)
    if not response: return None
    try:
        clean = response.strip()
        if clean.startswith("```"): clean = clean.split("\n", 1)[1] if "\n" in clean else clean[3:]
        if clean.endswith("```"): clean = clean[:-3]
        return json.loads(clean.strip())
    except json.JSONDecodeError as e:
        err(f"Plan JSON parse hatas\u0131: {e}"); return None


def phase1_plan_retry(args):
    log("\U0001f4d0 Plan yeniden olu\u015fturuluyor...")
    system = """SADECE JSON d\u00f6nd\u00fcr. MAKSIMUM 4 Kotlin dosyas\u0131. shared_contracts DOLDUR.
JSON: {"files": [{"path": "...", "type": "data|screen|main", "description": "...", "classes": [], "functions": [], "estimated_lines": 100}], "dependencies": [], "shared_contracts": {}}"""
    pkg_path = args.package.replace(".", "/")
    user = f"""G\u00d6REV: {args.task}\nPAKET: {args.package}\nYOL: app/src/main/java/{pkg_path}/\n\n\u00d6NCEK\u0130 PLAN REDDEDILDI. 3-4 Kotlin dosyas\u0131 ile yeni plan ver. SADECE JSON."""
    response = call_api(args.provider, args.api_url, args.api_key, args.model, 2000, system, user)
    if not response: return None
    try:
        clean = response.strip()
        if clean.startswith("```"): clean = clean.split("\n", 1)[1]
        if clean.endswith("```"): clean = clean[:-3]
        return json.loads(clean.strip())
    except: return None


def phase2_write_file(args, file_info, plan, written_files, contracts):
    path = file_info["path"]
    desc = file_info.get("description", "")
    log(f"\U0001f4dd Yaz\u0131l\u0131yor: {os.path.basename(path)} ({file_info.get('estimated_lines', '?')} sat\u0131r)")
    
    context = ""
    if written_files:
        context = "\n\n=== DAHA \u00d6NCE YAZILAN DOSYALAR (import edebilirsin, AYNI \u0130S\u0130MLER\u0130 KULLAN) ===\n"
        for wf_path, wf_code in written_files.items():
            context += f"\n--- {os.path.basename(wf_path)} ---\n{wf_code}\n"
        context += "=== DOSYALAR SONU ===\n"
    
    contract_info = ""
    if contracts:
        contract_info = "\n\n=== ORTAK SINIF TANIMLARI (bunlar\u0131 kullan, yenisini uydurma) ===\n"
        for k, v in contracts.items():
            contract_info += f"{k}: {v}\n"
        contract_info += "=== S\u00d6ZLE\u015eME SONU ===\n"
    
    other_files = ""
    for f in plan.get("files", []):
        if f["path"] != path:
            other_files += f"- {os.path.basename(f['path'])}: {f.get('description','')}"
            if f.get("classes"): other_files += f" [s\u0131n\u0131flar: {', '.join(f['classes'])}]"
            other_files += "\n"

    system = f"""Sen bir Kotlin/Android uzman\u0131s\u0131n. SADECE TEK DOSYA yaz.

Dosya: {path}
```kotlin
// tam dosya
```

KURALLAR:
- SADECE {os.path.basename(path)} yaz
- TAM yaz, yar\u0131da b\u0131rakma YASAK
- ASLA soru sorma
- Paket: {args.package}
- Navigation KULLANMA (sealed class Screen + mutableStateOf)
- \u00d6NCEK\u0130 dosyalardaki s\u0131n\u0131f/fonksiyon isimlerini AYNEN kullan
- Farkl\u0131 dosyadaki s\u0131n\u0131f\u0131 import et: import {args.package}.SinifAdi
- isSystemInDarkTheme kullan (isSystemInDarkMode DEĞİL)
- ui/theme/ klasörü OLUŞTURMA, XxxTheme fonksiyonu YAZMA
- Sadece MaterialTheme {{ }} kullan
- Ses efekti gerekiyorsa R.raw.ses_adi kullan, dosya otomatik olusturulur
- rawResourceId = 0 veya placeholder YAZMA\u011e\u0130L)
- Modifier.systemBarsPadding() kullan"""

    user = f"""G\u00d6REV: {args.task}

DOSYA: {path}
A\u00c7IKLAMA: {desc}

D\u0130\u011eER DOSYALAR:
{other_files}{contract_info}{context}

Sadece {os.path.basename(path)} yaz."""

    return call_api(args.provider, args.api_url, args.api_key, args.model, args.max_tokens, system, user)


def phase3_build_gradle(args, plan):
    log(f"\U0001f4dd app/build.gradle (\u015fablon, paket={args.package})")
    dep_lines = "".join(f"    implementation '{d}'\n" for d in plan.get("dependencies", []))
    return f"""Dosya: app/build.gradle
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
    buildTypes {{ release {{ minifyEnabled false; proguardFiles getDefaultProguardFile('proguard-android-optimize.txt'), 'proguard-rules.pro' }} }}
    compileOptions {{ sourceCompatibility JavaVersion.VERSION_1_8; targetCompatibility JavaVersion.VERSION_1_8 }}
    kotlinOptions {{ jvmTarget = '1.8' }}
    buildFeatures {{ compose true }}
    composeOptions {{ kotlinCompilerExtensionVersion '1.5.8' }}
}}

dependencies {{
    implementation 'androidx.core:core-ktx:1.12.0'
    implementation 'androidx.lifecycle:lifecycle-runtime-ktx:2.7.0'
    implementation 'androidx.activity:activity-compose:1.8.0'
    implementation platform('androidx.compose:compose-bom:2023.10.01')
    implementation 'androidx.compose.ui:ui'
    implementation 'androidx.compose.ui:ui-graphics'
    implementation 'androidx.compose.material3:material3'
    implementation 'androidx.compose.material:material-icons-extended:1.5.4'
    implementation 'androidx.compose.foundation:foundation:1.5.4'
{dep_lines}    debugImplementation 'androidx.compose.ui:ui-tooling'
}}
```

auto_continue: false"""


IMPORT_TO_DEP = {
    "androidx.room": "    implementation 'androidx.room:room-runtime:2.6.1'\n    implementation 'androidx.room:room-ktx:2.6.1'\n    kapt 'androidx.room:room-compiler:2.6.1'",
    "androidx.navigation.compose": "    implementation 'androidx.navigation:navigation-compose:2.7.7'",
    "kotlinx.coroutines": "    implementation 'org.jetbrains.kotlinx:kotlinx-coroutines-android:1.7.3'",
    "coil.compose": "    implementation 'io.coil-kt:coil-compose:2.5.0'",
    "retrofit2": "    implementation 'com.squareup.retrofit2:retrofit:2.9.0'\n    implementation 'com.squareup.retrofit2:converter-gson:2.9.0'",
    "androidx.datastore": "    implementation 'androidx.datastore:datastore-preferences:1.0.0'",
}

def detect_and_inject_deps(all_content):
    combined = "\n".join(all_content)
    needed = [(p, d) for p, d in IMPORT_TO_DEP.items() if f"import {p}" in combined]
    if not needed: return all_content
    new_content = []
    for content in all_content:
        if "app/build.gradle" in content and "dependencies {" in content:
            if any("room" in d for _, d in needed) and "kapt" not in content:
                content = content.replace("    id 'org.jetbrains.kotlin.android'", "    id 'org.jetbrains.kotlin.android'\n    id 'kotlin-kapt'")
            dep_lines = "\n".join(d for _, d in needed)
            content = content.replace("    debugImplementation", f"{dep_lines}\n    debugImplementation")
            log(f"\U0001f4e6 Dep eklendi: {', '.join(p for p, _ in needed)}")
        new_content.append(content)
    return new_content


def extract_kotlin_code(response):
    import re
    match = re.search(r'```\w*\n(.*?)```', response, re.DOTALL)
    if match: return match.group(1).strip()
    lines = response.split("\n")
    return "\n".join(l for l in lines if not l.startswith("Dosya:") and not l.strip().startswith("```")).strip()




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
    
    total_start = time.time()
    
    plan = phase1_plan(args, "")
    if not plan or "files" not in plan:
        err("Plan olu\u015fturulamad\u0131!"); return 1
    
    files = plan["files"]
    contracts = plan.get("shared_contracts", {})
    faz1_end = time.time()
    
    kt_files = [f for f in files if f["path"].endswith(".kt")]
    if len(kt_files) == 1 and kt_files[0].get("estimated_lines", 0) > 250:
        warn("Tek b\u00fcy\u00fck dosya \u2014 b\u00f6lme!")
        plan2 = phase1_plan_retry(args)
        if plan2 and len([f for f in plan2.get("files", []) if f["path"].endswith(".kt")]) > 1:
            plan, files, contracts = plan2, plan2["files"], plan2.get("shared_contracts", {})
            ok(f"B\u00f6l\u00fcnm\u00fc\u015f plan: {len(files)} dosya")
    elif len(kt_files) > 5:
        warn(f"{len(kt_files)} dosya \u2014 \u00e7ok fazla, yeniden planlama...")
        plan2 = phase1_plan_retry(args)
        if plan2:
            kt2 = [f for f in plan2.get("files", []) if f["path"].endswith(".kt")]
            if 2 <= len(kt2) <= 5:
                plan, files, contracts = plan2, plan2["files"], plan2.get("shared_contracts", {})
                ok(f"Azalt\u0131lm\u0131\u015f plan: {len(files)} dosya")
    
    ok(f"Plan haz\u0131r: {len(files)} dosya ({faz1_end-total_start:.1f}s)")
    for f in files:
        print(f"  \U0001f4c4 {f['path']} (~{f.get('estimated_lines','?')} sat\u0131r) \u2014 {f.get('description','')}")
    if contracts:
        log(f"\U0001f4cb S\u00f6zle\u015fmeler: {list(contracts.keys())}")
    
    faz2_start = time.time()
    print(f"\n\033[1;34m{'='*50}\033[0m")
    log(f"\U0001f4dd FAZ 2: {len(files)} dosya yaz\u0131l\u0131yor")
    print(f"\033[1;34m{'='*50}\033[0m\n")
    
    all_content = []
    written_files = {}
    
    bg = phase3_build_gradle(args, plan)
    if bg: all_content.append(bg); ok("app/build.gradle yaz\u0131ld\u0131")
    
    type_order = {"data": 0, "util": 1, "screen": 2, "main": 3}
    sorted_files = sorted(files, key=lambda f: type_order.get(f.get("type", "screen"), 2))
    
    for i, fi in enumerate(sorted_files):
        path = fi["path"]
        if "build.gradle" in path or "AndroidManifest" in path: continue
        
        t0 = time.time()
        response = phase2_write_file(args, fi, plan, written_files, contracts)
        elapsed = time.time() - t0
        
        if response:
            all_content.append(response)
            code = extract_kotlin_code(response)
            if code: written_files[path] = code
            ok(f"{os.path.basename(path)} yaz\u0131ld\u0131 ({i+1}/{len(sorted_files)}) [{elapsed:.1f}s]")
            time.sleep(5)
        else:
            err(f"{os.path.basename(path)} yaz\u0131lamad\u0131! [{elapsed:.1f}s]")
    
    if not all_content:
        err("Hi\u00e7bir dosya yaz\u0131lamad\u0131!"); return 1
    
    all_content = detect_and_inject_deps(all_content)
    combined = "\n\n".join(all_content)
    
    import re as _re
    combined = _re.sub(r'auto_continue\s*:\s*true', 'auto_continue: false', combined)
    combined += "\n\nauto_continue: false\n"
    
    with open(args.output, 'w', encoding='utf-8') as f:
        f.write(combined)
    
    total_elapsed = time.time() - total_start
    ok(f"Orkestrat\u00f6r tamamland\u0131: {len(all_content)} dosya")
    log(f"Toplam: ~{combined.count(chr(10))} sat\u0131r, {len(combined)} karakter")
    log(f"API: 1 plan + {len(all_content)} dosya = {1+len(all_content)} \u00e7a\u011fr\u0131")
    log(f"\u23f1\ufe0f  Plan {faz1_end-total_start:.0f}s + Dosyalar {time.time()-faz2_start:.0f}s = Toplam {total_elapsed:.0f}s ({total_elapsed/60:.1f}dk)")
    return 0

if __name__ == "__main__":
    sys.exit(main())
