package com.example.shenliyuan

import android.content.Context
import android.content.res.Configuration
import android.graphics.Color
import org.json.JSONObject

enum class NativeHomeWidgetKind(val storageName: String, val defaultTitle: String) {
    COURSE("course", "沈理校园"),
    EXAM("exam", "考试日程"),
}

enum class NativeHomeWidgetTheme(val storageName: String) {
    SYSTEM("system"),
    APP_THEME("appTheme"),
    LIGHT("light"),
    DARK("dark"),
    CAMPUS_BLUE("campusBlue");

    companion object {
        fun fromStorage(value: String?): NativeHomeWidgetTheme =
            entries.firstOrNull { it.storageName == value } ?: SYSTEM

        fun fromLegacyTextColor(value: String?): NativeHomeWidgetTheme =
            if (value.equals("#FFFFFF", ignoreCase = true) || value == "#FFF") DARK else LIGHT
    }
}

enum class NativeHomeWidgetFontSize(val storageName: String) {
    SMALL("small"),
    STANDARD("standard"),
    LARGE("large"),
    EXTRA_LARGE("extraLarge");

    companion object {
        fun fromStorage(value: String?): NativeHomeWidgetFontSize =
            entries.firstOrNull { it.storageName == value } ?: STANDARD
    }
}

data class NativeHomeWidgetAppearance(
    val kind: NativeHomeWidgetKind,
    val theme: NativeHomeWidgetTheme,
    val title: String,
    val fontSize: NativeHomeWidgetFontSize,
    val frostedGlass: Boolean = false,
)

data class HomeWidgetThemeConfig(
    val resolvedTheme: NativeHomeWidgetTheme,
    val backgroundResource: Int,
    val primaryTextColor: Int,
    val secondaryTextColor: Int,
    val mutedTextColor: Int,
    val accentColor: Int,
    val dividerColor: Int,
    val backgroundTintColor: Int? = null,
) {
    fun backgroundResource(frostedGlass: Boolean): Int = if (!frostedGlass) backgroundResource else when (resolvedTheme) {
        NativeHomeWidgetTheme.DARK -> R.drawable.widget_bg_glass_dark
        NativeHomeWidgetTheme.CAMPUS_BLUE -> R.drawable.widget_bg_glass_campus_blue
        else -> R.drawable.widget_bg_glass_light
    }

    companion object {
        private const val PREFS_NAME = "FlutterSharedPreferences"
        private const val APP_PALETTE_KEY = "flutter.widget_app_palette_v1"

        private fun isNightMode(context: Context): Boolean {
            val nightMode = context.resources.configuration.uiMode and
                Configuration.UI_MODE_NIGHT_MASK
            return nightMode == Configuration.UI_MODE_NIGHT_YES
        }

        private fun parseArgbOrRgb(raw: String): Int {
            val trimmed = raw.trim()
            return Color.parseColor(trimmed)
        }

        private fun resolveAppTheme(context: Context): HomeWidgetThemeConfig? {
            val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            val raw = prefs.getString(APP_PALETTE_KEY, null) ?: return null
            return try {
                val root = JSONObject(raw)
                val variantKey = if (isNightMode(context)) "dark" else "light"
                val variant = root.optJSONObject(variantKey) ?: return null
                val bgRaw = parseArgbOrRgb(variant.getString("background"))
                // 不透明度统一由 RemoteViews setImageAlpha 控制（毛玻璃 209，否则 255）。
                val opaqueBg = bgRaw or (0xFF shl 24)
                HomeWidgetThemeConfig(
                    resolvedTheme = NativeHomeWidgetTheme.APP_THEME,
                    backgroundResource = android.R.color.transparent,
                    primaryTextColor = parseArgbOrRgb(variant.getString("primaryText")),
                    secondaryTextColor = parseArgbOrRgb(variant.getString("secondaryText")),
                    mutedTextColor = parseArgbOrRgb(variant.getString("mutedText")),
                    accentColor = parseArgbOrRgb(variant.getString("accent")),
                    dividerColor = parseArgbOrRgb(variant.getString("divider")),
                    backgroundTintColor = opaqueBg,
                )
            } catch (_: Exception) {
                null
            }
        }

        fun resolve(context: Context, theme: NativeHomeWidgetTheme): HomeWidgetThemeConfig {
            if (theme == NativeHomeWidgetTheme.APP_THEME) {
                resolveAppTheme(context)?.let { return it }
            }

            val resolved = if (theme == NativeHomeWidgetTheme.SYSTEM || theme == NativeHomeWidgetTheme.APP_THEME) {
                if (isNightMode(context)) {
                    NativeHomeWidgetTheme.DARK
                } else {
                    NativeHomeWidgetTheme.LIGHT
                }
            } else {
                theme
            }

            return when (resolved) {
                NativeHomeWidgetTheme.DARK -> HomeWidgetThemeConfig(
                    resolvedTheme = NativeHomeWidgetTheme.DARK,
                    backgroundResource = R.drawable.widget_bg_dark,
                    primaryTextColor = Color.parseColor("#F9FAFB"),
                    secondaryTextColor = Color.parseColor("#D1D5DB"),
                    mutedTextColor = Color.parseColor("#9CA3AF"),
                    accentColor = Color.parseColor("#60A5FA"),
                    dividerColor = Color.parseColor("#4B5563"),
                )
                NativeHomeWidgetTheme.CAMPUS_BLUE -> HomeWidgetThemeConfig(
                    resolvedTheme = NativeHomeWidgetTheme.CAMPUS_BLUE,
                    backgroundResource = R.drawable.widget_bg_campus_blue,
                    primaryTextColor = Color.parseColor("#1E3A8A"),
                    secondaryTextColor = Color.parseColor("#475569"),
                    mutedTextColor = Color.parseColor("#94A3B8"),
                    accentColor = Color.parseColor("#3B82F6"),
                    dividerColor = Color.parseColor("#BFDBFE"),
                )
                NativeHomeWidgetTheme.LIGHT,
                NativeHomeWidgetTheme.SYSTEM,
                NativeHomeWidgetTheme.APP_THEME -> HomeWidgetThemeConfig(
                    resolvedTheme = NativeHomeWidgetTheme.LIGHT,
                    backgroundResource = R.drawable.widget_bg_light,
                    primaryTextColor = Color.parseColor("#111827"),
                    secondaryTextColor = Color.parseColor("#4B5563"),
                    mutedTextColor = Color.parseColor("#9CA3AF"),
                    accentColor = Color.parseColor("#3B82F6"),
                    dividerColor = Color.parseColor("#E5E7EB"),
                )
            }
        }
    }
}

object HomeWidgetAppearanceStore {
    private const val PREFS_NAME = "FlutterSharedPreferences"
    private const val COURSE_THEME = "flutter.widget_course_theme"
    private const val EXAM_THEME = "flutter.widget_exam_theme"
    private const val COURSE_TITLE = "flutter.widget_course_title"
    private const val EXAM_TITLE = "flutter.widget_exam_title"
    private const val COURSE_FONT_SIZE = "flutter.widget_course_font_size"
    private const val EXAM_FONT_SIZE = "flutter.widget_exam_font_size"
    private const val APP_PALETTE = "flutter.widget_app_palette_v1"
    private const val LEGACY_TEXT_COLOR = "flutter.widget_text_color"
    private const val LEGACY_TITLE = "flutter.widget_title"

    fun read(context: Context, kind: NativeHomeWidgetKind): NativeHomeWidgetAppearance {
        migrateLegacy(context)
        val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val themeKey = if (kind == NativeHomeWidgetKind.COURSE) COURSE_THEME else EXAM_THEME
        val titleKey = if (kind == NativeHomeWidgetKind.COURSE) COURSE_TITLE else EXAM_TITLE
        val fontSizeKey = fontSizeStorageKey(kind)
        return NativeHomeWidgetAppearance(
            kind = kind,
            theme = NativeHomeWidgetTheme.fromStorage(prefs.getString(themeKey, null)),
            title = prefs.getString(titleKey, kind.defaultTitle)
                ?.trim()
                ?.ifBlank { kind.defaultTitle }
                ?: kind.defaultTitle,
            fontSize = NativeHomeWidgetFontSize.fromStorage(
                prefs.getString(fontSizeKey, null),
            ),
            frostedGlass = prefs.getBoolean(glassKey(kind), false),
        )
    }

    /**
     * Flutter 偏好缓存与原生 SharedPreferences 可能短暂不同步；刷新前在原生侧一次提交完整快照，
     * 保证背景、标题和列表服务读取的是同一版本。
     */
    fun synchronize(
        context: Context,
        courseTheme: String?,
        courseTitle: String?,
        courseFontSize: String?,
        examTheme: String?,
        examTitle: String?,
        examFontSize: String?,
        courseFrostedGlass: Boolean? = null,
        examFrostedGlass: Boolean? = null,
        appPalette: String? = null,
    ) {
        val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val editor = prefs.edit()
        courseFrostedGlass?.let { editor.putBoolean(glassKey(NativeHomeWidgetKind.COURSE), it) }
        examFrostedGlass?.let { editor.putBoolean(glassKey(NativeHomeWidgetKind.EXAM), it) }
        appPalette?.let { editor.putString(APP_PALETTE, it) }
        courseTheme?.let {
            editor.putString(COURSE_THEME, NativeHomeWidgetTheme.fromStorage(it).storageName)
        }
        courseFontSize?.let {
            editor.putString(COURSE_FONT_SIZE, NativeHomeWidgetFontSize.fromStorage(it).storageName)
        }
        examTheme?.let {
            editor.putString(EXAM_THEME, NativeHomeWidgetTheme.fromStorage(it).storageName)
        }
        examFontSize?.let {
            editor.putString(EXAM_FONT_SIZE, NativeHomeWidgetFontSize.fromStorage(it).storageName)
        }
        if (courseTitle != null) {
            editor.putString(
                COURSE_TITLE,
                courseTitle.trim().ifBlank { NativeHomeWidgetKind.COURSE.defaultTitle },
            )
        }
        if (examTitle != null) {
            editor.putString(
                EXAM_TITLE,
                examTitle.trim().ifBlank { NativeHomeWidgetKind.EXAM.defaultTitle },
            )
        }
        if (!editor.commit()) throw IllegalStateException("桌面小组件原生外观同步失败")
    }

    /** 暴露纯字符串映射，便于在不启动 Android/Launcher 环境时做契约测试。 */
    fun fontSizeStorageKey(kind: NativeHomeWidgetKind): String =
        if (kind == NativeHomeWidgetKind.COURSE) COURSE_FONT_SIZE else EXAM_FONT_SIZE

    private fun glassKey(kind: NativeHomeWidgetKind) = "flutter.widget_${kind.storageName}_frosted_glass"

    fun migrateLegacy(context: Context) {
        val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val legacyTheme = if (prefs.contains(LEGACY_TEXT_COLOR)) {
            NativeHomeWidgetTheme.fromLegacyTextColor(prefs.getString(LEGACY_TEXT_COLOR, null))
        } else {
            NativeHomeWidgetTheme.SYSTEM
        }
        val legacyTitle = prefs.getString(LEGACY_TITLE, null)?.trim()?.takeIf { it.isNotEmpty() }
        val editor = prefs.edit()
        if (!prefs.contains(COURSE_THEME)) editor.putString(COURSE_THEME, legacyTheme.storageName)
        if (!prefs.contains(EXAM_THEME)) editor.putString(EXAM_THEME, legacyTheme.storageName)
        if (!prefs.contains(COURSE_TITLE)) {
            editor.putString(COURSE_TITLE, legacyTitle ?: NativeHomeWidgetKind.COURSE.defaultTitle)
        }
        if (!prefs.contains(EXAM_TITLE)) {
            editor.putString(EXAM_TITLE, legacyTitle ?: NativeHomeWidgetKind.EXAM.defaultTitle)
        }
        if (!prefs.contains(COURSE_FONT_SIZE)) {
            editor.putString(COURSE_FONT_SIZE, NativeHomeWidgetFontSize.STANDARD.storageName)
        }
        if (!prefs.contains(EXAM_FONT_SIZE)) {
            editor.putString(EXAM_FONT_SIZE, NativeHomeWidgetFontSize.STANDARD.storageName)
        }
        editor.apply()
    }
}
