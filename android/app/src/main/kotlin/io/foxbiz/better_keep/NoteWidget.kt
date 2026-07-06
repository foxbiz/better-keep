package io.foxbiz.better_keep

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.net.Uri
import android.widget.RemoteViews
import org.json.JSONObject

class NoteWidget : AppWidgetProvider() {
    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray
    ) {
        for (appWidgetId in appWidgetIds) {
            val views = RemoteViews(context.packageName, R.layout.note_widget)

            val prefs = context.getSharedPreferences(
                "FlutterSharedPreferences",
                Context.MODE_PRIVATE
            )
            val jsonStr = prefs.getString("flutter.note_widget_data_$appWidgetId", "") ?: ""

            if (jsonStr.isNotEmpty()) {
                try {
                    val note = JSONObject(jsonStr)

                    val title = note.optString("title", "")
                    val text = note.optString("text", "")
                    val colorHex = note.optString("colorHex", "FFFFFFFF")
                    val foregroundDark = note.optBoolean("foregroundDark", false)
                    val pinned = note.optBoolean("pinned", false)
                    val locked = note.optBoolean("locked", false)
                    val hasReminder = note.optBoolean("hasReminder", false)
                    val hasCheckboxes = note.optBoolean("hasCheckboxes", false)
                    val checkboxChecked = note.optInt("checkboxChecked", 0)
                    val checkboxTotal = note.optInt("checkboxTotal", 0)
                    val hasAttachments = note.optBoolean("hasAttachments", false)
                    val labels = note.optString("labels", "")
                    val updatedAt = note.optString("updatedAt", "")
                    val noteId = note.optInt("noteId", 0)

                    val bgColor = try {
                        Color.parseColor("#$colorHex")
                    } catch (e: Exception) {
                        Color.TRANSPARENT
                    }
                    val textColor = if (foregroundDark) Color.WHITE else Color.BLACK
                    val secondaryColor = if (foregroundDark)
                        Color.argb(180, 255, 255, 255)
                    else
                        Color.argb(150, 0, 0, 0)

                    views.setInt(R.id.widget_root, "setBackgroundColor", bgColor)

                    views.setTextViewText(R.id.title, title.ifEmpty { "Untitled" })
                    views.setTextColor(R.id.title, textColor)
                    views.setTextViewText(R.id.content, text)
                    views.setTextColor(R.id.content, secondaryColor)
                    views.setTextViewText(R.id.labels, labels)
                    views.setTextColor(R.id.labels, secondaryColor)
                    views.setTextViewText(R.id.date, updatedAt)
                    views.setTextColor(R.id.date, secondaryColor)

                    views.setViewVisibility(
                        R.id.pin_icon,
                        if (pinned) android.view.View.VISIBLE else android.view.View.GONE
                    )
                    views.setImageViewResource(R.id.pin_icon, android.R.drawable.ic_menu_edit)

                    views.setViewVisibility(
                        R.id.lock_icon,
                        if (locked) android.view.View.VISIBLE else android.view.View.GONE
                    )

                    views.setViewVisibility(
                        R.id.reminder_icon,
                        if (hasReminder) android.view.View.VISIBLE else android.view.View.GONE
                    )

                    views.setViewVisibility(
                        R.id.attachment_icon,
                        if (hasAttachments) android.view.View.VISIBLE else android.view.View.GONE
                    )

                    if (hasCheckboxes && checkboxTotal > 0) {
                        views.setViewVisibility(R.id.checkbox_info, android.view.View.VISIBLE)
                        views.setTextViewText(
                            R.id.checkbox_info,
                            "$checkboxChecked/$checkboxTotal"
                        )
                    } else {
                        views.setViewVisibility(R.id.checkbox_info, android.view.View.GONE)
                    }

                    val intent = Intent(Intent.ACTION_VIEW).apply {
                        data = Uri.parse("betterkeep://note?id=$noteId")
                        flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
                    }
                    val pendingIntent = PendingIntent.getActivity(
                        context, appWidgetId, intent,
                        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
                    )
                    views.setOnClickPendingIntent(R.id.widget_root, pendingIntent)
                } catch (e: Exception) {
                    showEmptyState(views, context, appWidgetId)
                }
            } else {
                showEmptyState(views, context, appWidgetId)
            }

            appWidgetManager.updateAppWidget(appWidgetId, views)
        }
    }

    override fun onDeleted(context: Context, appWidgetIds: IntArray) {
        val prefs = context.getSharedPreferences(
            "FlutterSharedPreferences",
            Context.MODE_PRIVATE
        )
        val editor = prefs.edit()
        for (appWidgetId in appWidgetIds) {
            editor.remove("flutter.note_widget_id_$appWidgetId")
            editor.remove("flutter.note_widget_data_$appWidgetId")
        }
        editor.apply()
    }

    private fun showEmptyState(views: RemoteViews, context: Context, appWidgetId: Int) {
        views.setInt(
            R.id.widget_root, "setBackgroundColor",
            Color.TRANSPARENT
        )
        views.setTextViewText(R.id.title, "No note selected")
        views.setTextColor(R.id.title, Color.GRAY)
        views.setTextViewText(R.id.content, "Tap to select a note")
        views.setTextColor(R.id.content, Color.GRAY)
        views.setTextViewText(R.id.labels, "")
        views.setTextViewText(R.id.date, "")
        views.setViewVisibility(R.id.pin_icon, android.view.View.GONE)
        views.setViewVisibility(R.id.lock_icon, android.view.View.GONE)
        views.setViewVisibility(R.id.reminder_icon, android.view.View.GONE)
        views.setViewVisibility(R.id.attachment_icon, android.view.View.GONE)
        views.setViewVisibility(R.id.checkbox_info, android.view.View.GONE)

        val intent = Intent(Intent.ACTION_VIEW).apply {
            data = Uri.parse("betterkeep://widget/select-note?target=note&widgetId=$appWidgetId")
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val pendingIntent = PendingIntent.getActivity(
            context, appWidgetId, intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        views.setOnClickPendingIntent(R.id.widget_root, pendingIntent)
    }
}
