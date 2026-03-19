package com.wizaicorp.apkfactory

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import com.wizaicorp.apkfactory.ui.AppNavigation
import com.wizaicorp.apkfactory.ui.theme.ApkFactoryTheme

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent {
            ApkFactoryTheme {
                AppNavigation()
            }
        }
    }
}
