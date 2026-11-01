import UIKit

@main class AppDelegate: UIResponder, UIApplicationDelegate {
  var window: UIWindow?
  func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
    window = UIWindow(frame: UIScreen.main.bounds)
    window?.rootViewController = Sender()
    window?.makeKeyAndVisible()
    return true
  }
}
class Sender: UIViewController {
  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .white
    let stack = UIStackView()
    stack.axis = .vertical
    stack.spacing = 30
    stack.frame = CGRect(x: 30, y: 200, width: 300, height: 200)
    for (title, count) in [("Share 1", 1), ("Share 2", 2), ("Share oversized image", 0)] {
      let button = UIButton(type: .system)
      button.setTitle(title, for: .normal)
      button.tag = count
      button.addTarget(self, action: #selector(share(_:)), for: .touchUpInside)
      stack.addArrangedSubview(button)
    }
    view.addSubview(stack)
  }
  @objc func share(_ button: UIButton) {
    var urls = (0..<button.tag).map { i -> URL in
      let image = UIGraphicsImageRenderer(size: CGSize(width: 640, height: 480)).image { ctx in
        (i == 0 ? UIColor.systemRed : UIColor.systemBlue).setFill()
        ctx.fill(CGRect(x: 0, y: 0, width: 640, height: 480))
        NSString(string: "Image share QA \(i + 1)").draw(at: CGPoint(x: 50, y: 150), withAttributes: [.font: UIFont.systemFont(ofSize: 48), .foregroundColor: UIColor.white])
      }
      let url = FileManager.default.temporaryDirectory.appendingPathComponent("qa-image-\(i).png")
      try! image.pngData()!.write(to: url)
      return url
    }
    if button.tag == 0 {
      let url = FileManager.default.temporaryDirectory.appendingPathComponent("oversized.png")
      let image = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { ctx in
        UIColor.systemRed.setFill()
        ctx.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
      }
      try! image.pngData()!.write(to: url)
      let file = try! FileHandle(forWritingTo: url)
      try! file.truncate(atOffset: UInt64(50 * 1024 * 1024 + 1))
      try! file.close()
      urls = [url]
    }
    let sheet = UIActivityViewController(activityItems: urls, applicationActivities: nil)
    sheet.popoverPresentationController?.sourceView = button
    present(sheet, animated: true)
  }
}
