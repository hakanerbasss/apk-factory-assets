package com.wizaicorp.apkfactory.ui.theme

import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color

private val DarkColors = darkColorScheme(
    primary        = Color(0xFF4B7BFF),
    secondary      = Color(0xFF7C5CFC),
    background     = Color(0xFF0A0A10),
    surface        = Color(0xFF13131A),
    surfaceVariant = Color(0xFF1A1A24),
    onBackground   = Color(0xFFFFFFFF),
    onSurface      = Color(0xFFFFFFFF),
    onPrimary      = Color(0xFFFFFFFF),
)

@Composable
fun ApkFactoryTheme(content: @Composable () -> Unit) {
    MaterialTheme(
        colorScheme = DarkColors,
        content = content
    )
}
