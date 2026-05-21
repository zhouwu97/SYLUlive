# Home Widget
-keep class com.example.shenliyuan.CourseScheduleWidgetProvider { *; }

# JPush
-keep class cn.jpush.android.** { *; }
-keep class cn.jiguang.** { *; }

# Flutter Local Notifications
-keep class com.dexterous.flutterlocalnotifications.** { *; }

# Any other receivers or providers mentioned in AndroidManifest
-keep class com.example.shenliyuan.CourseReminderLiveReceiver { *; }
-keep class com.example.shenliyuan.CourseReminderLiveBootReceiver { *; }
-keep class com.example.shenliyuan.MainActivity { *; }
