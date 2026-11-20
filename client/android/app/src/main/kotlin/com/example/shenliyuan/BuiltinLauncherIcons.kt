package com.example.shenliyuan

import android.app.Activity
import android.app.AppOpsManager
import android.app.Application
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.Process
import android.provider.Settings
import androidx.core.content.pm.ShortcutInfoCompat
import androidx.core.content.pm.ShortcutManagerCompat
import androidx.core.graphics.drawable.IconCompat
import java.io.File

data class BuiltinLauncherIcon(
    val id: String,
    val displayName: String,
    val mipmapRes: Int,
    val foregroundRes: Int,
    val staticAliasClass: String,
    val themedAliasClass: String,
    val defaultEnabledStatic: Boolean = false,
)

object BuiltinLauncherIcons {
    // 维护者 1024×1024 备选图标源图到位前仅打包 default；未知与未打包 ID 按契约回退 default。
    val entries: List<BuiltinLauncherIcon> = listOf(
        BuiltinLauncherIcon(
            id = "default",
            displayName = "沈理青",
            mipmapRes = R.mipmap.ic_launcher_main,
            foregroundRes = R.mipmap.ic_launcher_foreground,
            staticAliasClass = "com.example.shenliyuan.LauncherDefaultStatic",
            themedAliasClass = "com.example.shenliyuan.LauncherDefault",
            defaultEnabledStatic = true,
        ),
    )

    fun resolve(id: String?): BuiltinLauncherIcon =
        entries.firstOrNull { it.id == id } ?: entries.first()
}

object LauncherIconManager {
    private const val PREFS_NAME = "FlutterSharedPreferences"
    private const val KEY_DESIRED_ID = "flutter.launcher_icon_id_v1"
    private const val KEY_DESIRED_THEMED = "flutter.launcher_icon_themed_v1"
    private const val MIUI_OP_INSTALL_SHORTCUT = 10017

    private val handler = Handler(Looper.getMainLooper())
    private var lifecycleRegistered = false
    @Volatile
    private var startedActivityCount = 0

    private val backgroundApplyRunnable = Runnable {
        val app = appContext ?: return@Runnable
        if (startedActivityCount == 0) {
            applyIfNeeded(app)
        }
    }

    private var appContext: Context? = null

    fun isInForeground(): Boolean = startedActivityCount > 0

    @Synchronized
    fun registerLifecycleObserver(application: Application) {
        if (lifecycleRegistered) return
        lifecycleRegistered = true
        appContext = application.applicationContext
        application.registerActivityLifecycleCallbacks(object : Application.ActivityLifecycleCallbacks {
            override fun onActivityCreated(activity: Activity, savedInstanceState: Bundle?) = Unit
            override fun onActivityStarted(activity: Activity) {
                startedActivityCount += 1
                handler.removeCallbacks(backgroundApplyRunnable)
            }
            override fun onActivityResumed(activity: Activity) = Unit
            override fun onActivityPaused(activity: Activity) = Unit
            override fun onActivityStopped(activity: Activity) {
                if (startedActivityCount > 0) {
                    startedActivityCount -= 1
                }
                if (startedActivityCount == 0 && !activity.isChangingConfigurations) {
                    handler.removeCallbacks(backgroundApplyRunnable)
                    handler.postDelayed(backgroundApplyRunnable, 1000L)
                }
            }
            override fun onActivitySaveInstanceState(activity: Activity, outState: Bundle) = Unit
            override fun onActivityDestroyed(activity: Activity) = Unit
        })
    }

    fun setDesired(context: Context, id: String?, themed: Boolean) {
        val resolved = BuiltinLauncherIcons.resolve(id)
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .edit()
            .putString(KEY_DESIRED_ID, resolved.id)
            .putBoolean(KEY_DESIRED_THEMED, themed)
            .apply()
    }

    fun current(context: Context): Map<String, Any> {
        val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val desiredIcon = BuiltinLauncherIcons.resolve(prefs.getString(KEY_DESIRED_ID, "default"))
        val desiredThemed = prefs.getBoolean(KEY_DESIRED_THEMED, false)
        val pm = context.packageManager

        var activeId = "default"
        for (icon in BuiltinLauncherIcons.entries) {
            val staticEnabled = isAliasEffectivelyEnabled(
                pm = pm,
                packageName = context.packageName,
                aliasClass = icon.staticAliasClass,
                manifestDefaultEnabled = icon.defaultEnabledStatic,
            )
            val themedEnabled = isAliasEffectivelyEnabled(
                pm = pm,
                packageName = context.packageName,
                aliasClass = icon.themedAliasClass,
                manifestDefaultEnabled = false,
            )
            if (staticEnabled || themedEnabled) {
                activeId = icon.id
                break
            }
        }

        return mapOf(
            "activeId" to activeId,
            "desiredId" to desiredIcon.id,
            "themed" to desiredThemed,
            "sdkInt" to Build.VERSION.SDK_INT,
            "pinShortcutSupported" to ShortcutManagerCompat.isRequestPinShortcutSupported(context),
        )
    }

    @Synchronized
    fun applyIfNeeded(context: Context) {
        val pm = context.packageManager
        val pkg = context.packageName

        // 确保深链与小部件所依赖的 MainActivity 始终启用。
        val mainComponent = ComponentName(pkg, MainActivity::class.java.name)
        val mainState = pm.getComponentEnabledSetting(mainComponent)
        if (mainState == PackageManager.COMPONENT_ENABLED_STATE_DISABLED ||
            mainState == PackageManager.COMPONENT_ENABLED_STATE_DISABLED_USER
        ) {
            pm.setComponentEnabledSetting(
                mainComponent,
                PackageManager.COMPONENT_ENABLED_STATE_ENABLED,
                PackageManager.DONT_KILL_APP,
            )
        }

        val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val targetIcon = BuiltinLauncherIcons.resolve(prefs.getString(KEY_DESIRED_ID, "default"))
        val useThemed = Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            prefs.getBoolean(KEY_DESIRED_THEMED, false)
        val targetAlias = if (useThemed) targetIcon.themedAliasClass else targetIcon.staticAliasClass

        val allAliases = BuiltinLauncherIcons.entries.flatMap {
            listOf(
                it.staticAliasClass to it.defaultEnabledStatic,
                it.themedAliasClass to false,
            )
        }

        val alreadyAligned = allAliases.all { (aliasClass, defaultEnabled) ->
            val enabled = isAliasEffectivelyEnabled(pm, pkg, aliasClass, defaultEnabled)
            if (aliasClass == targetAlias) enabled else !enabled
        }
        if (alreadyAligned) return

        // 先启用目标 alias，再禁用其余 alias，每次调用均携带 DONT_KILL_APP。
        pm.setComponentEnabledSetting(
            ComponentName(pkg, targetAlias),
            PackageManager.COMPONENT_ENABLED_STATE_ENABLED,
            PackageManager.DONT_KILL_APP,
        )
        for ((aliasClass, _) in allAliases) {
            if (aliasClass == targetAlias) continue
            pm.setComponentEnabledSetting(
                ComponentName(pkg, aliasClass),
                PackageManager.COMPONENT_ENABLED_STATE_DISABLED,
                PackageManager.DONT_KILL_APP,
            )
        }
    }

    private fun isAliasEffectivelyEnabled(
        pm: PackageManager,
        packageName: String,
        aliasClass: String,
        manifestDefaultEnabled: Boolean,
    ): Boolean {
        return when (pm.getComponentEnabledSetting(ComponentName(packageName, aliasClass))) {
            PackageManager.COMPONENT_ENABLED_STATE_ENABLED -> true
            PackageManager.COMPONENT_ENABLED_STATE_DEFAULT -> manifestDefaultEnabled
            else -> false
        }
    }

    fun requestPinThemeShortcut(
        context: Context,
        imagePath: String?,
        themeId: String?,
        label: String?,
    ): Map<String, Any?> {
        if (!ShortcutManagerCompat.isRequestPinShortcutSupported(context)) {
            return mapOf("status" to "unsupported", "message" to "当前桌面不支持创建固定快捷方式")
        }
        if (needsXiaomiShortcutPermission(context)) {
            return mapOf("status" to "permission_required")
        }
        if (imagePath.isNullOrBlank()) {
            return mapOf("status" to "failed", "message" to "未找到主题图标文件")
        }
        val file = File(imagePath)
        if (!file.exists() || !file.isFile) {
            return mapOf("status" to "failed", "message" to "主题图标文件不存在")
        }
        val decoded = BitmapFactory.decodeFile(file.absolutePath)
            ?: return mapOf("status" to "failed", "message" to "主题图标无法解码")
        val scaled = if (decoded.width == 432 && decoded.height == 432) {
            decoded
        } else {
            Bitmap.createScaledBitmap(decoded, 432, 432, true).also {
                if (it !== decoded) decoded.recycle()
            }
        }

        val safeThemeId = (themeId ?: "custom").replace(Regex("[^a-zA-Z0-9_-]"), "_")
        val safeLabel = label?.trim()?.takeIf { it.isNotEmpty() } ?: "沈理校园"
        val launchIntent = Intent(context, MainActivity::class.java).apply {
            action = Intent.ACTION_VIEW
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val shortcut = ShortcutInfoCompat.Builder(context, "theme_$safeThemeId")
            .setShortLabel(safeLabel)
            .setLongLabel(safeLabel)
            .setIcon(IconCompat.createWithAdaptiveBitmap(scaled))
            .setIntent(launchIntent)
            .build()

        val accepted = ShortcutManagerCompat.requestPinShortcut(context, shortcut, null)
        return mapOf("status" to if (accepted) "requested" else "rejected")
    }

    private fun needsXiaomiShortcutPermission(context: Context): Boolean {
        val manufacturer = Build.MANUFACTURER ?: ""
        val brand = Build.BRAND ?: ""
        val isXiaomiFamily = listOf("xiaomi", "redmi", "poco").any {
            manufacturer.equals(it, ignoreCase = true) || brand.equals(it, ignoreCase = true)
        }
        if (!isXiaomiFamily) return false
        return try {
            val appOps = context.getSystemService(Context.APP_OPS_SERVICE) as? AppOpsManager
                ?: return false
            val method = AppOpsManager::class.java.getMethod(
                "checkOpNoThrow",
                Int::class.javaPrimitiveType,
                Int::class.javaPrimitiveType,
                String::class.java,
            )
            val mode = method.invoke(
                appOps,
                MIUI_OP_INSTALL_SHORTCUT,
                Process.myUid(),
                context.packageName,
            ) as? Int ?: return false
            // 1 = MODE_IGNORED（拒绝），5 = MIUI MODE_ASK（询问但未放行后台固定快捷方式）
            mode == 1 || mode == 5
        } catch (_: Exception) {
            false
        }
    }

    fun openShortcutPermissionSettings(context: Context): Boolean {
        val miuiIntent = Intent("miui.intent.action.APP_PERM_EDITOR").apply {
            putExtra("extra_pkgname", context.packageName)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        try {
            if (miuiIntent.resolveActivity(context.packageManager) != null) {
                context.startActivity(miuiIntent)
                return true
            }
        } catch (_: Exception) {
        }
        return try {
            val fallback = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                data = Uri.fromParts("package", context.packageName, null)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            context.startActivity(fallback)
            true
        } catch (_: Exception) {
            false
        }
    }
}
