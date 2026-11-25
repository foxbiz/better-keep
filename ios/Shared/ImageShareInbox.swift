import Foundation

/// Only a ready marker makes a complete batch visible to the app.
enum ImageShareInbox {
  static let groupID = "group.io.foxbiz.betterKeep.imageShare"

  static func store() throws -> ImageShareStore {
    #if os(iOS)
    guard let container = FileManager.default.containerURL(
      forSecurityApplicationGroupIdentifier: groupID
    ) else { throw ImageShareError.unavailable }
    return try ImageShareStore(root: container.appendingPathComponent("ImageShares", isDirectory: true))
    #else
    throw ImageShareError.unavailable
    #endif
  }

  static func pending() throws -> [[String: Any]] { try store().pending() }
  static func complete(_ id: String) throws { try store().complete(id) }
  static func failed(_ id: String) throws -> Int { try store().failed(id) }
}

enum ImageShareError: Error { case unavailable, tooLarge, timedOut }

struct ImageShareStore {
  static let maxImageBytes = 50 * 1024 * 1024
  static let maxAttempts = 3
  static let retention: TimeInterval = 7 * 24 * 60 * 60
  static let partialRetention: TimeInterval = 60 * 60
  let root: URL

  init(root: URL) throws {
    self.root = root
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Self.protect(root)
  }

  static func protect(_ url: URL) throws {
    #if os(iOS)
    try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
    #endif
    var resource = url
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try resource.setResourceValues(values)
  }

  static func write(_ data: Data, to url: URL) throws {
    var options: Data.WritingOptions = [.atomic]
    #if os(iOS)
    options.insert(.completeFileProtection)
    #endif
    try data.write(to: url, options: options)
    try protect(url)
  }

  func directory(_ id: String) throws -> URL {
    guard UUID(uuidString: id) != nil else { throw CocoaError(.fileReadInvalidFileName) }
    return root.appendingPathComponent(id, isDirectory: true)
  }

  func pending(now: Date = Date()) throws -> [[String: Any]] {
    let directories = try FileManager.default.contentsOfDirectory(
      at: root, includingPropertiesForKeys: [.creationDateKey, .isDirectoryKey, .isSymbolicLinkKey]
    )
    var batches: [(Date, String, [String: Any])] = []
    for directory in directories {
      guard UUID(uuidString: directory.lastPathComponent) != nil else { continue }
      let values = try directory.resourceValues(forKeys: [.creationDateKey, .isDirectoryKey, .isSymbolicLinkKey])
      guard values.isDirectory == true, values.isSymbolicLink != true else { continue }
      let created = values.creationDate ?? now
      let age = now.timeIntervalSince(created)
      if age > Self.retention {
        try FileManager.default.removeItem(at: directory)
        continue
      }
      let marker = directory.appendingPathComponent("ready.json")
      let markerData: Data?
      do { markerData = try Self.readIfPresent(marker) }
      catch { continue } // Keep this batch for retry without blocking other shares.
      let names = markerData.flatMap { try? JSONDecoder().decode([String].self, from: $0) }
      let valid = names.map { !$0.isEmpty && $0.count <= 50 && $0.allSatisfy(Self.safeName) } ?? false
      if !valid && age > Self.partialRetention {
        try FileManager.default.removeItem(at: directory)
        continue
      }
      guard valid, let names, let count = try? attempts(directory), count < Self.maxAttempts else { continue }
      let paths = names.map { directory.appendingPathComponent($0).path }
      batches.append((created, directory.lastPathComponent, ["id": directory.lastPathComponent, "paths": paths]))
    }
    return batches.sorted { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0 }.map { $0.2 }
  }

  private static func safeName(_ name: String) -> Bool {
    !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\\")
  }

  private static func readIfPresent(_ url: URL) throws -> Data? {
    // Protection/other I/O errors must remain retryable, not become corruption
    // that hides a ready batch or expires it under the shorter partial lifetime.
    do { return try Data(contentsOf: url) }
    catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
  }

  private func attempts(_ directory: URL) throws -> Int {
    let file = directory.appendingPathComponent("attempts.json")
    guard let data = try Self.readIfPresent(file) else { return 0 }
    // A corrupt attempt record is quarantined too, never reset into an infinite retry.
    return (try? JSONDecoder().decode(Int.self, from: data)) ?? Self.maxAttempts
  }

  func failed(_ id: String) throws -> Int {
    let directory = try directory(id)
    let count = min(Self.maxAttempts, max(0, try attempts(directory)) + 1)
    try Self.write(JSONEncoder().encode(count), to: directory.appendingPathComponent("attempts.json"))
    return count
  }

  func complete(_ id: String) throws {
    let directory = try directory(id)
    if FileManager.default.fileExists(atPath: directory.path) {
      try FileManager.default.removeItem(at: directory)
    }
  }

  static func copyImage(from source: URL, to destination: URL) throws {
    let input = try FileHandle(forReadingFrom: source)
    defer { try? input.close() }
    guard try input.seekToEnd() <= maxImageBytes else { throw ImageShareError.tooLarge }
    try input.seek(toOffset: 0)
    try write(Data(), to: destination)
    let output = try FileHandle(forWritingTo: destination)
    defer { try? output.close() }
    var total = 0
    while let data = try input.read(upToCount: 1024 * 1024), !data.isEmpty {
      total += data.count
      guard total <= maxImageBytes else { throw ImageShareError.tooLarge }
      try output.write(contentsOf: data)
    }
  }
}

/// Serializes timeout/cancellation with the provider callback, including its file copy.
/// A late callback must neither resume twice nor recreate an abandoned batch.
final class ImageShareTransfer {
  private let lock = NSLock()
  private var completion: ((Result<String, Error>) -> Void)?
  private var progress: Progress?

  init(timeout: TimeInterval, completion: @escaping (Result<String, Error>) -> Void) {
    self.completion = completion
    DispatchQueue.global().asyncAfter(deadline: .now() + max(0, timeout)) { [weak self] in
      self?.cancel(ImageShareError.timedOut)
    }
  }

  func attach(_ progress: Progress) {
    lock.lock()
    let finished = completion == nil
    if !finished { self.progress = progress }
    lock.unlock()
    if finished { progress.cancel() }
  }

  func resolve(_ copy: () throws -> String) {
    lock.lock()
    guard let completion else { lock.unlock(); return }
    let result = Result(catching: copy)
    self.completion = nil
    progress = nil
    lock.unlock()
    completion(result)
  }

  func cancel(_ error: Error = CancellationError()) {
    lock.lock()
    let completion = self.completion
    self.completion = nil
    let progress = self.progress
    self.progress = nil
    lock.unlock()
    progress?.cancel()
    completion?(.failure(error))
  }
}
