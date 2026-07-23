import Flutter
import Foundation

enum AssistantNoteBridgeStatus: String, Sendable {
  case saved
  case cancelled
  case unavailable
  case failed
}

struct AssistantNoteBridgeResult: Sendable {
  let status: AssistantNoteBridgeStatus
  let noteId: Int64?

  static let unavailable = AssistantNoteBridgeResult(status: .unavailable, noteId: nil)
  static let failed = AssistantNoteBridgeResult(status: .failed, noteId: nil)

  static func fromFlutter(_ value: Any?) -> AssistantNoteBridgeResult {
    guard
      let dictionary = value as? [String: Any],
      let rawStatus = dictionary["status"] as? String,
      let status = AssistantNoteBridgeStatus(rawValue: rawStatus)
    else {
      return .failed
    }
    let noteId = (dictionary["noteId"] as? NSNumber)?.int64Value
    return AssistantNoteBridgeResult(status: status, noteId: noteId)
  }
}

struct AssistantNoteBridgeRequest: Sendable {
  let requestId: String
  let source: String
  let title: String?
  let text: String?

  var arguments: [String: Any] {
    var value: [String: Any] = [
      "requestId": requestId,
      "source": source,
    ]
    if let title { value["title"] = title }
    if let text { value["text"] = text }
    return value
  }
}

/// Holds dictated content only in process memory while Flutter becomes ready.
@MainActor
final class AssistantNotesBridge {
  static let shared = AssistantNotesBridge()
  private static let channelName = "io.foxbiz.better_keep/assistant_notes"

  private struct PendingRequest {
    let request: AssistantNoteBridgeRequest
    let continuation: CheckedContinuation<AssistantNoteBridgeResult, Never>
  }

  private var channel: FlutterMethodChannel?
  private var pending: [PendingRequest] = []
  private var dartReady = false
  private var submitting = false

  private init() {}

  func configure(messenger: FlutterBinaryMessenger) {
    channel?.setMethodCallHandler(nil)
    let channel = FlutterMethodChannel(
      name: Self.channelName,
      binaryMessenger: messenger
    )
    channel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "ready" else {
        result(FlutterMethodNotImplemented)
        return
      }
      self?.dartReady = true
      result(nil)
      self?.flush()
    }
    self.channel = channel
    dartReady = false
  }

  func submit(
    _ request: AssistantNoteBridgeRequest,
    timeout: TimeInterval = 30
  ) async -> AssistantNoteBridgeResult {
    await withCheckedContinuation { continuation in
      pending.append(PendingRequest(request: request, continuation: continuation))
      flush()
      Task { [weak self] in
        let nanoseconds = UInt64(timeout * 1_000_000_000)
        try? await Task.sleep(nanoseconds: nanoseconds)
        self?.expire(requestId: request.requestId)
      }
    }
  }

  private func flush() {
    guard dartReady, !submitting, !pending.isEmpty, let channel else { return }
    submitting = true
    let item = pending[0]
    channel.invokeMethod("createNote", arguments: item.request.arguments) { [weak self] value in
      guard let self else { return }
      let result = AssistantNoteBridgeResult.fromFlutter(value)
      self.complete(requestId: item.request.requestId, result: result)
    }
  }

  private func complete(requestId: String, result: AssistantNoteBridgeResult) {
    guard let index = pending.firstIndex(where: { $0.request.requestId == requestId }) else {
      return
    }
    let item = pending.remove(at: index)
    submitting = false
    item.continuation.resume(returning: result)
    flush()
  }

  private func expire(requestId: String) {
    guard let index = pending.firstIndex(where: { $0.request.requestId == requestId }) else {
      return
    }
    let wasActive = index == 0 && submitting
    let item = pending.remove(at: index)
    if wasActive { submitting = false }
    item.continuation.resume(returning: .unavailable)
    flush()
  }
}
