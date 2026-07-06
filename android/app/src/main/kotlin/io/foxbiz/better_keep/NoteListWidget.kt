package io.foxbiz.better_keep

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.net.Uri
import android.widget.RemoteViews
import org.json.JSONArray
import org.json.JSONObject

class NoteListWidget : AppWidgetProvider() {
    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray
    ) {
        for (appWidgetId in appWidgetIds) {
            val views = RemoteViews(context.packageName, R.layout.note_list_widget)

            val prefs = context.getSharedPreferences(
                "FlutterSharedPreferences",
                Context.MODE_PRIVATE
            )
            val jsonStr = prefs.getString("flutter.note_list_widget_data", "") ?: ""

            if (jsonStr.isNotEmpty()) {
                try {
                    val notesArray = JSONArray(jsonStr)

                    for (i in 0 until 4) {
                        if (i < notesArray.length()) {
                            showNoteRow(context, views, i, notesArray.getJSONObject(i))
                        } else {
                            hideNoteRow(views, i)
                        }
                    }

                    if (notesArray.length() <= 1) {
                        hideDivider(views, 0)
                    } else if (notesArray.length() >= 2) {
                        showDivider(views, 0)
                    }
                    if (notesArray.length() >= 3) {
                        showDivider(views, 1)
                    } else {
                        hideDivider(views, 1)
                    }
                    if (notesArray.length() >= 4) {
                        showDivider(views, 2)
                    } else {
                        hideDivider(views, 2)
                    }
                } catch (e: Exception) {
                    showEmptyState(views)
                }
            } else {
                showEmptyState(views)
            }

            appWidgetManager.updateAppWidget(appWidgetId, views)
        }
    }

    private fun showNoteRow(
        context: Context,
        views: RemoteViews,
        index: Int,
        note: JSONObject
    ) {
        val title = note.optString("title", "")
        val text = note.optString("text", "")
        val colorHex = note.optString("colorHex", "FFFFFFFF")
        val pinned = note.optBoolean("pinned", false)
        val hasCheckboxes = note.optBoolean("hasCheckboxes", false)
        val checkboxChecked = note.optInt("checkboxChecked", 0)
        val checkboxTotal = note.optInt("checkboxTotal", 0)
        val labels = note.optString("labels", "")
        val updatedAt = note.optString("updatedAt", "")
        val noteId = note.optInt("noteId", 0)
        val foregroundDark = note.optBoolean("foregroundDark", false)

        val stripColor = try {
            Color.parseColor("#$colorHex")
        } catch (e: Exception) {
            Color.TRANSPARENT
        }

        val rowId = when (index) {
            0 -> R.id.note_row_0
            1 -> R.id.note_row_1
            2 -> R.id.note_row_2
            3 -> R.id.note_row_3
            else -> return
        }

        val stripId = when (index) {
            0 -> R.id.note_0_strip
            1 -> R.id.note_1_strip
            2 -> R.id.note_2_strip
            3 -> R.id.note_3_strip
            else -> return
        }

        val titleId = when (index) {
            0 -> R.id.note_0_title
            1 -> R.id.note_1_title
            2 -> R.id.note_2_title
            3 -> R.id.note_3_title
            else -> return
        }

        val textId = when (index) {
            0 -> R.id.note_0_text
            1 -> R.id.note_1_text
            2 -> R.id.note_2_text
            3 -> R.id.note_3_text
            else -> return
        }

        val pinId = when (index) {
            0 -> R.id.note_0_pin
            1 -> R.id.note_1_pin
            2 -> R.id.note_2_pin
            3 -> R.id.note_3_pin
            else -> return
        }

        val dateId = when (index) {
            0 -> R.id.note_0_date
            1 -> R.id.note_1_date
            2 -> R.id.note_2_date
            3 -> R.id.note_3_date
            else -> return
        }

        val metaId = when (index) {
            0 -> R.id.note_0_meta
            1 -> R.id.note_1_meta
            2 -> R.id.note_2_meta
            3 -> R.id.note_3_meta
            else -> return
        }

        val checkboxId = when (index) {
            0 -> R.id.note_0_checkbox
            1 -> R.id.note_1_checkbox
            2 -> R.id.note_2_checkbox
            3 -> R.id.note_3_checkbox
            else -> return
        }

        val labelId = when (index) {
            0 -> R.id.note_0_labels
            1 -> R.id.note_1_labels
            2 -> R.id.note_2_labels
            3 -> R.id.note_3_labels
            else -> return
        }

        views.setViewVisibility(rowId, android.view.View.VISIBLE)
        views.setInt(stripId, "setBackgroundColor", stripColor)

        val textColor = if (foregroundDark) Color.WHITE else Color.BLACK
        val secondaryColor = if (foregroundDark)
            Color.argb(180, 255, 255, 255)
        else
            Color.argb(150, 0, 0, 0)

        views.setTextViewText(titleId, title.ifEmpty { "Untitled" })
        views.setTextColor(titleId, textColor)
        views.setTextViewText(dateId, updatedAt)
        views.setTextColor(dateId, secondaryColor)

        views.setViewVisibility(
            pinId,
            if (pinned) android.view.View.VISIBLE else android.view.View.GONE
        )

        if (text.isNotEmpty()) {
            views.setViewVisibility(textId, android.view.View.VISIBLE)
            views.setTextViewText(textId, text)
            views.setTextColor(textId, secondaryColor)
        } else {
            views.setViewVisibility(textId, android.view.View.GONE)
        }

        if (hasCheckboxes || labels.isNotEmpty()) {
            views.setViewVisibility(metaId, android.view.View.VISIBLE)
            if (hasCheckboxes && checkboxTotal > 0) {
                views.setTextViewText(checkboxId, "$checkboxChecked/$checkboxTotal")
                views.setTextColor(checkboxId, secondaryColor)
            } else {
                views.setTextViewText(checkboxId, "")
            }
            if (labels.isNotEmpty()) {
                views.setTextViewText(labelId, labels)
                views.setTextColor(labelId, secondaryColor)
            } else {
                views.setTextViewText(labelId, "")
            }
        } else {
            views.setViewVisibility(metaId, android.view.View.GONE)
        }

        val intent = Intent(Intent.ACTION_VIEW).apply {
            data = Uri.parse("betterkeep://note?id=$noteId")
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val pendingIntent = PendingIntent.getActivity(
            context, noteId, intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        views.setOnClickPendingIntent(rowId, pendingIntent)
    }

    private fun hideNoteRow(views: RemoteViews, index: Int) {
        val rowId = when (index) {
            0 -> R.id.note_row_0
            1 -> R.id.note_row_1
            2 -> R.id.note_row_2
            3 -> R.id.note_row_3
            else -> return
        }
        views.setViewVisibility(rowId, android.view.View.GONE)
    }

    private fun showDivider(views: RemoteViews, index: Int) {
        val dividerId = when (index) {
            0 -> R.id.divider_0_1
            1 -> R.id.divider_1_2
            2 -> R.id.divider_2_3
            else -> return
        }
        views.setViewVisibility(dividerId, android.view.View.VISIBLE)
    }

    private fun hideDivider(views: RemoteViews, index: Int) {
        val dividerId = when (index) {
            0 -> R.id.divider_0_1
            1 -> R.id.divider_1_2
            2 -> R.id.divider_2_3
            else -> return
        }
        views.setViewVisibility(dividerId, android.view.View.GONE)
    }

    private fun showEmptyState(views: RemoteViews) {
        for (i in 0 until 4) {
            hideNoteRow(views, i)
        }
        hideDivider(views, 0)
        hideDivider(views, 1)
        hideDivider(views, 2)
    }
}
