package io.foxbiz.better_keep

data class AssistantNoteRequest(
    val requestId: String,
    val source: String,
    val title: String?,
    val text: String?,
)

object AssistantNoteIntentParser {
    const val ACTION_CREATE_NOTE = "com.google.android.gms.actions.CREATE_NOTE"
    const val EXTRA_NAME = "com.google.android.gms.actions.extra.NAME"
    const val EXTRA_TEXT = "com.google.android.gms.actions.extra.TEXT"
    const val EXTRA_CONSUMED = "io.foxbiz.better_keep.extra.ASSISTANT_NOTE_CONSUMED"

    fun parse(
        action: String?,
        mimeType: String?,
        title: String?,
        text: String?,
        alreadyConsumed: Boolean,
        requestId: () -> String,
    ): AssistantNoteRequest? {
        if (alreadyConsumed || action != ACTION_CREATE_NOTE || mimeType != "text/plain") {
            return null
        }
        if (title.isNullOrBlank() && text.isNullOrBlank()) return null

        return AssistantNoteRequest(
            requestId = requestId(),
            source = "androidCreateNote",
            title = title,
            text = text,
        )
    }
}
