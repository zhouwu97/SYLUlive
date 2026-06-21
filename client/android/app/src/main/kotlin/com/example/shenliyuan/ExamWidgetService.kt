package com.example.shenliyuan

import android.content.Context
import android.content.Intent
import android.widget.RemoteViews
import android.widget.RemoteViewsService

class ExamWidgetService : RemoteViewsService() {
    override fun onGetViewFactory(intent: Intent): RemoteViewsFactory {
        return ExamRemoteViewsFactory(this.applicationContext)
    }
}

class ExamRemoteViewsFactory(private val context: Context) : RemoteViewsService.RemoteViewsFactory {

    private var examData: WidgetExamData? = null

    override fun onCreate() {
        // Initialization if needed
    }

    override fun onDataSetChanged() {
        examData = ExamDataReader.read(context)
    }

    override fun onDestroy() {
        examData = null
    }

    override fun getCount(): Int {
        return examData?.exams?.size ?: 0
    }

    override fun getViewAt(position: Int): RemoteViews {
        val views = RemoteViews(context.packageName, R.layout.widget_exam_item)
        val data = examData ?: return views

        if (position >= data.exams.size) return views
        val exam = data.exams[position]

        views.setTextViewText(R.id.tv_exam_name, exam.name)
        views.setTextViewText(R.id.tv_exam_date, exam.date)
        views.setTextViewText(R.id.tv_exam_time, exam.time)
        views.setTextViewText(R.id.tv_exam_location, exam.location)

        if (exam.countdown.isNotEmpty()) {
            views.setViewVisibility(R.id.tv_exam_countdown, android.view.View.VISIBLE)
            views.setTextViewText(R.id.tv_exam_countdown, exam.countdown)
        } else {
            views.setViewVisibility(R.id.tv_exam_countdown, android.view.View.GONE)
        }

        try {
            val parsedTextColor = android.graphics.Color.parseColor(data.textColor)
            views.setTextColor(R.id.tv_exam_name, parsedTextColor)
            views.setTextColor(R.id.tv_exam_date, parsedTextColor)
            views.setTextColor(R.id.tv_exam_time, parsedTextColor)
        } catch (e: Exception) {
            // ignore
        }

        val fillInIntent = Intent()
        fillInIntent.putExtra("exam_name", exam.name)
        fillInIntent.putExtra("exam_date", exam.date)
        views.setOnClickFillInIntent(R.id.item_root_layout, fillInIntent)

        return views
    }

    override fun getLoadingView(): RemoteViews? = null
    override fun getViewTypeCount(): Int = 1
    override fun getItemId(position: Int): Long = position.toLong()
    override fun hasStableIds(): Boolean = true
}
