package com.example.shenliyuan

import org.junit.Assert.assertEquals
import org.junit.Test

class HomeWidgetTypographyTest {
    @Test
    fun `空值和非法字号降级为 standard`() {
        assertEquals(
            NativeHomeWidgetFontSize.STANDARD,
            NativeHomeWidgetFontSize.fromStorage(null),
        )
        assertEquals(
            NativeHomeWidgetFontSize.STANDARD,
            NativeHomeWidgetFontSize.fromStorage("bad"),
        )
    }

    @Test
    fun `2x2 和 4x2 的三档字号映射符合规格`() {
        val compactSmall = HomeWidgetTypography.resolve(
            NativeHomeWidgetSize.SIZE_2X2,
            NativeHomeWidgetFontSize.SMALL,
        )
        val compactStandard = HomeWidgetTypography.resolve(
            NativeHomeWidgetSize.SIZE_2X2,
            NativeHomeWidgetFontSize.STANDARD,
        )
        val compactLarge = HomeWidgetTypography.resolve(
            NativeHomeWidgetSize.SIZE_2X2,
            NativeHomeWidgetFontSize.LARGE,
        )
        val detailedSmall = HomeWidgetTypography.resolve(
            NativeHomeWidgetSize.SIZE_4X2,
            NativeHomeWidgetFontSize.SMALL,
        )
        val detailedStandard = HomeWidgetTypography.resolve(
            NativeHomeWidgetSize.SIZE_4X2,
            NativeHomeWidgetFontSize.STANDARD,
        )
        val detailedLarge = HomeWidgetTypography.resolve(
            NativeHomeWidgetSize.SIZE_4X2,
            NativeHomeWidgetFontSize.LARGE,
        )

        assertEquals(12f, compactSmall.titleSp)
        assertEquals(13f, compactStandard.titleSp)
        assertEquals(14f, compactLarge.titleSp)
        assertEquals(13f, detailedSmall.titleSp)
        assertEquals(14f, detailedStandard.titleSp)
        assertEquals(15f, detailedLarge.titleSp)
        assertEquals(11f, compactStandard.primarySp)
        assertEquals(12f, detailedStandard.primarySp)
        assertEquals(9f, detailedLarge.tertiarySp)
    }

    @Test
    fun `课表和考试字号 key 独立映射`() {
        assertEquals(
            "flutter.widget_course_font_size",
            HomeWidgetAppearanceStore.fontSizeStorageKey(NativeHomeWidgetKind.COURSE),
        )
        assertEquals(
            "flutter.widget_exam_font_size",
            HomeWidgetAppearanceStore.fontSizeStorageKey(NativeHomeWidgetKind.EXAM),
        )
    }
}
