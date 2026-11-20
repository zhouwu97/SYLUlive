package com.example.shenliyuan

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.UserManager

class LauncherIconUpdateReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        if (intent?.action != Intent.ACTION_MY_PACKAGE_REPLACED) return
        if (LauncherIconManager.isInForeground()) return
        val userManager = context.getSystemService(UserManager::class.java)
        if (userManager != null && !userManager.isUserUnlocked) return
        LauncherIconManager.applyIfNeeded(context.applicationContext)
    }
}
