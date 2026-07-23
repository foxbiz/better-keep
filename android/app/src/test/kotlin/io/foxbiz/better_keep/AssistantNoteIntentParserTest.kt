package io.foxbiz.better_keep

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class AssistantNoteIntentParserTest {
    @Test
    fun parsesStandardCreateNoteIntent() {
        val parsed = AssistantNoteIntentParser.parse(
            action = AssistantNoteIntentParser.ACTION_CREATE_NOTE,
            mimeType = "text/plain",
            title = "Shopping",
            text = "Milk",
            alreadyConsumed = false,
            requestId = { "request-1" },
        )

        assertEquals("request-1", parsed?.requestId)
        assertEquals("androidCreateNote", parsed?.source)
        assertEquals("Shopping", parsed?.title)
        assertEquals("Milk", parsed?.text)
    }

    @Test
    fun acceptsTitleOnlyAndBodyOnly() {
        val titleOnly = parse(title = "Idea", text = null)
        val bodyOnly = parse(title = null, text = "Call Sam")

        assertEquals("Idea", titleOnly?.title)
        assertEquals("Call Sam", bodyOnly?.text)
    }

    @Test
    fun rejectsWrongActionMimeBlankAndConsumedIntents() {
        assertNull(parse(action = "android.intent.action.SEND"))
        assertNull(parse(mimeType = "text/html"))
        assertNull(parse(title = " ", text = "\n"))
        assertNull(parse(alreadyConsumed = true))
    }

    private fun parse(
        action: String? = AssistantNoteIntentParser.ACTION_CREATE_NOTE,
        mimeType: String? = "text/plain",
        title: String? = "Title",
        text: String? = "Body",
        alreadyConsumed: Boolean = false,
    ) = AssistantNoteIntentParser.parse(
        action = action,
        mimeType = mimeType,
        title = title,
        text = text,
        alreadyConsumed = alreadyConsumed,
        requestId = { "request" },
    )
}
