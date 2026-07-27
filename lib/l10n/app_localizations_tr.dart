// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Turkish (`tr`).
class AppLocalizationsTr extends AppLocalizations {
  AppLocalizationsTr([String locale = 'tr']) : super(locale);

  @override
  String get appTitle => 'Better Keep';

  @override
  String get reminderType => 'Hatırlatıcı türü';

  @override
  String get notificationReminder => 'Bildirim';

  @override
  String get notificationReminderDescription =>
      'Zamana duyarlı standart bir bildirim gösterir';

  @override
  String get alarmReminder => 'Alarm';

  @override
  String get alarmReminderDescription => 'Siz durdurana kadar sürekli çalar';

  @override
  String get alarmUnsupportedPlatform =>
      'Alarmlar bu platformda desteklenmiyor. Hatırlatıcı eşitlenecek ve Android ya da iOS\'ta alarm olarak ayarlanacaktır.';

  @override
  String get notificationUnsupportedPlatform =>
      'Bu platformda Better Keep kapalıyken zamanlanmış bildirim kullanılamaz. Hatırlatıcı yine eşitlenir ve zamanı geldiğinde uygulamada görünür.';

  @override
  String get alarmRequiresSpecificTime =>
      'Alarmlar belirli bir saat gerektirir; Tüm gün yalnızca bildirimlerde kullanılabilir.';

  @override
  String get reminderDue => 'Hatırlatıcı zamanı';

  @override
  String get overdueReminderTitle => 'Gecikmiş hatırlatıcı';

  @override
  String get overdueReminderMessage =>
      'Bu hatırlatıcının zamanı geçti. Şimdi tamamlandı olarak işaretlensin mi?';

  @override
  String get markReminderDoneFailed =>
      'Hatırlatıcı tamamlandı olarak işaretlenemedi. Lütfen tekrar deneyin.';

  @override
  String get markAsDone => 'Tamamlandı Olarak İşaretle';

  @override
  String get reminderSavedPermissionRequired =>
      'Hatırlatıcı kaydedildi ancak bu cihazda zamanlamak için izin gerekiyor.';

  @override
  String get reminderSavedAlreadyDue =>
      'Hatırlatıcı kaydedildi ve zamanı zaten geldi.';

  @override
  String get reminderScheduleFailed =>
      'Hatırlatıcı kaydedildi ancak bu cihaz zamanlayamadı.';

  @override
  String get reminderCapacityExceeded =>
      'Hatırlatıcı kaydedildi ancak bu cihazda yeni bir hatırlatıcı zamanlamak için çok fazla bekleyen hatırlatıcı var.';

  @override
  String get reminderTimeZoneUnavailable =>
      'Hatırlatıcı kaydedildi ancak bu cihazın saat dilimi belirlenemedi. Cihazın saat ayarlarını kontrol edip tekrar deneyin.';

  @override
  String get cancel => 'İptal';

  @override
  String get ok => 'Tamam';

  @override
  String get save => 'Kaydet';

  @override
  String get delete => 'Sil';

  @override
  String get close => 'Kapat';

  @override
  String get retry => 'Yeniden Dene';

  @override
  String get protectedSketchTitle => 'Korumalı çizim';

  @override
  String get protectedSketchRecoveryMessage =>
      'Bu eski korumalı çizim henüz kurtarılamadı. Orijinal şifreli çizim korundu ve uygulama bir sonraki başarılı kilit açma işleminden sonra yeniden deneyecek.';

  @override
  String get sketchBackgroundUnavailable =>
      'Arka plan kullanılamıyor; çizim korundu';

  @override
  String get discard => 'Sil';

  @override
  String get attachmentCommitFailedTitle => 'Ek eklenemedi';

  @override
  String get attachmentCommitFailedMessage =>
      'Orijinal dosya güvende. Eklemeyi yeniden deneyin veya bu cihazdan silin.';

  @override
  String get done => 'Bitti';

  @override
  String get remove => 'Kaldır';

  @override
  String get open => 'Aç';

  @override
  String get select => 'Seç';

  @override
  String get verify => 'Doğrula';

  @override
  String get link => 'Bağla';

  @override
  String get unlink => 'Bağlantıyı Kaldır';

  @override
  String get approve => 'Onayla';

  @override
  String get deny => 'Reddet';

  @override
  String get primary => 'Birincil';

  @override
  String get signOut => 'Çıkış Yap';

  @override
  String get signOutAnyway => 'Yine de Çıkış Yap';

  @override
  String get continueOffline => 'Çevrimdışı Devam Et';

  @override
  String get cancelSignIn => 'Girişi İptal Et';

  @override
  String get signInCancelled => 'Giriş iptal edildi';

  @override
  String get signInWithFacebook => 'Facebook ile Giriş Yap';

  @override
  String get signInWithGithub => 'GitHub ile Giriş Yap';

  @override
  String get signInWithEmail => 'E-posta ile Giriş Yap';

  @override
  String get about => 'Hakkında';

  @override
  String get help => 'Yardım';

  @override
  String get settings => 'Ayarlar';

  @override
  String get labels => 'Etiketler';

  @override
  String get addLink => 'Bağlantı Ekle';

  @override
  String get editLink => 'Bağlantıyı Düzenle';

  @override
  String get setReminder => 'Hatırlatıcı Ayarla';

  @override
  String get displayText => 'Görüntülenecek Metin';

  @override
  String get enterDisplayText => 'Görüntülenecek metni girin';

  @override
  String get pleaseEnterDisplayText => 'Lütfen görüntülenecek metni girin';

  @override
  String get url => 'URL';

  @override
  String get urlHint => 'https://ornek.com';

  @override
  String get titleYourThought => 'Notunuza başlık ekleyin';

  @override
  String get email => 'E-posta';

  @override
  String get emailHint => 'mailadresiniz@ornek.com';

  @override
  String get enterEmailAddress => 'E-posta adresinizi girin';

  @override
  String get password => 'Parola';

  @override
  String get confirmPassword => 'Parolayı Onayla';

  @override
  String get newPassword => 'Yeni Parola';

  @override
  String get enterNewPassword => 'Yeni parola girin';

  @override
  String get reenterNewPassword => 'Yeni parolayı tekrar girin';

  @override
  String get currentPassphrase => 'Mevcut İfade';

  @override
  String get enterYourPassphrase => 'İfadenizi girin';

  @override
  String get enterCurrentPassphrase => 'Mevcut ifadenizi girin';

  @override
  String get recoveryPassphrase => 'Kurtarma İfadesi';

  @override
  String get enterStrongPassphrase => 'Güçlü bir ifade girin';

  @override
  String get confirmPassphrase => 'İfadeyi Onayla';

  @override
  String get reenterPassphrase => 'İfadenizi tekrar girin';

  @override
  String get newPassphrase => 'Yeni İfade';

  @override
  String get confirmNewPassphrase => 'Yeni İfadeyi Onayla';

  @override
  String get reenterNewPassphrase => 'Yeni ifadenizi tekrar girin';

  @override
  String get hintOptional => 'İpucu (İsteğe Bağlı)';

  @override
  String get hintToRemember => 'Hatırlamanıza yardımcı olacak bir ipucu';

  @override
  String get pin => 'PIN';

  @override
  String get enterPin => 'PIN girin';

  @override
  String get newLabelName => 'Yeni etiket adı';

  @override
  String get addLabel => 'Etiket ekle';

  @override
  String get searchLogs => 'Günlüklerde ara...';

  @override
  String get audioRecording => 'Ses Kaydı';

  @override
  String get deleteRecording => 'Kaydı Sil';

  @override
  String get title => 'Başlık';

  @override
  String get enterRecordingTitle => 'Bu kayıt için bir başlık girin';

  @override
  String get theme => 'Tema';

  @override
  String get customizeAppearance => 'Uygulama görünümünü özelleştir';

  @override
  String get followSystemTheme => 'Sistem Temasına Göre';

  @override
  String get autoSwitchLightDark =>
      'Açık ve karanlık mod arasında otomatik geçiş yap';

  @override
  String get followSystemAnimations => 'Sistem animasyon tercihine uy';

  @override
  String get reduceAnimationsFromSystem =>
      'Cihaz veya tarayıcı ayarlarında etkinse animasyonları azalt';

  @override
  String get darkMode => 'Karanlık Mod';

  @override
  String get darkTheme => 'Karanlık Tema';

  @override
  String get lightTheme => 'Aydınlık Tema';

  @override
  String get showSyncProgress => 'Eşitleme İlerlemesini Göster';

  @override
  String get displaySyncStatus => 'Eşitleme durumu göstergesini görüntüle';

  @override
  String get alarmSound => 'Alarm Sesi';

  @override
  String get reminderTimeSettings => 'Hatırlatıcı Zaman Ayarları';

  @override
  String get setDefaultTimes =>
      'Hatırlatıcılar için varsayılan zamanları ayarla';

  @override
  String get morning => 'Sabah';

  @override
  String get afternoon => 'Öğleden Sonra';

  @override
  String get evening => 'Akşam';

  @override
  String get localDataProtection => 'Yerel Veri Koruması';

  @override
  String get encryptDeviceData => 'Bu cihazda depolanan verileri şifrele';

  @override
  String get encryptNotes => 'Notları şifrele';

  @override
  String get encryptFiles => 'Dosyaları şifrele';

  @override
  String get lockedNotesSecurity => 'Kilitli Notlar Güvenliği';

  @override
  String get privacyLockedNotes => 'Kilitli notlar için gizlilik ayarları';

  @override
  String get forgetPasswordOnClose => 'Kapatıldığında parolayı unut';

  @override
  String get requirePasswordAgain => 'Uygulama her açıldığında parola iste';

  @override
  String get nerdStats => 'Detaylı İstatistikler';

  @override
  String get developer => 'Geliştirici';

  @override
  String get contactUs => 'Bize Ulaşın';

  @override
  String get developedBy => 'Geliştiren:';

  @override
  String get viewOnGithub => 'GitHub\'da görüntüle';

  @override
  String get archive => 'Arşivle';

  @override
  String get unarchive => 'Arşivden Çıkar';

  @override
  String get readOnly => 'Salt Okunur';

  @override
  String get locked => 'Kilitli';

  @override
  String get saveAs => 'Farklı kaydet';

  @override
  String get copyAs => 'Farklı kopyala';

  @override
  String get share => 'Paylaş';

  @override
  String get duplicate => 'Çoğalt';

  @override
  String get markdown => 'Markdown';

  @override
  String get markdownFile => 'Markdown (.md)';

  @override
  String get html => 'HTML';

  @override
  String get htmlFile => 'HTML (.html)';

  @override
  String get plainText => 'Düz Metin';

  @override
  String get plainTextFile => 'Düz Metin (.txt)';

  @override
  String get restore => 'Geri Yükle';

  @override
  String get reminder => 'Hatırlatıcı';

  @override
  String get hideKeyboard => 'Klavyeyi gizle';

  @override
  String get refresh => 'Yenile';

  @override
  String get dismiss => 'Kapat';

  @override
  String get back => 'Geri';

  @override
  String get copyToClipboard => 'Panoya kopyala';

  @override
  String get copiedToClipboard => 'Panoya kopyalandı';

  @override
  String get scribble => 'Karalama';

  @override
  String get revokeLink => 'Bağlantıyı iptal et';

  @override
  String get expandToolbar => 'Araç çubuğunu genişlet';

  @override
  String get collapseToolbar => 'Araç çubuğunu daralt';

  @override
  String get align => 'Hizala';

  @override
  String get textSize => 'Metin Boyutu';

  @override
  String get indent => 'Girinti';

  @override
  String get attach => 'Ekle';

  @override
  String get paperColor => 'Kağıt Rengi';

  @override
  String get pagePattern => 'Sayfa Deseni';

  @override
  String get moreOptions => 'Daha fazla seçenek';

  @override
  String get move => 'Taşı';

  @override
  String get viewAllPages => 'Tüm sayfaları görüntüle';

  @override
  String get insert => 'Ekle';

  @override
  String get importAsNote => 'Not Olarak İçe Aktar';

  @override
  String get removeDevice => 'Cihazı kaldır';

  @override
  String get noteJson => 'Not JSON\'u';

  @override
  String get passwordResetSuccess =>
      'Parola başarıyla sıfırlandı! Lütfen giriş yapın.';

  @override
  String get emailVerifiedSuccess => 'E-posta başarıyla doğrulandı!';

  @override
  String get useDifferentAccount => 'Farklı bir hesap kullan';

  @override
  String get recoverySuccessful => 'Kurtarma başarılı! Erişim sağlandı.';

  @override
  String get deviceApproved => 'Cihaz onaylandı!';

  @override
  String get waitingForApproval => 'Hala onay bekleniyor...';

  @override
  String get reapprovalRequestSent =>
      'Yeniden onay isteği gönderildi. Onay bekleniyor...';

  @override
  String failedReapproval(String error) {
    return 'Yeniden onay istenemedi: $error';
  }

  @override
  String get rememberDevice => 'Bu cihazı hatırla';

  @override
  String get recoverWithPassphrase => 'İfade ile Kurtar';

  @override
  String get startFresh => 'Temiz Bir Başlangıç Yap';

  @override
  String get startFreshInstead => 'Bunun Yerine Temiz Bir Başlangıç Yap';

  @override
  String get requestReapproval => 'Yeniden Onay İste';

  @override
  String get accessApproved => 'Erişim onaylandı';

  @override
  String failedToApprove(String error) {
    return 'Onaylanamadı: $error';
  }

  @override
  String get accessDenied => 'Erişim reddedildi';

  @override
  String failedToDeny(String error) {
    return 'Reddedilemedi: $error';
  }

  @override
  String get allUpToDate => 'Her şey güncel';

  @override
  String get upgradeNow => 'Şimdi Yükselt';

  @override
  String get continueTrial => 'Denemeye Devam Et';

  @override
  String get cancelSubscription => 'Aboneliği İptal Et';

  @override
  String get keepSubscription => 'Aboneliği Koru';

  @override
  String get linkingAccount => 'Hesap bağlanıyor...';

  @override
  String unlinkProvider(String provider) {
    return '$provider bağlantısı kaldırılsın mı?';
  }

  @override
  String unlinkedProvider(String provider) {
    return '$provider bağlantısı kaldırıldı';
  }

  @override
  String successfullyLinked(String provider) {
    return '$provider hesabı başarıyla bağlandı';
  }

  @override
  String unknownProvider(String provider) {
    return 'Bilinmeyen sağlayıcı: $provider';
  }

  @override
  String get recoveryKey => 'Kurtarma Anahtarı';

  @override
  String get manageRecoveryPassphrase => 'Kurtarma ifadenizi yönetin';

  @override
  String get enableE2EE => 'Uçtan Uca Şifrelemeyi Etkinleştir';

  @override
  String failedSaveRecoveryKey(String error) {
    return 'Kurtarma Anahtarı kaydedilemedi: $error';
  }

  @override
  String get recoverySuccessWelcome =>
      'Kurtarma başarılı! Tekrar hoş geldiniz.';

  @override
  String get confirmConsequences => 'Lütfen sonuçları anladığınızı onaylayın';

  @override
  String get accountResetSuccess => 'Hesap başarıyla sıfırlandı. Hoş geldiniz!';

  @override
  String failedResetAccount(String error) {
    return 'Hesap sıfırlanamadı: $error';
  }

  @override
  String errorSigningOut(String error) {
    return 'Çıkış yapılırken hata oluştu: $error';
  }

  @override
  String errorPlayingSound(String error) {
    return 'Ses çalınırken hata oluştu: $error';
  }

  @override
  String get checkNestedItems => 'İç içe geçmiş öğeler işaretlensin mi?';

  @override
  String get uncheckNestedItems =>
      'İç içe geçmiş öğelerin işareti kaldırılsın mı?';

  @override
  String get yes => 'Evet';

  @override
  String get no => 'Hayır';

  @override
  String get clipboardEmpty => 'Pano boş';

  @override
  String get noteDeletedPermanently => 'Not kalıcı olarak silindi';

  @override
  String get reminderRemoved => 'Hatırlatıcı kaldırıldı';

  @override
  String get reminderCompleted => 'Hatırlatıcı tamamlandı';

  @override
  String get reminderSet => 'Hatırlatıcı ayarlandı';

  @override
  String get failedCreateImageNote => 'Resim notu oluşturulamadı';

  @override
  String errorSavingSketchWithError(String error) {
    return 'Çizim kaydedilirken hata oluştu: $error';
  }

  @override
  String get failedSaveNote => 'Not kaydedilemedi';

  @override
  String failedSave(String error) {
    return 'Kaydedilemedi: $error';
  }

  @override
  String copiedAs(String format) {
    return '$format olarak kopyalandı';
  }

  @override
  String failedCopy(String error) {
    return 'Kopyalanamadı: $error';
  }

  @override
  String get pastedAsPlainText => 'Düz metin olarak yapıştırıldı';

  @override
  String failedPaste(String error) {
    return 'Yapıştırılamadı: $error';
  }

  @override
  String get contentInserted => 'İçerik eklendi';

  @override
  String failedInsertContent(String error) {
    return 'İçerik eklenemedi: $error';
  }

  @override
  String get actionCancelled => 'İşlem iptal edildi';

  @override
  String get noteLocked => 'Not kilitlendi';

  @override
  String failedLockNote(String error) {
    return 'Not kilitlenemedi: $error';
  }

  @override
  String get lockRemoved => 'Kilit kaldırıldı';

  @override
  String failedRemoveLock(String error) {
    return 'Kilit kaldırılamadı: $error';
  }

  @override
  String get noteDuplicated => 'Not çoğaltıldı';

  @override
  String get errorSavingNote => 'Not kaydedilirken hata oluştu';

  @override
  String get contentShared => 'İçerik paylaşıldı';

  @override
  String get failedShare => 'Paylaşılamadı';

  @override
  String get notes => 'Notlar';

  @override
  String get allNotes => 'Tüm Notlar';

  @override
  String get archivedNotes => 'Arşivlenmiş';

  @override
  String get deletedNotes => 'Silinmiş';

  @override
  String get pinnedNotes => 'Sabitlenmiş';

  @override
  String get otherNotes => 'Diğerleri';

  @override
  String get noNotes => 'Henüz not yok';

  @override
  String get noArchivedNotes => 'Arşivlenmiş not yok';

  @override
  String get noDeletedNotes => 'Silinmiş not yok';

  @override
  String get searchNotes => 'Notlarda ara';

  @override
  String nSelectedNotes(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count not seçildi',
      one: '1 not seçildi',
    );
    return '$_temp0';
  }

  @override
  String get deleteNote => 'Notu Sil';

  @override
  String get deleteNotes => 'Notları Sil';

  @override
  String get moveToTrash => 'Çöp kutusuna taşı';

  @override
  String get deletePermanently => 'Kalıcı olarak sil';

  @override
  String get pinNote => 'Sabitle';

  @override
  String get unpinNote => 'Sabitlemeyi kaldır';

  @override
  String get newNote => 'Yeni Not';

  @override
  String get newSketch => 'Yeni Çizim';

  @override
  String get newFolder => 'Yeni Klasör';

  @override
  String get renameFolder => 'Klasörü Yeniden Adlandır';

  @override
  String get deleteFolder => 'Klasörü Sil';

  @override
  String get folderName => 'Klasör adı';

  @override
  String get camera => 'Kamera';

  @override
  String get gallery => 'Galeri';

  @override
  String get audioRecorder => 'Ses Kaydedici';

  @override
  String get importFile => 'Dosya İçe Aktar';

  @override
  String get language => 'Dil';

  @override
  String get systemDefault => 'Sistem Varsayılanı';

  @override
  String get selectLanguage => 'Dil Seç';

  @override
  String get english => 'İngilizce';

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
  String get today => 'Bugün';

  @override
  String get tomorrow => 'Yarın';

  @override
  String get nextWeek => 'Gelecek hafta';

  @override
  String get nextMonth => 'Gelecek ay';

  @override
  String get pickDateTime => 'Tarih ve saat seç';

  @override
  String get time => 'Saat';

  @override
  String get selectTime => 'Saat seç';

  @override
  String get allDay => 'Tüm gün';

  @override
  String get date => 'Tarih';

  @override
  String get repeat => 'Tekrarla';

  @override
  String get frequency => 'Sıklık';

  @override
  String get never => 'Asla';

  @override
  String get daily => 'Günlük';

  @override
  String get weekly => 'Haftalık';

  @override
  String get monthly => 'Aylık';

  @override
  String get yearly => 'Yıllık';

  @override
  String get snooze => 'Ertele';

  @override
  String get fiveMinutes => '5 dakika';

  @override
  String get tenMinutes => '10 dakika';

  @override
  String get thirtyMinutes => '30 dakika';

  @override
  String get oneHour => '1 saat';

  @override
  String get gridView => 'Izgara görünümü';

  @override
  String get listView => 'Liste görünümü';

  @override
  String get galleryView => 'Galeri görünümü';

  @override
  String get undo => 'Geri al';

  @override
  String get redo => 'Yinele';

  @override
  String get bold => 'Kalın';

  @override
  String get italic => 'İtalik';

  @override
  String get underline => 'Altı çizili';

  @override
  String get strikethrough => 'Üstü çizili';

  @override
  String get bulletList => 'Madde işaretli liste';

  @override
  String get numberedList => 'Numaralı liste';

  @override
  String get checklist => 'Kontrol listesi';

  @override
  String get quote => 'Alıntı';

  @override
  String get codeBlock => 'Kod bloğu';

  @override
  String get textColor => 'Metin rengi';

  @override
  String get highlightColor => 'Vurgu rengi';

  @override
  String get alignLeft => 'Sola hizala';

  @override
  String get alignCenter => 'Ortala';

  @override
  String get alignRight => 'Sağa hizala';

  @override
  String get alignJustify => 'İki yana yasla';

  @override
  String get increaseIndent => 'Girintiyi artır';

  @override
  String get decreaseIndent => 'Girintiyi azalt';

  @override
  String get heading1 => 'Başlık 1';

  @override
  String get heading2 => 'Başlık 2';

  @override
  String get heading3 => 'Başlık 3';

  @override
  String get normalText => 'Normal metin';

  @override
  String get pen => 'Tükenmez Kalem';

  @override
  String get pencil => 'Kurşun Kalem';

  @override
  String get brush => 'Fırça';

  @override
  String get highlighter => 'Vurgulayıcı';

  @override
  String get eraser => 'Silgi';

  @override
  String get lasso => 'Kement';

  @override
  String get addPage => 'Sayfa ekle';

  @override
  String get deletePage => 'Sayfayı sil';

  @override
  String get page => 'Sayfa';

  @override
  String pageNumber(int number) {
    return 'Sayfa $number';
  }

  @override
  String get connectedAccounts => 'Bağlı Hesaplar';

  @override
  String get subscription => 'Abonelik';

  @override
  String get free => 'Ücretsiz';

  @override
  String get pro => 'Pro';

  @override
  String get trial => 'Deneme';

  @override
  String trialEndsIn(int days) {
    return 'Deneme süresinin bitmesine $days gün kaldı';
  }

  @override
  String get devices => 'Cihazlar';

  @override
  String get thisDevice => 'Bu cihaz';

  @override
  String lastActive(String time) {
    return 'Son etkinlik: $time';
  }

  @override
  String get pendingApproval => 'Onay bekliyor';

  @override
  String get security => 'Güvenlik';

  @override
  String get endToEndEncryption => 'Uçtan Uca Şifreleme';

  @override
  String get e2eeEnabled => 'Etkin';

  @override
  String get e2eeDisabled => 'Etkin değil';

  @override
  String get setupRecoveryKey => 'Kurtarma Anahtarını Ayarla';

  @override
  String get changeRecoveryKey => 'Kurtarma Anahtarını Değiştir';

  @override
  String get verifyRecoveryKey => 'Kurtarma Anahtarını Doğrula';

  @override
  String get error => 'Hata';

  @override
  String errorWithMessage(String message) {
    return 'Hata: $message';
  }

  @override
  String get loading => 'Yükleniyor...';

  @override
  String get syncing => 'Eşitleniyor...';

  @override
  String get syncComplete => 'Eşitleme tamamlandı';

  @override
  String get syncFailed => 'Eşitleme başarısız';

  @override
  String get offline => 'Çevrimdışı';

  @override
  String get online => 'Çevrimiçi';

  @override
  String get getApp => 'Uygulamayı Edin';

  @override
  String get sessionExpired =>
      'Oturumunuzun süresi doldu. Lütfen tekrar giriş yapın.';

  @override
  String get confirmSignOut => 'Çıkış yapmak istediğinizden emin misiniz?';

  @override
  String get unsyncedChanges =>
      'Eşitlenmemiş değişiklikleriniz var, bunlar kaybolacak.';

  @override
  String get deleteConfirmation => 'Bunu silmek istediğinizden emin misiniz?';

  @override
  String get permanentAction => 'Bu işlem geri alınamaz.';

  @override
  String get encryptNoteContent => 'Not İçeriğini Şifrele';

  @override
  String get encryptNotesInDatabase => 'Yerel veritabanındaki notları şifrele';

  @override
  String get encryptAttachments => 'Ekleri Şifrele';

  @override
  String get encryptImagesSketchesFiles =>
      'Resimleri, çizimleri ve dosyaları şifrele';

  @override
  String get localEncryptionInfo =>
      'Yerel şifreleme, cihazınız tehlikeye girerse verilerinizi korur. AES-256-GCM şifreleme yöntemini kullanır.';

  @override
  String get lockedNotes => 'Kilitli Notlar';

  @override
  String get requireReenterPin =>
      'Kilitli bir not yeniden açıldığında PIN\'in tekrar girilmesini iste';

  @override
  String get faqAndSupport => 'SSS ve destek ile iletişime geç';

  @override
  String get appInfoCredits => 'Uygulama bilgileri ve katkıda bulunanlar';

  @override
  String get advancedSettings => 'Gelişmiş Ayarlar';

  @override
  String get speechRecognitionModel => 'Ses Tanıma Modeli';

  @override
  String whisperModelDownloaded(String size) {
    return 'İndirildi ($size)';
  }

  @override
  String whisperModelNotDownloaded(String size) {
    return 'İndirilmedi ($size) - indirmek için dokunun';
  }

  @override
  String get deleteWhisperModelConfirm =>
      'Ses tanıma modeli silinsin mi? Daha sonra tekrar indirebilirsiniz.';

  @override
  String get whisperModelDeleted => 'Ses tanıma modeli silindi';

  @override
  String get deleteModel => 'Modeli Sil';

  @override
  String get download => 'İndir';

  @override
  String get viewDatabaseStats =>
      'Veritabanı ve eşitleme istatistiklerini görüntüle';

  @override
  String get selectDarkTheme => 'Karanlık Tema Seç';

  @override
  String get selectLightTheme => 'Aydınlık Tema Seç';

  @override
  String get encryptingNotes => 'Mevcut notlar şifreleniyor...';

  @override
  String noteEncryptionEnabled(int count) {
    return 'Not şifreleme etkinleştirildi. $count not şifrelendi.';
  }

  @override
  String get noteEncryptionEnabledSimple => 'Not şifreleme etkinleştirildi.';

  @override
  String errorEncryptingNotes(String error) {
    return 'Notlar şifrelenirken hata oluştu: $error';
  }

  @override
  String get noteEncryptionDisabled => 'Not şifreleme devre dışı bırakıldı.';

  @override
  String get fileEncryptionEnabled =>
      'Dosya şifreleme etkinleştirildi. Yeni ekler şifrelenecek.';

  @override
  String get fileEncryptionDisabled => 'Dosya şifreleme devre dışı bırakıldı.';

  @override
  String get encryptDataOnDevice => 'Bu cihazda depolanan verileri şifrele';

  @override
  String get signInCancelledMessage => 'Giriş iptal edildi';

  @override
  String get startingSignIn => 'Giriş başlatılıyor...';

  @override
  String get continueWithGoogle => 'Google ile Devam Et';

  @override
  String get continueWithApple => 'Apple ile Devam Et';

  @override
  String get signInWithApple => 'Apple ile Giriş Yap';

  @override
  String get chooseSignInMethod => 'Tercih ettiğiniz giriş yöntemini seçin';

  @override
  String get yourNoteSecuredAndSynced => 'Notlarınız güvende ve senkronize';

  @override
  String get endToEndEncryptionFeature => 'Uçtan Uca Şifreleme';

  @override
  String get endToEndEncryptionDescription =>
      'Notlarınız eşitlenmeden önce cihazınızda şifrelenir. Onları sadece siz okuyabilirsiniz; biz bile verilerinize erişemeyiz.';

  @override
  String get seamlessSync => 'Kusursuz Eşitleme';

  @override
  String get seamlessSyncDescription =>
      'Notlarınıza herhangi bir cihazdan erişin. Değişiklikler tüm cihazlarınız arasında anında ve güvenli bir şekilde eşitlenir.';

  @override
  String get richFormatting => 'Zengin Biçimlendirme';

  @override
  String get richFormattingDescription =>
      'Zengin metin, kontrol listeleri, resimler, çizimler ve sesli notlarla kendinizi ifade edin. Notlarınız, sizin tarzınız.';

  @override
  String get gotIt => 'Anladım';

  @override
  String get or => 'veya';

  @override
  String get signInWithGoogle => 'Google ile Giriş Yap';

  @override
  String get resetPassword => 'Parolayı Sıfırla';

  @override
  String get resetPasswordDescription =>
      'E-posta adresinizi girin, size parolanızı sıfırlamanız için bir doğrulama kodu göndereceğiz.';

  @override
  String get sendVerificationCode => 'Doğrulama Kodu Gönder';

  @override
  String get sending => 'Gönderiliyor...';

  @override
  String get enterVerificationCode => 'Doğrulama Kodunu Girin';

  @override
  String get enterCodeSentTo => 'Şu adrese gönderilen 6 haneli kodu girin:';

  @override
  String get pleaseEnterCompleteCode => 'Lütfen 6 haneli kodu eksiksiz girin';

  @override
  String get verifying => 'Doğrulanıyor...';

  @override
  String get continue_ => 'Devam Et';

  @override
  String get resendCode => 'Kodu yeniden gönder';

  @override
  String resendCodeIn(int seconds) {
    return 'Kodu yeniden gönder (${seconds}s)';
  }

  @override
  String get codeExpiresIn => 'Kodun süresi 10 dakika içinde dolacak';

  @override
  String get createNewPassword => 'Yeni Parola Oluştur';

  @override
  String get enterNewPasswordDescription =>
      'Hesabınız için yeni bir parola girin.';

  @override
  String get enterNewPasswordHint => 'Yeni parola girin';

  @override
  String get reenterNewPasswordHint => 'Yeni parolayı tekrar girin';

  @override
  String get resettingPassword => 'Parola Sıfırlanıyor...';

  @override
  String get pleaseEnterNewPassword => 'Lütfen yeni bir parola girin';

  @override
  String get pleaseEnterEmailAddress => 'Lütfen e-posta adresinizi girin';

  @override
  String get pleaseEnterValidEmail => 'Lütfen geçerli bir e-posta adresi girin';

  @override
  String get failedSendVerificationCode =>
      'Doğrulama kodu gönderilemedi. Lütfen tekrar deneyin.';

  @override
  String get invalidVerificationCode => 'Geçersiz doğrulama kodu';

  @override
  String get verificationFailed =>
      'Doğrulama başarısız oldu. Lütfen tekrar deneyin.';

  @override
  String get passwordResetFailed =>
      'Parola sıfırlama başarısız oldu. Lütfen tekrar deneyin.';

  @override
  String get verifyYourEmail => 'E-postanızı Doğrulayın';

  @override
  String get sendingVerificationCode => 'Doğrulama kodu gönderiliyor...';

  @override
  String get emailVerifiedSuccessfully => 'E-posta başarıyla doğrulandı!';

  @override
  String get deviceRevoked => 'Cihaz İptal Edildi';

  @override
  String get waitingForApprovalTitle => 'Onay Bekleniyor';

  @override
  String get deviceRevokedDescription =>
      'Bu cihaz iptal edildi ve artık notlarınıza erişemiyor. Yeniden yetkilendirmek için lütfen onaylı bir cihazdan tekrar giriş yapın.';

  @override
  String get pleaseApproveFrom => 'Lütfen şuradan onaylayın:';

  @override
  String get waitingForApprovalFromDevice =>
      'Başka bir cihazdan onay bekleniyor...';

  @override
  String get rememberThisDevice => 'Bu cihazı hatırla';

  @override
  String get deviceRemovedOnSignOut =>
      'İşareti kaldırılırsa, çıkış yaptığınızda bu cihaz kaldırılacaktır';

  @override
  String get checkingStatus => 'Kontrol ediliyor...';

  @override
  String get checkStatus => 'Durumu Kontrol Et';

  @override
  String get cancelRequest => 'İsteği İptal Et';

  @override
  String get pleaseWait => 'Lütfen bekleyin...';

  @override
  String get updateRecoveryKey => 'Kurtarma Anahtarını Güncelle';

  @override
  String get recoveryPassphraseDescription =>
      'Tüm cihazlarınızı kaybetmeniz durumunda notlarınıza erişimi geri yükleyebilecek bir kurtarma ifadesi oluşturun.';

  @override
  String get recoveryPassphraseWarning =>
      'Bu kurtarma ifadesini güvenli bir şekilde saklayın. Bu olmadan, tüm cihazlarınızı kaybetmeniz durumunda notlarınızı kurtaramazsınız.';

  @override
  String get enterAStrongPassphrase => 'Güçlü bir ifade girin';

  @override
  String get pleaseEnterPassphrase => 'Lütfen bir ifade girin';

  @override
  String get passphraseMinLength => 'İfade en az 6 karakter olmalıdır';

  @override
  String get passphrasesDoNotMatch => 'İfadeler eşleşmiyor';

  @override
  String get passphraseTooCommon =>
      'Bu ifade çok yaygın ve tahmin edilmesi kolay';

  @override
  String get passphraseStrengthAdvice =>
      'Daha güçlü bir ifade için büyük harf, küçük harf, sayı veya semboller eklemeyi düşünün';

  @override
  String get saving => 'Kaydediliyor...';

  @override
  String get saveRecoveryKey => 'Kurtarma Anahtarını Kaydet';

  @override
  String get passwordShortWarning =>
      'Parola oldukça kısa. En az 6 karakter kullanmayı düşünün.';

  @override
  String get passwordLongerAdvice =>
      'Daha iyi güvenlik için daha uzun bir parola kullanmayı düşünün.';

  @override
  String get passwordMixAdvice =>
      'Daha güçlü bir güvenlik için hem harf hem de sayı eklemeyi düşünün.';

  @override
  String version(String version, String buildNumber) {
    return 'Sürüm $version ($buildNumber)';
  }

  @override
  String get openSource => 'Kaynak Koduna Erişim';

  @override
  String get openSourceDescription =>
      'Kaynak kodu CC BY-NC 4.0 kapsamında incelenebilir. Ticari yeniden kullanım kısıtlı olduğundan OSI onaylı açık kaynak değil, kaynak kodu erişilebilir yazılımdır.';

  @override
  String get frequentlyAskedQuestions => 'Sıkça Sorulan Sorular';

  @override
  String get needMoreHelp => 'Daha Fazla Yardıma mı İhtiyacınız Var?';

  @override
  String get needMoreHelpDescription =>
      'Herhangi bir sorunuz varsa veya yardıma ihtiyacınız olursa, bize ulaşmaktan çekinmeyin.';

  @override
  String get deleteImage => 'Resmi Sil';

  @override
  String get deleteImageConfirmation =>
      'Bu resmi silmek istediğinizden emin misiniz?';

  @override
  String get importAsNoteTooltip => 'Not Olarak İçe Aktar';

  @override
  String get insertTooltip => 'Ekle';

  @override
  String failedToImport(String error) {
    return 'İçe aktarılamadı: $error';
  }

  @override
  String get notes_ => 'Notlar';

  @override
  String get media => 'Medya';

  @override
  String plan(String planName) {
    return '$planName Planı';
  }

  @override
  String get freeTrialActive => 'Ücretsiz Deneme Aktif';

  @override
  String expiresOnDaysLeft(String date, int days) {
    return '$date tarihinde sona eriyor ($days gün kaldı)';
  }

  @override
  String get enjoyProFeatures =>
      'Deneme süreniz boyunca tüm Pro özelliklerinin keyfini çıkarın!';

  @override
  String get billing => 'Faturalandırma';

  @override
  String get renews => 'Yenilenme tarihi:';

  @override
  String get expires => 'Bitiş tarihi:';

  @override
  String get monthlySubscription => 'Aylık abonelik';

  @override
  String get yearlySubscription => 'Yıllık abonelik';

  @override
  String get freeTrial => 'Ücretsiz Deneme';

  @override
  String get subscriptionInGracePeriod =>
      'Aboneliğiniz ek sürede. Lütfen ödeme yönteminizi güncelleyin.';

  @override
  String subscriptionCancelledInfo(String date) {
    return 'Pro erişiminiz $date tarihinde sona erecektir. Süresi dolduktan sonra tekrar abone olabilirsiniz.';
  }

  @override
  String get subscriptionCancelled => 'Abonelik İptal Edildi';

  @override
  String get upgradeToProDescription =>
      'Sınırsız kilitli notlar, bulut eşitleme ve daha fazlası için Pro\'ya yükseltin.';

  @override
  String get cancellingSubscription => 'İptal ediliyor...';

  @override
  String get manageSubscription => 'Aboneliği Yönet';

  @override
  String get renewSubscription => 'Aboneliği Yenile';

  @override
  String get restoreInfoText =>
      'Abone olduğunuzda, mevcut abonelikleriniz veya önceki satın alımlarınız otomatik olarak geri yüklenir.';

  @override
  String get cancelSubscriptionConfirmation =>
      'Aboneliğinizi iptal etmek istediğinizden emin misiniz?\n\nAboneliğiniz, mevcut fatura döneminin sonuna kadar aktif kalacaktır. Bundan sonra Pro özelliklerine erişiminizi kaybedeceksiniz.';

  @override
  String get subscriptionChangesMayTakeMoment =>
      'Değişiklik yaptıysanız, görünmesi biraz zaman alabilir.';

  @override
  String get subscriptionRestored => 'Aboneliğiniz geri yüklendi!';

  @override
  String get subscriptionAlreadyActive => 'Zaten aktif bir aboneliğiniz var.';

  @override
  String get subscriptionActivated => 'Abonelik başarıyla etkinleştirildi!';

  @override
  String get purchaseCancelled => 'Satın alma iptal edildi.';

  @override
  String get paymentFailed => 'Ödeme başarısız oldu.';

  @override
  String get couldNotOpenSubscriptionManagement =>
      'Abonelik yönetimi açılamadı.';

  @override
  String manageSubscriptionInStore(String store) {
    return '$store\'da aboneliğinizi yönetin.';
  }

  @override
  String get loadingFailedTryAgain => 'Yükleme başarısız — Tekrar deneyin';

  @override
  String get reloadPrices => 'Fiyatları yeniden yükle';

  @override
  String subscribeWithPrice(String price) {
    return 'Abone ol — $price';
  }

  @override
  String get noAdsDescription =>
      'Reklam yok, veri satışı yok — aboneliğiniz güvenli sunucuları ve sürekli geliştirmeyi finanse eder.';

  @override
  String get detectingLocation => 'Konumunuz tespit ediliyor...';

  @override
  String get currencyHelpText =>
      'Hint kartları için INR, uluslararası kartlar için USD kullanın.';

  @override
  String get selfHostContact =>
      'Kendi sunucunuzu mu kurmak istiyorsunuz? contact@betterkeep.app adresinden bize ulaşın';

  @override
  String get welcomeToProMessage => 'Better Keep Pro\'ya Hoş Geldiniz!';

  @override
  String get loadingPrices => 'Fiyatlar yükleniyor...';

  @override
  String get processingSubscription => 'İşleniyor...';

  @override
  String get subscriptionAutoRenewTerms =>
      'Ödeme hesabınıza yansıtılacaktır. Mevcut dönem sona ermeden en az 24 saat önce otomatik yenileme kapatılmadığı sürece abonelik otomatik olarak yenilenir.';

  @override
  String savePercent(int percent) {
    return '%$percent tasarruf edin';
  }

  @override
  String get subscriptionCancelledSuccessfully =>
      'Abonelik başarıyla iptal edildi.';

  @override
  String get subscriptionResumedSuccessfully =>
      'Abonelik başarıyla devam ettirildi.';

  @override
  String get failedToCancelSubscription => 'Abonelik iptal edilemedi.';

  @override
  String get failedToResumeSubscription => 'Abonelik devam ettirilemedi.';

  @override
  String get featureTableHeader => 'Özellik';

  @override
  String get unlimited => 'Sınırsız';

  @override
  String get paywallLocalNotes => 'Yerel notlar';

  @override
  String get lockedNotesFreeLimit => 'Maks. 5';

  @override
  String get signInWithAnyLinked => 'Bağlı herhangi bir hesapla giriş yapın';

  @override
  String get linkingRequiresAuth =>
      'Bağlama işlemi, sahipliği doğrulamak için her platformda kimlik doğrulama gerektirir.';

  @override
  String get connected => 'Bağlandı';

  @override
  String get cannotUnlinkPrimary =>
      'Orijinal giriş yönteminin bağlantısı kaldırılamaz';

  @override
  String get verifyAccountLink => 'Hesap Bağlantısını Doğrula';

  @override
  String get verifyAndLink => 'Doğrula ve Bağla';

  @override
  String get yourNotesAreProtected => 'Notlarınız güvende';

  @override
  String get waitingForDeviceApproval => 'Cihaz onayı bekleniyor';

  @override
  String get protectionNotEnabled => 'Koruma etkin değil';

  @override
  String get somethingWentWrong => 'Bir şeyler ters gitti';

  @override
  String get deviceAccessRemoved => 'Cihaz erişimi kaldırıldı';

  @override
  String get gettingReady => 'Hazırlanıyor...';

  @override
  String get notesAndAttachmentsEncrypted =>
      'Notlarınız ve ekleriniz şifrelendi';

  @override
  String get encryption => 'Şifreleme';

  @override
  String get keyExchange => 'Anahtar Değişimi';

  @override
  String get keySize => 'Anahtar Boyutu';

  @override
  String nDevicesAuthorized(int count) {
    return '$count cihaz yetkilendirildi';
  }

  @override
  String get important => 'Önemli';

  @override
  String get approveOnOtherDevice =>
      'Bu cihazı onaylamak için halihazırda yetkilendirilmiş bir cihazda Better Keep\'i açın.';

  @override
  String get yourDevices => 'Cihazlarınız';

  @override
  String get pendingApprovalSection => 'Onay Bekleyenler';

  @override
  String get authorizedDevices => 'Yetkili Cihazlar';

  @override
  String get noInternetConnection =>
      'İnternet bağlantısı yok. Lütfen ağınızı kontrol edip tekrar deneyin.';

  @override
  String get dangerZone => 'Tehlikeli Bölge';

  @override
  String get dangerZoneDescription =>
      'Hesabınızı ve ilişkili tüm verileri kalıcı olarak silin. Bu işlem 30 günlük bir ek sürenin ardından tamamlanacaktır.';

  @override
  String get deleteMyAccount => 'Hesabımı Sil';

  @override
  String get unsyncedNotesWarning =>
      'Henüz buluta eşitlenmemiş notlarınız var. Şimdi çıkış yaparsanız, bu notlar SONSUZA KADAR KAYBOLACAKTIR.\n\nEşitlemenin tamamlanmasını beklemeyi veya önce verilerinizi dışa aktarmayı düşünün.';

  @override
  String notesNotSynced(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count not eşitlenmedi',
      one: '1 not eşitlenmedi',
    );
    return '$_temp0';
  }

  @override
  String get dataLossWarning => 'VERİ KAYBI UYARISI';

  @override
  String get noRecoveryKeySet => 'Kurtarma Anahtarı ayarlanmamış';

  @override
  String get signOutNoRecoveryKeyWarning =>
      'Eğer çıkış yaparsanız ve onaylı tüm cihazlarınıza erişimi kaybederseniz, tüm şifrelenmiş notlarınıza erişimi KALICI olarak kaybedersiniz.\n\nBu işlem geri alınamaz.';

  @override
  String get signOutConfirmation =>
      'Çıkış yapmak istediğinizden emin misiniz?\n\nNotlarınıza erişmek için tekrar giriş yapmanız gerekecek.';

  @override
  String nDevicesWaitingForApproval(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count Cihaz Onay Bekliyor',
      one: '1 Cihaz Onay Bekliyor',
    );
    return '$_temp0';
  }

  @override
  String get reviewAndApprove => 'Erişim vermek için inceleyin ve onaylayın';

  @override
  String nShareAccessRequests(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count Paylaşım Erişim İsteği',
      one: '1 Paylaşım Erişim İsteği',
    );
    return '$_temp0';
  }

  @override
  String get someoneWantsToView =>
      'Birisi paylaştığınız notu görüntülemek istiyor';

  @override
  String get deviceApproved_ => 'Cihaz onaylandı';

  @override
  String failedApproveDevice(String error) {
    return 'Cihaz onaylanamadı: $error';
  }

  @override
  String get deviceRemoved => 'Cihaz kaldırıldı';

  @override
  String nDevicesRemoved(int count) {
    return '$count cihaz kaldırıldı';
  }

  @override
  String failedRemoveDevice(String error) {
    return 'Cihaz kaldırılamadı: $error';
  }

  @override
  String get removeDevice_ => 'Cihazı Kaldır';

  @override
  String removeDeviceConfirmation(String deviceName) {
    return '\"$deviceName\" cihazını kaldırmak istediğinizden emin misiniz?\n\nBu cihaz artık notlarınıza erişemeyecek.';
  }

  @override
  String get enableE2EEConfirmation =>
      'Bu, tüm notlarınızı ve eklerinizi şifreleyecektir. Yalnızca yetkilendirdiğiniz cihazlar bunları okuyabilecektir.\n\nE2EE\'yi etkinleştirdikten sonra bir Kurtarma Anahtarı ayarladığınızdan emin olun, aksi takdirde tüm cihazlarınızı kaybederseniz notlarınıza erişimi kaybedebilirsiniz.';

  @override
  String get enableE2EE_ => 'E2EE\'yi Etkinleştir';

  @override
  String failedEnableE2EE(String error) {
    return 'E2EE etkinleştirilemedi: $error';
  }

  @override
  String get recoveryKeySavedSuccessfully =>
      'Kurtarma Anahtarı başarıyla kaydedildi!';

  @override
  String get noRecoveryKeyWarning =>
      'Uyarı: Bir Kurtarma Anahtarı olmadan, tüm cihazlarınızı kaybederseniz notlarınızı kurtaramazsınız!';

  @override
  String get recoveryKeySetUp =>
      'Ayarlanmış bir Kurtarma Anahtarınız var. Ne yapmak istersiniz?';

  @override
  String get update => 'Güncelle';

  @override
  String get recoveryKeyUpdated => 'Kurtarma Anahtarı güncellendi!';

  @override
  String get recoveryKeyRemoved => 'Kurtarma Anahtarı kaldırıldı';

  @override
  String get recoveryKeySaved => 'Kurtarma Anahtarı kaydedildi!';

  @override
  String get upgradeNowQuestion => 'Şimdi Yükseltilsin mi?';

  @override
  String trialTimeLeft(String timeLeft) {
    return 'Ücretsiz denemenizin bitmesine hala $timeLeft var.';
  }

  @override
  String get subscribeNowTrialEnds =>
      'Şimdi abone olursanız, deneme süreniz hemen sona erecek ve faturalandırma hemen başlayacaktır.';

  @override
  String alreadyHaveSubscription(String planName) {
    return 'Zaten aktif bir $planName aboneliğiniz var!';
  }

  @override
  String unlinkProviderQuestion(String provider) {
    return '$provider bağlantısı kaldırılsın mı?';
  }

  @override
  String get unlinkProviderWarning =>
      'Artık bu hesapla giriş yapamayacaksınız. Hesabınıza erişmek için başka bir yolunuz olduğundan emin olun.';

  @override
  String unlinkedSuccessfully(String provider) {
    return '$provider bağlantısı kaldırıldı';
  }

  @override
  String get failedUnlinkAccount => 'Hesap bağlantısı kaldırılamadı';

  @override
  String get cannotUnlinkOnlyMethod =>
      'Tek giriş yönteminin bağlantısı kaldırılamaz.';

  @override
  String unknownProviderError(String provider) {
    return 'Bilinmeyen sağlayıcı: $provider';
  }

  @override
  String get takingTooLong =>
      'İşlem çok uzun sürüyor. İptal edip tekrar deneyebilirsiniz.';

  @override
  String get failedSendCode => 'Doğrulama kodu gönderilemedi';

  @override
  String get pleaseTryAgain => 'Lütfen tekrar deneyin.';

  @override
  String get pleaseSignInAgain => 'Lütfen tekrar giriş yapıp deneyin.';

  @override
  String get noEmailAssociated => 'Hesabınızla ilişkilendirilmiş e-posta yok.';

  @override
  String providerAlreadyLinked(String provider) {
    return '$provider hesabınıza zaten bağlı.';
  }

  @override
  String get pleaseWaitBeforeRequesting =>
      'Tekrar istekte bulunmadan önce lütfen bekleyin.';

  @override
  String get sessionExpired_ => 'Oturum süresi doldu. Lütfen tekrar deneyin.';

  @override
  String get failedLinkAccount => 'Hesap bağlanamadı';

  @override
  String providerLinkedToAnother(String provider) {
    return 'Bu $provider hesabı zaten başka bir kullanıcıya bağlı.';
  }

  @override
  String get emailAlreadyInUse =>
      'Bu e-postaya sahip bir hesap zaten var. Önce o hesapla giriş yapın, ardından oradan bağlantı kurun.';

  @override
  String get linkingCancelled => 'Bağlantı işlemi iptal edildi.';

  @override
  String successfullyLinkedProvider(String provider) {
    return '$provider hesabı başarıyla bağlandı';
  }

  @override
  String get deleteYourAccount => 'Hesabınız Silinsin mi?';

  @override
  String get actionIrreversible => 'Bu işlem geri alınamaz';

  @override
  String get allNotesDeleted => 'Tüm notlarınız kalıcı olarak silinecektir';

  @override
  String get allAttachmentsRemoved => 'Tüm ekler ve medya kaldırılacaktır';

  @override
  String get loggedOutAllDevices => 'Tüm cihazlardan çıkış yapacaksınız';

  @override
  String get accountCannotBeRecovered => 'Hesabınız kurtarılamaz';

  @override
  String get gracePeriodInfo =>
      '30 günlük ek süre: Silme işlemini iptal etmek için tekrar giriş yapın.';

  @override
  String get verificationCodeViaEmail =>
      'E-posta yoluyla bir doğrulama kodu alacaksınız.';

  @override
  String get keepMyAccount => 'Hesabımı Koru';

  @override
  String get deleteAccount => 'Hesabı Sil';

  @override
  String get verifyYourIdentity => 'Kimliğinizi Doğrulayın';

  @override
  String get userNotSignedIn => 'Kullanıcı giriş yapmamış';

  @override
  String get failedScheduleDeletion => 'Silme işlemi planlanamadı';

  @override
  String get deletionScheduled => 'Silme İşlemi Planlandı';

  @override
  String accountWillBeDeletedOn(String date) {
    return 'Hesabınız $date tarihinde silinecek.';
  }

  @override
  String get exportBeforeSignOut =>
      'Çıkış yapmadan önce verilerinizi dışa aktarmak ister misiniz?';

  @override
  String get skip => 'Geç';

  @override
  String get exportData => 'Verileri Dışa Aktar';

  @override
  String get exportingData => 'Veriler Dışa Aktarılıyor';

  @override
  String get exportCancelled => 'Dışa aktarma iptal edildi';

  @override
  String get exportFailed => 'Dışa aktarma başarısız';

  @override
  String get exportComplete => 'Dışa Aktarma Tamamlandı';

  @override
  String exportCompleteMessage(String path) {
    return 'Verileriniz başarıyla dışa aktarıldı.\n\nDosya şuraya kaydedildi:\n$path\n\nDışa aktarılan dosyayı paylaşmak ister misiniz?';
  }

  @override
  String deletionScheduledMessage(String date) {
    return 'Hesap silme işlemi $date için planlandı. İptal etmek için tekrar giriş yapın.';
  }

  @override
  String get iphoneIpad => 'iPhone/iPad';

  @override
  String get webBrowser => 'Web Tarayıcısı';

  @override
  String get debugDeleteSubscription => 'DEBUG: Aboneliği Sil';

  @override
  String get debugDeleteSubscriptionWarning =>
      'Bu işlem aboneliğinizi veritabanından hemen silecektir.\n\nBu YALNIZCA TEST AMAÇLIDIR ve asıl Razorpay aboneliğini iptal etmez.';

  @override
  String get debugSubscriptionDeleted => 'DEBUG: Abonelik başarıyla silindi';

  @override
  String get debugSubscriptionDeleteFailed => 'DEBUG: Abonelik silinemedi';

  @override
  String get removeLink => 'Bağlantıyı Kaldır';

  @override
  String get add => 'Ekle';

  @override
  String get recent => 'En Son';

  @override
  String get custom => 'Özel';

  @override
  String get createLabelToOrganize =>
      'Notlarınızı düzenlemek için yukarıdan bir etiket oluşturun';

  @override
  String editLabelName(String labelName) {
    return '$labelName öğesini düzenle';
  }

  @override
  String get enterNewName => 'Yeni ad girin';

  @override
  String get deleteLabel => 'Etiketi Sil';

  @override
  String deleteLabelConfirmation(String labelName) {
    return 'Bu etiketi ($labelName) silmek istediğinizden emin misiniz?';
  }

  @override
  String get pasteAs => 'Farklı yapıştır';

  @override
  String get formattedText => 'Biçimlendirilmiş metin';

  @override
  String get previewAndInsertFormatted =>
      'Biçimlendirilmiş içerik olarak önizle ve ekle';

  @override
  String get insertAsPlainText => 'Biçimlendirme olmadan düz metin olarak ekle';

  @override
  String get prompt => 'İstem';

  @override
  String get notMatched => 'Eşleşmedi';

  @override
  String confirmPlaceholder(String placeholder) {
    return '$placeholder onayla';
  }

  @override
  String get notificationPermissionsRequired =>
      'Hatırlatıcılar için bildirim ve alarm izinleri gereklidir';

  @override
  String get checkAll => 'Tümünü İşaretle';

  @override
  String get uncheckAll => 'Tüm İşaretleri Kaldır';

  @override
  String checkNestedItemsCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'öğeyi',
      one: 'öğeyi',
    );
    return 'Bu, iç içe geçmiş $count $_temp0 işaretleyecektir.';
  }

  @override
  String uncheckNestedItemsCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'öğenin',
      one: 'öğenin',
    );
    return 'Bu, iç içe geçmiş $count $_temp0 işaretini kaldıracaktır.';
  }

  @override
  String get somethingWentWrongTryAgain =>
      'Bir şeyler ters gitti. Lütfen tekrar deneyin.';

  @override
  String get verifyingPassphrase => 'İfade doğrulanıyor...';

  @override
  String get settingAsPrimaryDevice => 'Birincil cihaz olarak ayarlanıyor...';

  @override
  String get finalizing => 'Sonuçlandırılıyor...';

  @override
  String get incorrectPassphrase => 'Hatalı ifade. Lütfen tekrar deneyin.';

  @override
  String get recoveryTimedOut =>
      'Kurtarma zaman aşımına uğradı. Lütfen bağlantınızı kontrol edip tekrar deneyin.';

  @override
  String get recoveryKeyMobileOnly =>
      'Bu Kurtarma Anahtarı bir mobil veya masaüstü uygulamasında oluşturuldu ve tarayıcıda kullanılamaz. Lütfen kurtarmak için mobil veya masaüstü uygulamasını kullanın.';

  @override
  String get somethingWentWrongCheckConnection =>
      'Bir şeyler ters gitti. Lütfen bağlantınızı kontrol edip tekrar deneyin.';

  @override
  String get recover => 'Kurtar';

  @override
  String get recoverInfoTooltip =>
      'Kurtarma ifadenizi kullanarak şifreleme anahtarlarınızı kurtarın';

  @override
  String hintLabel(String hint) {
    return 'İpucu: $hint';
  }

  @override
  String get setAsPrimaryDevice => 'Birincil cihaz olarak ayarla';

  @override
  String get pleaseEnterRecoveryPassphrase => 'Lütfen kurtarma ifadenizi girin';

  @override
  String get currentPassphraseIncorrect => 'Mevcut ifade yanlış';

  @override
  String get pleaseEnterCurrentPassphrase => 'Lütfen mevcut ifadenizi girin';

  @override
  String get pleaseEnterNewPassphrase => 'Lütfen yeni bir ifade girin';

  @override
  String get removeRecoveryKey => 'Kurtarma Anahtarını Kaldır';

  @override
  String get removeRecoveryKeyWarning =>
      'Uyarı: Bir Kurtarma Anahtarı olmadan, tüm cihazlarınızı kaybederseniz notlarınızı kurtaramazsınız!';

  @override
  String get enterPassphraseToConfirmRemoval =>
      'Kaldırma işlemini onaylamak için mevcut ifadenizi girin:';

  @override
  String get passphraseIncorrect => 'İfade yanlış';

  @override
  String get unlockNote => 'Notun Kilidini Aç';

  @override
  String get pleaseEnterPin => 'Lütfen PIN\'i girin';

  @override
  String tooManyAttemptsWait(int seconds) {
    return 'Çok fazla deneme yapıldı. $seconds saniye bekleyin.';
  }

  @override
  String attemptsRemaining(String message, int remaining) {
    return '$message. $remaining deneme hakkı kaldı.';
  }

  @override
  String get failedToUnlockNote => 'Notun kilidi açılamadı';

  @override
  String lockedSeconds(int seconds) {
    return 'Kilitli ($seconds sn)';
  }

  @override
  String get unlock => 'Kilidi Aç';

  @override
  String get lockNote => 'Notu Kilitle';

  @override
  String get pinForgotWarning =>
      'Bu PIN\'i unutursanız, notu kurtarmanın bir yolu yoktur.';

  @override
  String get pleaseEnterAPin => 'Lütfen bir PIN girin';

  @override
  String get pinMinLength => 'PIN en az 4 karakter uzunluğunda olmalıdır';

  @override
  String get pinTooWeak => 'PIN çok zayıf (tümü aynı karakterler)';

  @override
  String get pinTooCommon => 'PIN çok yaygın';

  @override
  String get confirmPin => 'PIN\'i Onayla';

  @override
  String get reenterPin => 'PIN\'i tekrar girin';

  @override
  String get pinsDoNotMatch => 'PIN\'ler eşleşmiyor';

  @override
  String get lock => 'Kilitle';

  @override
  String get recordAudio => 'Ses Kaydet';

  @override
  String get microphonePermissionRequired =>
      'Ses kaydetmek için mikrofon izni gereklidir.';

  @override
  String get openSettings => 'Ayarları Aç';

  @override
  String get stopRecording => 'Kaydı durdur';

  @override
  String get startRecording => 'Kaydı başlat';

  @override
  String get transcriptionUnavailable => 'Metne dönüştürme kullanılamıyor';

  @override
  String get liveTranscription => 'Canlı metne dönüştürme';

  @override
  String get recordingContinuesWithoutTranscription =>
      'Kayıt metne dönüştürme olmadan devam edecek';

  @override
  String get listening => 'Dinleniyor...';

  @override
  String get allowMicAccess =>
      'Kayda başlamak için mikrofon erişimine izin verin.';

  @override
  String get tapStartToRecord =>
      'Kayda başlamak için başlat düğmesine dokunun.';

  @override
  String get transcribeWhileRecording => 'Kaydederken metne dönüştür';

  @override
  String get transcription => 'Metne Dönüştürme';

  @override
  String get editTranscriptionHint => 'Gerekirse metni düzenleyin';

  @override
  String get addTranscriptionToNote => 'Metni nota ekle';

  @override
  String get noSpeechDetected => 'Kayıt sırasında konuşma algılanmadı.';

  @override
  String get titleOptional => 'Başlık (isteğe bağlı)';

  @override
  String get enterTitleForRecording => 'Bu kayıt için bir başlık girin';

  @override
  String get okay => 'Tamam';

  @override
  String get failedToStartRecording => 'Kayıt başlatılamadı';

  @override
  String get transcriptionDisabledWebPrivacy =>
      'Gizlilik nedeniyle web\'de sesin metne dönüştürülmesi devre dışı bırakılmıştır. Sesiniz cihazınızda kalır.';

  @override
  String get whisperModelRequired => 'Ses tanıma modeli gereklidir';

  @override
  String whisperModelDescription(String size) {
    return 'Cihaz üzerinde sesten metne dönüştürme için küçük bir AI modeli ($size) indirin. Sesiniz asla cihazınızı terk etmez.';
  }

  @override
  String get downloadModel => 'Modeli İndir';

  @override
  String get useFallback => 'Cihaz varsayılanını kullan';

  @override
  String get whisperTranscriptionActive =>
      'Cihaz içi AI transkripsiyonu (gizli)';

  @override
  String get modelDownloadComplete => 'Ses modeli başarıyla indirildi';

  @override
  String get modelDownloadFailed => 'Ses modeli indirilemedi';

  @override
  String get transcribingAudio => 'Ses metne dönüştürülüyor...';

  @override
  String get polishingTranscription => 'Metin düzeltiliyor...';

  @override
  String get transcriptionFailed =>
      'Metne dönüştürme başarısız oldu. Lütfen tekrar deneyin.';

  @override
  String get deleteQuestion => 'Silinsin mi?';

  @override
  String get actionCannotBeUndone => 'Bu işlem geri alınamaz.';

  @override
  String get permanentDeleteWarning =>
      'Bu, tüm verileri kalıcı olarak silecektir ve kurtarılamaz.';

  @override
  String get sentVerificationCodeTo =>
      'Şu adrese bir doğrulama kodu gönderdik:';

  @override
  String codeExpiresInMinutes(int minutes) {
    return 'Kodun süresi $minutes dakika içinde dolacak';
  }

  @override
  String get verificationFailedTryAgain =>
      'Doğrulama başarısız oldu. Lütfen tekrar deneyin.';

  @override
  String get shareNote => 'Notu Paylaş';

  @override
  String get untitledNote => 'Başlıksız Not';

  @override
  String get shareAsText => 'Metin Olarak Paylaş';

  @override
  String get plainTextContent => 'Düz metin içeriği';

  @override
  String get shareAsMarkdown => 'Markdown Olarak Paylaş';

  @override
  String get formattedWithMarkdown => 'Markdown sözdizimi ile biçimlendirilmiş';

  @override
  String get createSecureLink => 'Güvenli Bağlantı Oluştur';

  @override
  String get encryptedLinkWithApproval =>
      'Erişim onayı ile şifrelenmiş bağlantı';

  @override
  String get linkCreated => 'Bağlantı Oluşturuldu';

  @override
  String activeLinks(int count) {
    return 'Aktif Bağlantılar ($count)';
  }

  @override
  String get secureLink => 'Güvenli Bağlantı';

  @override
  String get createNewLink => 'Yeni Bağlantı Oluştur';

  @override
  String get revokeLink_ => 'Bağlantıyı iptal et';

  @override
  String get copy => 'Kopyala';

  @override
  String get linkNotAvailable =>
      'Bağlantı kullanılamıyor (başka bir cihazda oluşturulmuş)';

  @override
  String get revokeLinkQuestion => 'Bağlantı İptal Edilsin mi?';

  @override
  String get revokeLinkWarning =>
      'Bu işlem, paylaşım bağlantısını kalıcı olarak devre dışı bırakacaktır. Bağlantıya sahip olan hiç kimse artık nota erişemeyecektir.';

  @override
  String get revoke => 'İptal Et';

  @override
  String get linkRevoked => 'Bağlantı iptal edildi';

  @override
  String failedToRevoke(String error) {
    return 'İptal edilemedi: $error';
  }

  @override
  String get linkCopied => 'Bağlantı panoya kopyalandı';

  @override
  String get linkExpiresAfter => 'Bağlantı şu süreden sonra sona erer:';

  @override
  String get options => 'Seçenekler';

  @override
  String get includeAttachments => 'Ekleri dahil et';

  @override
  String nAttachments(int count) {
    return '$count ek';
  }

  @override
  String get createLink => 'Bağlantı Oluştur';

  @override
  String get creating => 'Oluşturuluyor...';

  @override
  String get e2eeApprovalInfo =>
      'Uçtan uca şifrelenmiş. Her erişim isteğini siz onaylayacaksınız.';

  @override
  String get linkCreatedSuccess => 'Bağlantı Oluşturuldu!';

  @override
  String expiresIn(String duration) {
    return '$duration içinde sona eriyor';
  }

  @override
  String get accessNotification =>
      'Biri erişim istediğinde bir bildirim alacaksınız.';

  @override
  String get pleaseUnlockNoteFirst =>
      'Paylaşmak için lütfen önce notun kilidini açın';

  @override
  String sharedNote(String title) {
    return 'Paylaşılan Not: $title';
  }

  @override
  String get sessionProblem => 'Oturum Problemi';

  @override
  String get syncDisabledPleaseSignOut =>
      'Eşitleme devre dışı. Lütfen çıkış yapıp tekrar giriş yapın.';

  @override
  String get signOutConfirmationWithNote =>
      'Çıkış yapmak istediğinizden emin misiniz?\n\nNotlarınıza erişmek için tekrar giriş yapmanız gerekecek.';

  @override
  String get sketchTool => 'Araç';

  @override
  String get sketchSize => 'Boyut';

  @override
  String get sketchColor => 'Renk';

  @override
  String get transcript => 'Metin';

  @override
  String get duration => 'Süre';

  @override
  String get deleteRecordingConfirmation =>
      'Bu ses kaydını silmek istediğinizden emin misiniz?';

  @override
  String get encryptedNote => 'Şifrelenmiş Not';

  @override
  String get decryptionFailed => 'Şifre çözme başarısız oldu';

  @override
  String get decryptionFailedRetryMessage =>
      'Bu not şifresi çözülemedi. Bu, şifreleme anahtarlarının geçici olarak kullanılamaması durumunda olabilir. Tekrar senkronize etmeyi deneyebilir veya notu kalıcı olarak silebilirsiniz.';

  @override
  String get deletingNoteFromAllDevicesWarning =>
      'Silme işlemi bu notu sunucudaki şifrelenmiş kopya dahil tüm cihazlarınızdan kaldırır.';

  @override
  String get retryDecryption => 'Tekrar Dene';

  @override
  String get retryingDecryption => 'Senkronizasyon yeniden deneniyor...';

  @override
  String get e2eeNotReady =>
      'Şifreleme hazır değil. Lütfen cihaz onay durumunuzu kontrol edin.';

  @override
  String get thisNoteIsLocked => 'Bu not kilitli';

  @override
  String get audio => 'Ses';

  @override
  String audioCount(int count) {
    return '$count ses';
  }

  @override
  String syncFailedCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count başarısız',
      one: '1 başarısız',
    );
    return '$_temp0';
  }

  @override
  String get openInAppForBestExperience =>
      'En iyi deneyim için uygulamada açın';

  @override
  String get useAppForBetterExperience =>
      'Daha iyi bir deneyim için uygulamayı kullanın';

  @override
  String get noteMarkedAsDone => 'Not tamamlandı olarak işaretlendi';

  @override
  String get pickTextColor => 'Metin Rengi Seç';

  @override
  String get image => 'Resim';

  @override
  String get sketch => 'Çizim';

  @override
  String get textSizeTiny => 'Çok Küçük';

  @override
  String get textSizeSmall => 'Küçük';

  @override
  String get textSizeNormal => 'Normal';

  @override
  String get textSizeBig => 'Büyük';

  @override
  String get textSizeHuge => 'Çok Büyük';

  @override
  String get lineSpacing => 'Satır Aralığı';

  @override
  String get lineSpacingTight => 'Sıkı';

  @override
  String get lineSpacingNormal => 'Normal';

  @override
  String get lineSpacingRelaxed => 'Geniş';

  @override
  String get lineSpacingDouble => 'Çift';

  @override
  String get lineSpacingRemove => 'Aralığı Kaldır';

  @override
  String get startWriting => 'Yazmaya başla...';

  @override
  String get imageFailedToLoad => 'Resim yüklenemedi';

  @override
  String maxAttachmentsReached(int count) {
    return 'Not başına maksimum $count ek sınırına ulaşıldı';
  }

  @override
  String get processingImage => 'Resim işleniyor...';

  @override
  String get pickNoteColor => 'Not Rengi Seç';

  @override
  String failedToPaste(String error) {
    return 'Yapıştırılamadı: $error';
  }

  @override
  String failedToInsertContent(String error) {
    return 'İçerik eklenemedi: $error';
  }

  @override
  String failedToLockNote(String error) {
    return 'Not kilitlenemedi: $error';
  }

  @override
  String failedToRemoveLock(String error) {
    return 'Kilit kaldırılamadı: $error';
  }

  @override
  String noteDuplicatedButFailedToLock(String error) {
    return 'Not çoğaltıldı ancak kilitlenemedi: $error';
  }

  @override
  String get pastedContent => 'Yapıştırılan İçerik';

  @override
  String get trash => 'Çöp Kutusu';

  @override
  String get reminders => 'Hatırlatıcılar';

  @override
  String get notificationsEnabled =>
      'Bildirimler etkinleştirildi! Hatırlatıcılarınız ayarlandı.';

  @override
  String get shareApp => 'Uygulamayı Paylaş';

  @override
  String get shareAppMessage =>
      'Güvenli bir not alma uygulaması olan Better Keep Notes\'a göz atın!\nhttps://play.google.com/store/apps/details?id=io.foxbiz.better_keep';

  @override
  String get installBetterKeep => 'Better Keep\'i Yükle';

  @override
  String get installApp => 'Uygulamayı Yükle';

  @override
  String get getAndroidApp => 'Android Uygulamasını Edin';

  @override
  String get getWindowsApp => 'Windows Uygulamasını Edin';

  @override
  String get selectView => 'Görünüm Seç';

  @override
  String get viewModeGrid => 'Izgara';

  @override
  String get viewModeList => 'Liste';

  @override
  String get viewModeColors => 'Renkler';

  @override
  String get clear => 'Temizle';

  @override
  String get noMatchingNotes => 'Eşleşen not yok';

  @override
  String get noNotesYet => 'Henüz not yok';

  @override
  String get trashIsEmpty => 'Çöp kutusu boş';

  @override
  String get noPinnedNotes => 'Sabitlenmiş not yok';

  @override
  String get noLockedNotes => 'Kilitli not yok';

  @override
  String get noRemindersSet => 'Hatırlatıcı ayarlanmadı';

  @override
  String get createYourFirstNote => 'İlk notunuzu oluşturun';

  @override
  String get noLabelsYet => 'Henüz etiket yok';

  @override
  String get noColoredNotesYet => 'Henüz renkli not yok';

  @override
  String get addLabelsToOrganize =>
      'Notlarınızı klasörler halinde düzenlemek için etiketler ekleyin';

  @override
  String get addColorsToOrganize =>
      'Notlarınızı klasörler halinde düzenlemek için renkler ekleyin';

  @override
  String get getTheAndroidApp => 'Android Uygulamasını Edin';

  @override
  String get androidAppAvailable =>
      'Better Keep, Google Play\'de! Bildirimler, widget\'lar ve daha fazlasıyla en iyi deneyim için yerel uygulamayı edinin.';

  @override
  String get openPlayStore => 'Play Store\'u Aç';

  @override
  String get getTheWindowsApp => 'Windows Uygulamasını Edin';

  @override
  String get windowsAppAvailable =>
      'Better Keep, Microsoft Store\'da! Sistem entegrasyonu ve çevrimdışı erişim ile en iyi deneyim için yerel uygulamayı edinin.';

  @override
  String get openMicrosoftStore => 'Microsoft Store\'u Aç';

  @override
  String get installForQuickAccess =>
      'Ana ekranınızdan hızlı erişim ve çevrimdışı destek için Better Keep\'i yükleyin!';

  @override
  String get install => 'Yükle';

  @override
  String get notNow => 'Şimdi değil';

  @override
  String get noRecoveryKey => 'Kurtarma Anahtarı Yok';

  @override
  String get iUnderstand => 'Anlıyorum';

  @override
  String get deleteForever => 'Sonsuza Dek Sil';

  @override
  String get deleteAllTrashForever =>
      'Çöp kutusundaki tüm notları gerçekten sonsuza dek silmek istiyor musunuz? Bu işlem geri alınamaz.';

  @override
  String deleteSelectedNotesForever(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other:
          '$count notu gerçekten kalıcı olarak silmek istiyor musunuz? Bu işlem geri alınamaz.',
      one:
          'Bu notu gerçekten kalıcı olarak silmek istiyor musunuz? Bu işlem geri alınamaz.',
    );
    return '$_temp0';
  }

  @override
  String get search => 'Ara';

  @override
  String get todo => 'Yapılacaklar';

  @override
  String get audioNote => 'Sesli Not';

  @override
  String get failedToCreateImageNote => 'Resim notu oluşturulamadı';

  @override
  String get pleaseEnterYourEmail => 'Lütfen e-posta adresinizi girin';

  @override
  String get pleaseEnterAValidEmail =>
      'Lütfen geçerli bir e-posta adresi girin';

  @override
  String get pleaseEnterYourPassword => 'Lütfen parolanızı girin';

  @override
  String get passwordMustBeAtLeast6Characters =>
      'Parola en az 6 karakter uzunluğunda olmalıdır';

  @override
  String get pleaseConfirmYourPassword => 'Lütfen parolanızı onaylayın';

  @override
  String get passwordsDoNotMatch => 'Parolalar eşleşmiyor';

  @override
  String get creatingAccount => 'Hesap oluşturuluyor...';

  @override
  String get signingIn => 'Giriş yapılıyor...';

  @override
  String get createAccount => 'Hesap Oluştur';

  @override
  String get welcomeBack => 'Tekrar Hoş Geldiniz';

  @override
  String get signUpWithYourEmail => 'E-postanızla kaydolun';

  @override
  String get signInToContinue => 'Devam etmek için giriş yapın';

  @override
  String get forgotPassword => 'Parolamı Unuttum?';

  @override
  String get signIn => 'Giriş Yap';

  @override
  String get signUp => 'Kaydol';

  @override
  String get alreadyHaveAnAccount => 'Zaten bir hesabınız var mı?';

  @override
  String get dontHaveAnAccount => 'Hesabınız yok mu?';

  @override
  String get recoverySuccessfulWelcomeBack =>
      'Kurtarma başarılı! Tekrar hoş geldiniz.';

  @override
  String get approvalRequestSent =>
      'Onay isteği gönderildi! Başka bir cihazdan onaylayın.';

  @override
  String get checkingAccountStatus => 'Hesap durumu kontrol ediliyor...';

  @override
  String get recoverYourAccount => 'Hesabınızı Kurtarın';

  @override
  String get accountRecoveryRequired => 'Hesap Kurtarma Gerekli';

  @override
  String get noActiveDevicesRecoveryKey =>
      'Aktif cihaz bulunamadı. Şifrelenmiş notlarınıza erişimi geri yüklemek için kurtarma ifadenizi kullanın.';

  @override
  String get noActiveDevicesNoRecoveryKey =>
      'Aktif cihaz bulunamadı ve Kurtarma Anahtarı ayarlanmamış. Yeni bir hesapla baştan başlayabilirsiniz, ancak önceki notlarınız kurtarılamaz.';

  @override
  String get previousNotesEncryptedWarning =>
      'Önceki notlarınız şifrelenmiştir ve Kurtarma Anahtarı olmadan kurtarılamaz.';

  @override
  String get notYourMainDevice => 'Ana cihazınız değil mi?';

  @override
  String get anotherDeviceApprovalHint =>
      'Notlarınıza erişimi olan başka bir cihazınız varsa, o cihazdan onay isteyebilirsiniz.';

  @override
  String get requesting => 'İsteniyor...';

  @override
  String get requestApprovalFromAnotherDevice => 'Başka Bir Cihazdan Onay İste';

  @override
  String get signingOut => 'Çıkış yapılıyor...';

  @override
  String get takingTooLongTryAgain =>
      'Çok uzun sürüyor. İptal edip tekrar deneyebilirsiniz.';

  @override
  String get requestTimedOut =>
      'İstek zaman aşımına uğradı. Lütfen tekrar deneyin.';

  @override
  String get failedToSendVerificationCode => 'Doğrulama kodu gönderilemedi';

  @override
  String get yourEmail => 'e-postanız';

  @override
  String get continueLabel => 'Devam Et';

  @override
  String get pleaseConfirmConsequences =>
      'Lütfen sonuçları anladığınızı onaylayın';

  @override
  String get accountResetSuccessfully =>
      'Hesap başarıyla sıfırlandı. Hoş geldiniz!';

  @override
  String get failedToResetAccount => 'Hesap sıfırlanamadı';

  @override
  String failedToResetAccountError(String error) {
    return 'Hesap sıfırlanamadı: $error';
  }

  @override
  String get startFreshQuestion => 'Temiz Bir Başlangıç Yapılsın mı?';

  @override
  String get thisActionWill => 'Bu işlem şunları yapacaktır:';

  @override
  String get removeAllDeviceAuthorizations =>
      'Tüm cihaz yetkilendirmelerini kaldıracak';

  @override
  String get makeOldNotesUnrecoverable =>
      'Eski notlarınızı kurtarılamaz hale getirecek';

  @override
  String get createNewEncryptionKey =>
      'Yeni bir şifreleme anahtarı oluşturacak';

  @override
  String get startWithBlankAccount => 'Boş bir hesapla başlayacak';

  @override
  String get iUnderstandOldNotesInaccessible =>
      'Eski notlarımın kalıcı olarak erişilemez olacağını anlıyorum';

  @override
  String get saveToGallery => 'Galeriye Kaydet';

  @override
  String get newLabel => 'Yeni';

  @override
  String get pickPaperColor => 'Kağıt Rengi Seç';

  @override
  String get pickPenColor => 'Kalem Rengi Seç';

  @override
  String get savedToGallery => 'Galeriye Kaydedildi';

  @override
  String get sketchDownloaded => 'Çizim indirildi';

  @override
  String get failedToSaveSketch => 'Çizim kaydedilemedi';

  @override
  String errorSavingSketch(String error) {
    return 'Çizim kaydedilirken hata oluştu: $error';
  }

  @override
  String get planFree => 'Ücretsiz';

  @override
  String get planPro => 'Pro';

  @override
  String lockedNotesLimitReached(int count) {
    return '$count adet kilitli not sınırına ulaştınız';
  }

  @override
  String get realtimeCloudSyncRequiresPro =>
      'Gerçek zamanlı bulut eşitlemesi, Pro aboneliği gerektirir';

  @override
  String get unlimitedLockedNotes => 'Sınırsız kilitli notlar';

  @override
  String get realtimeCloudSync => 'Gerçek zamanlı bulut eşitlemesi';

  @override
  String get upgrade => 'Yükselt';

  @override
  String get upgradeToPro => 'Pro\'ya Yükselt';

  @override
  String unlockFeature(String feature) {
    return '$feature kilidini aç';
  }

  @override
  String featureRequiresPro(String feature) {
    return '$feature özelliği Pro gerektirir';
  }

  @override
  String get thisFeatureRequiresPro => 'Bu özellik Pro aboneliği gerektirir';

  @override
  String featureIsProFeature(String feature) {
    return '$feature bir Pro özelliğidir.';
  }

  @override
  String get unlockAllFeatures =>
      'Tüm özelliklerin kilidini açın ve geliştirmeyi destekleyin.';

  @override
  String get protectUnlimitedNotesWithPin =>
      'Sınırsız notu PIN kilitleriyle koruyun';

  @override
  String get syncAcrossDevicesSecurely =>
      'Tüm cihazlarınız arasında güvenli bir şekilde eşitleyin';

  @override
  String get unlimitedLockedNotesAndSync =>
      'Sınırsız kilitli notlar ve gerçek zamanlı bulut eşitlemesi';

  @override
  String get unlockTheFullExperience => 'Tam Deneyimin Kilidini Açın';

  @override
  String get maybeLater => 'Belki daha sonra';

  @override
  String get enableNotificationsTitle => 'Bildirimleri Etkinleştir';

  @override
  String get enableNotificationsForReminders =>
      'Senkronize edilen notlarınızda hatırlatıcılar var. Kaçırmamak için bildirimleri etkinleştirin.';

  @override
  String get enableNotifications => 'Etkinleştir';

  @override
  String get rateOnAppStore => 'App Store\'da Değerlendir';

  @override
  String get rateOnPlayStore => 'Play Store\'da Değerlendir';

  @override
  String get rateOnMicrosoftStore => 'Microsoft Store\'da Değerlendir';

  @override
  String get sortBy => 'Sıralama ölçütü';

  @override
  String get sortCustom => 'Özel';

  @override
  String get sortCreatedNewest => 'Oluşturma tarihi';

  @override
  String get sortUpdatedNewest => 'Güncelleme tarihi';

  @override
  String get dragToReorder => 'Yeniden sıralamak için basılı tutun';

  @override
  String get moveNoteBefore => 'Notu önceye taşı';

  @override
  String get moveNoteAfter => 'Notu sonraya taşı';

  @override
  String get pinnedReorderBoundary =>
      'Sabitlenmiş ve sabitlenmemiş notlar ayrı ayrı düzenlenir.';

  @override
  String get reorderSaveFailed =>
      'Yeni not sırası kaydedilemedi. Önceki sıra geri yüklendi.';

  @override
  String get noteDisplayOptions => 'Not görüntüleme seçenekleri';

  @override
  String get noteDisplayOptionsSaveFailed =>
      'Not görüntüleme seçenekleri kaydedilemedi. Tekrar deneyin.';

  @override
  String get noteDisplayOptionsSaved =>
      'Not görüntüleme seçenekleri kaydedildi';

  @override
  String get reorderCustomHint =>
      'Bir nota basılı tutun, ardından yeniden düzenlemek için sürükleyin.';

  @override
  String get reorderDateSortHint =>
      'Tarihe göre sıralarken elle yeniden düzenleme kullanılamaz. Notları yeniden düzenlemek için Özel\'i seçin.';
}
