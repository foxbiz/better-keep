// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Indonesian (`id`).
class AppLocalizationsId extends AppLocalizations {
  AppLocalizationsId([String locale = 'id']) : super(locale);

  @override
  String get appTitle => 'Better Keep';

  @override
  String get reminderType => 'Jenis pengingat';

  @override
  String get notificationReminder => 'Notifikasi';

  @override
  String get notificationReminderDescription =>
      'Menampilkan notifikasi standar yang peka waktu';

  @override
  String get alarmReminder => 'Alarm';

  @override
  String get alarmReminderDescription =>
      'Berbunyi terus sampai Anda menghentikannya';

  @override
  String get alarmUnsupportedPlatform =>
      'Alarm tidak didukung di platform ini. Pengingat akan disinkronkan dan menjadi alarm di Android atau iOS.';

  @override
  String get notificationUnsupportedPlatform =>
      'Notifikasi terjadwal tidak tersedia saat Better Keep ditutup di platform ini. Pengingat tetap disinkronkan dan muncul di aplikasi saat waktunya tiba.';

  @override
  String get alarmRequiresSpecificTime =>
      'Alarm memerlukan waktu tertentu; Sepanjang hari hanya tersedia untuk notifikasi.';

  @override
  String get reminderDue => 'Pengingat jatuh tempo';

  @override
  String get overdueReminderTitle => 'Pengingat terlambat';

  @override
  String get overdueReminderMessage =>
      'Pengingat ini sudah lewat waktunya. Tandai sebagai selesai sekarang?';

  @override
  String get markReminderDoneFailed =>
      'Tidak dapat menandai pengingat ini sebagai selesai. Coba lagi.';

  @override
  String get markAsDone => 'Tandai Selesai';

  @override
  String get reminderSavedPermissionRequired =>
      'Pengingat disimpan, tetapi izin diperlukan untuk menjadwalkannya di perangkat ini.';

  @override
  String get reminderSavedAlreadyDue =>
      'Pengingat disimpan dan waktunya sudah tiba.';

  @override
  String get reminderScheduleFailed =>
      'Pengingat disimpan, tetapi perangkat ini tidak dapat menjadwalkannya.';

  @override
  String get reminderCapacityExceeded =>
      'Pengingat disimpan, tetapi perangkat ini memiliki terlalu banyak pengingat tertunda untuk menjadwalkan yang baru.';

  @override
  String get reminderTimeZoneUnavailable =>
      'Pengingat disimpan, tetapi zona waktu perangkat ini tidak dapat dikenali. Periksa pengaturan waktu perangkat dan coba lagi.';

  @override
  String get cancel => 'Batal';

  @override
  String get ok => 'OK';

  @override
  String get save => 'Simpan';

  @override
  String get delete => 'Hapus';

  @override
  String get close => 'Tutup';

  @override
  String get retry => 'Coba Lagi';

  @override
  String get protectedSketchTitle => 'Sketsa terlindungi';

  @override
  String get protectedSketchRecoveryMessage =>
      'Sketsa lama yang dilindungi ini belum dapat dipulihkan. Gambar terenkripsi aslinya telah dipertahankan dan aplikasi akan mencoba lagi setelah pembukaan kunci berhasil berikutnya.';

  @override
  String get sketchBackgroundUnavailable =>
      'Latar belakang tidak tersedia; gambar tetap tersimpan';

  @override
  String get discard => 'Buang';

  @override
  String get attachmentCommitFailedTitle => 'Tidak dapat menambahkan lampiran';

  @override
  String get attachmentCommitFailedMessage =>
      'File asli tetap aman. Coba tambahkan lagi, atau buang dari perangkat ini.';

  @override
  String get done => 'Selesai';

  @override
  String get remove => 'Hapus';

  @override
  String get open => 'Buka';

  @override
  String get select => 'Pilih';

  @override
  String get verify => 'Verifikasi';

  @override
  String get link => 'Tautkan';

  @override
  String get unlink => 'Lepas Tautan';

  @override
  String get approve => 'Setujui';

  @override
  String get deny => 'Tolak';

  @override
  String get primary => 'Utama';

  @override
  String get signOut => 'Keluar';

  @override
  String get signOutAnyway => 'Tetap Keluar';

  @override
  String get continueOffline => 'Lanjutkan Offline';

  @override
  String get cancelSignIn => 'Batalkan Masuk';

  @override
  String get signInCancelled => 'Masuk dibatalkan';

  @override
  String get signInWithFacebook => 'Masuk dengan Facebook';

  @override
  String get signInWithGithub => 'Masuk dengan GitHub';

  @override
  String get signInWithEmail => 'Masuk dengan Email';

  @override
  String get about => 'Tentang';

  @override
  String get help => 'Bantuan';

  @override
  String get settings => 'Pengaturan';

  @override
  String get labels => 'Label';

  @override
  String get addLink => 'Tambah Tautan';

  @override
  String get editLink => 'Edit Tautan';

  @override
  String get setReminder => 'Atur Pengingat';

  @override
  String get displayText => 'Teks Tampilan';

  @override
  String get enterDisplayText => 'Masukkan teks untuk ditampilkan';

  @override
  String get pleaseEnterDisplayText => 'Silakan masukkan teks tampilan';

  @override
  String get url => 'URL';

  @override
  String get urlHint => 'https://example.com';

  @override
  String get titleYourThought => 'Beri judul pikiran Anda';

  @override
  String get email => 'Email';

  @override
  String get emailHint => 'anda@example.com';

  @override
  String get enterEmailAddress => 'Masukkan alamat email Anda';

  @override
  String get password => 'Kata Sandi';

  @override
  String get confirmPassword => 'Konfirmasi Kata Sandi';

  @override
  String get newPassword => 'Kata Sandi Baru';

  @override
  String get enterNewPassword => 'Masukkan kata sandi baru';

  @override
  String get reenterNewPassword => 'Masukkan ulang kata sandi baru';

  @override
  String get currentPassphrase => 'Frasa Sandi Saat Ini';

  @override
  String get enterYourPassphrase => 'Masukkan frasa sandi Anda';

  @override
  String get enterCurrentPassphrase => 'Masukkan frasa sandi Anda saat ini';

  @override
  String get recoveryPassphrase => 'Frasa Sandi Pemulihan';

  @override
  String get enterStrongPassphrase => 'Masukkan frasa sandi yang kuat';

  @override
  String get confirmPassphrase => 'Konfirmasi Frasa Sandi';

  @override
  String get reenterPassphrase => 'Masukkan ulang frasa sandi Anda';

  @override
  String get newPassphrase => 'Frasa Sandi Baru';

  @override
  String get confirmNewPassphrase => 'Konfirmasi Frasa Sandi Baru';

  @override
  String get reenterNewPassphrase => 'Masukkan ulang frasa sandi baru Anda';

  @override
  String get hintOptional => 'Petunjuk (Opsional)';

  @override
  String get hintToRemember => 'Petunjuk untuk membantu Anda mengingat';

  @override
  String get pin => 'PIN';

  @override
  String get enterPin => 'Masukkan PIN';

  @override
  String get newLabelName => 'Nama label baru';

  @override
  String get addLabel => 'Tambah label';

  @override
  String get searchLogs => 'Cari log...';

  @override
  String get audioRecording => 'Rekaman Audio';

  @override
  String get deleteRecording => 'Hapus Rekaman';

  @override
  String get title => 'Judul';

  @override
  String get enterRecordingTitle => 'Masukkan judul untuk rekaman ini';

  @override
  String get theme => 'Tema';

  @override
  String get customizeAppearance => 'Sesuaikan tampilan aplikasi';

  @override
  String get followSystemTheme => 'Ikuti Tema Sistem';

  @override
  String get autoSwitchLightDark => 'Beralih otomatis antara terang dan gelap';

  @override
  String get followSystemAnimations => 'Ikuti preferensi animasi sistem';

  @override
  String get reduceAnimationsFromSystem =>
      'Kurangi animasi saat diaktifkan di pengaturan perangkat atau browser';

  @override
  String get darkMode => 'Mode Gelap';

  @override
  String get darkTheme => 'Tema Gelap';

  @override
  String get lightTheme => 'Tema Terang';

  @override
  String get showSyncProgress => 'Tampilkan Kemajuan Sinkronisasi';

  @override
  String get displaySyncStatus => 'Tampilkan indikator status sinkronisasi';

  @override
  String get alarmSound => 'Suara Alarm';

  @override
  String get reminderTimeSettings => 'Pengaturan Waktu Pengingat';

  @override
  String get setDefaultTimes => 'Atur waktu default untuk pengingat';

  @override
  String get morning => 'Pagi';

  @override
  String get afternoon => 'Siang';

  @override
  String get evening => 'Malam';

  @override
  String get localDataProtection => 'Perlindungan Data Lokal';

  @override
  String get encryptDeviceData =>
      'Enkripsi data yang disimpan di perangkat ini';

  @override
  String get encryptNotes => 'Enkripsi Catatan';

  @override
  String get encryptFiles => 'Enkripsi File';

  @override
  String get lockedNotesSecurity => 'Keamanan Catatan Terkunci';

  @override
  String get privacyLockedNotes => 'Pengaturan privasi untuk catatan terkunci';

  @override
  String get forgetPasswordOnClose => 'Lupakan kata sandi saat ditutup';

  @override
  String get requirePasswordAgain =>
      'Minta kata sandi setiap kali aplikasi dibuka';

  @override
  String get nerdStats => 'Statistik Pengembang';

  @override
  String get developer => 'Pengembang';

  @override
  String get contactUs => 'Hubungi Kami';

  @override
  String get developedBy => 'Dikembangkan oleh';

  @override
  String get viewOnGithub => 'Lihat di GitHub';

  @override
  String get archive => 'Arsipkan';

  @override
  String get unarchive => 'Batalkan Arsip';

  @override
  String get readOnly => 'Hanya Baca';

  @override
  String get locked => 'Terkunci';

  @override
  String get saveAs => 'Simpan sebagai';

  @override
  String get copyAs => 'Salin sebagai';

  @override
  String get share => 'Bagikan';

  @override
  String get duplicate => 'Duplikat';

  @override
  String get markdown => 'Markdown';

  @override
  String get markdownFile => 'Markdown (.md)';

  @override
  String get html => 'HTML';

  @override
  String get htmlFile => 'HTML (.html)';

  @override
  String get plainText => 'Teks Biasa';

  @override
  String get plainTextFile => 'Teks Biasa (.txt)';

  @override
  String get restore => 'Pulihkan';

  @override
  String get reminder => 'Pengingat';

  @override
  String get hideKeyboard => 'Sembunyikan keyboard';

  @override
  String get refresh => 'Segarkan';

  @override
  String get dismiss => 'Tutup';

  @override
  String get back => 'Kembali';

  @override
  String get copyToClipboard => 'Salin ke clipboard';

  @override
  String get copiedToClipboard => 'Disalin ke clipboard';

  @override
  String get scribble => 'Coretan';

  @override
  String get revokeLink => 'Cabut tautan';

  @override
  String get expandToolbar => 'Perluas toolbar';

  @override
  String get collapseToolbar => 'Ciutkan toolbar';

  @override
  String get align => 'Ratakan';

  @override
  String get textSize => 'Ukuran Teks';

  @override
  String get indent => 'Indentasi';

  @override
  String get attach => 'Lampirkan';

  @override
  String get paperColor => 'Warna Kertas';

  @override
  String get pagePattern => 'Pola Halaman';

  @override
  String get moreOptions => 'Opsi lainnya';

  @override
  String get move => 'Pindahkan';

  @override
  String get viewAllPages => 'Lihat semua halaman';

  @override
  String get insert => 'Sisipkan';

  @override
  String get importAsNote => 'Impor sebagai Catatan';

  @override
  String get removeDevice => 'Hapus perangkat';

  @override
  String get noteJson => 'JSON Catatan';

  @override
  String get passwordResetSuccess =>
      'Kata sandi berhasil direset! Silakan masuk.';

  @override
  String get emailVerifiedSuccess => 'Email berhasil diverifikasi!';

  @override
  String get useDifferentAccount => 'Gunakan akun lain';

  @override
  String get recoverySuccessful => 'Pemulihan berhasil! Akses dipulihkan.';

  @override
  String get deviceApproved => 'Perangkat disetujui!';

  @override
  String get waitingForApproval => 'Menunggu persetujuan...';

  @override
  String get reapprovalRequestSent =>
      'Permintaan persetujuan ulang terkirim. Menunggu persetujuan...';

  @override
  String failedReapproval(String error) {
    return 'Gagal meminta persetujuan ulang: $error';
  }

  @override
  String get rememberDevice => 'Ingat perangkat ini';

  @override
  String get recoverWithPassphrase => 'Pulihkan dengan Frasa Sandi';

  @override
  String get startFresh => 'Mulai Baru';

  @override
  String get startFreshInstead => 'Mulai Baru Saja';

  @override
  String get requestReapproval => 'Minta Persetujuan Ulang';

  @override
  String get accessApproved => 'Akses disetujui';

  @override
  String failedToApprove(String error) {
    return 'Gagal menyetujui: $error';
  }

  @override
  String get accessDenied => 'Akses ditolak';

  @override
  String failedToDeny(String error) {
    return 'Gagal menolak: $error';
  }

  @override
  String get allUpToDate => 'Semua sudah terbaru';

  @override
  String get upgradeNow => 'Upgrade Sekarang';

  @override
  String get continueTrial => 'Lanjutkan Uji Coba';

  @override
  String get cancelSubscription => 'Batalkan Langganan';

  @override
  String get keepSubscription => 'Pertahankan Langganan';

  @override
  String get linkingAccount => 'Menautkan akun...';

  @override
  String unlinkProvider(String provider) {
    return 'Lepas tautan $provider?';
  }

  @override
  String unlinkedProvider(String provider) {
    return 'Tautan $provider dilepas';
  }

  @override
  String successfullyLinked(String provider) {
    return 'Berhasil menautkan akun $provider';
  }

  @override
  String unknownProvider(String provider) {
    return 'Provider tidak dikenal: $provider';
  }

  @override
  String get recoveryKey => 'Kunci Pemulihan';

  @override
  String get manageRecoveryPassphrase => 'Kelola frasa sandi pemulihan Anda';

  @override
  String get enableE2EE => 'Aktifkan Enkripsi End-to-End';

  @override
  String failedSaveRecoveryKey(String error) {
    return 'Gagal menyimpan kunci pemulihan: $error';
  }

  @override
  String get recoverySuccessWelcome =>
      'Pemulihan berhasil! Selamat datang kembali.';

  @override
  String get confirmConsequences =>
      'Harap konfirmasi bahwa Anda memahami konsekuensinya';

  @override
  String get accountResetSuccess => 'Akun berhasil direset. Selamat datang!';

  @override
  String failedResetAccount(String error) {
    return 'Gagal mereset akun: $error';
  }

  @override
  String errorSigningOut(String error) {
    return 'Error saat keluar: $error';
  }

  @override
  String errorPlayingSound(String error) {
    return 'Error memutar suara: $error';
  }

  @override
  String get checkNestedItems => 'Centang item bersarang?';

  @override
  String get uncheckNestedItems => 'Hapus centang item bersarang?';

  @override
  String get yes => 'Ya';

  @override
  String get no => 'Tidak';

  @override
  String get clipboardEmpty => 'Clipboard kosong';

  @override
  String get noteDeletedPermanently => 'Catatan dihapus permanen';

  @override
  String get reminderRemoved => 'Pengingat dihapus';

  @override
  String get reminderCompleted => 'Pengingat selesai';

  @override
  String get reminderSet => 'Pengingat diatur';

  @override
  String get failedCreateImageNote => 'Gagal membuat catatan gambar';

  @override
  String errorSavingSketchWithError(String error) {
    return 'Error menyimpan sketsa: $error';
  }

  @override
  String get failedSaveNote => 'Gagal menyimpan catatan';

  @override
  String failedSave(String error) {
    return 'Gagal menyimpan: $error';
  }

  @override
  String copiedAs(String format) {
    return 'Disalin sebagai $format';
  }

  @override
  String failedCopy(String error) {
    return 'Gagal menyalin: $error';
  }

  @override
  String get pastedAsPlainText => 'Ditempel sebagai teks biasa';

  @override
  String failedPaste(String error) {
    return 'Gagal menempel: $error';
  }

  @override
  String get contentInserted => 'Konten disisipkan';

  @override
  String failedInsertContent(String error) {
    return 'Gagal menyisipkan konten: $error';
  }

  @override
  String get actionCancelled => 'Tindakan dibatalkan';

  @override
  String get noteLocked => 'Catatan dikunci';

  @override
  String failedLockNote(String error) {
    return 'Gagal mengunci catatan: $error';
  }

  @override
  String get lockRemoved => 'Kunci dihapus';

  @override
  String failedRemoveLock(String error) {
    return 'Gagal menghapus kunci: $error';
  }

  @override
  String get noteDuplicated => 'Catatan diduplikat';

  @override
  String get errorSavingNote => 'Error menyimpan catatan';

  @override
  String get contentShared => 'Konten dibagikan';

  @override
  String get failedShare => 'Gagal membagikan';

  @override
  String get notes => 'Catatan';

  @override
  String get allNotes => 'Semua Catatan';

  @override
  String get archivedNotes => 'Diarsipkan';

  @override
  String get deletedNotes => 'Dihapus';

  @override
  String get pinnedNotes => 'Dipin';

  @override
  String get otherNotes => 'Lainnya';

  @override
  String get noNotes => 'Belum ada catatan';

  @override
  String get noArchivedNotes => 'Tidak ada catatan yang diarsipkan';

  @override
  String get noDeletedNotes => 'Tidak ada catatan yang dihapus';

  @override
  String get searchNotes => 'Cari catatan';

  @override
  String nSelectedNotes(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count catatan dipilih',
      one: '1 catatan dipilih',
    );
    return '$_temp0';
  }

  @override
  String get deleteNote => 'Hapus Catatan';

  @override
  String get deleteNotes => 'Hapus Catatan';

  @override
  String get moveToTrash => 'Pindahkan ke sampah';

  @override
  String get deletePermanently => 'Hapus permanen';

  @override
  String get pinNote => 'Pin';

  @override
  String get unpinNote => 'Lepas Pin';

  @override
  String get newNote => 'Catatan Baru';

  @override
  String get newSketch => 'Sketsa Baru';

  @override
  String get newFolder => 'Folder Baru';

  @override
  String get renameFolder => 'Ubah Nama Folder';

  @override
  String get deleteFolder => 'Hapus Folder';

  @override
  String get folderName => 'Nama folder';

  @override
  String get camera => 'Kamera';

  @override
  String get gallery => 'Galeri';

  @override
  String get audioRecorder => 'Perekam Audio';

  @override
  String get importFile => 'Impor File';

  @override
  String get language => 'Bahasa';

  @override
  String get systemDefault => 'Default Sistem';

  @override
  String get selectLanguage => 'Pilih Bahasa';

  @override
  String get english => 'English';

  @override
  String get japanese => '日本語';

  @override
  String get korean => '한국어';

  @override
  String get indonesian => 'Bahasa Indonesia';

  @override
  String get portugueseBrazil => 'Português (Brasil)';

  @override
  String get chinese => '中文';

  @override
  String get today => 'Hari Ini';

  @override
  String get tomorrow => 'Besok';

  @override
  String get nextWeek => 'Minggu depan';

  @override
  String get nextMonth => 'Bulan depan';

  @override
  String get pickDateTime => 'Pilih tanggal & waktu';

  @override
  String get time => 'Waktu';

  @override
  String get selectTime => 'Pilih waktu';

  @override
  String get allDay => 'Sepanjang hari';

  @override
  String get date => 'Tanggal';

  @override
  String get repeat => 'Ulangi';

  @override
  String get frequency => 'Frekuensi';

  @override
  String get never => 'Tidak pernah';

  @override
  String get daily => 'Harian';

  @override
  String get weekly => 'Mingguan';

  @override
  String get monthly => 'Bulanan';

  @override
  String get yearly => 'Tahunan';

  @override
  String get snooze => 'Tunda';

  @override
  String get fiveMinutes => '5 menit';

  @override
  String get tenMinutes => '10 menit';

  @override
  String get thirtyMinutes => '30 menit';

  @override
  String get oneHour => '1 jam';

  @override
  String get gridView => 'Tampilan grid';

  @override
  String get listView => 'Tampilan daftar';

  @override
  String get galleryView => 'Tampilan galeri';

  @override
  String get undo => 'Urungkan';

  @override
  String get redo => 'Ulangi';

  @override
  String get bold => 'Tebal';

  @override
  String get italic => 'Miring';

  @override
  String get underline => 'Garis bawah';

  @override
  String get strikethrough => 'Coret';

  @override
  String get bulletList => 'Daftar bullet';

  @override
  String get numberedList => 'Daftar bernomor';

  @override
  String get checklist => 'Daftar centang';

  @override
  String get quote => 'Kutipan';

  @override
  String get codeBlock => 'Blok kode';

  @override
  String get textColor => 'Warna teks';

  @override
  String get highlightColor => 'Warna sorotan';

  @override
  String get alignLeft => 'Rata kiri';

  @override
  String get alignCenter => 'Rata tengah';

  @override
  String get alignRight => 'Rata kanan';

  @override
  String get alignJustify => 'Rata kanan kiri';

  @override
  String get increaseIndent => 'Tambah indentasi';

  @override
  String get decreaseIndent => 'Kurangi indentasi';

  @override
  String get heading1 => 'Heading 1';

  @override
  String get heading2 => 'Heading 2';

  @override
  String get heading3 => 'Heading 3';

  @override
  String get normalText => 'Teks normal';

  @override
  String get pen => 'Pena';

  @override
  String get pencil => 'Pensil';

  @override
  String get brush => 'Kuas';

  @override
  String get highlighter => 'Stabilo';

  @override
  String get eraser => 'Penghapus';

  @override
  String get lasso => 'Lasso';

  @override
  String get addPage => 'Tambah halaman';

  @override
  String get deletePage => 'Hapus halaman';

  @override
  String get page => 'Halaman';

  @override
  String pageNumber(int number) {
    return 'Halaman $number';
  }

  @override
  String get connectedAccounts => 'Akun Terhubung';

  @override
  String get subscription => 'Langganan';

  @override
  String get free => 'Gratis';

  @override
  String get pro => 'Pro';

  @override
  String get trial => 'Uji Coba';

  @override
  String trialEndsIn(int days) {
    return 'Uji coba berakhir dalam $days hari';
  }

  @override
  String get devices => 'Perangkat';

  @override
  String get thisDevice => 'Perangkat ini';

  @override
  String lastActive(String time) {
    return 'Terakhir aktif: $time';
  }

  @override
  String get pendingApproval => 'Menunggu persetujuan';

  @override
  String get security => 'Keamanan';

  @override
  String get endToEndEncryption => 'Enkripsi End-to-End';

  @override
  String get e2eeEnabled => 'Diaktifkan';

  @override
  String get e2eeDisabled => 'Tidak diaktifkan';

  @override
  String get setupRecoveryKey => 'Atur Kunci Pemulihan';

  @override
  String get changeRecoveryKey => 'Ubah Kunci Pemulihan';

  @override
  String get verifyRecoveryKey => 'Verifikasi Kunci Pemulihan';

  @override
  String get error => 'Error';

  @override
  String errorWithMessage(String message) {
    return 'Error: $message';
  }

  @override
  String get loading => 'Memuat...';

  @override
  String get syncing => 'Menyinkronkan...';

  @override
  String get syncComplete => 'Sinkronisasi selesai';

  @override
  String get syncFailed => 'Sinkronisasi gagal';

  @override
  String get offline => 'Offline';

  @override
  String get online => 'Online';

  @override
  String get getApp => 'Dapatkan Aplikasi';

  @override
  String get sessionExpired => 'Sesi Anda telah berakhir. Silakan masuk lagi.';

  @override
  String get confirmSignOut => 'Apakah Anda yakin ingin keluar?';

  @override
  String get unsyncedChanges =>
      'Anda memiliki perubahan yang belum disinkronkan yang akan hilang.';

  @override
  String get deleteConfirmation => 'Apakah Anda yakin ingin menghapus ini?';

  @override
  String get permanentAction => 'Tindakan ini tidak dapat dibatalkan.';

  @override
  String get encryptNoteContent => 'Enkripsi Konten Catatan';

  @override
  String get encryptNotesInDatabase => 'Enkripsi catatan di database lokal';

  @override
  String get encryptAttachments => 'Enkripsi Lampiran';

  @override
  String get encryptImagesSketchesFiles => 'Enkripsi gambar, sketsa, dan file';

  @override
  String get localEncryptionInfo =>
      'Enkripsi lokal melindungi data Anda jika perangkat Anda disusupi. Menggunakan enkripsi AES-256-GCM.';

  @override
  String get lockedNotes => 'Catatan Terkunci';

  @override
  String get requireReenterPin =>
      'Wajib memasukkan ulang PIN saat membuka kembali catatan terkunci';

  @override
  String get faqAndSupport => 'FAQ dan hubungi dukungan';

  @override
  String get appInfoCredits => 'Info aplikasi dan kredit';

  @override
  String get advancedSettings => 'Pengaturan Lanjutan';

  @override
  String get speechRecognitionModel => 'Model Pengenalan Suara';

  @override
  String whisperModelDownloaded(String size) {
    return 'Terunduh ($size)';
  }

  @override
  String whisperModelNotDownloaded(String size) {
    return 'Belum terunduh ($size) - ketuk untuk mengunduh';
  }

  @override
  String get deleteWhisperModelConfirm =>
      'Hapus model pengenalan suara? Anda dapat mengunduhnya lagi nanti.';

  @override
  String get whisperModelDeleted => 'Model pengenalan suara dihapus';

  @override
  String get deleteModel => 'Hapus Model';

  @override
  String get download => 'Unduh';

  @override
  String get viewDatabaseStats => 'Lihat statistik database dan sinkronisasi';

  @override
  String get selectDarkTheme => 'Pilih Tema Gelap';

  @override
  String get selectLightTheme => 'Pilih Tema Terang';

  @override
  String get encryptingNotes => 'Mengenkripsi catatan yang ada...';

  @override
  String noteEncryptionEnabled(int count) {
    return 'Enkripsi catatan diaktifkan. $count catatan dienkripsi.';
  }

  @override
  String get noteEncryptionEnabledSimple => 'Enkripsi catatan diaktifkan.';

  @override
  String errorEncryptingNotes(String error) {
    return 'Error mengenkripsi catatan: $error';
  }

  @override
  String get noteEncryptionDisabled => 'Enkripsi catatan dinonaktifkan.';

  @override
  String get fileEncryptionEnabled =>
      'Enkripsi file diaktifkan. Lampiran baru akan dienkripsi.';

  @override
  String get fileEncryptionDisabled => 'Enkripsi file dinonaktifkan.';

  @override
  String get encryptDataOnDevice =>
      'Enkripsi data yang disimpan di perangkat ini';

  @override
  String get signInCancelledMessage => 'Masuk dibatalkan';

  @override
  String get startingSignIn => 'Memulai masuk...';

  @override
  String get continueWithGoogle => 'Lanjutkan dengan Google';

  @override
  String get continueWithApple => 'Lanjutkan dengan Apple';

  @override
  String get signInWithApple => 'Masuk dengan Apple';

  @override
  String get chooseSignInMethod => 'Pilih metode masuk yang Anda inginkan';

  @override
  String get yourNoteSecuredAndSynced =>
      'Catatan Anda, aman dan tersinkronisasi';

  @override
  String get endToEndEncryptionFeature => 'Enkripsi End-to-End';

  @override
  String get endToEndEncryptionDescription =>
      'Catatan Anda dienkripsi di perangkat Anda sebelum disinkronkan. Hanya Anda yang dapat membacanya — bahkan kami pun tidak dapat mengakses data Anda.';

  @override
  String get seamlessSync => 'Sinkronisasi Mulus';

  @override
  String get seamlessSyncDescription =>
      'Akses catatan Anda di perangkat mana pun. Perubahan disinkronkan secara instan dan aman di semua perangkat Anda.';

  @override
  String get richFormatting => 'Format Kaya';

  @override
  String get richFormattingDescription =>
      'Ekspresikan diri Anda dengan teks kaya, daftar centang, gambar, coretan, dan catatan suara. Catatan Anda, cara Anda.';

  @override
  String get gotIt => 'Mengerti';

  @override
  String get or => 'atau';

  @override
  String get signInWithGoogle => 'Masuk dengan Google';

  @override
  String get resetPassword => 'Reset Kata Sandi';

  @override
  String get resetPasswordDescription =>
      'Masukkan alamat email Anda dan kami akan mengirimkan kode verifikasi untuk mereset kata sandi Anda.';

  @override
  String get sendVerificationCode => 'Kirim Kode Verifikasi';

  @override
  String get sending => 'Mengirim...';

  @override
  String get enterVerificationCode => 'Masukkan Kode Verifikasi';

  @override
  String get enterCodeSentTo => 'Masukkan kode 6 digit yang dikirim ke:';

  @override
  String get pleaseEnterCompleteCode => 'Silakan masukkan kode 6 digit lengkap';

  @override
  String get verifying => 'Memverifikasi...';

  @override
  String get continue_ => 'Lanjutkan';

  @override
  String get resendCode => 'Kirim ulang kode';

  @override
  String resendCodeIn(int seconds) {
    return 'Kirim ulang kode dalam $seconds detik';
  }

  @override
  String get codeExpiresIn => 'Kode kedaluwarsa dalam 10 menit';

  @override
  String get createNewPassword => 'Buat Kata Sandi Baru';

  @override
  String get enterNewPasswordDescription =>
      'Masukkan kata sandi baru untuk akun Anda.';

  @override
  String get enterNewPasswordHint => 'Masukkan kata sandi baru';

  @override
  String get reenterNewPasswordHint => 'Masukkan ulang kata sandi baru';

  @override
  String get resettingPassword => 'Mereset Kata Sandi...';

  @override
  String get pleaseEnterNewPassword => 'Silakan masukkan kata sandi baru';

  @override
  String get pleaseEnterEmailAddress => 'Silakan masukkan alamat email Anda';

  @override
  String get pleaseEnterValidEmail =>
      'Silakan masukkan alamat email yang valid';

  @override
  String get failedSendVerificationCode =>
      'Gagal mengirim kode verifikasi. Silakan coba lagi.';

  @override
  String get invalidVerificationCode => 'Kode verifikasi tidak valid';

  @override
  String get verificationFailed => 'Verifikasi gagal. Silakan coba lagi.';

  @override
  String get passwordResetFailed =>
      'Reset kata sandi gagal. Silakan coba lagi.';

  @override
  String get verifyYourEmail => 'Verifikasi Email Anda';

  @override
  String get sendingVerificationCode => 'Mengirim kode verifikasi...';

  @override
  String get emailVerifiedSuccessfully => 'Email berhasil diverifikasi!';

  @override
  String get deviceRevoked => 'Perangkat Dicabut';

  @override
  String get waitingForApprovalTitle => 'Menunggu Persetujuan';

  @override
  String get deviceRevokedDescription =>
      'Perangkat ini telah dicabut dan tidak dapat lagi mengakses catatan Anda. Silakan masuk lagi dari perangkat yang disetujui untuk mengotorisasi ulang.';

  @override
  String get pleaseApproveFrom => 'Silakan setujui dari:';

  @override
  String get waitingForApprovalFromDevice =>
      'Menunggu persetujuan dari perangkat lain...';

  @override
  String get rememberThisDevice => 'Ingat perangkat ini';

  @override
  String get deviceRemovedOnSignOut =>
      'Jika tidak dicentang, perangkat ini akan dihapus saat Anda keluar';

  @override
  String get checkingStatus => 'Memeriksa...';

  @override
  String get checkStatus => 'Periksa Status';

  @override
  String get cancelRequest => 'Batalkan Permintaan';

  @override
  String get pleaseWait => 'Mohon tunggu...';

  @override
  String get updateRecoveryKey => 'Perbarui Kunci Pemulihan';

  @override
  String get recoveryPassphraseDescription =>
      'Buat frasa sandi pemulihan yang dapat memulihkan akses ke catatan Anda jika Anda kehilangan semua perangkat.';

  @override
  String get recoveryPassphraseWarning =>
      'Simpan frasa sandi ini dengan aman. Tanpa itu, Anda tidak dapat memulihkan catatan jika kehilangan semua perangkat.';

  @override
  String get enterAStrongPassphrase => 'Masukkan frasa sandi yang kuat';

  @override
  String get pleaseEnterPassphrase => 'Silakan masukkan frasa sandi';

  @override
  String get passphraseMinLength => 'Frasa sandi harus minimal 6 karakter';

  @override
  String get passphrasesDoNotMatch => 'Frasa sandi tidak cocok';

  @override
  String get passphraseTooCommon =>
      'Frasa sandi ini terlalu umum dan mudah ditebak';

  @override
  String get passphraseStrengthAdvice =>
      'Pertimbangkan untuk menambahkan huruf besar, huruf kecil, angka, atau simbol untuk frasa sandi yang lebih kuat';

  @override
  String get saving => 'Menyimpan...';

  @override
  String get saveRecoveryKey => 'Simpan Kunci Pemulihan';

  @override
  String get passwordShortWarning =>
      'Kata sandi cukup pendek. Pertimbangkan untuk menggunakan minimal 6 karakter.';

  @override
  String get passwordLongerAdvice =>
      'Pertimbangkan untuk menggunakan kata sandi yang lebih panjang untuk keamanan yang lebih baik.';

  @override
  String get passwordMixAdvice =>
      'Pertimbangkan untuk menambahkan huruf dan angka untuk keamanan yang lebih kuat.';

  @override
  String version(String version, String buildNumber) {
    return 'Versi $version ($buildNumber)';
  }

  @override
  String get openSource => 'Sumber Tersedia';

  @override
  String get openSourceDescription =>
      'Kode sumber dapat diperiksa dengan lisensi CC BY-NC 4.0. Karena penggunaan komersial dibatasi, ini adalah source-available, bukan open source yang disetujui OSI.';

  @override
  String get frequentlyAskedQuestions => 'Pertanyaan yang Sering Diajukan';

  @override
  String get needMoreHelp => 'Butuh Bantuan Lebih?';

  @override
  String get needMoreHelpDescription =>
      'Jika Anda memiliki pertanyaan atau membutuhkan bantuan, jangan ragu untuk menghubungi kami.';

  @override
  String get deleteImage => 'Hapus Gambar';

  @override
  String get deleteImageConfirmation =>
      'Apakah Anda yakin ingin menghapus gambar ini?';

  @override
  String get importAsNoteTooltip => 'Impor sebagai Catatan';

  @override
  String get insertTooltip => 'Sisipkan';

  @override
  String failedToImport(String error) {
    return 'Gagal mengimpor: $error';
  }

  @override
  String get notes_ => 'Catatan';

  @override
  String get media => 'Media';

  @override
  String plan(String planName) {
    return 'Paket $planName';
  }

  @override
  String get freeTrialActive => 'Uji Coba Gratis Aktif';

  @override
  String expiresOnDaysLeft(String date, int days) {
    return 'Kedaluwarsa $date ($days hari lagi)';
  }

  @override
  String get enjoyProFeatures =>
      'Nikmati semua fitur Pro selama uji coba Anda!';

  @override
  String get billing => 'Penagihan';

  @override
  String get renews => 'Diperbarui';

  @override
  String get expires => 'Kedaluwarsa';

  @override
  String get monthlySubscription => 'Langganan bulanan';

  @override
  String get yearlySubscription => 'Langganan tahunan';

  @override
  String get freeTrial => 'Uji Coba Gratis';

  @override
  String get subscriptionInGracePeriod =>
      'Langganan Anda dalam masa tenggang. Silakan perbarui metode pembayaran Anda.';

  @override
  String subscriptionCancelledInfo(String date) {
    return 'Akses Pro Anda akan berakhir pada $date. Anda dapat berlangganan lagi setelah kedaluwarsa.';
  }

  @override
  String get subscriptionCancelled => 'Langganan Dibatalkan';

  @override
  String get upgradeToProDescription =>
      'Upgrade ke Pro untuk catatan terkunci tanpa batas, sinkronisasi cloud, dan lainnya.';

  @override
  String get cancellingSubscription => 'Membatalkan...';

  @override
  String get manageSubscription => 'Kelola Langganan';

  @override
  String get renewSubscription => 'Perbarui Langganan';

  @override
  String get restoreInfoText =>
      'Berlangganan akan secara otomatis memulihkan langganan aktif atau pembelian sebelumnya.';

  @override
  String get cancelSubscriptionConfirmation =>
      'Apakah Anda yakin ingin membatalkan langganan Anda?\n\nLangganan Anda akan tetap aktif hingga akhir periode penagihan saat ini. Setelah itu, Anda akan kehilangan akses ke fitur Pro.';

  @override
  String get subscriptionChangesMayTakeMoment =>
      'Jika Anda melakukan perubahan, mungkin perlu beberapa saat untuk muncul.';

  @override
  String get subscriptionRestored => 'Langganan Anda telah dipulihkan!';

  @override
  String get subscriptionAlreadyActive =>
      'Anda sudah memiliki langganan aktif.';

  @override
  String get subscriptionActivated => 'Langganan berhasil diaktifkan!';

  @override
  String get purchaseCancelled => 'Pembelian dibatalkan.';

  @override
  String get paymentFailed => 'Pembayaran gagal.';

  @override
  String get couldNotOpenSubscriptionManagement =>
      'Tidak dapat membuka manajemen langganan.';

  @override
  String manageSubscriptionInStore(String store) {
    return 'Kelola langganan Anda di $store.';
  }

  @override
  String get loadingFailedTryAgain => 'Gagal memuat — Coba lagi';

  @override
  String get reloadPrices => 'Muat ulang harga';

  @override
  String subscribeWithPrice(String price) {
    return 'Berlangganan — $price';
  }

  @override
  String get noAdsDescription =>
      'Tanpa iklan, tanpa penjualan data — langganan Anda mendanai server aman & pengembangan berkelanjutan.';

  @override
  String get detectingLocation => 'Mendeteksi lokasi Anda...';

  @override
  String get currencyHelpText =>
      'Gunakan INR untuk kartu India, USD untuk kartu internasional.';

  @override
  String get selfHostContact =>
      'Ingin self-host? Hubungi kami di contact@betterkeep.app';

  @override
  String get welcomeToProMessage => 'Selamat datang di Better Keep Pro!';

  @override
  String get loadingPrices => 'Memuat harga...';

  @override
  String get processingSubscription => 'Memproses...';

  @override
  String get subscriptionAutoRenewTerms =>
      'Pembayaran akan dikenakan ke akun Anda. Langganan otomatis diperbarui kecuali perpanjangan otomatis dinonaktifkan setidaknya 24 jam sebelum akhir periode saat ini.';

  @override
  String savePercent(int percent) {
    return 'Hemat $percent%';
  }

  @override
  String get subscriptionCancelledSuccessfully =>
      'Langganan berhasil dibatalkan.';

  @override
  String get subscriptionResumedSuccessfully =>
      'Langganan berhasil dilanjutkan.';

  @override
  String get failedToCancelSubscription => 'Gagal membatalkan langganan.';

  @override
  String get failedToResumeSubscription => 'Gagal melanjutkan langganan.';

  @override
  String get featureTableHeader => 'Fitur';

  @override
  String get unlimited => 'Tidak terbatas';

  @override
  String get paywallLocalNotes => 'Catatan lokal';

  @override
  String get lockedNotesFreeLimit => 'Maks 5';

  @override
  String get signInWithAnyLinked => 'Masuk dengan akun terhubung mana pun';

  @override
  String get linkingRequiresAuth =>
      'Menautkan memerlukan autentikasi dengan setiap platform untuk memverifikasi kepemilikan.';

  @override
  String get connected => 'Terhubung';

  @override
  String get cannotUnlinkPrimary =>
      'Tidak dapat melepas tautan metode masuk asli';

  @override
  String get verifyAccountLink => 'Verifikasi Tautan Akun';

  @override
  String get verifyAndLink => 'Verifikasi & Tautkan';

  @override
  String get yourNotesAreProtected => 'Catatan Anda dilindungi';

  @override
  String get waitingForDeviceApproval => 'Menunggu persetujuan perangkat';

  @override
  String get protectionNotEnabled => 'Perlindungan tidak diaktifkan';

  @override
  String get somethingWentWrong => 'Terjadi kesalahan';

  @override
  String get deviceAccessRemoved => 'Akses perangkat dihapus';

  @override
  String get gettingReady => 'Mempersiapkan...';

  @override
  String get notesAndAttachmentsEncrypted =>
      'Catatan dan lampiran Anda dienkripsi';

  @override
  String get encryption => 'Enkripsi';

  @override
  String get keyExchange => 'Pertukaran Kunci';

  @override
  String get keySize => 'Ukuran Kunci';

  @override
  String nDevicesAuthorized(int count) {
    return '$count diotorisasi';
  }

  @override
  String get important => 'Penting';

  @override
  String get approveOnOtherDevice =>
      'Buka Better Keep di perangkat yang sudah diotorisasi untuk menyetujui perangkat ini.';

  @override
  String get yourDevices => 'Perangkat Anda';

  @override
  String get pendingApprovalSection => 'Menunggu Persetujuan';

  @override
  String get authorizedDevices => 'Perangkat yang Diotorisasi';

  @override
  String get noInternetConnection =>
      'Tidak ada koneksi internet. Silakan periksa jaringan Anda dan coba lagi.';

  @override
  String get dangerZone => 'Zona Bahaya';

  @override
  String get dangerZoneDescription =>
      'Hapus akun Anda dan semua data terkait secara permanen. Tindakan ini akan diselesaikan setelah masa tenggang 30 hari.';

  @override
  String get deleteMyAccount => 'Hapus Akun Saya';

  @override
  String get unsyncedNotesWarning =>
      'Anda memiliki catatan yang belum disinkronkan ke cloud. Jika Anda keluar sekarang, catatan ini akan HILANG SELAMANYA.\n\nPertimbangkan untuk menunggu sinkronisasi selesai atau mengekspor data Anda terlebih dahulu.';

  @override
  String notesNotSynced(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count catatan belum disinkronkan',
      one: '1 catatan belum disinkronkan',
    );
    return '$_temp0';
  }

  @override
  String get dataLossWarning => 'PERINGATAN KEHILANGAN DATA';

  @override
  String get noRecoveryKeySet => 'Kunci pemulihan belum diatur';

  @override
  String get signOutNoRecoveryKeyWarning =>
      'Jika Anda keluar dan kehilangan akses ke semua perangkat yang disetujui, Anda akan KEHILANGAN AKSES SECARA PERMANEN ke SEMUA catatan terenkripsi Anda.\n\nTindakan ini tidak dapat dibatalkan.';

  @override
  String get signOutConfirmation =>
      'Apakah Anda yakin ingin keluar?\n\nAnda perlu masuk lagi untuk mengakses catatan Anda.';

  @override
  String nDevicesWaitingForApproval(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count Perangkat Menunggu Persetujuan',
      one: '1 Perangkat Menunggu Persetujuan',
    );
    return '$_temp0';
  }

  @override
  String get reviewAndApprove => 'Tinjau dan setujui untuk memberikan akses';

  @override
  String nShareAccessRequests(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count Permintaan Akses Berbagi',
      one: '1 Permintaan Akses Berbagi',
    );
    return '$_temp0';
  }

  @override
  String get someoneWantsToView =>
      'Seseorang ingin melihat catatan yang Anda bagikan';

  @override
  String get deviceApproved_ => 'Perangkat disetujui';

  @override
  String failedApproveDevice(String error) {
    return 'Gagal menyetujui perangkat: $error';
  }

  @override
  String get deviceRemoved => 'Perangkat dihapus';

  @override
  String nDevicesRemoved(int count) {
    return '$count perangkat dihapus';
  }

  @override
  String failedRemoveDevice(String error) {
    return 'Gagal menghapus perangkat: $error';
  }

  @override
  String get removeDevice_ => 'Hapus Perangkat';

  @override
  String removeDeviceConfirmation(String deviceName) {
    return 'Apakah Anda yakin ingin menghapus \"$deviceName\"?\n\nPerangkat ini tidak akan lagi memiliki akses ke catatan Anda.';
  }

  @override
  String get enableE2EEConfirmation =>
      'Ini akan mengenkripsi semua catatan dan lampiran Anda. Hanya perangkat yang Anda otorisasi yang dapat membacanya.\n\nPastikan untuk mengatur kunci pemulihan setelah mengaktifkan E2EE, atau Anda mungkin kehilangan akses ke catatan jika kehilangan semua perangkat.';

  @override
  String get enableE2EE_ => 'Aktifkan E2EE';

  @override
  String failedEnableE2EE(String error) {
    return 'Gagal mengaktifkan E2EE: $error';
  }

  @override
  String get recoveryKeySavedSuccessfully =>
      'Kunci pemulihan berhasil disimpan!';

  @override
  String get noRecoveryKeyWarning =>
      'Peringatan: Tanpa kunci pemulihan, Anda mungkin kehilangan akses ke catatan jika kehilangan semua perangkat.';

  @override
  String get recoveryKeySetUp =>
      'Anda memiliki kunci pemulihan. Apa yang ingin Anda lakukan?';

  @override
  String get update => 'Perbarui';

  @override
  String get recoveryKeyUpdated => 'Kunci pemulihan diperbarui!';

  @override
  String get recoveryKeyRemoved => 'Kunci pemulihan dihapus';

  @override
  String get recoveryKeySaved => 'Kunci pemulihan disimpan!';

  @override
  String get upgradeNowQuestion => 'Upgrade Sekarang?';

  @override
  String trialTimeLeft(String timeLeft) {
    return 'Anda masih memiliki $timeLeft pada uji coba gratis Anda.';
  }

  @override
  String get subscribeNowTrialEnds =>
      'Jika Anda berlangganan sekarang, uji coba Anda akan segera berakhir dan penagihan akan dimulai segera.';

  @override
  String alreadyHaveSubscription(String planName) {
    return 'Anda sudah memiliki langganan $planName yang aktif!';
  }

  @override
  String unlinkProviderQuestion(String provider) {
    return 'Lepas tautan $provider?';
  }

  @override
  String get unlinkProviderWarning =>
      'Anda tidak akan lagi dapat masuk dengan akun ini. Pastikan Anda memiliki cara lain untuk mengakses akun Anda.';

  @override
  String unlinkedSuccessfully(String provider) {
    return 'Tautan $provider dilepas';
  }

  @override
  String get failedUnlinkAccount => 'Gagal melepas tautan akun';

  @override
  String get cannotUnlinkOnlyMethod =>
      'Tidak dapat melepas tautan satu-satunya metode masuk.';

  @override
  String unknownProviderError(String provider) {
    return 'Provider tidak dikenal: $provider';
  }

  @override
  String get takingTooLong =>
      'Terlalu lama. Anda dapat membatalkan dan mencoba lagi.';

  @override
  String get failedSendCode => 'Gagal mengirim kode verifikasi';

  @override
  String get pleaseTryAgain => 'Silakan coba lagi.';

  @override
  String get pleaseSignInAgain => 'Silakan masuk lagi dan coba.';

  @override
  String get noEmailAssociated =>
      'Tidak ada email yang terkait dengan akun Anda.';

  @override
  String providerAlreadyLinked(String provider) {
    return '$provider sudah ditautkan ke akun Anda.';
  }

  @override
  String get pleaseWaitBeforeRequesting =>
      'Silakan tunggu sebelum meminta lagi.';

  @override
  String get sessionExpired_ => 'Sesi kedaluwarsa. Silakan coba lagi.';

  @override
  String get failedLinkAccount => 'Gagal menautkan akun';

  @override
  String providerLinkedToAnother(String provider) {
    return 'Akun $provider ini sudah ditautkan ke pengguna lain.';
  }

  @override
  String get emailAlreadyInUse =>
      'Akun dengan email ini sudah ada. Masuk dengan akun tersebut terlebih dahulu, lalu tautkan dari sana.';

  @override
  String get linkingCancelled => 'Penautkan dibatalkan.';

  @override
  String successfullyLinkedProvider(String provider) {
    return 'Berhasil menautkan akun $provider';
  }

  @override
  String get deleteYourAccount => 'Hapus Akun Anda?';

  @override
  String get actionIrreversible => 'Tindakan ini tidak dapat dibatalkan';

  @override
  String get allNotesDeleted =>
      'Semua catatan Anda akan dihapus secara permanen';

  @override
  String get allAttachmentsRemoved => 'Semua lampiran dan media akan dihapus';

  @override
  String get loggedOutAllDevices => 'Anda akan keluar dari semua perangkat';

  @override
  String get accountCannotBeRecovered => 'Akun Anda tidak dapat dipulihkan';

  @override
  String get gracePeriodInfo =>
      'Masa tenggang 30 hari: Masuk kembali untuk membatalkan penghapusan.';

  @override
  String get verificationCodeViaEmail =>
      'Anda akan menerima kode verifikasi melalui email.';

  @override
  String get keepMyAccount => 'Pertahankan Akun Saya';

  @override
  String get deleteAccount => 'Hapus Akun';

  @override
  String get verifyYourIdentity => 'Verifikasi Identitas Anda';

  @override
  String get userNotSignedIn => 'Pengguna tidak masuk';

  @override
  String get failedScheduleDeletion => 'Gagal menjadwalkan penghapusan';

  @override
  String get deletionScheduled => 'Penghapusan Dijadwalkan';

  @override
  String accountWillBeDeletedOn(String date) {
    return 'Akun Anda akan dihapus pada $date.';
  }

  @override
  String get exportBeforeSignOut =>
      'Apakah Anda ingin mengekspor data sebelum keluar?';

  @override
  String get skip => 'Lewati';

  @override
  String get exportData => 'Ekspor Data';

  @override
  String get exportingData => 'Mengekspor Data';

  @override
  String get exportCancelled => 'Ekspor dibatalkan';

  @override
  String get exportFailed => 'Ekspor gagal';

  @override
  String get exportComplete => 'Ekspor Selesai';

  @override
  String exportCompleteMessage(String path) {
    return 'Data Anda telah berhasil diekspor.\n\nFile disimpan ke:\n$path\n\nApakah Anda ingin membagikan file ekspor?';
  }

  @override
  String deletionScheduledMessage(String date) {
    return 'Penghapusan akun dijadwalkan untuk $date. Masuk lagi untuk membatalkan.';
  }

  @override
  String get iphoneIpad => 'iPhone/iPad';

  @override
  String get webBrowser => 'Browser Web';

  @override
  String get debugDeleteSubscription => 'DEBUG: Hapus Langganan';

  @override
  String get debugDeleteSubscriptionWarning =>
      'Ini akan segera menghapus langganan Anda dari database.\n\nIni HANYA untuk PENGUJIAN dan tidak akan membatalkan langganan Razorpay yang sebenarnya.';

  @override
  String get debugSubscriptionDeleted => 'DEBUG: Langganan berhasil dihapus';

  @override
  String get debugSubscriptionDeleteFailed =>
      'DEBUG: Gagal menghapus langganan';

  @override
  String get removeLink => 'Hapus Tautan';

  @override
  String get add => 'Tambah';

  @override
  String get recent => 'Terbaru';

  @override
  String get custom => 'Kustom';

  @override
  String get createLabelToOrganize =>
      'Buat label di atas untuk mengorganisir catatan Anda';

  @override
  String editLabelName(String labelName) {
    return 'Edit $labelName';
  }

  @override
  String get enterNewName => 'Masukkan nama baru';

  @override
  String get deleteLabel => 'Hapus Label';

  @override
  String deleteLabelConfirmation(String labelName) {
    return 'Apakah Anda yakin ingin menghapus label ini ($labelName)?';
  }

  @override
  String get pasteAs => 'Tempel sebagai';

  @override
  String get formattedText => 'Teks berformat';

  @override
  String get previewAndInsertFormatted =>
      'Pratinjau dan sisipkan sebagai konten berformat';

  @override
  String get insertAsPlainText => 'Sisipkan sebagai teks biasa tanpa format';

  @override
  String get prompt => 'Prompt';

  @override
  String get notMatched => 'Tidak cocok';

  @override
  String confirmPlaceholder(String placeholder) {
    return 'Konfirmasi $placeholder';
  }

  @override
  String get notificationPermissionsRequired =>
      'Izin notifikasi dan alarm diperlukan untuk pengingat';

  @override
  String get checkAll => 'Centang Semua';

  @override
  String get uncheckAll => 'Hapus Centang Semua';

  @override
  String checkNestedItemsCount(int count) {
    return 'Ini akan mencentang $count item bersarang.';
  }

  @override
  String uncheckNestedItemsCount(int count) {
    return 'Ini akan menghapus centang $count item bersarang.';
  }

  @override
  String get somethingWentWrongTryAgain =>
      'Terjadi kesalahan. Silakan coba lagi.';

  @override
  String get verifyingPassphrase => 'Memverifikasi frasa sandi...';

  @override
  String get settingAsPrimaryDevice => 'Mengatur sebagai perangkat utama...';

  @override
  String get finalizing => 'Menyelesaikan...';

  @override
  String get incorrectPassphrase => 'Frasa sandi salah. Silakan coba lagi.';

  @override
  String get recoveryTimedOut =>
      'Pemulihan habis waktu. Silakan periksa koneksi Anda dan coba lagi.';

  @override
  String get recoveryKeyMobileOnly =>
      'Kunci pemulihan ini dibuat di aplikasi mobile atau desktop dan tidak dapat digunakan di browser. Silakan gunakan aplikasi mobile atau desktop untuk memulihkan.';

  @override
  String get somethingWentWrongCheckConnection =>
      'Terjadi kesalahan. Silakan periksa koneksi Anda dan coba lagi.';

  @override
  String get recover => 'Pulihkan';

  @override
  String get recoverInfoTooltip =>
      'Pulihkan kunci enkripsi Anda menggunakan frasa sandi pemulihan';

  @override
  String hintLabel(String hint) {
    return 'Petunjuk: $hint';
  }

  @override
  String get setAsPrimaryDevice => 'Atur sebagai perangkat utama';

  @override
  String get pleaseEnterRecoveryPassphrase =>
      'Silakan masukkan frasa sandi pemulihan Anda';

  @override
  String get currentPassphraseIncorrect => 'Frasa sandi saat ini salah';

  @override
  String get pleaseEnterCurrentPassphrase =>
      'Silakan masukkan frasa sandi Anda saat ini';

  @override
  String get pleaseEnterNewPassphrase => 'Silakan masukkan frasa sandi baru';

  @override
  String get removeRecoveryKey => 'Hapus Kunci Pemulihan';

  @override
  String get removeRecoveryKeyWarning =>
      'Peringatan: Tanpa kunci pemulihan, Anda tidak dapat memulihkan catatan jika kehilangan semua perangkat!';

  @override
  String get enterPassphraseToConfirmRemoval =>
      'Masukkan frasa sandi Anda saat ini untuk mengonfirmasi penghapusan:';

  @override
  String get passphraseIncorrect => 'Frasa sandi salah';

  @override
  String get unlockNote => 'Buka Kunci Catatan';

  @override
  String get pleaseEnterPin => 'Silakan masukkan PIN';

  @override
  String tooManyAttemptsWait(int seconds) {
    return 'Terlalu banyak percobaan. Tunggu $seconds detik.';
  }

  @override
  String attemptsRemaining(String message, int remaining) {
    return '$message. $remaining percobaan tersisa.';
  }

  @override
  String get failedToUnlockNote => 'Gagal membuka kunci catatan';

  @override
  String lockedSeconds(int seconds) {
    return 'Terkunci ($seconds detik)';
  }

  @override
  String get unlock => 'Buka Kunci';

  @override
  String get lockNote => 'Kunci Catatan';

  @override
  String get pinForgotWarning =>
      'Jika Anda lupa PIN ini, tidak ada cara untuk memulihkan catatan.';

  @override
  String get pleaseEnterAPin => 'Silakan masukkan PIN';

  @override
  String get pinMinLength => 'PIN harus minimal 4 karakter';

  @override
  String get pinTooWeak => 'PIN terlalu lemah (semua karakter sama)';

  @override
  String get pinTooCommon => 'PIN terlalu umum';

  @override
  String get confirmPin => 'Konfirmasi PIN';

  @override
  String get reenterPin => 'Masukkan ulang PIN';

  @override
  String get pinsDoNotMatch => 'PIN tidak cocok';

  @override
  String get lock => 'Kunci';

  @override
  String get recordAudio => 'Rekam Audio';

  @override
  String get microphonePermissionRequired =>
      'Izin mikrofon diperlukan untuk merekam audio.';

  @override
  String get openSettings => 'Buka Pengaturan';

  @override
  String get stopRecording => 'Hentikan perekaman';

  @override
  String get startRecording => 'Mulai perekaman';

  @override
  String get transcriptionUnavailable => 'Transkripsi tidak tersedia';

  @override
  String get liveTranscription => 'Transkripsi langsung';

  @override
  String get recordingContinuesWithoutTranscription =>
      'Perekaman akan berlanjut tanpa transkripsi';

  @override
  String get listening => 'Mendengarkan...';

  @override
  String get allowMicAccess => 'Izinkan akses mikrofon untuk mulai merekam.';

  @override
  String get tapStartToRecord => 'Ketuk mulai untuk memulai perekaman.';

  @override
  String get transcribeWhileRecording => 'Transkripsi saat merekam';

  @override
  String get transcription => 'Transkripsi';

  @override
  String get editTranscriptionHint => 'Edit transkripsi jika diperlukan';

  @override
  String get addTranscriptionToNote => 'Tambahkan transkripsi ke catatan';

  @override
  String get noSpeechDetected =>
      'Tidak ada ucapan yang terdeteksi selama perekaman.';

  @override
  String get titleOptional => 'Judul (opsional)';

  @override
  String get enterTitleForRecording => 'Masukkan judul untuk rekaman ini';

  @override
  String get okay => 'Oke';

  @override
  String get failedToStartRecording => 'Gagal memulai perekaman';

  @override
  String get transcriptionDisabledWebPrivacy =>
      'Transkripsi suara dinonaktifkan di web untuk privasi. Audio Anda tetap di perangkat.';

  @override
  String get whisperModelRequired => 'Diperlukan model pengenalan suara';

  @override
  String whisperModelDescription(String size) {
    return 'Unduh model AI kecil ($size) untuk konversi suara-ke-teks di perangkat. Audio Anda tidak pernah meninggalkan perangkat.';
  }

  @override
  String get downloadModel => 'Unduh Model';

  @override
  String get useFallback => 'Gunakan default perangkat';

  @override
  String get whisperTranscriptionActive =>
      'Transkripsi AI di perangkat (privat)';

  @override
  String get modelDownloadComplete => 'Model suara berhasil diunduh';

  @override
  String get modelDownloadFailed => 'Gagal mengunduh model suara';

  @override
  String get transcribingAudio => 'Mentranskrip audio...';

  @override
  String get polishingTranscription => 'Memoles transkripsi...';

  @override
  String get transcriptionFailed => 'Transkripsi gagal. Silakan coba lagi.';

  @override
  String get deleteQuestion => 'Hapus?';

  @override
  String get actionCannotBeUndone => 'Tindakan ini tidak dapat dibatalkan.';

  @override
  String get permanentDeleteWarning =>
      'Ini akan menghapus semua data secara permanen dan tidak dapat dipulihkan.';

  @override
  String get sentVerificationCodeTo => 'Kami mengirim kode verifikasi ke:';

  @override
  String codeExpiresInMinutes(int minutes) {
    return 'Kode kedaluwarsa dalam $minutes menit';
  }

  @override
  String get verificationFailedTryAgain =>
      'Verifikasi gagal. Silakan coba lagi.';

  @override
  String get shareNote => 'Bagikan Catatan';

  @override
  String get untitledNote => 'Catatan Tanpa Judul';

  @override
  String get shareAsText => 'Bagikan sebagai Teks';

  @override
  String get plainTextContent => 'Konten teks biasa';

  @override
  String get shareAsMarkdown => 'Bagikan sebagai Markdown';

  @override
  String get formattedWithMarkdown => 'Diformat dengan sintaks markdown';

  @override
  String get createSecureLink => 'Buat Tautan Aman';

  @override
  String get encryptedLinkWithApproval =>
      'Tautan terenkripsi dengan persetujuan akses';

  @override
  String get linkCreated => 'Tautan Dibuat';

  @override
  String activeLinks(int count) {
    return 'Tautan Aktif ($count)';
  }

  @override
  String get secureLink => 'Tautan Aman';

  @override
  String get createNewLink => 'Buat Tautan Baru';

  @override
  String get revokeLink_ => 'Cabut tautan';

  @override
  String get copy => 'Salin';

  @override
  String get linkNotAvailable =>
      'Tautan tidak tersedia (dibuat di perangkat lain)';

  @override
  String get revokeLinkQuestion => 'Cabut Tautan?';

  @override
  String get revokeLinkWarning =>
      'Ini akan menonaktifkan tautan berbagi ini secara permanen. Siapa pun yang memiliki tautan tidak akan lagi dapat mengakses catatan.';

  @override
  String get revoke => 'Cabut';

  @override
  String get linkRevoked => 'Tautan dicabut';

  @override
  String failedToRevoke(String error) {
    return 'Gagal mencabut: $error';
  }

  @override
  String get linkCopied => 'Tautan disalin ke clipboard';

  @override
  String get linkExpiresAfter => 'Tautan kedaluwarsa setelah';

  @override
  String get options => 'Opsi';

  @override
  String get includeAttachments => 'Sertakan lampiran';

  @override
  String nAttachments(int count) {
    return '$count lampiran';
  }

  @override
  String get createLink => 'Buat Tautan';

  @override
  String get creating => 'Membuat...';

  @override
  String get e2eeApprovalInfo =>
      'Terenkripsi end-to-end. Anda akan menyetujui setiap permintaan akses.';

  @override
  String get linkCreatedSuccess => 'Tautan Dibuat!';

  @override
  String expiresIn(String duration) {
    return 'Kedaluwarsa dalam $duration';
  }

  @override
  String get accessNotification =>
      'Anda akan mendapat notifikasi saat seseorang meminta akses.';

  @override
  String get pleaseUnlockNoteFirst =>
      'Silakan buka kunci catatan terlebih dahulu untuk membagikannya';

  @override
  String sharedNote(String title) {
    return 'Catatan Dibagikan: $title';
  }

  @override
  String get sessionProblem => 'Masalah Sesi';

  @override
  String get syncDisabledPleaseSignOut =>
      'Sinkronisasi dinonaktifkan. Silakan keluar dan masuk lagi.';

  @override
  String get signOutConfirmationWithNote =>
      'Apakah Anda yakin ingin keluar?\n\nAnda perlu masuk lagi untuk mengakses catatan Anda.';

  @override
  String get sketchTool => 'Alat';

  @override
  String get sketchSize => 'Ukuran';

  @override
  String get sketchColor => 'Warna';

  @override
  String get transcript => 'Transkrip';

  @override
  String get duration => 'Durasi';

  @override
  String get deleteRecordingConfirmation =>
      'Apakah Anda yakin ingin menghapus rekaman audio ini?';

  @override
  String get encryptedNote => 'Catatan Terenkripsi';

  @override
  String get decryptionFailed => 'Dekripsi gagal';

  @override
  String get decryptionFailedRetryMessage =>
      'Catatan ini tidak dapat didekripsi. Ini bisa terjadi saat kunci enkripsi sementara tidak tersedia. Anda dapat mencoba menyinkronkan ulang, atau menghapus catatan secara permanen.';

  @override
  String get deletingNoteFromAllDevicesWarning =>
      'Menghapus akan menghapus catatan ini dari semua perangkat Anda, termasuk salinan terenkripsi di server.';

  @override
  String get retryDecryption => 'Coba Lagi';

  @override
  String get retryingDecryption => 'Mencoba sinkronisasi ulang...';

  @override
  String get e2eeNotReady =>
      'Enkripsi belum siap. Silakan periksa status persetujuan perangkat Anda.';

  @override
  String get thisNoteIsLocked => 'Catatan ini terkunci';

  @override
  String get audio => 'Audio';

  @override
  String audioCount(int count) {
    return '$count audio';
  }

  @override
  String syncFailedCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count gagal',
      one: '1 gagal',
    );
    return '$_temp0';
  }

  @override
  String get openInAppForBestExperience =>
      'Buka di aplikasi untuk pengalaman terbaik';

  @override
  String get useAppForBetterExperience =>
      'Gunakan aplikasi untuk pengalaman yang lebih baik';

  @override
  String get noteMarkedAsDone => 'Catatan ditandai selesai';

  @override
  String get pickTextColor => 'Pilih Warna Teks';

  @override
  String get image => 'Gambar';

  @override
  String get sketch => 'Sketsa';

  @override
  String get textSizeTiny => 'Sangat Kecil';

  @override
  String get textSizeSmall => 'Kecil';

  @override
  String get textSizeNormal => 'Normal';

  @override
  String get textSizeBig => 'Besar';

  @override
  String get textSizeHuge => 'Sangat Besar';

  @override
  String get lineSpacing => 'Spasi Baris';

  @override
  String get lineSpacingTight => 'Rapat';

  @override
  String get lineSpacingNormal => 'Normal';

  @override
  String get lineSpacingRelaxed => 'Longgar';

  @override
  String get lineSpacingDouble => 'Ganda';

  @override
  String get lineSpacingRemove => 'Hapus Spasi';

  @override
  String get startWriting => 'Mulai menulis...';

  @override
  String get imageFailedToLoad => 'Gambar gagal dimuat';

  @override
  String maxAttachmentsReached(int count) {
    return 'Maksimal $count lampiran per catatan tercapai';
  }

  @override
  String get processingImage => 'Memproses gambar...';

  @override
  String get pickNoteColor => 'Pilih Warna Catatan';

  @override
  String failedToPaste(String error) {
    return 'Gagal menempel: $error';
  }

  @override
  String failedToInsertContent(String error) {
    return 'Gagal menyisipkan konten: $error';
  }

  @override
  String failedToLockNote(String error) {
    return 'Gagal mengunci catatan: $error';
  }

  @override
  String failedToRemoveLock(String error) {
    return 'Gagal menghapus kunci: $error';
  }

  @override
  String noteDuplicatedButFailedToLock(String error) {
    return 'Catatan diduplikat tetapi gagal dikunci: $error';
  }

  @override
  String get pastedContent => 'Konten yang Ditempel';

  @override
  String get trash => 'Sampah';

  @override
  String get reminders => 'Pengingat';

  @override
  String get notificationsEnabled =>
      'Notifikasi diaktifkan! Pengingat Anda telah diatur.';

  @override
  String get shareApp => 'Bagikan Aplikasi';

  @override
  String get shareAppMessage =>
      'Coba Better Keep Notes - aplikasi catatan yang aman!\nhttps://play.google.com/store/apps/details?id=io.foxbiz.better_keep';

  @override
  String get installBetterKeep => 'Instal Better Keep';

  @override
  String get installApp => 'Instal Aplikasi';

  @override
  String get getAndroidApp => 'Dapatkan Aplikasi Android';

  @override
  String get getWindowsApp => 'Dapatkan Aplikasi Windows';

  @override
  String get selectView => 'Pilih Tampilan';

  @override
  String get viewModeGrid => 'Grid';

  @override
  String get viewModeList => 'Daftar';

  @override
  String get viewModeColors => 'Warna';

  @override
  String get clear => 'Hapus';

  @override
  String get noMatchingNotes => 'Tidak ada catatan yang cocok';

  @override
  String get noNotesYet => 'Belum ada catatan';

  @override
  String get trashIsEmpty => 'Sampah kosong';

  @override
  String get noPinnedNotes => 'Tidak ada catatan yang dipin';

  @override
  String get noLockedNotes => 'Tidak ada catatan terkunci';

  @override
  String get noRemindersSet => 'Tidak ada pengingat yang diatur';

  @override
  String get createYourFirstNote => 'Buat catatan pertama Anda';

  @override
  String get noLabelsYet => 'Belum ada label';

  @override
  String get noColoredNotesYet => 'Belum ada catatan berwarna';

  @override
  String get addLabelsToOrganize =>
      'Tambahkan label ke catatan Anda untuk mengorganisirnya ke dalam folder';

  @override
  String get addColorsToOrganize =>
      'Tambahkan warna ke catatan Anda untuk mengorganisirnya ke dalam folder';

  @override
  String get getTheAndroidApp => 'Dapatkan Aplikasi Android';

  @override
  String get androidAppAvailable =>
      'Better Keep tersedia di Google Play! Dapatkan aplikasi native untuk pengalaman terbaik dengan notifikasi, widget, dan lainnya.';

  @override
  String get openPlayStore => 'Buka Play Store';

  @override
  String get getTheWindowsApp => 'Dapatkan Aplikasi Windows';

  @override
  String get windowsAppAvailable =>
      'Better Keep tersedia di Microsoft Store! Dapatkan aplikasi native untuk pengalaman terbaik dengan integrasi sistem dan akses offline.';

  @override
  String get openMicrosoftStore => 'Buka Microsoft Store';

  @override
  String get installForQuickAccess =>
      'Instal Better Keep untuk akses cepat dari layar utama dan dukungan offline!';

  @override
  String get install => 'Instal';

  @override
  String get notNow => 'Nanti saja';

  @override
  String get noRecoveryKey => 'Tidak Ada Kunci Pemulihan';

  @override
  String get iUnderstand => 'Saya Mengerti';

  @override
  String get deleteForever => 'Hapus Selamanya';

  @override
  String get deleteAllTrashForever =>
      'Apakah Anda benar-benar ingin menghapus semua catatan di sampah selamanya, ini tidak dapat dibatalkan.';

  @override
  String deleteSelectedNotesForever(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other:
          'Apakah Anda benar-benar ingin menghapus $count catatan selamanya? Ini tidak dapat dibatalkan.',
      one:
          'Apakah Anda benar-benar ingin menghapus catatan ini selamanya? Ini tidak dapat dibatalkan.',
    );
    return '$_temp0';
  }

  @override
  String get search => 'Cari';

  @override
  String get todo => 'Tugas';

  @override
  String get audioNote => 'Catatan Audio';

  @override
  String get failedToCreateImageNote => 'Gagal membuat catatan gambar';

  @override
  String get pleaseEnterYourEmail => 'Silakan masukkan email Anda';

  @override
  String get pleaseEnterAValidEmail => 'Silakan masukkan email yang valid';

  @override
  String get pleaseEnterYourPassword => 'Silakan masukkan kata sandi Anda';

  @override
  String get passwordMustBeAtLeast6Characters =>
      'Kata sandi harus minimal 6 karakter';

  @override
  String get pleaseConfirmYourPassword => 'Silakan konfirmasi kata sandi Anda';

  @override
  String get passwordsDoNotMatch => 'Kata sandi tidak cocok';

  @override
  String get creatingAccount => 'Membuat akun...';

  @override
  String get signingIn => 'Masuk...';

  @override
  String get createAccount => 'Buat Akun';

  @override
  String get welcomeBack => 'Selamat Datang Kembali';

  @override
  String get signUpWithYourEmail => 'Daftar dengan email Anda';

  @override
  String get signInToContinue => 'Masuk untuk melanjutkan';

  @override
  String get forgotPassword => 'Lupa Kata Sandi?';

  @override
  String get signIn => 'Masuk';

  @override
  String get signUp => 'Daftar';

  @override
  String get alreadyHaveAnAccount => 'Sudah punya akun?';

  @override
  String get dontHaveAnAccount => 'Belum punya akun?';

  @override
  String get recoverySuccessfulWelcomeBack =>
      'Pemulihan berhasil! Selamat datang kembali.';

  @override
  String get approvalRequestSent =>
      'Permintaan persetujuan terkirim! Setujui dari perangkat lain.';

  @override
  String get checkingAccountStatus => 'Memeriksa status akun...';

  @override
  String get recoverYourAccount => 'Pulihkan Akun Anda';

  @override
  String get accountRecoveryRequired => 'Pemulihan Akun Diperlukan';

  @override
  String get noActiveDevicesRecoveryKey =>
      'Tidak ada perangkat aktif yang ditemukan. Gunakan frasa sandi pemulihan Anda untuk memulihkan akses ke catatan terenkripsi Anda.';

  @override
  String get noActiveDevicesNoRecoveryKey =>
      'Tidak ada perangkat aktif yang ditemukan dan tidak ada kunci pemulihan yang diatur. Anda dapat memulai dari awal dengan akun baru, tetapi catatan sebelumnya tidak dapat dipulihkan.';

  @override
  String get previousNotesEncryptedWarning =>
      'Catatan sebelumnya Anda dienkripsi dan tidak dapat dipulihkan tanpa kunci pemulihan.';

  @override
  String get notYourMainDevice => 'Bukan perangkat utama Anda?';

  @override
  String get anotherDeviceApprovalHint =>
      'Jika Anda memiliki perangkat lain dengan akses ke catatan Anda, Anda dapat meminta persetujuan dari perangkat tersebut.';

  @override
  String get requesting => 'Meminta...';

  @override
  String get requestApprovalFromAnotherDevice =>
      'Minta Persetujuan dari Perangkat Lain';

  @override
  String get signingOut => 'Keluar...';

  @override
  String get takingTooLongTryAgain =>
      'Terlalu lama. Anda dapat membatalkan dan mencoba lagi.';

  @override
  String get requestTimedOut => 'Permintaan habis waktu. Silakan coba lagi.';

  @override
  String get failedToSendVerificationCode => 'Gagal mengirim kode verifikasi';

  @override
  String get yourEmail => 'email Anda';

  @override
  String get continueLabel => 'Lanjutkan';

  @override
  String get pleaseConfirmConsequences =>
      'Silakan konfirmasi bahwa Anda memahami konsekuensinya';

  @override
  String get accountResetSuccessfully =>
      'Akun berhasil direset. Selamat datang!';

  @override
  String get failedToResetAccount => 'Gagal mereset akun';

  @override
  String failedToResetAccountError(String error) {
    return 'Gagal mereset akun: $error';
  }

  @override
  String get startFreshQuestion => 'Mulai dari Awal?';

  @override
  String get thisActionWill => 'Tindakan ini akan:';

  @override
  String get removeAllDeviceAuthorizations =>
      'Menghapus semua otorisasi perangkat';

  @override
  String get makeOldNotesUnrecoverable =>
      'Membuat catatan lama Anda tidak dapat dipulihkan';

  @override
  String get createNewEncryptionKey => 'Membuat kunci enkripsi baru';

  @override
  String get startWithBlankAccount => 'Memulai dengan akun kosong';

  @override
  String get iUnderstandOldNotesInaccessible =>
      'Saya memahami bahwa catatan lama saya akan tidak dapat diakses secara permanen';

  @override
  String get saveToGallery => 'Simpan ke Galeri';

  @override
  String get newLabel => 'Baru';

  @override
  String get pickPaperColor => 'Pilih Warna Kertas';

  @override
  String get pickPenColor => 'Pilih Warna Pena';

  @override
  String get savedToGallery => 'Disimpan ke Galeri';

  @override
  String get sketchDownloaded => 'Sketsa diunduh';

  @override
  String get failedToSaveSketch => 'Gagal menyimpan sketsa';

  @override
  String errorSavingSketch(String error) {
    return 'Error menyimpan sketsa: $error';
  }

  @override
  String get planFree => 'Gratis';

  @override
  String get planPro => 'Pro';

  @override
  String lockedNotesLimitReached(int count) {
    return 'Anda telah mencapai batas $count catatan terkunci';
  }

  @override
  String get realtimeCloudSyncRequiresPro =>
      'Sinkronisasi cloud real-time memerlukan langganan Pro';

  @override
  String get unlimitedLockedNotes => 'Catatan terkunci tanpa batas';

  @override
  String get realtimeCloudSync => 'Sinkronisasi cloud real-time';

  @override
  String get upgrade => 'Upgrade';

  @override
  String get upgradeToPro => 'Upgrade ke Pro';

  @override
  String unlockFeature(String feature) {
    return 'Buka $feature';
  }

  @override
  String featureRequiresPro(String feature) {
    return '$feature memerlukan Pro';
  }

  @override
  String get thisFeatureRequiresPro => 'Fitur ini memerlukan Pro';

  @override
  String featureIsProFeature(String feature) {
    return '$feature adalah fitur Pro.';
  }

  @override
  String get unlockAllFeatures => 'Buka semua fitur dan dukung pengembangan.';

  @override
  String get protectUnlimitedNotesWithPin =>
      'Lindungi catatan tanpa batas dengan kunci PIN';

  @override
  String get syncAcrossDevicesSecurely =>
      'Sinkronisasi di semua perangkat Anda dengan aman';

  @override
  String get unlimitedLockedNotesAndSync =>
      'Catatan terkunci tanpa batas dan sinkronisasi cloud real-time';

  @override
  String get unlockTheFullExperience => 'Buka Pengalaman Lengkap';

  @override
  String get maybeLater => 'Mungkin nanti';

  @override
  String get enableNotificationsTitle => 'Aktifkan Notifikasi';

  @override
  String get enableNotificationsForReminders =>
      'Catatan yang disinkronkan memiliki pengingat. Aktifkan notifikasi agar Anda tidak melewatkannya.';

  @override
  String get enableNotifications => 'Aktifkan';

  @override
  String get rateOnAppStore => 'Beri Nilai di App Store';

  @override
  String get rateOnPlayStore => 'Beri Nilai di Play Store';

  @override
  String get rateOnMicrosoftStore => 'Beri Nilai di Microsoft Store';

  @override
  String get sortBy => 'Urutkan berdasarkan';

  @override
  String get sortCustom => 'Kustom';

  @override
  String get sortCreatedNewest => 'Tanggal dibuat';

  @override
  String get sortUpdatedNewest => 'Tanggal diperbarui';

  @override
  String get dragToReorder => 'Tekan dan tahan untuk mengurutkan';

  @override
  String get moveNoteBefore => 'Pindahkan catatan ke depan';

  @override
  String get moveNoteAfter => 'Pindahkan catatan ke belakang';

  @override
  String get pinnedReorderBoundary =>
      'Catatan yang disematkan dan tidak disematkan diatur secara terpisah.';

  @override
  String get reorderSaveFailed =>
      'Urutan catatan baru tidak dapat disimpan. Urutan sebelumnya telah dipulihkan.';

  @override
  String get noteDisplayOptions => 'Opsi tampilan catatan';

  @override
  String get noteDisplayOptionsSaveFailed =>
      'Opsi tampilan catatan tidak dapat disimpan. Silakan coba lagi.';

  @override
  String get noteDisplayOptionsSaved => 'Opsi tampilan catatan disimpan';

  @override
  String get reorderCustomHint =>
      'Tekan dan tahan catatan, lalu seret untuk mengatur ulang.';

  @override
  String get reorderDateSortHint =>
      'Pengaturan ulang manual tidak tersedia saat mengurutkan berdasarkan tanggal. Pilih Kustom untuk mengatur ulang catatan.';
}
