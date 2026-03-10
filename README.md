# APK Factory Assets

APK Factory uygulaması için prompt ve script deposu.

## Yapı
```
prompts/
  autofix_system.txt   ← Build hata düzeltme system promptu
  autofix_task.txt     ← Görev modu system promptu
scripts/
  autofix.sh           ← Ana autofix scripti
  prj.sh               ← Proje yönetim scripti
version.json           ← Versiyon takip dosyası
```

## Prompt Güncellemek

1. `prompts/` içindeki dosyayı düzenle
2. `version.json` içinde `prompt_version` sayısını artır
3. `git add . && git commit -m "prompt güncellendi" && git push`

Uygulama ve autofix.sh bir sonraki çalışmada yeni promptu otomatik indirir.
