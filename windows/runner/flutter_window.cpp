#include "flutter_window.h"

#include <optional>

#include "flutter/generated_plugin_registrant.h"

namespace {

constexpr char kMotionPreferenceChannel[] =
    "com.betterkeep/motion_preferences";
constexpr char kGetReduceMotionMethod[] = "getReduceMotionEnabled";
constexpr char kReduceMotionChangedMethod[] = "reduceMotionChanged";

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());

  reduce_motion_enabled_ = QueryReduceMotionEnabled();
  motion_preference_channel_ = std::make_unique<
      flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), kMotionPreferenceChannel,
      &flutter::StandardMethodCodec::GetInstance());
  motion_preference_channel_->SetMethodCallHandler(
      [this](const auto& call, auto result) {
        if (call.method_name() != kGetReduceMotionMethod) {
          result->NotImplemented();
          return;
        }

        reduce_motion_enabled_ = QueryReduceMotionEnabled();
        result->Success(flutter::EncodableValue(reduce_motion_enabled_));
      });

  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (motion_preference_channel_) {
    motion_preference_channel_->SetMethodCallHandler(nullptr);
  }
  motion_preference_channel_.reset();
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
    case WM_SETTINGCHANGE:
      NotifyReduceMotionPreferenceIfChanged();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}

bool FlutterWindow::QueryReduceMotionEnabled() const {
  BOOL animations_enabled = TRUE;
  if (!SystemParametersInfoW(SPI_GETCLIENTAREAANIMATION, 0,
                             &animations_enabled, 0)) {
    return false;
  }
  return animations_enabled == FALSE;
}

void FlutterWindow::NotifyReduceMotionPreferenceIfChanged() {
  const bool reduce_motion_enabled = QueryReduceMotionEnabled();
  if (reduce_motion_enabled == reduce_motion_enabled_) {
    return;
  }

  reduce_motion_enabled_ = reduce_motion_enabled;
  if (motion_preference_channel_) {
    motion_preference_channel_->InvokeMethod(
        kReduceMotionChangedMethod,
        std::make_unique<flutter::EncodableValue>(reduce_motion_enabled_));
  }
}
