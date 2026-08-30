package com.example.shenliyuan

import android.content.Context
import android.content.res.Configuration
import android.graphics.Color

enum class NativeHomeWidgetKind(val storageName: String, val defaultTitle: String) {
    COURSE("course", "沈理院课表"),
    EXAM("exam", "考试日程"),
}

enum class NativeHomeWidgetTheme(val storageName: String) {
    SYSTEM("system"),
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
    LARGE("large");

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
)

data class HomeWidgetThemeConfig(
    val backgroundResource: Int,
    val primaryTextColor: Int,
    val secondaryTextColor: Int,
    val mutedTextColor: Int,
    val accentColor: Int,
) {
    companion object {
        fun resolve(context: Context, theme: NativeHomeWidgetTheme): HomeWidgetThemeConfig {
            val resolved = if (theme == NativeHomeWidgetTheme.SYSTEM) {
                val nightMode = context.resources.configuration.uiMode and
                    Configuration.UI_MODE_NIGHT_MASK
                if (nightMode == Configuration.UI_MODE_NIGHT_YES) {
                    NativeHomeWidgetTheme.DARK
                } else {
                    NativeHomeWidgetTheme.LIGHT
                }
            } else {
                theme
            }

            return when (resolved) {
                NativeHomeWidgetTheme.DARK -> HomeWidgetThemeConfig(
                    backgroundResource = R.drawable.widget_bg_dark,
                    primaryTextColor = Color.parseColor("#F9FAFB"),
                    secondaryTextColor = Color.parseColor("#D1D5DB"),
                    mutedTextColor = Color.parseColor("#9CA3AF"),
                    accentColor = Color.parseColor("#60A5FA"),
                )
                NativeHomeWidgetTheme.CAMPUS_BLUE -> HomeWidgetThemeConfig(
                    backgroundResource = R.drawable.widget_bg_campus_blue,
                    primaryTextColor = Color.parseColor("#1E3A8A"),
                    secondaryTextColor = Color.parseColor("#475569"),
                    mutedTextColor = Color.parseColor("#94A3B8"),
                    accentColor = Color.parseColor("#3B82F6"),
                )
                NativeHomeWidgetTheme.LIGHT,
                NativeHomeWidgetTheme.SYSTEM -> HomeWidgetThemeConfig(
                    backgroundResource = R.drawable.widget_bg_light,
                    primaryTextColor = Color.parseColor("#111827"),
                    secondaryTextColor = Color.parseColor("#4B5563"),
                    mutedTextColor = Color.parseColor("#9CA3AF"),
                    accentColor = Color.parseColor("#3B82F6"),
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
        )
    }

    /** 暴露纯字符串映射，便于在不启动 Android/Launcher 环境时做契约测试。 */
    fun fontSizeStorageKey(kind: NativeHomeWidgetKind): String =
        if (kind == NativeHomeWidgetKind.COURSE) COURSE_FONT_SIZE else EXAM_FONT_SIZE

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
