package com.wizaicorp.apkfactory

import com.google.android.gms.ads.MobileAds
import com.google.android.gms.ads.AdRequest
import com.google.android.gms.ads.LoadAdError
import com.google.android.gms.ads.rewarded.RewardedAd
import com.google.android.gms.ads.rewarded.RewardedAdLoadCallback
import com.google.android.gms.ads.FullScreenContentCallback
import com.google.android.gms.ads.AdError
import android.app.Activity
import android.content.Context


import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.core.view.WindowCompat
import com.wizaicorp.apkfactory.ui.AppNavigation
import com.wizaicorp.apkfactory.ui.theme.ApkFactoryTheme

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        MobileAds.initialize(this) {}
        loadRewardedAd(this)
        
        // Android'in Light Mod inadını KESİN olarak ezen çekirdek komutları:
        WindowCompat.setDecorFitsSystemWindows(window, false)
        window.statusBarColor = android.graphics.Color.TRANSPARENT
        window.navigationBarColor = android.graphics.Color.TRANSPARENT
        WindowCompat.getInsetsController(window, window.decorView).apply {
            isAppearanceLightStatusBars = false // ZORLA BEYAZ İKON YAP (Arkaplan koyu diyoruz)
            isAppearanceLightNavigationBars = false
        }

        setContent {
            ApkFactoryTheme {
                AppNavigation()
            }
        }
    }
}

var mRewardedAd: RewardedAd? = null
var isAdLoading = false

fun loadRewardedAd(context: Context) {
    if (mRewardedAd != null || isAdLoading) return
    isAdLoading = true
    val adRequest = AdRequest.Builder().build()
    RewardedAd.load(context, "ca-app-pub-3940256099942544/5224354917", adRequest, object : RewardedAdLoadCallback() {
        override fun onAdFailedToLoad(adError: LoadAdError) { mRewardedAd = null; isAdLoading = false }
        override fun onAdLoaded(ad: RewardedAd) { mRewardedAd = ad; isAdLoading = false }
    })
}

fun showAdAndRun(context: Context, onComplete: () -> Unit) {
    val activity = context as? Activity
    if (activity != null && mRewardedAd != null) {
        mRewardedAd?.fullScreenContentCallback = object : FullScreenContentCallback() {
            override fun onAdDismissedFullScreenContent() {
                mRewardedAd = null
                loadRewardedAd(context)
                onComplete()
            }
            override fun onAdFailedToShowFullScreenContent(e: AdError) {
                mRewardedAd = null
                onComplete()
            }
        }
        mRewardedAd?.show(activity) {}
    } else {
        onComplete()
        if (activity != null) loadRewardedAd(activity)
    }
}
