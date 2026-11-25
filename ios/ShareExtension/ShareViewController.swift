import UIKit
import UniformTypeIdentifiers
import ImageIO

final class ShareViewController: UIViewController {
  private let status = UILabel()
  private let spinner = UIActivityIndicatorView(style: .medium)
  private let retryButton = UIButton(type: .system)
  private var providers: [NSItemProvider] = []
  private var previews: [UIImageView] = []
  private var previewProgress: Progress?
  private var saving = false
  private var queued = false
  private var closed = false
  private var transfer: ImageShareTransfer?

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemBackground
    providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? [])
      .flatMap { $0.attachments ?? [] }
      .filter { $0.hasItemConformingToTypeIdentifier(UTType.image.identifier) }
    preferredContentSize = CGSize(width: 0, height: 500)
    let title = UILabel()
    title.text = "Better Keep"
    title.font = .preferredFont(forTextStyle: .title2)
    title.adjustsFontForContentSizeCategory = true
    let cancel = UIButton(type: .system)
    cancel.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
    cancel.tintColor = .secondaryLabel
    cancel.accessibilityLabel = NSLocalizedString("Close", comment: "Close image share")
    cancel.addTarget(self, action: #selector(close), for: .touchUpInside)
    cancel.widthAnchor.constraint(equalToConstant: 44).isActive = true
    cancel.heightAnchor.constraint(equalToConstant: 44).isActive = true
    let header = UIStackView(arrangedSubviews: [title, cancel])
    header.alignment = .center

    let images = UIScrollView()
    images.showsHorizontalScrollIndicator = providers.count > 1
    let thumbnails = UIStackView()
    thumbnails.spacing = 12
    thumbnails.translatesAutoresizingMaskIntoConstraints = false
    images.addSubview(thumbnails)
    NSLayoutConstraint.activate([
      images.heightAnchor.constraint(equalToConstant: 240),
      thumbnails.leadingAnchor.constraint(equalTo: images.contentLayoutGuide.leadingAnchor),
      thumbnails.trailingAnchor.constraint(equalTo: images.contentLayoutGuide.trailingAnchor),
      thumbnails.topAnchor.constraint(equalTo: images.contentLayoutGuide.topAnchor),
      thumbnails.bottomAnchor.constraint(equalTo: images.contentLayoutGuide.bottomAnchor),
      thumbnails.heightAnchor.constraint(equalTo: images.frameLayoutGuide.heightAnchor)
    ])
    for index in providers.indices {
      let preview = UIImageView(image: UIImage(systemName: "photo"))
      preview.contentMode = .scaleAspectFit
      preview.backgroundColor = .secondarySystemBackground
      preview.tintColor = .tertiaryLabel
      preview.layer.cornerRadius = 16
      preview.clipsToBounds = true
      preview.isAccessibilityElement = true
      preview.accessibilityIdentifier = "shared-image-\(index)"
      preview.accessibilityLabel = String(format: NSLocalizedString("Image %ld of %ld", comment: "Shared image preview"), index + 1, providers.count)
      thumbnails.addArrangedSubview(preview)
      if providers.count == 1 {
        preview.widthAnchor.constraint(equalTo: images.frameLayoutGuide.widthAnchor).isActive = true
      } else {
        preview.widthAnchor.constraint(equalToConstant: 200).isActive = true
      }
      previews.append(preview)
    }

    let info = UILabel()
    info.text = NSLocalizedString("Add your selection to a new note.", comment: "Image share explanation")
    info.font = .preferredFont(forTextStyle: .subheadline)
    info.textColor = .secondaryLabel
    info.numberOfLines = 0
    info.textAlignment = .center
    info.adjustsFontForContentSizeCategory = true
    status.numberOfLines = 0
    status.textAlignment = .center
    status.font = .preferredFont(forTextStyle: .footnote)
    status.adjustsFontForContentSizeCategory = true
    status.isHidden = true
    spinner.hidesWhenStopped = true
    var buttonStyle = UIButton.Configuration.filled()
    buttonStyle.cornerStyle = .capsule
    buttonStyle.contentInsets = NSDirectionalEdgeInsets(top: 16, leading: 24, bottom: 16, trailing: 24)
    buttonStyle.title = NSLocalizedString("Create note", comment: "Create a note from shared images")
    retryButton.configuration = buttonStyle
    retryButton.accessibilityIdentifier = "create-image-note"
    retryButton.addTarget(self, action: #selector(retry), for: .touchUpInside)
    retryButton.isEnabled = !providers.isEmpty && providers.count <= 50

    let scroll = UIScrollView()
    scroll.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(scroll)
    let stack = UIStackView(arrangedSubviews: [header, images, info, retryButton, spinner, status])
    stack.axis = .vertical
    stack.spacing = 20
    stack.translatesAutoresizingMaskIntoConstraints = false
    scroll.addSubview(stack)
    NSLayoutConstraint.activate([
      scroll.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
      scroll.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
      scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
      scroll.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
      stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 24),
      stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -24),
      stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 12),
      stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -24),
      stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -48)
    ])
    loadPreview(at: 0)
  }

  private func loadPreview(at index: Int) {
    guard !closed && !saving && index < providers.count else { return }
    // Load one bounded thumbnail at a time, without persisting a pending share.
    previewProgress = providers[index].loadFileRepresentation(forTypeIdentifier: UTType.image.identifier) { [weak self] url, _ in
      var thumbnail: UIImage?
      if let url,
         let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
         size <= ImageShareStore.maxImageBytes,
         let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
         let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
           kCGImageSourceCreateThumbnailFromImageAlways: true,
           kCGImageSourceCreateThumbnailWithTransform: true,
           kCGImageSourceThumbnailMaxPixelSize: 480
         ] as CFDictionary) {
        thumbnail = UIImage(cgImage: image)
      }
      DispatchQueue.main.async {
        guard let self, !self.closed && !self.saving else { return }
        self.previewProgress = nil
        if let thumbnail { self.previews[index].image = thumbnail }
        self.loadPreview(at: index + 1)
      }
    }
  }

  @objc private func close() {
    closed = true
    previewProgress?.cancel()
    transfer?.cancel()
    extensionContext?.completeRequest(returningItems: nil)
  }

  @objc private func retry() {
    if queued { openApp() } else { save() }
  }

  private func save() {
    guard !saving && !closed else { return }
    guard !providers.isEmpty && providers.count <= 50 else {
      status.text = NSLocalizedString("Could not save these images. Please try again.", comment: "Image share failed")
      return
    }
    saving = true
    previewProgress?.cancel()
    status.isHidden = false
    retryButton.isHidden = true
    spinner.startAnimating()
    status.text = NSLocalizedString("Saving images…", comment: "Copying shared images")
    let id = UUID().uuidString
    Task {
      do {
        let inbox = try ImageShareInbox.store()
        _ = try inbox.pending()
        let directory = try inbox.directory(id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try ImageShareStore.protect(directory)
        let deadline = Date().addingTimeInterval(60)
        var names: [String] = []
        for (index, provider) in providers.enumerated() {
          guard !closed else { throw CancellationError() }
          let name = try await copyImage(provider, index: index, to: directory, timeout: min(15, deadline.timeIntervalSinceNow))
          names.append(name)
        }
        guard !closed else { throw CancellationError() }
        try ImageShareStore.write(JSONEncoder().encode(names), to: directory.appendingPathComponent("ready.json"))
        queued = true
        openApp()
      } catch {
        try? ImageShareInbox.complete(id)
        if !closed {
          status.text = NSLocalizedString("Could not save these images. Please try again.", comment: "Image share failed")
          retryButton.setTitle(NSLocalizedString("Try again", comment: "Retry image share"), for: .normal)
          retryButton.isHidden = false
          spinner.stopAnimating()
        }
      }
      transfer = nil
      saving = false
    }
  }

  private func openApp() {
    guard !closed else { return }
    retryButton.isHidden = true
    spinner.startAnimating()
    status.text = NSLocalizedString("Opening Better Keep…", comment: "Image share progress")
    let url = URL(string: "betterkeep://image-share")!
    // Match receive_sharing_intent's handoff. iOS does not officially support
    // opening a containing app from a share extension; retain the inbox on failure.
    var responder: UIResponder? = self
    while let current = responder {
      if let application = current as? UIApplication {
        application.open(url, options: [:]) { [weak self] opened in
          guard let self, !self.closed else { return }
          if opened { self.close() } else { self.showOpenFailure() }
        }
        return
      }
      responder = current.next
    }
    showOpenFailure()
  }

  private func showOpenFailure() {
    spinner.stopAnimating()
    status.text = NSLocalizedString("Your images are ready. Open Better Keep to view your note.", comment: "App could not be opened")
    retryButton.setTitle(NSLocalizedString("Open Better Keep", comment: "Retry opening the app"), for: .normal)
    retryButton.isHidden = false
  }

  private func copyImage(_ provider: NSItemProvider, index: Int, to directory: URL, timeout: TimeInterval) async throws -> String {
    guard timeout > 0 else { throw ImageShareError.timedOut }
    let suggestedName = provider.suggestedName
    return try await withCheckedThrowingContinuation { continuation in
      let transfer = ImageShareTransfer(timeout: timeout) { continuation.resume(with: $0) }
      self.transfer = transfer
      let progress = provider.loadFileRepresentation(forTypeIdentifier: UTType.image.identifier) { url, error in
        transfer.resolve {
          if let error { throw error }
          guard let url else { throw CocoaError(.fileReadUnknown) }
          let ext = url.pathExtension.lowercased()
          let safeExtension = !ext.isEmpty && ext.count <= 10 && ext.allSatisfy({ $0.isLetter || $0.isNumber }) ? ext : "img"
          let originalName = URL(fileURLWithPath: suggestedName ?? url.lastPathComponent)
            .deletingPathExtension().lastPathComponent
          let base = String(originalName.filter { $0.isLetter || $0.isNumber || " .-_".contains($0) }.prefix(48))
          let name = "\(index)-\(base.isEmpty ? "image" : base).\(safeExtension)"
          try ImageShareStore.copyImage(from: url, to: directory.appendingPathComponent(name))
          return name
        }
      }
      transfer.attach(progress)
    }
  }
}
