package io.foxbiz.better_keep

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.widget.RemoteViews

class QuickActionsWidget : AppWidgetProvider() {
    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray
    ) {
        for (appWidgetId in appWidgetIds) {
            val views = RemoteViews(context.packageName, R.layout.quick_actions_widget)

            views.setOnClickPendingIntent(
                R.id.action_note,
                createDeepLinkIntent(context, "note", 100)
            )
            views.setOnClickPendingIntent(
                R.id.action_todo,
                createDeepLinkIntent(context, "todo", 101)
            )
            views.setOnClickPendingIntent(
                R.id.action_voice,
                createDeepLinkIntent(context, "voice", 102)
            )
            views.setOnClickPendingIntent(
                R.id.action_photo,
                createDeepLinkIntent(context, "photo", 103)
            )

            appWidgetManager.updateAppWidget(appWidgetId, views)
        }
    }

    private fun createDeepLinkIntent(
        context: Context,
        type: String,
        requestCode: Int
    ): PendingIntent {
        val intent = Intent(Intent.ACTION_VIEW).apply {
            data = Uri.parse("betterkeep://create?type=$type")
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        return PendingIntent.getActivity(
            context, requestCode, intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
    }
}
