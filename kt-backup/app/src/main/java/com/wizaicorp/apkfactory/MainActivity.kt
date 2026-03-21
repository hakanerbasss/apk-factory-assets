package com.wizaicorp.apkfactory

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.core.view.WindowCompat
import com.wizaicorp.apkfactory.ui.AppNavigation
import com.wizaicorp.apkfactory.ui.theme.ApkFactoryTheme

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        
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
