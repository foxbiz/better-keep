import XCTest

final class ConfirmedImageSharing: XCTestCase {
  func testCancelPreviewDoesNotCreateNote() throws {
    continueAfterFailure = false
    let app = XCUIApplication(bundleIdentifier: "io.foxbiz.better-keep")
    app.launch()
    let counter = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Verified image notes: '")).firstMatch
    XCTAssertTrue(counter.waitForExistence(timeout: 30), app.debugDescription)
    let baseline = counter.label
    let sender = XCUIApplication()
    sender.launch()
    share(1, from: sender, create: false)
    sender.buttons["Close"].tap()
    assertNoteCountUnchanged(baseline, in: app)
  }

  func testCopyFailureShowsRetryAndDoesNotCreateNote() throws {
    continueAfterFailure = false
    let app = XCUIApplication(bundleIdentifier: "io.foxbiz.better-keep")
    app.launch()
    let counter = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Verified image notes: '")).firstMatch
    XCTAssertTrue(counter.waitForExistence(timeout: 30), app.debugDescription)
    let baseline = counter.label
    let sender = XCUIApplication()
    sender.launch()
    sender.buttons["Share oversized image"].tap()
    let betterKeep = sender.cells["Better Keep"].firstMatch
    XCTAssertTrue(betterKeep.waitForExistence(timeout: 10), sender.debugDescription)
    betterKeep.tap()
    let action = sender.buttons["create-image-note"]
    XCTAssertTrue(action.waitForExistence(timeout: 10), sender.debugDescription)
    action.tap()
    XCTAssertTrue(sender.buttons["Try again"].waitForExistence(timeout: 20), sender.debugDescription)
    XCTAssertTrue(sender.staticTexts["Could not save these images. Please try again."].exists)
    XCTAssertFalse(app.state == .runningForeground)
    sender.buttons["Close"].tap()
    assertNoteCountUnchanged(baseline, in: app)
  }

  private func assertNoteCountUnchanged(_ baseline: String, in app: XCUIApplication) {
    app.terminate()
    app.launch()
    XCTAssertTrue(app.staticTexts[baseline].waitForExistence(timeout: 30), app.debugDescription)
    let counter = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Verified image notes: '")).firstMatch
    let changed = NSPredicate { _, _ in counter.exists && counter.label != baseline }
    let noImport = XCTNSPredicateExpectation(predicate: changed, object: nil)
    noImport.isInverted = true
    wait(for: [noImport], timeout: 3)
  }

  func testColdAndWarmImageShares() throws {
    continueAfterFailure = false
    let app = XCUIApplication(bundleIdentifier: "io.foxbiz.better-keep")
    app.launch()
    let counter = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Verified image notes: '")).firstMatch
    XCTAssertTrue(counter.waitForExistence(timeout: 30), app.debugDescription)
    let baseline = Int(counter.label.split(separator: " ").last!)!
    print("BASELINE: \(baseline)")
    app.terminate()
    let sender = XCUIApplication()
    sender.launch()
    share(1, from: sender)
    // Do not activate/launch Better Keep here: the extension must foreground it.
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20), sender.debugDescription)
    XCTAssertTrue(app.buttons["Find in note"].waitForExistence(timeout: 30), app.debugDescription)
    let coldShot = XCTAttachment(screenshot: app.screenshot())
    coldShot.name = "Cold shared image note editor"
    coldShot.lifetime = .keepAlways
    add(coldShot)
    app.buttons["Back"].tap()
    XCTAssertTrue(app.staticTexts["Verified image notes: \(baseline + 1)"].waitForExistence(timeout: 30), app.debugDescription)
    XCTAssertFalse(app.buttons["Back"].exists, "Cold share must leave exactly one home route")
    sender.launch()
    share(2, from: sender)
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20), sender.debugDescription)
    XCTAssertTrue(app.buttons["Find in note"].waitForExistence(timeout: 30), app.debugDescription)
    let warmShot = XCTAttachment(screenshot: app.screenshot())
    warmShot.name = "Warm shared image note editor"
    warmShot.lifetime = .keepAlways
    add(warmShot)
    app.buttons["Back"].tap()
    XCTAssertTrue(app.staticTexts["Verified image notes: \(baseline + 2)"].waitForExistence(timeout: 30), app.debugDescription)
    XCTAssertFalse(app.buttons["Back"].exists, "Warm share must leave exactly one home route")
    app.terminate()
    app.launch()
    XCTAssertTrue(app.staticTexts["Verified image notes: \(baseline + 2)"].waitForExistence(timeout: 30), app.debugDescription)
    XCTAssertFalse(app.buttons["Find in note"].exists, "Restart must not reopen an acknowledged share")
    print("VERIFIED_BUTTON_HANDOFF_COLD_WARM_EDITOR_RESTART\n" + app.debugDescription)
  }
  func share(_ count: Int, from sender: XCUIApplication, create: Bool = true) {
    sender.buttons["Share \(count)"].tap()
    let betterKeep = sender.cells["Better Keep"].firstMatch
    XCTAssertTrue(betterKeep.waitForExistence(timeout: 10), sender.debugDescription)
    betterKeep.tap()
    let createNote = sender.buttons["create-image-note"]
    XCTAssertTrue(createNote.waitForExistence(timeout: 10), sender.debugDescription)
    XCTAssertTrue(sender.staticTexts["Add your selection to a new note."].exists, sender.debugDescription)
    for index in 0..<count {
      XCTAssertTrue(sender.images["shared-image-\(index)"].exists, sender.debugDescription)
    }
    let app = XCUIApplication(bundleIdentifier: "io.foxbiz.better-keep")
    XCTAssertFalse(app.wait(for: .runningForeground, timeout: 2), "Preview must wait for Create note")
    let shot = XCTAttachment(screenshot: sender.screenshot())
    shot.name = "Preview of \(count) selected images"
    shot.lifetime = .keepAlways
    add(shot)
    if create { createNote.tap() }
  }
}
