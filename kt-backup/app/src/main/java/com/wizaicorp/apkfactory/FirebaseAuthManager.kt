package com.wizaicorp.apkfactory

import android.content.Context
import com.google.android.gms.auth.api.signin.GoogleSignIn
import com.google.android.gms.auth.api.signin.GoogleSignInAccount
import com.google.android.gms.auth.api.signin.GoogleSignInClient
import com.google.android.gms.auth.api.signin.GoogleSignInOptions
import com.google.android.gms.common.api.Scope
import com.google.android.gms.auth.GoogleAuthUtil
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

object FirebaseAuthManager {
    fun getFirebaseGoogleSignInClient(context: Context): GoogleSignInClient {
        val cloudPlatformScope = Scope("https://www.googleapis.com/auth/cloud-platform")
        
        val gso = GoogleSignInOptions.Builder(GoogleSignInOptions.DEFAULT_SIGN_IN)
            .requestEmail()
            .requestScopes(cloudPlatformScope)
            .requestIdToken("116625167475-l3l75adap7cgr5srfug042nreh5o3cvo.apps.googleusercontent.com")
            .requestServerAuthCode("116625167475-l3l75adap7cgr5srfug042nreh5o3cvo.apps.googleusercontent.com")
            .build()

        return GoogleSignIn.getClient(context, gso)
    }

    suspend fun getFirebaseAccessToken(context: Context, account: GoogleSignInAccount): String? {
        return withContext(Dispatchers.IO) {
            try {
                val scopeString = "oauth2:https://www.googleapis.com/auth/cloud-platform"
                GoogleAuthUtil.getToken(context, account.account!!, scopeString)
            } catch (e: Exception) {
                e.printStackTrace()
                null
            }
        }
    }
}
