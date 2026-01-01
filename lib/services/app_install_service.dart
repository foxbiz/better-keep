// Use conditional exports to load web-specific implementation only on web
export 'app_install_service_stub.dart'
    if (dart.library.js_interop) 'app_install_service_web.dart';
