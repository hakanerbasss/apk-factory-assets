#!/data/data/com.termux/files/usr/bin/python3
"""APK Factory WS Bridge v11 — asyncio-native PTY (fork yok)"""
import asyncio, websockets, json, os, pty, signal, shutil, glob, re, subprocess, zipfile
from datetime import datetime

# --- BROKEN PIPE YÖNETİCİSİ ---
import sys, os
_old_excepthook = sys.excepthook
def _friendly_excepthook(exctype, value, traceback):
    if issubclass(exctype, BrokenPipeError):
        print("\nℹ️ [SİSTEM NOTU]: İhtiyaç olan veri başarıyla alındı. İhtiyaç fazlası akış (Broken Pipe) güvenle kesildi.", file=sys.stderr)
    else:
        _old_excepthook(exctype, value, traceback)
sys.excepthook = _friendly_excepthook

# Flush (çıktı boşaltma) sırasındaki kırılmaları kibarlaştırmak için:
if hasattr(sys.stdout, 'flush'):
    _orig_flush = sys.stdout.flush
    def _safe_flush():
        try:
            _orig_flush()
        except BrokenPipeError:
            print("\nℹ️ [SİSTEM NOTU]: İhtiyaç olan veri başarıyla alındı. İhtiyaç fazlası akış (Broken Pipe) güvenle kesildi.", file=sys.stderr)
            try:
                devnull = os.open(os.devnull, os.O_WRONLY)
                os.dup2(devnull, sys.stdout.fileno())
            except: pass
    sys.stdout.flush = _safe_flush
# ------------------------------

SISTEM_DIR    = "/storage/emulated/0/termux-otonom-sistem"
GITHUB_RAW    = "https://raw.githubusercontent.com/hakanerbasss/apk-factory-assets/main"
HOME          = os.path.expanduser("~")
PRJ_SH        = f"{SISTEM_DIR}/prj.sh"
KEYSTORE_DIR  = f"{SISTEM_DIR}/keystores"
BACKUP_DIR    = f"{SISTEM_DIR}/yedekler"
APILER_DIR    = f"{SISTEM_DIR}/apiler"
SETTINGS_FILE = f"{HOME}/.config/apkfactory.conf"
APK_OUT_DIR   = "/sdcard/Download/apk-cikti"
os.makedirs(APK_OUT_DIR, exist_ok=True)

ANSI = re.compile(rb'\x1b\[[0-9;]*[mKABCDEFGHJKSTfhilmnprsu]|\x1b\([AB]|\r')
def strip(b): return ANSI.sub(b'', b).decode('utf-8', errors='replace')

PROMPT_PATTERNS = [
    ("Kalıcı Yap / B=Yedeğe Dön",  "build_success"),
    ("Hata çözmeye devam et",       "build_failed"),
    ("Devam / İ=İptal",             "apply_changes"),
]
AUTO_ENTER = [
    "Seçim (", "Enter=", "Seçim yap (",
]
# factory.sh read promptları → otomatik cevap vereceğimiz pattern:key eşlemeleri
FACTORY_PROMPTS = [
    ("Proje Adı",           "_factory_name"),   # "Proje Adı (örn: ..."
    ("Yapay Zekaya Görevi", "_factory_task"),   # "Yapay Zekaya Görevi Ver..."
]

# ── Settings ──────────────────────────────────────────────────────────────────
def read_settings():
    d = {"DEFAULT_PROVIDER":"Claude","DEFAULT_MODEL":"claude-haiku-4-5-20251001",
         "MAX_LOOPS":"5","MAX_TOKENS":"8000","MAX_CHARS":"60000","KEYSTORE_PASS":"android123"}
    if not os.path.exists(SETTINGS_FILE): return d
    for line in open(SETTINGS_FILE):
        line = line.strip()
        if '=' in line and not line.startswith('#'):
            k, v = line.split('=', 1)
            d[k.strip()] = v.strip().strip('"').strip("'")
    return d

def save_settings(data):
    os.makedirs(os.path.dirname(SETTINGS_FILE), exist_ok=True)
    with open(SETTINGS_FILE, 'w') as f:
        f.writelines([f'{k}="{v}"\n' for k,v in data.items()])

    ac = f"{HOME}/.config/autofix.conf"
    os.makedirs(os.path.dirname(ac), exist_ok=True)
    ls = []
    if os.path.exists(ac):
        with open(ac, 'r') as f:
            ls = [l for l in f.readlines() if 'DEFAULT_PROVIDER=' not in l and 'MAX_LOOPS=' not in l and 'MAX_TOKENS=' not in l and 'MAX_CHARS=' not in l and 'SENIOR_PROVIDER=' not in l and 'SENIOR_MODEL=' not in l]
    
    ls += [f'DEFAULT_PROVIDER="{data.get("DEFAULT_PROVIDER","Claude")}"\n',
           f'MAX_LOOPS={data.get("MAX_LOOPS","5")}\n',
           f'MAX_TOKENS={data.get("MAX_TOKENS","8000")}\n',
           f'MAX_CHARS={data.get("MAX_CHARS","60000")}\n',
           f'SENIOR_PROVIDER="{data.get("SENIOR_PROVIDER","")}"\n',
           f'SENIOR_MODEL="{data.get("SENIOR_MODEL","")}"\n',
           f'UIX_PROVIDER="{data.get("UIX_PROVIDER","")}"\n',
           f'UIX_MODEL="{data.get("UIX_MODEL","")}"\n']
    
    with open(ac, 'w') as f:
        f.writelines(ls)

    prov_name = data.get("DEFAULT_PROVIDER","Claude").lower()
    cf = f"{APILER_DIR}/{prov_name}.conf"
    if os.path.exists(cf) and data.get("DEFAULT_MODEL"):
        # ÖNCE OKU (Hata buradaydı, çözüldü)
        with open(cf, 'r') as f:
            lines = f.readlines()
        
        # SONRA YAZ
        with open(cf, 'w') as f:
            for l in lines:
                if l.strip().startswith('MODEL='):
                    f.write(f'MODEL="{data["DEFAULT_MODEL"]}"\n')
                else:
                    f.write(l)

def read_projeler():
    conf = f"{SISTEM_DIR}/projeler.conf"
    if not os.path.exists(conf): return []
    res = []
    for line in open(conf):
        line = line.strip()
        if not line or line.startswith('#'): continue
        p = line.split('|')
        if len(p) >= 6 and p[0]:
            res.append({"name":p[0],"dir":p[1],"keystore":p[2],
                        "alias":p[3],"pass":p[4],"package":p[5]})
    return res

def get_proj_dir(name):
    for pr in read_projeler():
        if pr["name"] == name:
            return pr["dir"].replace("~", HOME)
    return f"{HOME}/{name}"

def read_api_key(path):
    try:
        for line in open(path):
            if line.strip().startswith('API_KEY='):
                return line[8:].strip().strip('"').strip("'")
    except: pass
    return ""


async def run_uix(ws, proj_name, proj_dir, complaint, start_fn=None):
    import urllib.request, urllib.error, base64, ssl, io
    import json as _j

    SDIR = "/storage/emulated/0/termux-otonom-sistem"
    HOME2 = os.path.expanduser("~")

    async def ul(msg):
        try: await ws.send(_j.dumps({"type":"log","text":msg}))
        except: pass

    try:
        # Config oku
        ac = f"{HOME2}/.config/autofix.conf"
        cfg = {"UIX_PROVIDER":"Claude","UIX_MODEL":"claude-sonnet-4-5-20251001"}
        if os.path.exists(ac):
            for line in open(ac):
                line=line.strip()
                if "=" in line and not line.startswith("#"):
                    k,v=line.split("=",1)
                    cfg[k.strip()]=v.strip().strip('"').strip("'")
        prov = cfg.get("UIX_PROVIDER","Claude").lower()
        model = cfg.get("UIX_MODEL","claude-sonnet-4-5-20251001")
        api_key = read_api_key(f"{SDIR}/apiler/{prov}.conf")
        if not api_key:
            await ul(f"❌ UIX: {prov} API key bulunamadı")
            await ws.send(_j.dumps({"type":"task_done","success":False,"text":f"❌ UIX: {prov} API key eksik"}))
            return
        await ul(f"🔑 UIX: {prov.title()} / {model}")

        # Resim
        img_b64 = ""
        img_path = f"{SDIR}/uix_referans.jpg"
        if os.path.exists(img_path):
            try:
                from PIL import Image as _IMG
                raw = open(img_path,"rb").read()
                img = _IMG.open(io.BytesIO(raw)).convert("RGB")
                w,h = img.size
                if max(w,h) > 1080:
                    r = 1080/max(w,h)
                    img = img.resize((int(w*r),int(h*r)),_IMG.LANCZOS)
                buf = io.BytesIO()
                img.save(buf,format="JPEG",quality=85)
                img_b64 = base64.b64encode(buf.getvalue()).decode()
                await ul(f"🖼️ Resim hazır ({len(img_b64)//1024}KB)")
            except Exception as ie:
                await ul(f"⚠️ Resim işlenemedi: {ie}")

        # Kodları topla
        SKIP_D = {"build",".gradle",".idea",".git","outputs","intermediates","tmp","__pycache__"}
        kodlar = ""
        for root,dirs,files in os.walk(proj_dir):
            dirs[:] = [d for d in dirs if d not in SKIP_D]
            for fname in files:
                if os.path.splitext(fname)[1].lower() not in (".kt",".xml"): continue
                rel = os.path.relpath(os.path.join(root,fname), proj_dir)
                try:
                    blk = f"\n--- Dosya: {rel} ---\n" + open(os.path.join(root,fname),encoding="utf-8",errors="replace").read() + "\n"
                    if len(kodlar)+len(blk) > 50000: kodlar += "\n--- [Limit: kalan atlandı] ---\n"; break
                    kodlar += blk
                except: pass
        await ul(f"📂 Kodlar toplandı ({len(kodlar)//1024}KB)")

        # Yedek al — autofix.sh ile aynı sistemi kullan (agent_yedekler + backup_map)
        AGENT_YEDEK_DIR = f"{SDIR}/agent_yedekler"
        BACKUP_MAP = f"{AGENT_YEDEK_DIR}/backup_map.txt"
        os.makedirs(AGENT_YEDEK_DIR, exist_ok=True)
        # Mevcut backup_map'i temizle (taze başlangıç)
        open(BACKUP_MAP, "w").write("")
        yedek_sayisi = 0
        for root, dirs, files in os.walk(proj_dir):
            dirs[:] = [d for d in dirs if d not in {"build",".gradle",".idea",".git","outputs","intermediates","tmp"}]
            for fname in files:
                if os.path.splitext(fname)[1].lower() not in (".kt", ".xml"): continue
                fpath = os.path.join(root, fname)
                rel = os.path.relpath(fpath, proj_dir)
                bak_name = rel.replace("/", "_") + ".bak_agent"
                bak_path = os.path.join(AGENT_YEDEK_DIR, bak_name)
                try:
                    import shutil as _sh
                    _sh.copy2(fpath, bak_path)
                    with open(BACKUP_MAP, "a") as bm:
                        bm.write(f"{fpath}|{bak_path}\n")
                    yedek_sayisi += 1
                except: pass
        await ul(f"💾 UIX yedek alındı: {yedek_sayisi} dosya → agent_yedekler/")

        # Prompt
        pf = f"{SDIR}/prompts/uix_system.txt"
        if os.path.exists(pf):
            sys_p = open(pf,encoding="utf-8",errors="replace").read().strip()
            await ul("📋 Özel UIX prompt yüklendi")
        else:
            sys_p = ("Sen kıdemli bir Android UI/UX uzmanısın (Jetpack Compose ve XML).\n"
                     "Görsel ve kod analizi yaparak sorunları düzelt.\n\n"
                     "ÇIKIŞ FORMATI:\nDosya: yol/dosya.kt\n```kotlin\n// kodun tamamı\n```")

        user_txt = f"Proje: {proj_name}\nŞikayet: {complaint}\n\nKodlar:\n{kodlar}"

        # API isteği
        ctx2 = ssl.create_default_context()
        ctx2.check_hostname = False; ctx2.verify_mode = ssl.CERT_NONE

        if prov == "claude":
            parts = []
            if img_b64: parts.append({"type":"image","source":{"type":"base64","media_type":"image/jpeg","data":img_b64}})
            parts.append({"type":"text","text":user_txt})
            payload = {"model":model,"max_tokens":8000,"system":sys_p,"messages":[{"role":"user","content":parts}]}
            req = urllib.request.Request("https://api.anthropic.com/v1/messages",
                data=_j.dumps(payload).encode(),
                headers={"x-api-key":api_key,"anthropic-version":"2023-06-01","content-type":"application/json"},
                method="POST")
        elif prov == "gemini":
            parts2 = []
            if img_b64: parts2.append({"inline_data":{"mime_type":"image/jpeg","data":img_b64}})
            parts2.append({"text":f"{sys_p}\n\n{user_txt}"})
            payload = {"contents":[{"parts":parts2}]}
            req = urllib.request.Request(
                f"https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent?key={api_key}",
                data=_j.dumps(payload).encode(),
                headers={"content-type":"application/json"}, method="POST")
        else:
            await ws.send(_j.dumps({"type":"task_done","success":False,"text":f"❌ UIX: Desteklenmeyen provider: {prov}"}))
            return

        await ul("⏳ Vision AI'ya gönderildi, yanıt bekleniyor...")
        def do_req():
            with urllib.request.urlopen(req, timeout=120, context=ctx2) as r:
                return _j.loads(r.read().decode())
        rj = await asyncio.to_thread(do_req)

        # Yanıt
        ai_txt = ""
        if prov == "claude":
            for b in rj.get("content",[]):
                if b.get("type")=="text": ai_txt += b.get("text","")
        elif prov == "gemini":
            for c in rj.get("candidates",[]):
                for p in c.get("content",{}).get("parts",[]):
                    ai_txt += p.get("text","")

        if not ai_txt.strip():
            await ws.send(_j.dumps({"type":"task_done","success":False,"text":"❌ UIX: Boş yanıt"}))
            return
        await ul(f"✅ Yanıt alındı ({len(ai_txt)} karakter)")

        # Dosyaları yaz
        import re as _re
        matches = list(_re.compile(r"Dosya:\s*([^\n`]+?)\s*\n```[a-zA-Z]*\n(.*?)```", _re.DOTALL).finditer(ai_txt))
        if not matches:
            await ul("⚠️ Dosya bloğu bulunamadı:\n" + ai_txt[:500])
            await ws.send(_j.dumps({"type":"task_done","success":False,"text":"⚠️ UIX: AI yanıtında dosya bloğu yok"}))
            return

        yazilan = 0
        for m in matches:
            rel = m.group(1).strip()
            code = m.group(2)
            abs_p = os.path.join(proj_dir, rel)
            try:
                os.makedirs(os.path.dirname(abs_p), exist_ok=True)
                open(abs_p,"w",encoding="utf-8").write(code)
                await ul(f"✏️ Güncellendi: {rel}")
                yazilan += 1
            except Exception as we:
                await ul(f"❌ Yazma hatası [{rel}]: {we}")

        if yazilan == 0:
            await ws.send(_j.dumps({"type":"task_done","success":False,"text":"❌ UIX: Hiçbir dosya yazılamadı"}))
            return

        await ul(f"📝 {yazilan} dosya güncellendi — AutoFix başlatılıyor...")
        PRJ_SH2 = f"{SDIR}/prj.sh"
        if start_fn:
            # PTY üzerinden prj e → AutoFix döngüsü devreye girer, loglar ekrana gelir
            async def uix_done(rc, _pn=proj_name, _pd=proj_dir):
                apk = copy_apk(_pd, _pn) if rc == 0 else None
                await ws.send(_j.dumps({"type":"task_done","success":rc==0,
                    "text":"✅ UIX tamamlandı!" if rc==0 else "❌ UIX Build başarısız",
                    "apk_path":apk or "","project":_pn}))
            # Görevi dosyaya yaz, bash escape sorununu önle
            degisen = ", ".join([m.group(1).strip() for m in matches])
            uix_task = (
                f"UIX modeli az önce şu dosyaları güncelledi: {degisen}. "
                f"Kullanici sikayeti: {complaint}. "
                f"Build hatasi oluştuysa SADECE o hatayı düzelt, "
                f"UIX degisikliklerini silme veya geri alma. "
                f"Eksik bagimlilik varsa app/build.gradle'a ekle."
            )
            uix_task_file = f"{SDIR}/_uix_task.txt"
            open(uix_task_file, "w", encoding="utf-8").write(uix_task)
            await start_fn(f"bash {PRJ_SH2} ef '{uix_task_file}'", proj_dir, uix_done)
        else:
            # start_fn yoksa eski yöntem
            proc = await asyncio.create_subprocess_shell(f"bash {PRJ_SH2} d", cwd=proj_dir,
                stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.STDOUT)
            while True:
                lb = await proc.stdout.readline()
                if not lb: break
                try: await ws.send(_j.dumps({"type":"log","text":lb.decode("utf-8",errors="replace").rstrip()}))
                except: break
            await proc.wait()
            rc = proc.returncode or 0
            apk = copy_apk(proj_dir, proj_name) if rc == 0 else None
            await ws.send(_j.dumps({"type":"task_done","success":rc==0,
                "text":"✅ UIX tamamlandı!" if rc==0 else "❌ UIX Build başarısız",
                "apk_path":apk or "","project":proj_name}))

    except urllib.error.HTTPError as he:
        body = he.read().decode(errors="replace")
        await ul(f"❌ API HTTP {he.code}: {body[:300]}")
        await ws.send(_j.dumps({"type":"task_done","success":False,"text":f"❌ UIX API hatası: HTTP {he.code}"}))
    except Exception as ex:
        import traceback
        await ul(f"❌ UIX hata: {ex}\n{traceback.format_exc()[:400]}")
        await ws.send(_j.dumps({"type":"task_done","success":False,"text":f"❌ UIX: {ex}"}))

def copy_apk(proj_dir, proj_name):
    candidates = [
        (f"{proj_dir}/app/build/outputs/apk/debug/app-debug.apk",           "apk"),
        (f"{proj_dir}/app/build/outputs/apk/release/app-release.apk",        "apk"),
        (f"{proj_dir}/app/build/outputs/bundle/release/app-release.aab",      "aab"),
    ]
    for p, ext in candidates:
        if os.path.exists(p):
            ts  = datetime.now().strftime("%Y%m%d-%H%M%S")
            dst = f"{APK_OUT_DIR}/{proj_name}-{ts}.{ext}"
            shutil.copy2(p, dst); return dst
    return None

def list_apks(project=""):
    if not os.path.exists(APK_OUT_DIR): return []
    res = []
    for f in sorted(os.listdir(APK_OUT_DIR), reverse=True):
        ext = f.rsplit('.', 1)[-1] if '.' in f else ''
        if ext not in ('apk', 'aab'): continue
        if project and not f.startswith(project): continue
        path = f"{APK_OUT_DIR}/{f}"; st = os.stat(path)
        proj = f.split('-202')[0] if '-202' in f else f.rsplit('.', 1)[0]
        res.append({"name":f,"project":proj,"path":path,"size":st.st_size,
                    "type": ext,
                    "date":(lambda m: datetime.strptime(m.group(1), "%Y%m%d-%H%M%S").strftime("%d.%m.%Y %H:%M:%S") if m else datetime.fromtimestamp(st.st_mtime).strftime("%d.%m.%Y %H:%M:%S"))(__import__("re").search(r"-(202\d{5}-\d{6})", f))})
    return res

# ── PTY runner (asyncio-native, fork yok) ─────────────────────────────────────
async def pty_run(cmd, cwd, ws, state, on_done):
    loop      = asyncio.get_event_loop()
    master, slave = pty.openpty()

    proc = await asyncio.create_subprocess_exec(
        "bash", "-c", cmd,
        stdin=slave, stdout=slave, stderr=slave,
        close_fds=True, cwd=cwd,
        preexec_fn=os.setsid
    )
    os.close(slave)
    state["proc"]   = proc
    state["master"] = master

    buf        = b""
    last_line  = ""
    data_q     = asyncio.Queue()

    def reader_cb():
        try:
            chunk = os.read(master, 8192)
            data_q.put_nowait(chunk)
        except OSError:
            data_q.put_nowait(None)   # EOF

    loop.add_reader(master, reader_cb)

    async def send_log(text):
        nonlocal last_line
        text = text.strip()
        if text and text != last_line:
            last_line = text
            try:
                if text.startswith("POSTA_ICERIGI:"):
                    posta = text[len("POSTA_ICERIGI:"):]
                    await ws.send(json.dumps({"type":"log","text":f"📬 Posta: {posta[:100]}..."}))
                elif text.startswith("USER_ACTION_REQUIRED:"):
                    action = text[len("USER_ACTION_REQUIRED:"):]
                    await ws.send(json.dumps({"type":"log","text":f"⚠️ KULLANICI AKSİYONU:\n{action}"}))
                else:
                    await ws.send(json.dumps({"type":"log","text":text}))
            except: return False
        return True

    try:
        while True:
            # Kill isteği kontrol et
            if state.get("kill_req"):
                break

            try:
                chunk = await asyncio.wait_for(data_q.get(), timeout=0.1)
            except asyncio.TimeoutError:
                # Process bitti mi?
                if proc.returncode is not None:
                    break
                continue

            if chunk is None:
                break   # EOF

            buf += chunk

            # Tam satırları işle
            while b'\n' in buf:
                idx  = buf.index(b'\n')
                line = strip(buf[:idx])
                buf  = buf[idx+1:]
                if not await send_log(line):
                    break

            # Prompt tespiti — satır sonu gelmeden bekleyen metinler
            partial = strip(buf)
            if partial:
                # factory.sh proje adı / görev okuma → state'den otomatik cevap ver
                factory_ans = None
                for pat, key in FACTORY_PROMPTS:
                    if pat in partial and key in state:
                        factory_ans = state.pop(key)   # bir kez kullan
                        break
                # "→ " = AI görevi satırı (state'de yoksa default kullan)
                if factory_ans is None and partial.strip().endswith("→") and "_factory_task_default" in state:
                    factory_ans = state.pop("_factory_task_default")
                if factory_ans is not None:
                    try: await ws.send(json.dumps({"type":"log","text":f"→ {factory_ans[:40]}..."}))
                    except: pass
                    await asyncio.sleep(0.2)
                    os.write(master, (factory_ans + "\n").encode())
                    buf = b""
                    continue

                # Otomatik Enter (provider/model seçimi)
                if any(p in partial for p in AUTO_ENTER):
                    await asyncio.sleep(0.3)
                    os.write(master, b"\n")
                    buf = b""
                    continue

                # Kullanıcı kararı gerekiyor
                ptype = None
                for pat, pt in PROMPT_PATTERNS:
                    if pat in partial:
                        ptype = pt; break

                if ptype and not state.get("waiting_prompt"):
                    # Prompt satırını log olarak gönder
                    await send_log(partial)
                    buf = b""

                    # Auto mode: build_failed veya apply_changes → otomatik cevapla
                    if state.get("auto_mode") and ptype in ("build_failed", "apply_changes"):
                        auto_ans = "" # Enter = devam et
                        await send_log("⚡ Otomatik devam ediyor...")
                        os.write(master, (auto_ans + "\n").encode())
                        continue
                    # build_success → auto_mode'u kapat, kullanıcı karar versin
                    if ptype == "build_success":
                        state["auto_mode"] = False

                    # Kullanıcıya sor — son hata mesajlarını da gönder
                    state["waiting_prompt"] = ptype
                    state["answer_event"]   = asyncio.Event()
                    last_error = state.get("last_error_msg", "")
                    try: await ws.send(json.dumps({
                        "type":"prompt",
                        "prompt_type":ptype,
                        "error_msg": last_error
                    }))
                    except: break

                    # Cevap bekle
                    while not state["answer_event"].is_set():
                        if state.get("kill_req"): break
                        await asyncio.sleep(0.05)

                    if state.get("kill_req"): break

                    ans = state.pop("prompt_answer", "")
                    state.pop("waiting_prompt", None)
                    state.pop("answer_event", None)
                    os.write(master, (ans + "\n").encode())

    except Exception as e:
        try: await ws.send(json.dumps({"type":"log","text":f"[bridge: {e}]"}))
        except: pass
    finally:
        loop.remove_reader(master)
        try: os.close(master)
        except: pass

    # Kill
    if state.get("kill_req"):
        state["kill_req"] = False
        try: os.killpg(os.getpgid(proc.pid), signal.SIGTERM)
        except: pass
        try: proc.kill()
        except: pass

    # Kalan buffer
    if buf:
        await send_log(strip(buf))

    try: await proc.wait()
    except: pass

    state.pop("proc", None); state.pop("master", None)
    state.pop("waiting_prompt", None); state.pop("answer_event", None)
    await on_done(proc.returncode or 0)

# ── WebSocket handler ──────────────────────────────────────────────────────────
async def handle(ws):
    state   = {}
    running = {"task": None}

    async def start(cmd, cwd, done_cb):
        if running["task"] and not running["task"].done():
            running["task"].cancel()
            await asyncio.sleep(0.3)
        running["task"] = asyncio.create_task(pty_run(cmd, cwd, ws, state, done_cb))

    try:
        await ws.send(json.dumps({"type":"connected","text":"APK Factory v11 hazır 🚀"}))

        async for msg in ws:
            try:
                d = json.loads(msg); t = d.get("type","")

                if t == "ping":
                    await ws.send(json.dumps({"type":"pong"}))

                elif t == "kill_process":
                    state["kill_req"] = True
                    # Önce event'i serbest bırak (prompt bekliyorsa)
                    ev = state.get("answer_event")
                    if ev: ev.set()
                    # PTY'ye Ctrl+C gönder (SIGINT)
                    m = state.get("master")
                    if m:
                        try: os.write(m, b"\x03")  # Ctrl+C
                        except: pass
                    # Process'i kill et
                    proc = state.get("proc")
                    if proc:
                        try:
                            pgid = os.getpgid(proc.pid)
                            os.killpg(pgid, signal.SIGTERM)
                            await asyncio.sleep(0.3)
                            os.killpg(pgid, signal.SIGKILL)
                        except: pass
                        try: proc.kill()
                        except: pass
                    # Tüm ilgili processleri temizle (gradle daemon vs)
                    try:
                        subprocess.run(["pkill", "-9", "-f", "gradlew"], capture_output=True)
                        subprocess.run(["pkill", "-9", "-f", "GradleDaemon"], capture_output=True)
                    except: pass
                    await ws.send(json.dumps({"type":"task_done","success":False,"text":"⏹ Durduruldu"}))

                elif t == "set_auto_mode":
                    state["auto_mode"] = d.get("enabled", False)
                    # autofix.conf'a yaz — autofix.sh okusun
                    conf_dir = os.path.join(HOME, ".config")
                    os.makedirs(conf_dir, exist_ok=True)
                    conf_file = os.path.join(conf_dir, "autofix.conf")
                    val = "1" if state["auto_mode"] else "0"
                    lines = open(conf_file).readlines() if os.path.exists(conf_file) else []
                    lines = [l for l in lines if not l.startswith("AUTO_CONFIRM=")]
                    lines.append(f"AUTO_CONFIRM={val}\n")
                    open(conf_file, "w").writelines(lines)
                    await ws.send(json.dumps({"type":"status",
                        "text": "⚡ Otomatik devam açık — tüm denemeler otomatik" if state["auto_mode"] else "⏸ Manuel mod"}))

                elif t == "send_input":
                    ev = state.get("answer_event")
                    if ev and state.get("waiting_prompt"):
                        state["prompt_answer"] = d.get("text","")
                        ev.set()
                    else:
                        m = state.get("master")
                        if m:
                            try: os.write(m, (d.get("text","") + "\n").encode())
                            except: pass

                elif t == "list_projects":
                    logos_dir = f"{SISTEM_DIR}/logos"
                    os.makedirs(logos_dir, exist_ok=True)
                    prs = read_projeler()
                    for pr in prs:
                        src = os.path.expanduser(f"~/{pr['name']}/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png")
                        dst = f"{logos_dir}/{pr['name']}.png"
                        if os.path.exists(src):
                            import shutil
                            shutil.copy2(src, dst)
                    await ws.send(json.dumps({"type":"projects","data":prs}))

                elif t == "delete_project":
                    pname = d.get("project","")
                    proj_dir = get_proj_dir(pname)
                    import shutil as _shutil
                    # Conf'dan sil ve keystore bul
                    conf = f"{SISTEM_DIR}/projeler.conf"
                    ks_file = ""
                    if os.path.exists(conf):
                        lines_all = open(conf).readlines()
                        for l in lines_all:
                            if l.startswith(pname + "|"):
                                parts = l.strip().split("|")
                                if len(parts) > 2: ks_file = parts[2]
                        lines = [l for l in lines_all if not l.startswith(pname + "|")]
                        open(conf,'w').writelines(lines)
                    # Keystore sil
                    if ks_file:
                        for ks_dir in [KEYSTORE_DIR, "/sdcard/Download"]:
                            ks_path = os.path.join(ks_dir, ks_file)
                            if os.path.exists(ks_path):
                                try: os.remove(ks_path)
                                except: pass
                    # Klasörü sil
                    try:
                        if os.path.exists(proj_dir):
                            _shutil.rmtree(proj_dir)
                        await ws.send(json.dumps({"type":"task_done","success":True,"text":f"🗑 {pname} silindi"}))
                    except Exception as e:
                        await ws.send(json.dumps({"type":"task_done","success":False,"text":f"❌ Silinemedi: {e}"}))

                elif t == "clone_project":
                    old_name = d.get("old_name","")
                    new_name = d.get("new_name","").strip()
                    if not new_name:
                        await ws.send(json.dumps({"type":"error","text":"Yeni isim boş olamaz"})); continue
                    old_dir = get_proj_dir(old_name)
                    new_dir = os.path.join(HOME, new_name)
                    
                    try:
                        if not os.path.exists(old_dir):
                            await ws.send(json.dumps({"type":"error","text":f"Kaynak proje bulunamadı: {old_name}"}))
                            continue
                        if os.path.exists(new_dir):
                            await ws.send(json.dumps({"type":"error","text":f"Bu isimde bir proje zaten var: {new_name}"}))
                            continue

                        await ws.send(json.dumps({"type":"status","text":f"⏳ {new_name} klonlanıyor..."}))

                        # 1. KLASÖRÜ KOPYALA
                        import shutil
                        shutil.copytree(old_dir, new_dir)

                        # 2a. MANIFEST LABEL GÜNCELLE
                        manifest_path = os.path.join(new_dir, "app/src/main/AndroidManifest.xml")
                        if os.path.exists(manifest_path):
                            with open(manifest_path, "r") as f:
                                manifest = f.read()
                            manifest = manifest.replace(f'android:label="{old_name}"', f'android:label="{new_name}"')
                            with open(manifest_path, "w") as f:
                                f.write(manifest)

                        # 2. SETTINGS.GRADLE İSMİNİ GÜNCELLE
                        settings_path = os.path.join(new_dir, "settings.gradle")
                        if os.path.exists(settings_path):
                            with open(settings_path, "r", encoding="utf-8") as f:
                                settings_content = f.read()
                            settings_content = settings_content.replace(f'rootProject.name = "{old_name}"', f'rootProject.name = "{new_name}"')
                            with open(settings_path, "w", encoding="utf-8") as f:
                                f.write(settings_content)

                        # 3. YENİ KEYSTORE ÜRET
                        conf_path = f"{SISTEM_DIR}/projeler.conf"
                        keystore_dir = f"{SISTEM_DIR}/keystores"
                        import string
                        import random
                        
                        ks_pass = ''.join(random.choices(string.ascii_letters + string.digits, k=12))
                        ks_alias = new_name.replace('-', '')[:12]
                        if not ks_alias.isalpha():
                            ks_alias = "app" + ks_alias
                        ks_file = f"{new_name}-release.keystore"
                        ks_full_path = os.path.join(keystore_dir, ks_file)

                        old_pkg = ""
                        if os.path.exists(conf_path):
                            with open(conf_path, "r", encoding="utf-8") as f:
                                lines = f.readlines()
                            for line in lines:
                                parts = line.strip().split('|')
                                if parts[0] == old_name and len(parts) >= 6:
                                    old_pkg = parts[5].strip()
                                    break
                        
                        # Yeni paket adı her zaman yeni isimden üretilir
                        new_pkg = f"com.wizaicorp.{new_name.replace('-', '_')}"

                        # Paket klasörünü yeniden düzenle
                        old_pkg_path = old_pkg.replace(".", "/") if old_pkg else ""
                        new_pkg_path = new_pkg.replace(".", "/")
                        old_java = os.path.join(new_dir, "app/src/main/java", old_pkg_path)
                        new_java = os.path.join(new_dir, "app/src/main/java", new_pkg_path)
                        if old_pkg_path and old_pkg_path != new_pkg_path and os.path.exists(old_java):
                            os.makedirs(os.path.dirname(new_java), exist_ok=True)
                            import shutil as _sh
                            _sh.copytree(old_java, new_java)
                            _sh.rmtree(old_java)
                            # KT dosyalarında paket adını güncelle
                            import glob as _gl
                            for kt in _gl.glob(os.path.join(new_java, "**/*.kt"), recursive=True):
                                txt = open(kt).read()
                                txt = txt.replace(f"package {old_pkg}", f"package {new_pkg}")
                                txt = txt.replace(f"import {old_pkg}.", f"import {new_pkg}.")
                                open(kt, 'w').write(txt)
                            # build.gradle namespace güncelle
                            bg = os.path.join(new_dir, "app/build.gradle")
                            if os.path.exists(bg):
                                txt = open(bg).read().replace(old_pkg, new_pkg)
                                open(bg, 'w').write(txt)
                            # Manifest güncelle
                            mf = os.path.join(new_dir, "app/src/main/AndroidManifest.xml")
                            if os.path.exists(mf):
                                txt = open(mf).read().replace(old_pkg, new_pkg)
                                open(mf, 'w').write(txt)

                        dname = f"CN={new_name}, OU=AI, O=AI, L=IST, S=IST, C=TR"
                        os.system(f'keytool -genkeypair -keystore "{ks_full_path}" -alias "{ks_alias}" -keyalg RSA -keysize 2048 -validity 10000 -storepass "{ks_pass}" -keypass "{ks_pass}" -dname "{dname}" 2>/dev/null')

                        # 4. PROJELER.CONF'A YENİ SATIR OLARAK EKLE
                        if os.path.exists(conf_path):
                            with open(conf_path, "a", encoding="utf-8") as f:
                                f.write(f"{new_name}|~/{new_name}|{ks_file}|{ks_alias}|{ks_pass}|{new_pkg}\n")

                        # İşlem bitti!
                        await ws.send(json.dumps({"type":"task_done","success":True,"text":f"✅ {old_name} başarıyla klonlandı!"}))

                    except Exception as e:
                        await ws.send(json.dumps({"type":"error","text":f"Klonlama Hatası: {str(e)}"}))


                elif t == "save_logo":
                    pname   = d.get("project","")
                    b64data = d.get("data","")
                    proj_dir = get_proj_dir(pname)
                    try:
                        import base64 as _b64
                        from PIL import Image
                        import io as _io
                        img_bytes = _b64.b64decode(b64data)
                        img = Image.open(_io.BytesIO(img_bytes)).convert("RGBA")
                        sizes = {"mdpi":48,"hdpi":72,"xhdpi":96,"xxhdpi":144,"xxxhdpi":192}
                        res_dir = os.path.join(proj_dir, "app/src/main/res")
                        for dpi, px in sizes.items():
                            out_dir = os.path.join(res_dir, f"mipmap-{dpi}")
                            os.makedirs(out_dir, exist_ok=True)
                            resized = img.resize((px, px), Image.LANCZOS)
                            resized.save(os.path.join(out_dir, "ic_launcher.png"))
                            resized.save(os.path.join(out_dir, "ic_launcher_round.png"))
                        # Build cache + gradle cache temizle
                        import shutil as _su2
                        for _cd in ["app/build", ".gradle"]:
                            _d = os.path.join(proj_dir, _cd)
                            if os.path.exists(_d): _su2.rmtree(_d)
                        # Manifest'te icon yoksa ekle
                        manifest_path = os.path.join(proj_dir, "app/src/main/AndroidManifest.xml")
                        if os.path.exists(manifest_path):
                            with open(manifest_path) as mf:
                                manifest = mf.read()
                            if 'android:icon' not in manifest:
                                manifest = manifest.replace(
                                    '<application android:allowBackup="true"',
                                    '<application android:icon="@mipmap/ic_launcher" android:roundIcon="@mipmap/ic_launcher_round" android:allowBackup="true"'
                                )
                                with open(manifest_path, 'w') as mf:
                                    mf.write(manifest)
                        await ws.send(json.dumps({"type":"task_done","success":True,"text":"✅ Logo güncellendi (cache temizlendi, build alabilirsin)"}))
                    except ImportError:
                        await ws.send(json.dumps({"type":"error","text":"❌ Pillow kurulu değil: pip install Pillow"}))
                    except Exception as e:
                        await ws.send(json.dumps({"type":"error","text":f"❌ Logo kaydedilemedi: {e}"}))

                elif t == "autofix":
                    p = d.get("project",""); pd = get_proj_dir(p)
                    await ws.send(json.dumps({"type":"status","text":f"🤖 prj af: {p}"}))
                    async def af_done(rc, _p=p, _pd=pd):
                        apk = copy_apk(_pd, _p) if rc == 0 else None
                        await ws.send(json.dumps({"type":"task_done","success":rc==0,
                            "text":"✅ AutoFix tamamlandı!" if rc==0 else "❌ AutoFix başarısız",
                            "apk_path":apk or ""}))
                    await start(f"bash {PRJ_SH} af", pd, af_done)

                elif t == "add_admob":
                    p       = d.get("project","")
                    app_id  = d.get("app_id","ca-app-pub-3940256099942544~3347511713")
                    unit_id = d.get("unit_id","ca-app-pub-3940256099942544/1033173712")
                    script  = f"{SISTEM_DIR}/admob_ekle.sh"
                    # Script yoksa GitHub'dan indir
                    if not os.path.exists(script):
                        import urllib.request
                        try:
                            urllib.request.urlretrieve(f"{GITHUB_RAW}/scripts/admob_ekle.sh", script)
                            os.chmod(script, 0o755)
                            await ws.send(json.dumps({"type":"status","text":"📥 admob_ekle.sh indirildi"}))
                        except Exception as ex:
                            await ws.send(json.dumps({"type":"error","text":f"❌ Script indirilemedi: {ex}"}))
                            continue
                    cmd     = f"bash '{script}' '{p}' '{app_id}' '{unit_id}'"
                    await ws.send(json.dumps({"type":"status","text":f"💰 AdMob enjekte ediliyor: {p}"}))
                    async def admob_done(rc):
                        await ws.send(json.dumps({"type":"task_done","success":rc==0,
                            "text":"✅ AdMob eklendi! Build alabilirsin." if rc==0 else "❌ AdMob eklenemedi",
                            "project":p}))
                    await start(cmd, get_proj_dir(p), admob_done)

                elif t == "add_admob_old":  # devre disi
                    p       = d.get("project","")
                    app_id  = d.get("app_id","ca-app-pub-3940256099942544~3347511713")
                    unit_id = d.get("unit_id","ca-app-pub-3940256099942544/1033173712")
                    proj_dir = get_proj_dir(p)
                    result = []
                    errors = []

                    try:
                        # 1. build.gradle - play-services-ads ekle
                        gradle = os.path.join(proj_dir, "app/build.gradle")
                        if os.path.exists(gradle):
                            g = open(gradle).read()
                            if "play-services-ads" not in g:
                                g = g.replace("dependencies {", "dependencies {\n    implementation 'com.google.android.gms:play-services-ads:22.6.0'")
                                open(gradle,'w').write(g)
                                result.append("✅ build.gradle: play-services-ads eklendi")
                            else:
                                result.append("ℹ️ build.gradle: play-services-ads zaten var")
                        else:
                            errors.append("❌ build.gradle bulunamadı")

                        # 2. AndroidManifest.xml - App ID meta-data ekle
                        manifest = os.path.join(proj_dir, "app/src/main/AndroidManifest.xml")
                        if os.path.exists(manifest):
                            m = open(manifest).read()
                            if "com.google.android.gms.ads.APPLICATION_ID" not in m:
                                meta = f'\n        <meta-data android:name="com.google.android.gms.ads.APPLICATION_ID" android:value="{app_id}"/>'
                                m = m.replace("<application", "<uses-permission android:name=\"android.permission.INTERNET\" />\n    <application", 1) if "INTERNET" not in m else m
                                m = m.replace("</application>", meta + "\n    </application>")
                                open(manifest,'w').write(m)
                                result.append("✅ AndroidManifest: App ID eklendi")
                            else:
                                # Güncelle
                                import re as _re
                                m = _re.sub(r'android:value="ca-app-pub-[^"]*"(\s*/?>)', f'android:value="{app_id}"\1', m)
                                open(manifest,'w').write(m)
                                result.append("ℹ️ AndroidManifest: App ID güncellendi")
                        else:
                            errors.append("❌ AndroidManifest bulunamadı")

                        # 3. MainActivity.kt - interstitial kodu ekle
                        import glob as _glob
                        kt_files = _glob.glob(os.path.join(proj_dir, "app/src/main/java/**/*.kt"), recursive=True)
                        main_kt = next((f for f in kt_files if "MainActivity" in f), None)

                        # AdMobManager.kt oluştur
                        admob_manager_kt = os.path.join(proj_dir, "app/src/main/java") 
                        # Paket klasörünü bul
                        kt_files2 = _glob.glob(os.path.join(proj_dir, "app/src/main/java/**/*.kt"), recursive=True)
                        if kt_files2:
                            pkg_dir = os.path.dirname(kt_files2[0])
                            admob_kt_path = os.path.join(pkg_dir, "AdMobManager.kt")
                            # Paketi bul
                            pkg_line = next((l for l in open(kt_files2[0]).readlines() if l.startswith("package ")), "package com.example.app")
                            pkg_name = pkg_line.strip().replace("package ","")
                            
                            admob_kt_content = f"""package {pkg_name}

import android.app.Activity
import android.app.Application
import android.os.Bundle
import com.google.android.gms.ads.AdRequest
import com.google.android.gms.ads.LoadAdError
import com.google.android.gms.ads.interstitial.InterstitialAd
import com.google.android.gms.ads.interstitial.InterstitialAdLoadCallback

class AdMobManager : Application.ActivityLifecycleCallbacks {{

    private var mInterstitialAd: InterstitialAd? = null
    private var isAdShown = false
    private var currentActivity: Activity? = null
    private var isLoading = false

    fun init(application: Application) {{
        application.registerActivityLifecycleCallbacks(this)
        loadAd(application)
    }}

    private fun loadAd(application: Application) {{
        if (isLoading) return
        isLoading = true
        val adRequest = AdRequest.Builder().build()
        InterstitialAd.load(application, "{unit_id}", adRequest,
            object : InterstitialAdLoadCallback() {{
                override fun onAdLoaded(ad: InterstitialAd) {{
                    mInterstitialAd = ad; isLoading = false
                    currentActivity?.let {{ act -> if (!isAdShown) {{ ad.show(act); isAdShown = true; mInterstitialAd = null }} }}
                }}
                override fun onAdFailedToLoad(e: LoadAdError) {{
                    mInterstitialAd = null; isLoading = false
                }}
            }})
    }}

    override fun onActivityResumed(activity: Activity) {{
        currentActivity = activity
        if (mInterstitialAd != null && !isAdShown) {{
            mInterstitialAd!!.show(activity)
            isAdShown = true
        }}
    }}

    override fun onActivityCreated(activity: Activity, savedInstanceState: Bundle?) {{}}
    override fun onActivityPaused(activity: Activity) {{ currentActivity = null }}
    override fun onActivityStarted(activity: Activity) {{}}
    override fun onActivityStopped(activity: Activity) {{}}
    override fun onActivitySaveInstanceState(activity: Activity, outState: Bundle) {{}}
    override fun onActivityDestroyed(activity: Activity) {{}}
}}
"""
                            open(admob_kt_path, 'w').write(admob_kt_content)
                            result.append("✅ AdMobManager.kt oluşturuldu")

                            # App.kt oluştur veya güncelle
                            app_kt_path = os.path.join(pkg_dir, "App.kt")
                            if os.path.exists(app_kt_path):
                                app_kt = open(app_kt_path).read()
                                if "AdMobManager" not in app_kt:
                                    app_kt = app_kt.replace(
                                        "super.onCreate()",
                                        "super.onCreate()\n        AdMobManager().init(this)"
                                    )
                                    open(app_kt_path, 'w').write(app_kt)
                                    result.append("✅ App.kt güncellendi")
                            else:
                                app_kt_content = f"""package {pkg_name}

import android.app.Application
import com.google.android.gms.ads.MobileAds

class App : Application() {{
    override fun onCreate() {{
        super.onCreate()
        MobileAds.initialize(this) {{}}
        AdMobManager().init(this)
    }}
}}
"""
                                open(app_kt_path, 'w').write(app_kt_content)
                                result.append("✅ App.kt oluşturuldu")

                            # Manifest'e android:name=".App" ekle
                            if os.path.exists(manifest):
                                m = open(manifest).read()
                                if 'android:name=' not in m:
                                    m = m.replace('<application android:allowBackup',
                                                  '<application android:name=".App" android:allowBackup')
                                    open(manifest, 'w').write(m)
                                    result.append("✅ Manifest: App sınıfı eklendi")

                        if main_kt:
                            kt = open(main_kt).read()
                            # Format kontrolü
                            if "ComponentActivity" not in kt and "AppCompatActivity" not in kt:
                                errors.append("⚠️ Uyumsuz format: MainActivity ComponentActivity veya AppCompatActivity kullanmıyor. Interstitial eklenemedi.")
                            elif "MobileAds" in kt or "loadInterstitialAd" in kt:
                                result.append("ℹ️ MainActivity: Eski kod var, temizlendi")
                                result.append("ℹ️ MainActivity: Eski kod var, temizlendi")
                            else:
                                result.append("✅ MainActivity: AdMobManager kullanılıyor")
                        else:
                            errors.append("❌ MainActivity.kt bulunamadı")

                        all_msgs = result + errors
                        success = len(errors) == 0
                        await ws.send(json.dumps({"type":"task_done","success":success,
                            "text":"\n".join(all_msgs),"project":p}))

                    except Exception as ex:
                        await ws.send(json.dumps({"type":"error","text":f"AdMob hata: {ex}"}))

                elif t == "check_chain_task":
                    p = d.get("project","")
                    pkg = ""
                    for pr in read_projeler():
                        if pr["name"] == p:
                            pkg = pr.get("package", p)
                            break
                            
                    found_task = ""
                    for cf in [f"{SISTEM_DIR}/next_task_{pkg}.txt" if pkg else "", f"{SISTEM_DIR}/next_task_{p}.txt", f"{SISTEM_DIR}/next_task.txt", f"{SISTEM_DIR}/chain_task.txt"]:
                        if cf and os.path.exists(cf):
                            found_task = open(cf).read().strip()
                            if found_task: break
                            
                    await ws.send(json.dumps({"type":"chain_task","task":found_task,"project":p}))

                elif t == "restore_agent_backups":
                    SDIR2 = "/storage/emulated/0/termux-otonom-sistem"
                    bmap  = f"{SDIR2}/agent_yedekler/backup_map.txt"
                    restored = 0; errors = []
                    if os.path.exists(bmap):
                        for line in open(bmap):
                            line = line.strip()
                            if "|" not in line: continue
                            orig, bak = line.split("|", 1)
                            if os.path.exists(bak):
                                try:
                                    os.makedirs(os.path.dirname(orig), exist_ok=True)
                                    import shutil as _sh2; _sh2.copy2(bak, orig); restored += 1
                                except Exception as re: errors.append(str(re))
                        open(bmap, "w").write("")
                    if errors:
                        await ws.send(json.dumps({"type":"task_done","success":False,
                            "text":f"⚠️ {restored} dosya geri yüklendi, {len(errors)} hata"}))
                    else:
                        await ws.send(json.dumps({"type":"task_done","success":True,
                            "text":f"↩ Yedeğe dönüldü ({restored} dosya)"}))

                elif t == "delete_chain_task":
                    import glob as _g
                    for cf in _g.glob(f"{SISTEM_DIR}/next_task*.txt") + [f"{SISTEM_DIR}/chain_task.txt"]:
                        try: os.remove(cf)
                        except: pass
                    await ws.send(json.dumps({"type":"task_done","success":True,"text":"🗑 Bekleyen görev silindi"}))

                elif t == "check_next_task":
                    p = d.get("project","")
                    ntf1 = f"{SISTEM_DIR}/next_task_{p}.txt"
                    ntf2 = f"{SISTEM_DIR}/next_task.txt"
                    ntf3 = f"{SISTEM_DIR}/chain_task.txt"
                    ntf = ntf1 if os.path.exists(ntf1) else (ntf2 if os.path.exists(ntf2) else ntf3)
                    if os.path.exists(ntf):
                        nt = open(ntf).read().strip(); os.remove(ntf)
                        await ws.send(json.dumps({"type":"next_task","task":nt,"project":p}))
                    else:
                        await ws.send(json.dumps({"type":"next_task","task":"","project":p}))

                elif t == "task":
                    _raw = d.get("task","")
                    if _raw.strip().upper().startswith("[UIX_MODE]"):
                        _complaint = _raw.strip()[len("[UIX_MODE]"):].strip()
                        _pd2 = get_proj_dir(d.get("project",""))
                        await ws.send(json.dumps({"type":"status","text":"👁️ UIX Modu — Vision AI başlatılıyor..."}))
                        asyncio.create_task(run_uix(ws, d.get("project",""), _pd2, _complaint, start))
                        continue
                    else:
                        p    = d.get("project","")
                        task = d.get("task","").replace("'","'\\''")
                        pd   = get_proj_dir(p)
                        await ws.send(json.dumps({"type":"status","text":f"✨ prj e: {p}"}))
                    # Paket adini bul (proje adi yerine, degismez)
                    pkg = ""
                    for pr in read_projeler():
                        if pr["name"] == p:
                            pkg = pr.get("package", p)
                            break
                    async def tk_done(rc, _p=p, _pd=pd, _pkg=pkg):
                        apk = copy_apk(_pd, _p) if rc == 0 else None
                        running["task"] = None
                        await ws.send(json.dumps({"type":"task_done","success":rc==0,
                            "text":"✅ Görev tamamlandı!" if rc==0 else "❌ Görev başarısız",
                            "apk_path":apk or "", "project":_p, "package":_pkg}))
                        # Paket bazli next_task kontrolu
                        next_task_file = f"{SISTEM_DIR}/next_task_{_pkg}.txt"
                        if not os.path.exists(next_task_file):
                            next_task_file = f"{SISTEM_DIR}/next_task_{_p}.txt"
                        if not os.path.exists(next_task_file):
                            next_task_file = f"{SISTEM_DIR}/next_task.txt"
                        if rc == 0 and os.path.exists(next_task_file):
                            try:
                                next_task = open(next_task_file).read().strip()
                                os.remove(next_task_file)
                                if next_task:
                                    await ws.send(json.dumps({"type":"status","text":f"📬 Zincir devam: {next_task[:50]}..."}))
                                    escaped = next_task.replace("'", "'\''")
                                    async def chain_done(rc2, _p=_p, _pd=_pd):
                                        apk2 = copy_apk(_pd, _p) if rc2 == 0 else None
                                        await ws.send(json.dumps({"type":"task_done","success":rc2==0,
                                            "text":"✅ Zincir tamamlandı!" if rc2==0 else "❌ Zincir başarısız",
                                            "apk_path":apk2 or ""}))
                                    running["task"] = None
                                    task_file = f"{SISTEM_DIR}/_running_chain.txt"
                                    open(task_file, 'w').write(next_task)
                                    await start(f"bash {PRJ_SH} ef '{task_file}'", _pd, chain_done)
                            except Exception as ex:
                                await ws.send(json.dumps({"type":"error","text":f"Zincir hatası: {ex}"}))
                    await start(f"bash {PRJ_SH} e '{task}'", pd, tk_done)

                elif t == "build_debug":
                    p = d.get("project",""); pd = get_proj_dir(p)
                    await ws.send(json.dumps({"type":"status","text":f"🔨 prj d: {p}"}))
                    async def bd_done(rc, _p=p, _pd=pd):
                        apk = copy_apk(_pd, _p) if rc == 0 else None
                        await ws.send(json.dumps({"type":"build_done","success":rc==0,
                            "project":_p,"apk_path":apk or ""}))
                    await start(f"bash {PRJ_SH} d", pd, bd_done)

                elif t == "build_release":
                    p = d.get("project",""); pd = get_proj_dir(p)
                    await ws.send(json.dumps({"type":"status","text":f"📦 prj b: {p}"}))
                    async def br_done(rc):
                        await ws.send(json.dumps({"type":"task_done","success":rc==0,
                            "text":"✅ AAB hazır!" if rc==0 else "❌ Release başarısız"}))
                    await start(f"bash {PRJ_SH} b", pd, br_done)

                elif t == "new_project":
                    n    = d.get("name","")
                    task = d.get("task","Merhaba Dünya yazan basit bir Android uygulaması")
                    # Oyun uyarısı
                    GAME_KEYWORDS = ["oyun", "game", "flappy", "angry bird", "snake", "tetris",
                                     "mario", "clash", "chess", "satranç", "pacman", "platformer",
                                     "rpg", "fps", "shooter", "physics", "fizik motoru"]
                    task_lower = task.lower()
                    if any(kw in task_lower for kw in GAME_KEYWORDS):
                        await ws.send(json.dumps({"type":"warning","text":"⚠️ Oyun geliştirme bu versiyon için optimize edilmemiş. Sonuç mükemmel olmayabilir. Devam edilecek..."}))
                    JAVA_KEYWORDS = {"do","if","in","is","as","by","fun","val","var","for","bin","lib","usr","tmp","etc",
                                     "try","int","out","new","get","set","run","when","else",
                                     "null","true","false","this","class","while","break",
                                     "super","throw","catch","final","return","import","object"}
                    if n.lower() in JAVA_KEYWORDS:
                        await ws.send(json.dumps({"type":"error","text":f"❌ '{n}' Java/Kotlin için ayrılmış kelime — farklı isim gir!"}))
                        continue
                    await ws.send(json.dumps({"type":"status","text":f"📦 Proje oluşturuluyor: {n}"}))
                    # factory.sh PTY'de çalışır; Proje Adı + AI Görevi read'lerini AUTO_ENTER
                    # ile değil, özel olarak cevaplıyoruz
                    # factory.sh prompt'una ek kural ekle - MyApplicationTheme referansı kullanma
                    full_task = task + ". ÖNEMLİ: Tema için sadece MaterialTheme kullan, özel tema sınıfı oluşturma."
                    pkg = d.get("pkg","")
                    if pkg: os.environ["PKG_OVERRIDE"] = pkg
                    else: os.environ.pop("PKG_OVERRIDE", None)
                    # AYARLARDAN ŞİFREYİ ÇEK VE BASH BETİĞİNE GÖNDER
                    user_settings = read_settings()
                    ks_pass = user_settings.get("KEYSTORE_PASS", "").strip()
                    if ks_pass:
                        os.environ["KEYSTORE_PASS"] = ks_pass
                    else:
                        os.environ.pop("KEYSTORE_PASS", None)

                    state["_factory_name"] = n
                    state["_factory_task"] = full_task
                    state["_factory_task_default"] = full_task   # "→ " için yedek
                    async def np_done(rc, _n=n):
                        state.pop("_factory_name", None)
                        state.pop("_factory_task", None)
                        running["task"] = None
                        await ws.send(json.dumps({"type":"project_done","success":rc==0,"name":_n}))
                    await start(f"bash {SISTEM_DIR}/factory.sh", HOME, np_done)

                elif t == "list_apks":
                    await ws.send(json.dumps({"type":"apk_list","data":list_apks(d.get("project",""))}))

                elif t == "list_backups":
                    bk = []
                    if os.path.exists(BACKUP_DIR):
                        files = sorted([f for f in os.listdir(BACKUP_DIR) if f.endswith('.tar.gz')], reverse=True)
                        pf = d.get("project","")
                        bk = [f for f in files if not pf or f.startswith(pf)]
                    await ws.send(json.dumps({"type":"backups","data":bk}))


                elif t == "backup":
                    p = d.get("project",""); pd = get_proj_dir(p)
                    ts = datetime.now().strftime("%Y%m%d-%H%M")
                    btype = d.get("backup_type", "normal")
                    
                    # 1. UI'dan gelen notu al
                    note = d.get("note", "yedek")
                    
                    # 2. Not "yedek" değilse isme "not(xxxx)-" formatında ekle
                    note_str = "" if note == "yedek" else f"-not({note})"
                    
                    os.makedirs(BACKUP_DIR, exist_ok=True)
                    if btype == "quick":
                        out = f"{BACKUP_DIR}/{p}{note_str}-{ts}-hizli.tar.gz"
                        excludes = "--exclude='*/build' --exclude='*/.gradle' --exclude='*/outputs' --exclude='*.class'"
                        label = "⚡ Hızlı"
                    elif btype == "full":
                        out = f"{BACKUP_DIR}/{p}{note_str}-{ts}-tam.tar.gz"
                        excludes = "--exclude='*/build/intermediates' --exclude='*/build/tmp'"
                        label = "📦 Tam"
                    else:
                        out = f"{BACKUP_DIR}/{p}{note_str}-{ts}-yedek.tar.gz"
                        excludes = "--exclude='*/build' --exclude='*/.gradle'"
                        label = "💾 Normal"



                    async def bk_done(rc, _o=out, _l=label):
                        await ws.send(json.dumps({"type":"task_done","success":rc==0,
                            "text":f"{_l} yedek: {os.path.basename(_o)}" if rc==0 else "❌ Yedekleme başarısız"}))
                    await start(
                        f"tar -czf '{out}' {excludes} -C '{os.path.dirname(pd)}' '{os.path.basename(pd)}'",
                        HOME, bk_done)

                elif t == "restore_backup":
                    name = d.get("name",""); tar = f"{BACKUP_DIR}/{name}"
                    if not os.path.exists(tar):
                        await ws.send(json.dumps({"type":"error","text":"Yedek bulunamadı"})); continue
                    pn = name.split('-202')[0]; pd = get_proj_dir(pn)
                    async def rb_done(rc):
                        await ws.send(json.dumps({"type":"task_done","success":rc==0,
                            "text":"↩ Yedek geri yüklendi" if rc==0 else "❌ Geri yükleme başarısız"}))
                    await start(f"rm -rf {pd} && tar -xzf {tar} -C {os.path.dirname(pd)}", HOME, rb_done)

                elif t == "delete_keystore":
                    name = d.get("name","")
                    ks_path = f"{KEYSTORE_DIR}/{name}"
                    if os.path.exists(ks_path):
                        os.remove(ks_path)
                    await ws.send(json.dumps({"type":"task_done","success":True,"text":"🗑 Keystore silindi"}))
                elif t == "delete_backup":
                    name = d.get("name",""); tar = f"{BACKUP_DIR}/{name}"
                    if not os.path.exists(tar):
                        await ws.send(json.dumps({"type":"error","text":"Yedek bulunamadı"})); continue
                    try:
                        os.remove(tar)
                        await ws.send(json.dumps({"type":"task_done","success":True,"text":f"🗑 {name} silindi"}))
                    except Exception as e:
                        await ws.send(json.dumps({"type":"error","text":f"Silinemedi: {e}"}))

                elif t == "list_keystores":
                    ks = []
                    if os.path.exists(KEYSTORE_DIR):
                        prs = read_projeler()
                        for f in sorted(os.listdir(KEYSTORE_DIR)):
                            if not (f.endswith('.keystore') or f.endswith('.jks')): continue
                            al = pnm = ""
                            for pr in prs:
                                if pr["keystore"] == f: al = pr["alias"]; pnm = pr["name"]; break
                            ks.append({"name":f,"path":f"{KEYSTORE_DIR}/{f}",
                                       "size":os.path.getsize(f"{KEYSTORE_DIR}/{f}"),
                                       "alias":al,"project":pnm})
                    await ws.send(json.dumps({"type":"keystores","data":ks}))

                elif t == "list_apis":
                    apis = []
                    if os.path.exists(APILER_DIR):
                        for f in sorted(os.listdir(APILER_DIR)):
                            if not f.endswith('.conf'): continue
                            nm = f.replace('.conf','')
                            key = read_api_key(f"{APILER_DIR}/{f}")
                            apis.append({"name":nm,"file":f,
                                         "key_preview":key[:12]+"..." if len(key)>12 else key,
                                         "has_key":len(key)>5})
                    await ws.send(json.dumps({"type":"api_list","data":apis}))

                elif t == "save_api":
                    nm = d.get("name",""); key = d.get("key","")
                    cf = f"{APILER_DIR}/{nm}.conf"
                    if not os.path.exists(cf):
                        await ws.send(json.dumps({"type":"error","text":"API dosyası bulunamadı"})); continue
                        
                    with open(cf, 'r') as f:
                        ls = f.readlines()
                        
                    nl = []; upd = False
                    for l in ls:
                        if l.strip().startswith('API_KEY='): 
                            nl.append(f'API_KEY="{key}"\n')
                            upd = True
                        else: 
                            nl.append(l)
                    if not upd: nl.append(f'API_KEY="{key}"\n')
                    
                    with open(cf, 'w') as f:
                        f.writelines(nl)
                        
                    ev = {"claude":"ANTHROPIC_API_KEY","deepseek":"DEEPSEEK_API_KEY",
                          "gemini":"GEMINI_API_KEY","openai":"OPENAI_API_KEY",
                          "groq":"GROQ_API_KEY","qwen":"QWEN_API_KEY"}.get(nm, f"{nm.upper()}_API_KEY")
                    br = f"{HOME}/.bashrc"
                    bls = []
                    if os.path.exists(br):
                        with open(br, 'r') as f:
                            bls = [l for l in f.readlines() if ev not in l]
                    bls.append(f'export {ev}="{key}"\n')
                    with open(br, 'w') as f:
                        f.writelines(bls)
                        
                    await ws.send(json.dumps({"type":"task_done","success":True,"text":f"✅ {nm} kaydedildi"}))
                

                elif t == "get_providers":
                    providers = []
                    if os.path.exists(APILER_DIR):
                        local_provs = []
                        for cf in sorted(os.listdir(APILER_DIR)):
                            if cf.endswith('.conf'):
                                data = {}
                                for line in open(f"{APILER_DIR}/{cf}").readlines():
                                    line = line.strip()
                                    if '=' in line:
                                        k, v = line.split('=', 1)
                                        data[k] = v.strip('"').strip("'")
                                local_provs.append((cf, data))
                        
                        def fetch_models(name, key, fallback):
                            if not key: return fallback
                            import urllib.request, json, ssl
                            try:
                                req = None
                                n = name.lower()
                                if n == "openai": req = urllib.request.Request("https://api.openai.com/v1/models", headers={"Authorization": f"Bearer {key}"})
                                elif n == "deepseek": req = urllib.request.Request("https://api.deepseek.com/models", headers={"Authorization": f"Bearer {key}", "Accept": "application/json"})
                                elif n == "groq": req = urllib.request.Request("https://api.groq.com/openai/v1/models", headers={"Authorization": f"Bearer {key}"})
                                elif n == "gemini": req = urllib.request.Request(f"https://generativelanguage.googleapis.com/v1beta/models?key={key}")
                                elif n == "claude": req = urllib.request.Request("https://api.anthropic.com/v1/models", headers={"x-api-key": key, "anthropic-version": "2023-06-01"})
                                if not req: return fallback
                                
                                ctx = ssl.create_default_context()
                                ctx.check_hostname = False
                                ctx.verify_mode = ssl.CERT_NONE
                                
                                with urllib.request.urlopen(req, timeout=5, context=ctx) as res:
                                    rj = json.loads(res.read().decode())
                                    if n == "gemini":
                                        m_list = [m["name"].replace("models/", "") for m in rj.get("models",[]) if "generateContent" in m.get("supportedGenerationMethods",[])]
                                        # NİHAİ KATI LİSTE: image, tts, robotics, computer-use eklendi!
                                        m_list = [m for m in m_list if "gemini" in m.lower() and not any(bad in m.lower() for bad in ["vision", "imagen", "image", "embedding", "aqa", "learnlm", "bison", "experimental", "tts", "robotics", "computer-use", "customtools"])]
                                    else:
                                        m_list = [m["id"] for m in rj.get("data",[])]
                                        if n == "openai": 
                                            m_list = [m for m in m_list if ("gpt" in m.lower() or "o1" in m.lower() or "o3" in m.lower()) and not any(bad in m.lower() for bad in ["audio", "realtime", "vision", "instruct", "dall-e", "tts", "whisper", "babbage", "davinci"])]
                                        elif n == "claude": 
                                            m_list = [m for m in m_list if "claude" in m.lower()]
                                        elif n == "groq": 
                                            m_list = [m for m in m_list if not any(bad in m.lower() for bad in ["whisper", "llava"])]
                                        elif n == "deepseek": 
                                            m_list = [m for m in m_list if "chat" in m.lower() or "reasoner" in m.lower() or "coder" in m.lower()]
                                    
                                    m_list = sorted(list(set(m_list)), reverse=True)
                                    return m_list if m_list else fallback
                            except Exception as e:
                                return [f"API_HATA: {str(e)}"] + fallback

                        async def build_prov(cf, data):
                            try:
                                raw_name = cf.replace(".conf", "")
                                if raw_name.lower() == "openai": raw_name = "OpenAI"
                                elif raw_name.lower() == "groq": raw_name = "Groq"
                                elif raw_name.lower() == "gemini": raw_name = "Gemini"
                                elif raw_name.lower() == "claude": raw_name = "Claude"
                                elif raw_name.lower() == "deepseek": raw_name = "DeepSeek"
                                
                                name = data.get("NAME", raw_name)
                                key = data.get("API_KEY", "").strip()
                                
                                fallback_str = data.get("MODELS", "")
                                fallback = [x.strip() for x in fallback_str.split(",")] if fallback_str else []
                                
                                live_models = await asyncio.to_thread(fetch_models, name, key, fallback)
                                
                                minfos = {}
                                for item in data.get("MODEL_INFOS", "").split("|"):
                                    if ":" in item:
                                        mid, mdesc = item.split(":", 1)
                                        minfos[mid.strip()] = mdesc.strip()
                                return {
                                    "name": name,
                                    "model": data.get("MODEL", ""),
                                    "models": live_models,
                                    "model_infos": minfos,
                                    "hasKey": bool(key)
                                }
                            except Exception as ex:
                                return {"name": raw_name, "models": [f"BLOK_HATA: {str(ex)}"], "hasKey": False}
                        
                        tasks = [build_prov(cf, d) for cf, d in local_provs]
                        if tasks:
                            providers = await asyncio.gather(*tasks)

                    await ws.send(json.dumps({"type":"providers","data":providers}))

                elif t == "get_settings":
                    await ws.send(json.dumps({"type":"settings","data":read_settings()}))

                elif t == "save_settings":
                    save_settings(d.get("data",{}))
                    await ws.send(json.dumps({"type":"task_done","success":True,"text":"✅ Ayarlar kaydedildi"}))

                elif t == "get_projects_conf":
                    cf = f"{SISTEM_DIR}/projeler.conf"
                    await ws.send(json.dumps({"type":"file_content","path":cf,
                        "content":open(cf).read() if os.path.exists(cf) else ""}))

                elif t == "save_projects_conf":
                    open(f"{SISTEM_DIR}/projeler.conf",'w').write(d.get("content",""))
                    await ws.send(json.dumps({"type":"task_done","success":True}))



                elif t == "list_prompt_archives":
                    arc_dir = f"{SISTEM_DIR}/prompts/arsiv"
                    os.makedirs(arc_dir, exist_ok=True)
                    files = sorted([
                        f for f in os.listdir(arc_dir) if f.endswith(".txt")
                    ], reverse=True)
                    await ws.send(json.dumps({"type":"prompt_archives","list": files}))

                elif t == "save_prompt_archive":
                    arc_name = d.get("arc_name","").strip()
                    prompt_name = d.get("prompt_name","autofix_system")
                    content_txt = d.get("content","")
                    if not arc_name:
                        await ws.send(json.dumps({"type":"error","text":"Arşiv adı boş olamaz"}))
                    else:
                        arc_dir = f"{SISTEM_DIR}/prompts/arsiv"
                        os.makedirs(arc_dir, exist_ok=True)
                        fname = f"{prompt_name}_{arc_name}.txt"
                        open(f"{arc_dir}/{fname}",'w').write(content_txt)
                        await ws.send(json.dumps({"type":"task_done","success":True,
                            "text":f"✅ '{arc_name}' arşive eklendi"}))

                elif t == "load_prompt_archive":
                    arc_file = d.get("arc_file","")
                    arc_dir = f"{SISTEM_DIR}/prompts/arsiv"
                    fpath = f"{arc_dir}/{arc_file}"
                    if os.path.exists(fpath):
                        cnt = open(fpath).read()
                        # prompt_name'i dosya adından çıkar
                        pname = "autofix_system" if arc_file.startswith("autofix_system") else "autofix_task"
                        await ws.send(json.dumps({"type":"prompt_content","name":pname,
                            "content":cnt,"is_default":False}))
                    else:
                        await ws.send(json.dumps({"type":"error","text":"Arşiv dosyası bulunamadı"}))

                elif t == "delete_prompt_archive":
                    arc_file = d.get("arc_file","")
                    arc_dir = f"{SISTEM_DIR}/prompts/arsiv"
                    fpath = f"{arc_dir}/{arc_file}"
                    if os.path.exists(fpath):
                        os.remove(fpath)
                        await ws.send(json.dumps({"type":"task_done","success":True,
                            "text":"🗑 Arşiv silindi"}))
                elif t == "run_setup":
                    setup_script = "/sdcard/apkfactory_setup_run.sh"
                    if os.path.exists(setup_script):
                        subprocess.Popen(["bash", setup_script], stdout=open("/sdcard/apkfactory_setup.log","a"), stderr=subprocess.STDOUT)
                        await ws.send(json.dumps({"type":"run_setup","status":"started"}))
                    else:
                        await ws.send(json.dumps({"type":"run_setup","status":"error","msg":"script bulunamadi"}))
                elif t == "get_prompt":
                    name = d.get("name","autofix_system")
                    pfile = f"{SISTEM_DIR}/prompts/{name}.txt"
                    if os.path.exists(pfile):
                        cnt = open(pfile).read()
                        is_def = False
                    else:
                        import urllib.request
                        try:
                            cnt = urllib.request.urlopen(f"{GITHUB_RAW}/prompts/{name}.txt", timeout=10).read().decode()
                            is_def = True
                        except:
                            cnt = ""; is_def = True
                    await ws.send(json.dumps({"type":"prompt_content","name":name,"content":cnt,"is_default":is_def}))

                elif t == "save_prompt":
                    name = d.get("name",""); cnt = d.get("content","")
                    os.makedirs(f"{SISTEM_DIR}/prompts", exist_ok=True)
                    open(f"{SISTEM_DIR}/prompts/{name}.txt",'w').write(cnt)
                    await ws.send(json.dumps({"type":"task_done","success":True,"text":f"✅ {name} kaydedildi"}))

                elif t == "reset_prompt":
                    name = d.get("name","")
                    import urllib.request
                    try:
                        cnt = urllib.request.urlopen(f"{GITHUB_RAW}/prompts/{name}.txt", timeout=15).read().decode()
                        os.makedirs(f"{SISTEM_DIR}/prompts", exist_ok=True)
                        open(f"{SISTEM_DIR}/prompts/{name}.txt",'w').write(cnt)
                        await ws.send(json.dumps({"type":"prompt_content","name":name,"content":cnt,"is_default":True}))
                        await ws.send(json.dumps({"type":"task_done","success":True,"text":f"✅ {name} sıfırlandı"}))
                    except Exception as ex:
                        await ws.send(json.dumps({"type":"error","text":f"GitHub hatası: {ex}"}))
                elif t == "delete_apk":
                    path = d.get("path","")
                    try:
                        if path and os.path.exists(path):
                            os.remove(path)
                            await ws.send(json.dumps({"type":"task_done","success":True,"text":"🗑 Silindi"}))
                        else:
                            await ws.send(json.dumps({"type":"task_done","success":False,"text":"❌ Dosya bulunamadı"}))
                    except Exception as ex:
                        await ws.send(json.dumps({"type":"task_done","success":False,"text":f"❌ {ex}"}))

                elif t == "delete_all_apks":
                    import glob
                    deleted = 0
                    for f2 in glob.glob("/sdcard/Download/apk-cikti/*.apk") + glob.glob("/sdcard/Download/apk-cikti/*.aab"):
                        try: os.remove(f2); deleted += 1
                        except: pass
                    await ws.send(json.dumps({"type":"task_done","success":True,"text":f"🗑 {deleted} dosya silindi"}))

                elif t == "get_version":
                    import urllib.request
                    try:
                        raw = urllib.request.urlopen(f"{GITHUB_RAW}/version.json", timeout=5).read().decode()
                        vdata = json.loads(raw)
                        local_sv = open(f"{SISTEM_DIR}/script_version.txt").read().strip() if os.path.exists(f"{SISTEM_DIR}/script_version.txt") else "0"
                        local_pv = open(f"{SISTEM_DIR}/prompt_version.txt").read().strip() if os.path.exists(f"{SISTEM_DIR}/prompt_version.txt") else "0"
                        has_update = (vdata.get("script_version","0") != local_sv or vdata.get("prompt_version","0") != local_pv)
                        await ws.send(json.dumps({"type":"version_info","data":vdata,"has_update":has_update}))
                    except Exception as ex:
                        await ws.send(json.dumps({"type":"error","text":f"Versiyon alınamadı: {ex}"}))

                elif t == "check_updates":
                    subprocess.Popen(["bash", "/storage/emulated/0/termux-otonom-sistem/check_updates.sh", "force"])
                    await ws.send(json.dumps({"type":"task_done","success":True,"text":"🔄 Güncelleme başlatıldı"}))


                elif t == "export_sources":
                    p = d.get("project",""); pd = get_proj_dir(p)
                    fmt = d.get("format","txt")
                    ts = datetime.now().strftime("%Y%m%d-%H%M")
                    SKIP_EXT = {'.jpg','.jpeg','.png','.gif','.webp','.bmp','.ico','.svg',
                                '.apk','.aab','.jar','.class','.dex','.so',
                                '.keystore','.jks','.tar','.gz','.zip','.rar',
                                '.mp3','.mp4','.wav','.ogg','.ttf','.otf','.woff','.woff2',
                                '.db','.sqlite','.bin','.dat','.o','.a','.pyc'}
                    SKIP_DIRS = {'build','.gradle','.idea','.git','__pycache__','node_modules','.cxx','intermediates','tmp','generated'}
                    MAX_SIZE = 100 * 1024

                    if not os.path.isdir(pd):
                        await ws.send(json.dumps({"type":"error","text":f"Proje bulunamadı: {pd}"}))
                        continue

                    try:
                        if fmt == "zip":
                            out_path = f"/sdcard/Download/{p}-proje-{ts}.zip"
                            with zipfile.ZipFile(out_path, 'w', zipfile.ZIP_DEFLATED) as zf:
                                file_count = 0
                                for root, dirs, files in os.walk(pd):
                                    dirs[:] = [dd for dd in dirs if dd not in SKIP_DIRS]
                                    for fname in sorted(files):
                                        fp = os.path.join(root, fname)
                                        ext = os.path.splitext(fname)[1].lower()
                                        if ext in SKIP_EXT: continue
                                        try:
                                            if os.path.getsize(fp) > MAX_SIZE: continue
                                        except OSError: continue
                                        arc_name = os.path.relpath(fp, os.path.dirname(pd))
                                        zf.write(fp, arc_name)
                                        file_count += 1
                            size_kb = os.path.getsize(out_path) // 1024
                            await ws.send(json.dumps({"type":"export_done","path":out_path,"format":"zip",
                                "text":f"📦 ZIP: {os.path.basename(out_path)} ({file_count} dosya, {size_kb}KB)"}))
                        else:
                            out_path = f"/sdcard/Download/{p}-tum-kod-{ts}.txt"
                            file_count = 0
                            with open(out_path, 'w', encoding='utf-8', errors='replace') as out:
                                for root, dirs, files in os.walk(pd):
                                    dirs[:] = [dd for dd in dirs if dd not in SKIP_DIRS]
                                    for fname in sorted(files):
                                        fp = os.path.join(root, fname)
                                        ext = os.path.splitext(fname)[1].lower()
                                        if ext in SKIP_EXT: continue
                                        try:
                                            if os.path.getsize(fp) > MAX_SIZE: continue
                                        except OSError: continue
                                        rel = os.path.relpath(fp, pd)
                                        try: content = open(fp,'r',encoding='utf-8',errors='replace').read()
                                        except: continue
                                        out.write(f"// ═══ FILE: {rel} ═══\n")
                                        out.write(content)
                                        if not content.endswith('\n'): out.write('\n')
                                        file_count += 1
                            size_kb = os.path.getsize(out_path) // 1024
                            await ws.send(json.dumps({"type":"export_done","path":out_path,"format":"txt",
                                "text":f"📄 TXT: {os.path.basename(out_path)} ({file_count} dosya, {size_kb}KB)"}))
                    except Exception as ex:
                        await ws.send(json.dumps({"type":"error","text":f"Export hatası: {ex}"}))

                elif t == "system_info":
                    await ws.send(json.dumps({"type":"system_info","data":{
                        "sistem_dir":SISTEM_DIR,"home":HOME,
                        "prj_sh":os.path.exists(PRJ_SH),
                        "backup_count":len(glob.glob(f"{BACKUP_DIR}/*.tar.gz")),
                        "apk_count":len(glob.glob(f"{APK_OUT_DIR}/*.apk")),
                    }}))

            except json.JSONDecodeError:
                await ws.send(json.dumps({"type":"error","text":"Geçersiz JSON"}))
            except Exception as e:
                await ws.send(json.dumps({"type":"error","text":str(e)}))

    except websockets.exceptions.ConnectionClosed:
        pass
    finally:
        state["kill_req"] = True
        ev = state.get("answer_event")
        if ev: ev.set()
        m = state.get("master")
        if m:
            try: asyncio.get_event_loop().remove_reader(m)
            except: pass
            try: os.close(m)
            except: pass

async def main():
    print("APK Factory WS Bridge v11 (asyncio-PTY) — 0.0.0.0:8765")
    print(f"prj.sh: {'✅' if os.path.exists(PRJ_SH) else '❌ BULUNAMADI!'}")
    async with websockets.serve(handle, "0.0.0.0", 8765, ping_interval=None, ping_timeout=None):
        print("✅ Hazır!")
        await asyncio.Future()

if __name__ == "__main__":
    asyncio.run(main())

