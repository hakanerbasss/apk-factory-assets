# 🤖 APK Factory

<div align="center">

**Android'den Android Uygulaması Geliştir — Yapay Zeka ile Tam Otonom**

[![WhatsApp](https://img.shields.io/badge/WhatsApp-Yardım_Grubu-25D366?style=for-the-badge&logo=whatsapp&logoColor=white)](https://chat.whatsapp.com/IcEx5RgBe7S87dboyHyYTg)
[![Platform](https://img.shields.io/badge/Platform-Android-3DDC84?style=for-the-badge&logo=android&logoColor=white)](https://github.com/hakanerbasss/apk-factory-assets)
[![Kotlin](https://img.shields.io/badge/Kotlin-Jetpack_Compose-7F52FF?style=for-the-badge&logo=kotlin&logoColor=white)](https://kotlinlang.org)

</div>

---

## 📱 Ne Yapar?

APK Factory, Android telefonundan Kotlin/Jetpack Compose uygulamaları geliştirmeni sağlayan otonom bir yapay zeka sistemidir.

- Yeni proje oluştur → Yapay zeka kodu yazar → Otomatik derler → APK hazır
- Build hataları varsa yapay zeka otomatik düzeltir
- Google Play'e hazır imzalı AAB üretir

---

## ⚡ Hızlı Kurulum

### Gereksinimler
- Android 8.0+
- [Termux (GitHub)](https://github.com/termux/termux-app/releases) — Google Play'den **indirme**
- [Termux:Boot (GitHub)](https://github.com/termux/termux-boot/releases)
- APK Factory uygulaması

### Otomatik Kurulum
APK Factory uygulamasını aç → **Kuruluma Başla** → İzinleri ver → Bekle → **Başlayalım**

---

## 🛠️ Manuel Termux Kurulumu

Otomatik kurulum çalışmazsa Termux'u açıp sırayla çalıştır:

```bash
# 1. Paketleri güncelle
pkg update -y && pkg upgrade -y

# 2. Gerekli paketleri kur
pkg install -y python git curl unzip wget openjdk-17 nodejs

# 3. Python websocket kur
pip install websockets --break-system-packages

# 4. Android SDK indir
mkdir -p ~/android-sdk/cmdline-tools && cd ~/android-sdk/cmdline-tools
wget https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip -O sdk.zip
unzip sdk.zip && mv cmdline-tools latest && rm sdk.zip

# 5. SDK lisanslarını kabul et
export ANDROID_HOME=~/android-sdk
export PATH=$PATH:$ANDROID_HOME/cmdline-tools/latest/bin
yes | sdkmanager --licenses
sdkmanager "build-tools;35.0.0" "platforms;android-35"

# 6. aapt2 düzelt
cp $ANDROID_HOME/build-tools/35.0.0/aapt2 $PREFIX/bin/aapt2
chmod +x $PREFIX/bin/aapt2

# 7. Setup scriptini çalıştır
curl -fsSL https://raw.githubusercontent.com/hakanerbasss/apk-factory-assets/main/scripts/setup_full.sh | bash

# 8. ws_bridge başlat
bash ~/restart_bridge.sh
```

---

## 📋 Termux Komut Referansı

| Komut | Açıklama |
|-------|----------|
| `bash ~/restart_bridge.sh` | ws_bridge'i yeniden başlat |
| `pgrep -f ws_bridge.py` | ws_bridge çalışıyor mu kontrol et |
| `bash /sdcard/termux-otonom-sistem/check_updates.sh force` | Tüm scriptleri zorla güncelle |
| `cat ~/apk-factory-ws/ws_bridge.log \| tail -20` | ws_bridge loglarını gör |
| `pkill -9 -f ws_bridge.py` | ws_bridge'i zorla öldür |
| `fuser -k 8765/tcp` | Port 8765'i serbest bırak |
| `aapt2 version` | aapt2 çalışıyor mu kontrol et |
| `java -version` | Java versiyonunu kontrol et (17 olmalı) |

### API Conf Düzenleme
```bash
# Claude API key ekle
nano /sdcard/termux-otonom-sistem/apiler/claude.conf

# Gemini modellerini gör
cat /sdcard/termux-otonom-sistem/apiler/gemini.conf

# Yeni model ekle (MODELS satırına virgülle ekle)
nano /sdcard/termux-otonom-sistem/apiler/deepseek.conf
```

### Proje Komutları
```bash
# Projeye git
cd ~/proje-adi

# Debug APK derle
bash /sdcard/termux-otonom-sistem/prj.sh d

# Release AAB derle
bash /sdcard/termux-otonom-sistem/prj.sh b

# AutoFix çalıştır
bash /sdcard/termux-otonom-sistem/autofix.sh

# Görev ver
bash /sdcard/termux-otonom-sistem/autofix.sh task "butona tıklayınca uyarı çıksın"
```

---

## 🔧 Hata Çözme

### Bağlantı Sorunu (Uygulama Bağsız Görünüyor)
```bash
# 1. ws_bridge durumunu kontrol et
pgrep -f ws_bridge.py

# 2. Çalışmıyorsa başlat
bash ~/restart_bridge.sh

# 3. Port meşgulse temizle
fuser -k 8765/tcp && sleep 2 && bash ~/restart_bridge.sh

# 4. Logları kontrol et
cat ~/apk-factory-ws/ws_bridge.log | tail -30
```

### aapt2 Hatası
```bash
export ANDROID_HOME=~/android-sdk
cp $ANDROID_HOME/build-tools/35.0.0/aapt2 $PREFIX/bin/aapt2
chmod +x $PREFIX/bin/aapt2
```

### Gradle / Build Araçları Eksik
```bash
export ANDROID_HOME=~/android-sdk
export PATH=$PATH:$ANDROID_HOME/cmdline-tools/latest/bin
sdkmanager "build-tools;35.0.0" "platforms;android-35"
yes | sdkmanager --licenses
```

### local.properties Hatası
```bash
# Proje klasöründe çalıştır
echo "sdk.dir=/data/data/com.termux/files/home/android-sdk" > local.properties
echo "android.aapt2FromMavenOverride=/data/data/com.termux/files/usr/bin/aapt2" >> local.properties
```

### Sistem Sıfırlama (Her Şey Bozulduysa)
```bash
# Otonom sistem klasörünü sil ve yeniden indir
rm -rf /sdcard/termux-otonom-sistem
curl -fsSL https://raw.githubusercontent.com/hakanerbasss/apk-factory-assets/main/scripts/setup_full.sh | bash
```

### Scripti Zorla Güncelle
```bash
bash /sdcard/termux-otonom-sistem/check_updates.sh force
```

---

## 📁 Dosya Yapısı

```
~/apk-factory-ws/
  ws_bridge.py              ← WebSocket sunucu (uygulama ile iletişim)
  ws_bridge.log             ← Bağlantı logları

~/restart_bridge.sh         ← ws_bridge yeniden başlatma scripti

~/.termux/boot/
  start_ws_bridge.sh        ← Telefon açılınca otomatik çalışır

/sdcard/termux-otonom-sistem/
  autofix.sh                ← Yapay zeka hata düzeltme motoru
  factory.sh                ← Yeni proje oluşturucu
  prj.sh                    ← Proje yöneticisi (build, release)
  check_updates.sh          ← GitHub güncelleme kontrolü
  apiler/                   ← API sağlayıcı conf dosyaları
    claude.conf
    gemini.conf
    deepseek.conf
    groq.conf
    openai.conf
    qwen.conf
  prompts/                  ← Yapay zeka talimatları
    autofix_system.txt
    autofix_task.txt
  keystores/                ← Proje imzalama dosyaları
  setup/                    ← Gradle wrapper dosyaları
```

---

## 🔑 API Key Nereden Alınır?

| Servis | Link | Not |
|--------|------|-----|
| Claude | [console.anthropic.com](https://console.anthropic.com) | Önerilen |
| DeepSeek | [platform.deepseek.com](https://platform.deepseek.com) | Uygun fiyatlı |
| Gemini | [aistudio.google.com](https://aistudio.google.com) | Ücretsiz kota |
| Groq | [console.groq.com](https://console.groq.com) | Çok hızlı |
| OpenAI | [platform.openai.com](https://platform.openai.com) | GPT modelleri |

---

## 💬 Yardım & Topluluk

[![WhatsApp Grubu](https://img.shields.io/badge/WhatsApp-Kullanım_Grubu_&_Yardım-25D366?style=for-the-badge&logo=whatsapp&logoColor=white)](https://chat.whatsapp.com/IcEx5RgBe7S87dboyHyYTg)

Sorularını WhatsApp grubunda sorabilirsin.
