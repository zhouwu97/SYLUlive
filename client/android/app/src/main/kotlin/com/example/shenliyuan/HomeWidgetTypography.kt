package com.example.shenliyuan

/**
 * RemoteViews 使用的语义字号角色。
 *
 * 字号档位只改变 TextView 的 sp，不改变布局资源、条目高度、字段顺序或 maxItems。
 * standard 与现有 XML 基线一致，确保旧用户升级后视觉尺寸基本不变。
 */
data class HomeWidgetTypography(
    val titleSp: Float,
    val subtitleSp: Float,
    val primarySp: Float,
    val secondarySp: Float,
    val tertiarySp: Float,
    val badgeSp: Float,
    val emptySp: Float,
) {
    companion object {
        fun resolve(
            size: NativeHomeWidgetSize,
            fontSize: NativeHomeWidgetFontSize,
        ): HomeWidgetTypography {
            return when (size) {
                NativeHomeWidgetSize.SIZE_2X2 -> when (fontSize) {
                    NativeHomeWidgetFontSize.SMALL -> HomeWidgetTypography(
                        titleSp = 12f,
                        subtitleSp = 8f,
                        primarySp = 10f,
                        secondarySp = 8f,
                        tertiarySp = 8f,
                        badgeSp = 7f,
                        emptySp = 10f,
                    )
                    NativeHomeWidgetFontSize.STANDARD -> HomeWidgetTypography(
                        titleSp = 13f,
                        subtitleSp = 9f,
                        primarySp = 11f,
                        secondarySp = 9f,
                        tertiarySp = 8f,
                        badgeSp = 8f,
                        emptySp = 11f,
                    )
                    NativeHomeWidgetFontSize.LARGE -> HomeWidgetTypography(
                        titleSp = 14f,
                        subtitleSp = 10f,
                        primarySp = 12f,
                        secondarySp = 10f,
                        tertiarySp = 9f,
                        badgeSp = 9f,
                        emptySp = 12f,
                    )
                }
                NativeHomeWidgetSize.SIZE_4X2 -> when (fontSize) {
                    NativeHomeWidgetFontSize.SMALL -> HomeWidgetTypography(
                        titleSp = 13f,
                        subtitleSp = 9f,
                        primarySp = 11f,
                        secondarySp = 8f,
                        tertiarySp = 7f,
                        badgeSp = 7f,
                        emptySp = 11f,
                    )
                    NativeHomeWidgetFontSize.STANDARD -> HomeWidgetTypography(
                        titleSp = 14f,
                        subtitleSp = 10f,
                        primarySp = 12f,
                        secondarySp = 9f,
                        tertiarySp = 8f,
                        badgeSp = 8f,
                        emptySp = 12f,
                    )
                    NativeHomeWidgetFontSize.LARGE -> HomeWidgetTypography(
                        titleSp = 15f,
                        subtitleSp = 11f,
                        primarySp = 13f,
                        secondarySp = 10f,
                        tertiarySp = 9f,
                        badgeSp = 9f,
                        emptySp = 13f,
                    )
                }
            }
        }
    }
}
