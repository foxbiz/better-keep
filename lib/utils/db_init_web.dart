import 'package:sqflite_common_ffi_web/sqflite_ffi_web.dart';
import 'package:sqflite/sqflite.dart';

import '../services/web_release.dart';

void initializeDb() {
  // Stable keeps the deployed worker's default protocol. Older workers cannot
  // accept setWebOptions, and existing stable tabs must share the same worker.
  databaseFactory = isBetaWebBuild
      ? createDatabaseFactoryFfiWeb(
          options: SqfliteFfiWebOptions(
            indexedDbName: 'better_keep_beta_sqlite',
            sharedWorkerUri: Uri.base.resolve('${betaWorkerBase}sqflite_sw.js'),
            sqlite3WasmUri: Uri.base.resolve('${betaWorkerBase}sqlite3.wasm'),
          ),
        )
      : databaseFactoryFfiWeb;
}
