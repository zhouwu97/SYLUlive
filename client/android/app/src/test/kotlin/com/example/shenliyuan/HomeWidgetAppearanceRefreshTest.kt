package com.example.shenliyuan

import android.content.Context
import android.appwidget.AppWidgetHostView
import android.graphics.Color
import android.graphics.drawable.GradientDrawable
import android.widget.FrameLayout
import android.widget.AbsListView
import android.widget.RemoteViewsService
import android.widget.TextView
import androidx.test.core.app.ApplicationProvider
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

/** 模拟 OEM 启动器复用 RemoteViewsFactory，实际 apply 每次刷新生成的 RemoteViews。 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class HomeWidgetAppearanceRefreshTest {
    private val context = ApplicationProvider.getApplicationContext<Context>()

    @Before fun seed() {
        context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
            .edit().clear()
            .putString("flutter.widget_course_data", """{"schema_version":1,"courses":[
                {"name":"课程一","time":"08:00-09:40","location":"A310","teacher":"教师","color":"#3B82F6"},
                {"name":"课程二","time":"10:00-11:40","location":"A410","teacher":"教师","color":"#3B82F6"}]}""")
            .putString("flutter.widget_exam_data", """{"schema_version":1,"exams":[
                {"name":"考试一","date":"2099-12-01","time":"08:00-10:00","location":"A310"},
                {"name":"考试二","date":"2099-12-02","time":"08:00-10:00","location":"A410"}]}""")
            .commit()
    }

    private fun save(theme: NativeHomeWidgetTheme, font: NativeHomeWidgetFontSize) {
        HomeWidgetAppearanceStore.synchronize(context,
            theme.storageName, "课表", font.storageName,
            theme.storageName, "考试", font.storageName)
    }

    private fun factory(variant: NativeWidgetVariant): RemoteViewsService.RemoteViewsFactory {
        val theme = HomeWidgetThemeConfig.resolve(context, NativeHomeWidgetTheme.LIGHT)
        val typography = HomeWidgetTypography.resolve(variant.size, NativeHomeWidgetFontSize.STANDARD)
        return if (variant.kind == NativeHomeWidgetKind.COURSE) {
            CourseRemoteViewsFactory(context, variant, theme, typography, NativeHomeWidgetFontSize.STANDARD)
        } else {
            ExamRemoteViewsFactory(context, variant, theme, typography, NativeHomeWidgetFontSize.STANDARD)
        }
    }

    private fun assertAppearance(factory: RemoteViewsService.RemoteViewsFactory,
        variant: NativeWidgetVariant, theme: NativeHomeWidgetTheme, font: NativeHomeWidgetFontSize) {
        factory.onDataSetChanged()
        assertEquals(2, factory.count)
        val views = factory.getViewAt(0)
        assertEquals(variant.itemLayoutResource(font), views.layoutId)
        val root = views.apply(context, FrameLayout(context))
        val title = root.findViewById<TextView>(
            if (variant.kind == NativeHomeWidgetKind.COURSE) R.id.tv_course_name else R.id.tv_exam_name)
        val palette = HomeWidgetThemeConfig.resolve(context, theme)
        val typography = HomeWidgetTypography.resolve(variant.size, font)
        assertEquals(palette.primaryTextColor, title.currentTextColor)
        assertEquals(typography.primarySp * context.resources.displayMetrics.scaledDensity, title.textSize, 0.01f)
        val detail = root.findViewById<TextView>(
            if (variant.kind == NativeHomeWidgetKind.COURSE) R.id.tv_course_time else R.id.tv_exam_time)
        assertEquals(palette.secondaryTextColor, detail.currentTextColor)
        assertEquals(typography.secondarySp * context.resources.displayMetrics.scaledDensity, detail.textSize, 0.01f)
    }

    @Test fun `所有尺寸的复用工厂同步更新颜色和字号及布局`() {
        for (variant in NativeWidgetVariant.entries) {
            val factory = factory(variant)
            for ((theme, font) in listOf(
                NativeHomeWidgetTheme.LIGHT to NativeHomeWidgetFontSize.STANDARD,
                NativeHomeWidgetTheme.CAMPUS_BLUE to NativeHomeWidgetFontSize.EXTRA_LARGE,
                NativeHomeWidgetTheme.DARK to NativeHomeWidgetFontSize.SMALL,
                NativeHomeWidgetTheme.LIGHT to NativeHomeWidgetFontSize.LARGE,
            )) {
                save(theme, font)
                assertAppearance(factory, variant, theme, font)
            }
            assertTrue(factory.viewTypeCount >= 2)
        }
    }

    @Test fun `独立材质开关覆盖全部尺寸根容器不改变文字颜色`() {
        for (theme in listOf(NativeHomeWidgetTheme.LIGHT, NativeHomeWidgetTheme.DARK, NativeHomeWidgetTheme.CAMPUS_BLUE)) {
            save(theme, NativeHomeWidgetFontSize.EXTRA_LARGE)
            for (glass in listOf(true, false)) {
                HomeWidgetAppearanceStore.synchronize(context, null, null, null, null, null, null,
                    courseFrostedGlass = glass, examFrostedGlass = glass)
                for (variant in NativeWidgetVariant.entries) {
                    assertEquals(glass, HomeWidgetAppearanceStore.read(context, variant.kind).frostedGlass)
                    val root = HomeWidgetRenderer.build(context, 42 + variant.ordinal, variant).apply(context, FrameLayout(context))
                    val drawable = root.findViewById<android.view.View>(android.R.id.background).background as GradientDrawable
                    assertEquals(if (glass) 199 else 242, Color.alpha(drawable.color!!.defaultColor))
                    val title = root.findViewById<TextView>(R.id.tv_widget_title)
                    assertEquals(HomeWidgetThemeConfig.resolve(context, theme).primaryTextColor, title.currentTextColor)
                }
            }
        }
    }

    @Test fun `同一工厂并发刷新不会重复追加条目或暴露半更新外观`() {
        save(NativeHomeWidgetTheme.CAMPUS_BLUE, NativeHomeWidgetFontSize.EXTRA_LARGE)
        val pool = java.util.concurrent.Executors.newFixedThreadPool(6)
        try {
            for (variant in NativeWidgetVariant.entries) {
                val factory = factory(variant)
                val tasks = (1..120).map { pool.submit {
                    factory.onDataSetChanged()
                    assertEquals(2, factory.count)
                    assertEquals(variant.itemLayoutResource(NativeHomeWidgetFontSize.EXTRA_LARGE), factory.getViewAt(1).layoutId)
                } }
                tasks.forEach { it.get(15, java.util.concurrent.TimeUnit.SECONDS) }
                assertEquals(2, factory.count)
            }
        } finally { pool.shutdownNow() }
    }

    @Test fun `跟随系统的复用工厂在日夜切换后重新解析颜色`() {
        save(NativeHomeWidgetTheme.SYSTEM, NativeHomeWidgetFontSize.STANDARD)
        val factory = factory(NativeWidgetVariant.COURSE_2X2)
        RuntimeEnvironment.setQualifiers("+notnight")
        assertAppearance(factory, NativeWidgetVariant.COURSE_2X2, NativeHomeWidgetTheme.LIGHT, NativeHomeWidgetFontSize.STANDARD)
        RuntimeEnvironment.setQualifiers("+night")
        assertAppearance(factory, NativeWidgetVariant.COURSE_2X2, NativeHomeWidgetTheme.DARK, NativeHomeWidgetFontSize.STANDARD)
    }

    @Test fun `延迟应用和连续重用桌面视图时背景标题条目必须是同一主题快照`() {
        for (variant in NativeWidgetVariant.entries) {
            var root: android.view.View? = null
            for (glass in listOf(false, true)) {
                for (theme in listOf(NativeHomeWidgetTheme.LIGHT, NativeHomeWidgetTheme.DARK, NativeHomeWidgetTheme.CAMPUS_BLUE, NativeHomeWidgetTheme.LIGHT)) {
                    save(theme, NativeHomeWidgetFontSize.EXTRA_LARGE)
                    HomeWidgetAppearanceStore.synchronize(context, null, null, null, null, null, null, glass, glass)
                    val snapshot = HomeWidgetRenderer.build(context, 70 + variant.ordinal, variant)
                    // 模拟旧请求在新偏好保存之后才被启动器应用，不允许条目重新读全局主题。
                    save(if (theme == NativeHomeWidgetTheme.DARK) NativeHomeWidgetTheme.LIGHT else NativeHomeWidgetTheme.DARK,
                        NativeHomeWidgetFontSize.SMALL)
                    if (root == null) {
                        val host = AppWidgetHostView(context)
                        root = snapshot.apply(context, host)
                        host.addView(root)
                    } else snapshot.reapply(context, root)
                    val palette = HomeWidgetThemeConfig.resolve(context, theme)
                    val background = root!!.findViewById<android.view.View>(android.R.id.background).background as GradientDrawable
                    val expected = context.getDrawable(palette.backgroundResource(glass)) as GradientDrawable
                    assertEquals(expected.color!!.defaultColor, background.color!!.defaultColor)
                    assertEquals(palette.primaryTextColor, root.findViewById<TextView>(R.id.tv_widget_title).currentTextColor)
                    val list = root.findViewById<AbsListView>(variant.listViewId)
                    assertNotNull("列表必须随背景一次提交，不能等待独立服务回调", list.adapter)
                    assertEquals(2, list.adapter.count)
                    val item = list.adapter.getView(0, null, list)
                    val titleId = if (variant.kind == NativeHomeWidgetKind.COURSE) R.id.tv_course_name else R.id.tv_exam_name
                    val title = item.findViewById<TextView>(titleId)
                    assertEquals(palette.primaryTextColor, title.currentTextColor)
                    assertEquals(HomeWidgetTypography.resolve(variant.size, NativeHomeWidgetFontSize.EXTRA_LARGE).primarySp * context.resources.displayMetrics.scaledDensity,
                        title.textSize, 0.01f)
                }
            }
        }
    }

    @Test @Config(sdk = [31])
    fun `Android12空数据失败降级和恢复也随整页外观更新`() {
        val prefs = context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
        for (variant in NativeWidgetVariant.entries) {
            seed()
            save(NativeHomeWidgetTheme.DARK, NativeHomeWidgetFontSize.STANDARD)
            val key = if (variant.kind == NativeHomeWidgetKind.COURSE) "flutter.widget_course_data" else "flutter.widget_exam_data"
            val original = prefs.getString(key, null)!!
            for ((raw, count) in listOf("{invalid" to 0, original to 2)) {
                prefs.edit().putString(key, raw).commit()
                val root = HomeWidgetRenderer.build(context, 91 + variant.ordinal, variant).apply(context, AppWidgetHostView(context))
                val list = root.findViewById<AbsListView>(variant.listViewId)
                assertEquals(count, list.adapter.count)
                val background = root.findViewById<android.view.View>(android.R.id.background).background as GradientDrawable
                assertEquals(Color.parseColor("#F21F2937"), background.color!!.defaultColor)
                assertEquals(if (count == 0) android.view.View.VISIBLE else android.view.View.GONE,
                    root.findViewById<android.view.View>(R.id.empty_view).visibility)
            }
        }
    }

    @Test @Config(sdk = [28])
    fun `Android9保留服务列表且深色根背景和标题正常应用`() {
        save(NativeHomeWidgetTheme.DARK, NativeHomeWidgetFontSize.EXTRA_LARGE)
        for (variant in NativeWidgetVariant.entries) {
            val root = HomeWidgetRenderer.build(context, 115 + variant.ordinal, variant).apply(context, FrameLayout(context))
            val background = root.findViewById<android.view.View>(android.R.id.background).background as GradientDrawable
            assertEquals(Color.parseColor("#F21F2937"), background.color!!.defaultColor)
            assertEquals(Color.parseColor("#F9FAFB"), root.findViewById<TextView>(R.id.tv_widget_title).currentTextColor)
        }
    }
}
