#!/data/data/com.termux/files/usr/bin/python3
"""APK Factory WS Bridge v11 — asyncio-native PTY (fork yok)"""
import asyncio, websockets, json, os, pty, signal, shutil, glob, re, subprocess
from datetime import datetime

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
    ("→ ",                  "_factory_task"),   # satır sonu → prompt
]

# ── Settings ──────────────────────────────────────────────────────────────────
def read_settings():
    d = {"DEFAULT_PROVIDER":"Claude","DEFAULT_MODEL":"claude-haiku-4-5-20251001",
         "MAX_LOOPS":"5","MAX_TOKENS":"8000","KEYSTORE_PASS":"android123"}
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
            ls = [l for l in f.readlines() if 'DEFAULT_PROVIDER=' not in l and 'MAX_LOOPS=' not in l and 'MAX_TOKENS=' not in l]
    
    ls += [f'DEFAULT_PROVIDER="{data.get("DEFAULT_PROVIDER","Claude")}"\n',
           f'MAX_LOOPS={data.get("MAX_LOOPS","5")}\n',
           f'MAX_TOKENS={data.get("MAX_TOKENS","8000")}\n']
    
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
                    "date":datetime.fromtimestamp(st.st_mtime).strftime("%d.%m.%Y %H:%M:%S")})
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
            try: await ws.send(json.dumps({"type":"log","text":text}))
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
            await ws.send(json.dumps({"type":"error","text":"Zaten bir işlem çalışıyor"}))
            return
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
                    await ws.send(json.dumps({"type":"projects","data":read_projeler()}))

                elif t == "delete_project":
                    pname = d.get("project","")
                    proj_dir = get_proj_dir(pname)
                    import shutil as _shutil
                    # Conf'dan sil
                    conf = f"{SISTEM_DIR}/projeler.conf"
                    if os.path.exists(conf):
                        lines = [l for l in open(conf) if not l.startswith(pname + "|")]
                        open(conf,'w').writelines(lines)
                    # Klasörü sil
                    try:
                        if os.path.exists(proj_dir):
                            _shutil.rmtree(proj_dir)
                        await ws.send(json.dumps({"type":"task_done","success":True,"text":f"🗑 {pname} silindi"}))
                    except Exception as e:
                        await ws.send(json.dumps({"type":"task_done","success":False,"text":f"❌ Silinemedi: {e}"}))

                elif t == "autofix":
                    p = d.get("project",""); pd = get_proj_dir(p)
                    await ws.send(json.dumps({"type":"status","text":f"🤖 prj af: {p}"}))
                    async def af_done(rc, _p=p, _pd=pd):
                        apk = copy_apk(_pd, _p) if rc == 0 else None
                        await ws.send(json.dumps({"type":"task_done","success":rc==0,
                            "text":"✅ AutoFix tamamlandı!" if rc==0 else "❌ AutoFix başarısız",
                            "apk_path":apk or ""}))
                    await start(f"bash {PRJ_SH} af", pd, af_done)

                elif t == "task":
                    p    = d.get("project","")
                    task = d.get("task","").replace("'","'\\''")
                    pd   = get_proj_dir(p)
                    await ws.send(json.dumps({"type":"status","text":f"✨ prj e: {p}"}))
                    async def tk_done(rc, _p=p, _pd=pd):
                        apk = copy_apk(_pd, _p) if rc == 0 else None
                        await ws.send(json.dumps({"type":"task_done","success":rc==0,
                            "text":"✅ Görev tamamlandı!" if rc==0 else "❌ Görev başarısız",
                            "apk_path":apk or ""}))
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
                    await ws.send(json.dumps({"type":"status","text":f"📦 Proje oluşturuluyor: {n}"}))
                    # factory.sh PTY'de çalışır; Proje Adı + AI Görevi read'lerini AUTO_ENTER
                    # ile değil, özel olarak cevaplıyoruz
                    # factory.sh prompt'una ek kural ekle - MyApplicationTheme referansı kullanma
                    full_task = task + ". ÖNEMLİ: Tema için sadece MaterialTheme kullan, özel tema sınıfı oluşturma."
                    pkg = d.get("pkg","")
                    if pkg: os.environ["PKG_OVERRIDE"] = pkg
                    else: os.environ.pop("PKG_OVERRIDE", None)
                    state["_factory_name"] = n
                    state["_factory_task"] = full_task
                    state["_factory_task_default"] = full_task   # "→ " için yedek
                    async def np_done(rc, _n=n):
                        state.pop("_factory_name", None)
                        state.pop("_factory_task", None)
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
                    out = f"{BACKUP_DIR}/{p}-{ts}-yedek.tar.gz"
                    os.makedirs(BACKUP_DIR, exist_ok=True)
                    async def bk_done(rc, _o=out):
                        await ws.send(json.dumps({"type":"task_done","success":rc==0,
                            "text":f"💾 {os.path.basename(_o)}" if rc==0 else "❌ Yedekleme başarısız"}))
                    await start(
                        f"tar -czf {out} --exclude='*/build' --exclude='*/.gradle' "
                        f"-C {os.path.dirname(pd)} {os.path.basename(pd)}",
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
                        for cf in sorted(os.listdir(APILER_DIR)):
                            if cf.endswith('.conf'):
                                data = {}
                                for line in open(f"{APILER_DIR}/{cf}").readlines():
                                    line = line.strip()
                                    if '=' in line:
                                        k, v = line.split('=', 1)
                                        data[k] = v.strip('"')
                                model_infos = {}
                                for item in data.get("MODEL_INFOS", "").split("|"):
                                    if ":" in item:
                                        mid, mdesc = item.split(":", 1)
                                        model_infos[mid.strip()] = mdesc.strip()
                                providers.append({
                                    "name": data.get("NAME", cf.replace(".conf","")),
                                    "model": data.get("MODEL", ""),
                                    "models": data.get("MODELS", "").split(",") if data.get("MODELS") else [],
                                    "model_infos": model_infos,
                                    "hasKey": bool(data.get("API_KEY", "").strip())
                                })
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
                    subprocess.Popen(["bash", "/storage/emulated/0/termux-otonom-sistem/check_updates.sh"])
                    await ws.send(json.dumps({"type":"task_done","success":True,"text":"🔄 Güncelleme başlatıldı"}))

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
