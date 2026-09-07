package dev.flutterquill.quill_native_bridge.util

import dev.flutterquill.quill_native_bridge.generated.FlutterError

// See https://github.com/flutter/packages/blob/main/packages/pigeon/example/README.md#kotlin

fun <T> ((Result<T>) -> Unit).respondFlutterPigeonError(
    code: String,
    message: String? = null,
    details: Any? = null,
) {
    this(
        Result.failure(
            FlutterError(
                code = code,
                message = message,
                details = details,
            ),
        ),
    )
}

fun <T> ((Result<T>) -> Unit).respondFlutterPigeonSuccess(value: T) {
    this(Result.success(value))
}
