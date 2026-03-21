#!/bin/bash
PROJE_ADI=$1
APP_ID=${2:-"ca-app-pub-3940256099942544~3347511713"}
UNIT_ID=${3:-"ca-app-pub-3940256099942544/1033173712"}
PROJE_DIZIN="/data/data/com.termux/files/home/$PROJE_ADI"

if [ ! -d "$PROJE_DIZIN" ]; then
    echo "HATA: Proje bulunamadı: $PROJE_ADI"
    exit 1
fi

PKG=$(grep -E 'namespace|applicationId' "$PROJE_DIZIN/app/build.gradle" | head -1 | sed "s/.*[\"']\([a-z][a-z0-9._]*\)[\"'].*/\1/")
PKG_PATH=$(echo "$PKG" | tr '.' '/')
MAIN_KT=$(find "$PROJE_DIZIN/app/src/main/java" -name "MainActivity.kt" | head -1)
MANIFEST="$PROJE_DIZIN/app/src/main/AndroidManifest.xml"
GRADLE="$PROJE_DIZIN/app/build.gradle"
JAVA_DIR=$(dirname "$MAIN_KT")

echo "📦 Proje: $PROJE_ADI ($PKG)"

# 1. build.gradle
if ! grep -q "play-services-ads" "$GRADLE"; then
    sed -i '/^    implementation/i\    implementation("com.google.android.gms:play-services-ads:23.0.0")' "$GRADLE"
    echo "✅ build.gradle güncellendi"
else
    echo "ℹ️ play-services-ads zaten var"
fi

# 2. Manifest
if ! grep -q "INTERNET" "$MANIFEST"; then
    sed -i '/<manifest/a\    <uses-permission android:name="android.permission.INTERNET" />' "$MANIFEST"
fi
if ! grep -q "APPLICATION_ID" "$MANIFEST"; then
    sed -i '/<application/a\        <meta-data android:name="com.google.android.gms.ads.APPLICATION_ID" android:value="'"$APP_ID"'"/>' "$MANIFEST"
    echo "✅ Manifest güncellendi"
else
    echo "ℹ️ App ID zaten var"
fi

# 3. Manifest'e android:name=".App" ekle
if ! grep -q 'android:name=".App"' "$MANIFEST"; then
    sed -i 's/<application android:allowBackup/<application android:name=".App" android:allowBackup/' "$MANIFEST"
fi

# 4. AdMobManager.kt oluştur
cat > "$JAVA_DIR/AdMobManager.kt" << KOTLIN
package $PKG

import android.app.Activity
import android.app.Application
import android.os.Bundle
import com.google.android.gms.ads.AdRequest
import com.google.android.gms.ads.LoadAdError
import com.google.android.gms.ads.interstitial.InterstitialAd
import com.google.android.gms.ads.interstitial.InterstitialAdLoadCallback

class AdMobManager : Application.ActivityLifecycleCallbacks {
    private var mInterstitialAd: InterstitialAd? = null
    private var isAdShown = false
    private var isLoading = false
    private var currentActivity: Activity? = null

    fun init(application: Application) {
        application.registerActivityLifecycleCallbacks(this)
        loadAd(application)
    }

    private fun loadAd(application: Application) {
        if (isLoading) return
        isLoading = true
        InterstitialAd.load(application, "$UNIT_ID", AdRequest.Builder().build(),
            object : InterstitialAdLoadCallback() {
                override fun onAdLoaded(ad: InterstitialAd) {
                    mInterstitialAd = ad; isLoading = false
                    currentActivity?.let { act ->
                        if (!isAdShown) { ad.show(act); isAdShown = true; mInterstitialAd = null }
                    }
                }
                override fun onAdFailedToLoad(e: LoadAdError) { mInterstitialAd = null; isLoading = false }
            })
    }

    override fun onActivityResumed(activity: Activity) {
        currentActivity = activity
        if (mInterstitialAd != null && !isAdShown) {
            mInterstitialAd!!.show(activity); isAdShown = true; mInterstitialAd = null
        }
    }
    override fun onActivityPaused(activity: Activity) { currentActivity = null }
    override fun onActivityCreated(activity: Activity, savedInstanceState: Bundle?) {}
    override fun onActivityStarted(activity: Activity) {}
    override fun onActivityStopped(activity: Activity) {}
    override fun onActivitySaveInstanceState(activity: Activity, outState: Bundle) {}
    override fun onActivityDestroyed(activity: Activity) {}
}
KOTLIN
echo "✅ AdMobManager.kt oluşturuldu"

# 5. App.kt oluştur
cat > "$JAVA_DIR/App.kt" << KOTLIN
package $PKG

import android.app.Application
import com.google.android.gms.ads.MobileAds

class App : Application() {
    override fun onCreate() {
        super.onCreate()
        MobileAds.initialize(this) {}
        AdMobManager().init(this)
    }
}
KOTLIN
echo "✅ App.kt oluşturuldu"

echo "🎉 AdMob enjeksiyonu tamamlandı: $PROJE_ADI"
