import Foundation

final class ImageShareTests {
  var root: URL!
  var store: ImageShareStore!

  func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    store = try ImageShareStore(root: root)
  }
  func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

  @discardableResult
  func batch(_ names: [String]? = ["0.jpg"], id: String = UUID().uuidString) throws -> String {
    let directory = try store.directory(id)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    if let names { try ImageShareStore.write(JSONEncoder().encode(names), to: directory.appendingPathComponent("ready.json")) }
    return id
  }

  func testReadyMarkerAndTraversal() throws {
    try batch(nil)
    try batch(["../outside.jpg"])
    try batch([".."])
    try batch(["/outside.jpg"])
    try batch([])
    let valid = try batch(["0.jpg", "1.png"])
    expectEqual(try store.pending().map { $0["id"] as! String }, [valid])
    expectThrows(try store.complete("../outside"))
    try store.complete(valid)
    try store.complete(valid)
    expectTrue(try store.pending().isEmpty)
  }

  func testPersistentQuarantineAndExpiration() throws {
    let id = try batch()
    for count in 1...3 { expectEqual(try store.failed(id), count) }
    let reopened = try ImageShareStore(root: root)
    expectTrue(try reopened.pending().isEmpty)
    expectTrue(FileManager.default.fileExists(atPath: try store.directory(id).path))
    expectTrue(try reopened.pending(now: Date().addingTimeInterval(ImageShareStore.retention + 10)).isEmpty)
    expectFalse(FileManager.default.fileExists(atPath: try store.directory(id).path))
  }

  func testPartialCleanupPreservesRecentAndReadyBatches() throws {
    let partial = try batch(nil)
    let ready = try batch()
    expectEqual(try store.pending().count, 1)
    _ = try store.pending(now: Date().addingTimeInterval(ImageShareStore.partialRetention + 10))
    expectFalse(FileManager.default.fileExists(atPath: try store.directory(partial).path))
    expectTrue(FileManager.default.fileExists(atPath: try store.directory(ready).path))
  }

  func testUnreadableMetadataRemainsRetryable() throws {
    for name in ["ready.json", "attempts.json"] {
      let id = try batch()
      let directory = try store.directory(id)
      let metadata = directory.appendingPathComponent(name)
      let contents = name == "ready.json" ? try JSONEncoder().encode(["0.jpg"]) : Data("1".utf8)
      if name == "ready.json" { try FileManager.default.removeItem(at: metadata) }
      // A directory produces a deterministic read error without depending on
      // the test user's permissions. I/O failure must not mean corrupt JSON.
      try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: false)
      expectTrue(try store.pending(now: Date().addingTimeInterval(ImageShareStore.partialRetention + 10)).isEmpty)
      expectTrue(FileManager.default.fileExists(atPath: directory.path))
      try FileManager.default.removeItem(at: metadata)
      try ImageShareStore.write(contents, to: metadata)
      expectEqual(try store.pending().map { $0["id"] as! String }, [id])
      if name == "attempts.json" { expectEqual(try store.failed(id), 2) }
      try FileManager.default.removeItem(at: metadata)
      try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: false)
      // Unreadable metadata must not bypass the existing seven-day retention.
      expectTrue(try store.pending(now: Date().addingTimeInterval(ImageShareStore.retention + 10)).isEmpty)
      expectFalse(FileManager.default.fileExists(atPath: directory.path))
    }
  }

  func testUnreadableBatchDoesNotBlockReadyShares() throws {
    for name in ["ready.json", "attempts.json"] {
      let unreadable = try batch()
      let metadata = try store.directory(unreadable).appendingPathComponent(name)
      if name == "ready.json" { try FileManager.default.removeItem(at: metadata) }
      try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: false)
      let ready = try batch()
      expectEqual(try store.pending().map { $0["id"] as! String }, [ready])
      expectTrue(FileManager.default.fileExists(atPath: try store.directory(unreadable).path))
      try store.complete(unreadable)
      try store.complete(ready)
    }
  }

  func testShareOrderUsesCreationDate() throws {
    let first = try batch(id: "FFFFFFFF-FFFF-4FFF-AFFF-FFFFFFFFFFFF")
    let second = try batch(id: "00000000-0000-4000-A000-000000000000")
    let created = Date().addingTimeInterval(-120)
    try FileManager.default.setAttributes([.creationDate: created], ofItemAtPath: store.directory(first).path)
    try FileManager.default.setAttributes([.creationDate: created.addingTimeInterval(60)], ofItemAtPath: store.directory(second).path)
    expectEqual(try store.pending().map { $0["id"] as! String }, [first, second])
  }

  func testCopyRejectsOversizedSourceAndPreservesOriginal() throws {
    let source = root.appendingPathComponent("large.jpg")
    try Data([1, 2, 3]).write(to: source)
    let file = try FileHandle(forWritingTo: source)
    try file.truncate(atOffset: UInt64(ImageShareStore.maxImageBytes + 1))
    try file.close()
    let destination = root.appendingPathComponent("copy.jpg")
    expectThrows(try ImageShareStore.copyImage(from: source, to: destination))
    expectFalse(FileManager.default.fileExists(atPath: destination.path))
    try Data([1, 2, 3]).write(to: source)
    try ImageShareStore.copyImage(from: source, to: destination)
    expectEqual(try Data(contentsOf: source), try Data(contentsOf: destination))
  }

  func testTimeoutCancelsProviderAndIgnoresLateCallback() {
    let expired = DispatchSemaphore(value: 0)
    let progress = Progress(totalUnitCount: 1)
    let transfer = ImageShareTransfer(timeout: 0.02) { result in
      if case .success = result { fatalError("Expected timeout") }
      expired.signal()
    }
    transfer.attach(progress)
    expectEqual(expired.wait(timeout: .now() + 1), .success)
    expectTrue(progress.isCancelled)
    transfer.resolve { fatalError("Late callback must not copy"); return "late.jpg" }
    transfer.cancel()
  }

  func testCancellationBeforeProgressAndDuplicateCompletion() {
    var completions = 0
    let transfer = ImageShareTransfer(timeout: 60) { _ in completions += 1 }
    transfer.cancel()
    let progress = Progress(totalUnitCount: 1)
    transfer.attach(progress)
    transfer.resolve { fatalError("Cancelled callback must not copy"); return "late.jpg" }
    expectTrue(progress.isCancelled)
    expectEqual(completions, 1)
    let success = ImageShareTransfer(timeout: 60) { result in
      expectEqual(try? result.get(), "ok.jpg")
      completions += 1
    }
    success.resolve { "ok.jpg" }
    success.resolve { fatalError("Duplicate callback must not copy"); return "duplicate.jpg" }
    success.cancel()
    expectEqual(completions, 2)
  }
}

@main struct RunImageShareTests {
  static func main() throws {
    let tests = ImageShareTests()
    let cases: [(String, () throws -> Void)] = [
      ("ready marker and traversal", tests.testReadyMarkerAndTraversal),
      ("persistent quarantine and expiration", tests.testPersistentQuarantineAndExpiration),
      ("partial cleanup", tests.testPartialCleanupPreservesRecentAndReadyBatches),
      ("unreadable metadata remains retryable", tests.testUnreadableMetadataRemainsRetryable),
      ("unreadable batch does not block ready shares", tests.testUnreadableBatchDoesNotBlockReadyShares),
      ("share order", tests.testShareOrderUsesCreationDate),
      ("bounded copy", tests.testCopyRejectsOversizedSourceAndPreservesOriginal),
      ("provider timeout", tests.testTimeoutCancelsProviderAndIgnoresLateCallback),
      ("cancellation and duplicate callbacks", tests.testCancellationBeforeProgressAndDuplicateCompletion)
    ]
    for (name, test) in cases {
      try tests.setUpWithError()
      defer { try? tests.tearDownWithError() }
      try test()
      print("PASS: \(name)")
    }
  }
}

func expectEqual<T: Equatable>(_ actual: @autoclosure () throws -> T, _ expected: T, file: StaticString = #filePath, line: UInt = #line) {
  do {
    let value = try actual()
    guard value == expected else { fatalError("Expected \(expected), got \(value)", file: file, line: line) }
  } catch { fatalError("Unexpected error: \(error)", file: file, line: line) }
}
func expectTrue(_ value: @autoclosure () throws -> Bool, file: StaticString = #filePath, line: UInt = #line) {
  expectEqual(try value(), true, file: file, line: line)
}
func expectFalse(_ value: @autoclosure () throws -> Bool, file: StaticString = #filePath, line: UInt = #line) {
  expectEqual(try value(), false, file: file, line: line)
}
func expectThrows(_ value: @autoclosure () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
  do { try value() } catch { return }
  fatalError("Expected an error", file: file, line: line)
}
