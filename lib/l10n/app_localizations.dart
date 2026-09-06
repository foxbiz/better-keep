import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_id.dart';
import 'app_localizations_ja.dart';
import 'app_localizations_ko.dart';
import 'app_localizations_pt.dart';
import 'app_localizations_tr.dart';
import 'app_localizations_zh.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations? of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations);
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('id'),
    Locale('ja'),
    Locale('ko'),
    Locale('pt'),
    Locale('tr'),
    Locale('zh'),
  ];

  /// The name of the application
  ///
  /// In en, this message translates to:
  /// **'Better Keep'**
  String get appTitle;

  /// Title shown when the app cannot finish starting
  ///
  /// In en, this message translates to:
  /// **'Unable to start Better Keep'**
  String get unableToStartApp;

  /// Retryable startup failure guidance
  ///
  /// In en, this message translates to:
  /// **'Something went wrong while opening the app. Please try again.'**
  String get startupRetryMessage;

  /// Non-retryable startup failure guidance
  ///
  /// In en, this message translates to:
  /// **'Something went wrong while opening the app. Close and reopen it to try again.'**
  String get startupRestartMessage;

  /// Sign-in error when an account does not exist
  ///
  /// In en, this message translates to:
  /// **'No account was found with this email.'**
  String get accountNotFound;

  /// Sign-in error for invalid credentials
  ///
  /// In en, this message translates to:
  /// **'The email or password is incorrect. Please try again.'**
  String get invalidCredentials;

  /// Sign-in error for a disabled account
  ///
  /// In en, this message translates to:
  /// **'This account is unavailable. Please contact support.'**
  String get accountDisabled;

  /// Title shown while browser payment is underway
  ///
  /// In en, this message translates to:
  /// **'Payment in progress'**
  String get paymentInProgress;

  /// Instructions for a browser-based payment
  ///
  /// In en, this message translates to:
  /// **'Complete the payment in your browser. This message will close automatically when you are finished.'**
  String get completePaymentInBrowser;

  /// No description provided for @legal.
  ///
  /// In en, this message translates to:
  /// **'Legal'**
  String get legal;

  /// No description provided for @termsOfUse.
  ///
  /// In en, this message translates to:
  /// **'Terms of Use'**
  String get termsOfUse;

  /// No description provided for @privacyPolicy.
  ///
  /// In en, this message translates to:
  /// **'Privacy Policy'**
  String get privacyPolicy;

  /// No description provided for @appLogoSemantics.
  ///
  /// In en, this message translates to:
  /// **'Better Keep app logo'**
  String get appLogoSemantics;

  /// No description provided for @selectColor.
  ///
  /// In en, this message translates to:
  /// **'Select color'**
  String get selectColor;

  /// No description provided for @unsupportedTextFile.
  ///
  /// In en, this message translates to:
  /// **'This file type isn’t supported. Choose a .txt or .md file.'**
  String get unsupportedTextFile;

  /// No description provided for @sharedFileEmpty.
  ///
  /// In en, this message translates to:
  /// **'This file is empty.'**
  String get sharedFileEmpty;

  /// No description provided for @fileNotFound.
  ///
  /// In en, this message translates to:
  /// **'This file could not be found.'**
  String get fileNotFound;

  /// No description provided for @fileTooLarge.
  ///
  /// In en, this message translates to:
  /// **'This file is too large. Choose a file smaller than 5 MB.'**
  String get fileTooLarge;

  /// No description provided for @couldNotReadFile.
  ///
  /// In en, this message translates to:
  /// **'This file could not be read. Please try another file.'**
  String get couldNotReadFile;

  /// No description provided for @couldNotOpenFile.
  ///
  /// In en, this message translates to:
  /// **'This file could not be opened. Please try again.'**
  String get couldNotOpenFile;

  /// No description provided for @noteSaved.
  ///
  /// In en, this message translates to:
  /// **'Note saved'**
  String get noteSaved;

  /// No description provided for @untitled.
  ///
  /// In en, this message translates to:
  /// **'Untitled'**
  String get untitled;

  /// No description provided for @failedToExportNote.
  ///
  /// In en, this message translates to:
  /// **'Couldn’t export the note. Please try again.'**
  String get failedToExportNote;

  /// No description provided for @failedToCopyNote.
  ///
  /// In en, this message translates to:
  /// **'Couldn’t copy the note. Please try again.'**
  String get failedToCopyNote;

  /// No description provided for @failedToDeleteSketch.
  ///
  /// In en, this message translates to:
  /// **'Couldn’t delete the sketch. Please try again.'**
  String get failedToDeleteSketch;

  /// No description provided for @lockedNoteReminder.
  ///
  /// In en, this message translates to:
  /// **'Reminder for a locked note'**
  String get lockedNoteReminder;

  /// No description provided for @notesReminder.
  ///
  /// In en, this message translates to:
  /// **'Better Keep note reminder'**
  String get notesReminder;

  /// No description provided for @blankPage.
  ///
  /// In en, this message translates to:
  /// **'Blank'**
  String get blankPage;

  /// No description provided for @linedPage.
  ///
  /// In en, this message translates to:
  /// **'Lined'**
  String get linedPage;

  /// No description provided for @doubleLinedPage.
  ///
  /// In en, this message translates to:
  /// **'Double lined'**
  String get doubleLinedPage;

  /// No description provided for @gridPage.
  ///
  /// In en, this message translates to:
  /// **'Grid'**
  String get gridPage;

  /// No description provided for @dotGridPage.
  ///
  /// In en, this message translates to:
  /// **'Dot grid'**
  String get dotGridPage;

  /// No description provided for @dataExportTitle.
  ///
  /// In en, this message translates to:
  /// **'Better Keep data export'**
  String get dataExportTitle;

  /// No description provided for @dataExportShareText.
  ///
  /// In en, this message translates to:
  /// **'My Better Keep data export'**
  String get dataExportShareText;

  /// No description provided for @noteReminders.
  ///
  /// In en, this message translates to:
  /// **'Note reminders'**
  String get noteReminders;

  /// No description provided for @noteRemindersDescription.
  ///
  /// In en, this message translates to:
  /// **'Time-sensitive reminders for notes'**
  String get noteRemindersDescription;

  /// No description provided for @deviceApproval.
  ///
  /// In en, this message translates to:
  /// **'Device approval'**
  String get deviceApproval;

  /// No description provided for @deviceApprovalDescription.
  ///
  /// In en, this message translates to:
  /// **'Notifications for device approval requests'**
  String get deviceApprovalDescription;

  /// No description provided for @newDeviceApprovalRequest.
  ///
  /// In en, this message translates to:
  /// **'New device approval request'**
  String get newDeviceApprovalRequest;

  /// No description provided for @deviceWantsAccess.
  ///
  /// In en, this message translates to:
  /// **'{deviceName} ({platform}) wants to access your notes'**
  String deviceWantsAccess(String deviceName, String platform);

  /// No description provided for @sharedText.
  ///
  /// In en, this message translates to:
  /// **'Shared text'**
  String get sharedText;

  /// No description provided for @sharedFile.
  ///
  /// In en, this message translates to:
  /// **'Shared file'**
  String get sharedFile;

  /// No description provided for @user.
  ///
  /// In en, this message translates to:
  /// **'User'**
  String get user;

  /// No description provided for @thirtyDaysFromNow.
  ///
  /// In en, this message translates to:
  /// **'30 days from now'**
  String get thirtyDaysFromNow;

  /// No description provided for @helpRequestSubject.
  ///
  /// In en, this message translates to:
  /// **'Better Keep - Help request'**
  String get helpRequestSubject;

  /// No description provided for @faqCreateNoteQuestion.
  ///
  /// In en, this message translates to:
  /// **'How do I create a new note?'**
  String get faqCreateNoteQuestion;

  /// No description provided for @faqCreateNoteAnswer.
  ///
  /// In en, this message translates to:
  /// **'Tap the + button at the bottom of the home screen. You can add text, images, audio, and more.'**
  String get faqCreateNoteAnswer;

  /// No description provided for @faqShortcutsQuestion.
  ///
  /// In en, this message translates to:
  /// **'How do I use quick shortcuts?'**
  String get faqShortcutsQuestion;

  /// No description provided for @faqShortcutsAnswer.
  ///
  /// In en, this message translates to:
  /// **'Press and hold the + button to reveal shortcuts for an image, audio, sketch, or to-do. Slide to the shortcut you want and release. A quick tap opens a blank note.'**
  String get faqShortcutsAnswer;

  /// No description provided for @faqLabelsQuestion.
  ///
  /// In en, this message translates to:
  /// **'How do I organize notes with labels?'**
  String get faqLabelsQuestion;

  /// No description provided for @faqLabelsAnswer.
  ///
  /// In en, this message translates to:
  /// **'Open a note and tap the label icon to add or create labels. You can filter notes by label from the side menu.'**
  String get faqLabelsAnswer;

  /// No description provided for @faqReminderQuestion.
  ///
  /// In en, this message translates to:
  /// **'How do I set a reminder?'**
  String get faqReminderQuestion;

  /// No description provided for @faqReminderAnswer.
  ///
  /// In en, this message translates to:
  /// **'Open a note and tap the reminder icon to choose a date and time.'**
  String get faqReminderAnswer;

  /// No description provided for @faqArchiveDeleteQuestion.
  ///
  /// In en, this message translates to:
  /// **'How do I archive or delete notes?'**
  String get faqArchiveDeleteQuestion;

  /// No description provided for @faqArchiveDeleteAnswer.
  ///
  /// In en, this message translates to:
  /// **'Press and hold a note to select it, then use the archive or delete action. Deleted notes move to Trash first and can be permanently deleted there.'**
  String get faqArchiveDeleteAnswer;

  /// No description provided for @faqThemeQuestion.
  ///
  /// In en, this message translates to:
  /// **'How do I change the app theme?'**
  String get faqThemeQuestion;

  /// No description provided for @faqThemeAnswer.
  ///
  /// In en, this message translates to:
  /// **'Open Settings and choose the theme options you prefer.'**
  String get faqThemeAnswer;

  /// No description provided for @faqSyncQuestion.
  ///
  /// In en, this message translates to:
  /// **'How do I sync notes across devices?'**
  String get faqSyncQuestion;

  /// No description provided for @faqSyncAnswer.
  ///
  /// In en, this message translates to:
  /// **'Sign in to securely sync your notes across your devices.'**
  String get faqSyncAnswer;

  /// No description provided for @faqReminderTimesQuestion.
  ///
  /// In en, this message translates to:
  /// **'How do I set morning, afternoon, and evening times?'**
  String get faqReminderTimesQuestion;

  /// No description provided for @faqReminderTimesAnswer.
  ///
  /// In en, this message translates to:
  /// **'Open Settings and choose Reminder Time Settings to customize those times.'**
  String get faqReminderTimesAnswer;

  /// No description provided for @faqAlarmSoundQuestion.
  ///
  /// In en, this message translates to:
  /// **'How do I change the alarm sound?'**
  String get faqAlarmSoundQuestion;

  /// No description provided for @faqAlarmSoundAnswer.
  ///
  /// In en, this message translates to:
  /// **'Open Settings, select Alarm Sound, and choose one of the available sounds.'**
  String get faqAlarmSoundAnswer;

  /// No description provided for @faqSecurityQuestion.
  ///
  /// In en, this message translates to:
  /// **'Is my data secure?'**
  String get faqSecurityQuestion;

  /// No description provided for @faqSecurityAnswer.
  ///
  /// In en, this message translates to:
  /// **'Your notes are stored securely. When sync protection is enabled, end-to-end encryption protects your synced data.'**
  String get faqSecurityAnswer;

  /// No description provided for @faqApproveDeviceQuestion.
  ///
  /// In en, this message translates to:
  /// **'How do I approve a new device?'**
  String get faqApproveDeviceQuestion;

  /// No description provided for @faqApproveDeviceAnswer.
  ///
  /// In en, this message translates to:
  /// **'Open Better Keep on an already approved device. In your profile, review Devices Waiting for Approval, then approve or deny the request.'**
  String get faqApproveDeviceAnswer;

  /// No description provided for @faqDeleteAccountQuestion.
  ///
  /// In en, this message translates to:
  /// **'How do I delete my account?'**
  String get faqDeleteAccountQuestion;

  /// No description provided for @faqDeleteAccountAnswer.
  ///
  /// In en, this message translates to:
  /// **'Open your profile and choose Delete Account. After email verification, deletion is scheduled for 30 days later and your devices are signed out.'**
  String get faqDeleteAccountAnswer;

  /// No description provided for @faqCancelDeletionQuestion.
  ///
  /// In en, this message translates to:
  /// **'Can I cancel account deletion?'**
  String get faqCancelDeletionQuestion;

  /// No description provided for @faqCancelDeletionAnswer.
  ///
  /// In en, this message translates to:
  /// **'Yes. Sign back in within 30 days to cancel the scheduled deletion and restore access to your account.'**
  String get faqCancelDeletionAnswer;

  /// No description provided for @faqDeletionEffectsQuestion.
  ///
  /// In en, this message translates to:
  /// **'What happens when I delete my account?'**
  String get faqDeletionEffectsQuestion;

  /// No description provided for @faqDeletionEffectsAnswer.
  ///
  /// In en, this message translates to:
  /// **'Your devices are signed out immediately. After 30 days, your notes, attachments, labels, and personal data are permanently deleted and cannot be recovered.'**
  String get faqDeletionEffectsAnswer;

  /// No description provided for @faqExportBeforeDeletionQuestion.
  ///
  /// In en, this message translates to:
  /// **'Can I export my data before deleting my account?'**
  String get faqExportBeforeDeletionQuestion;

  /// No description provided for @faqExportBeforeDeletionAnswer.
  ///
  /// In en, this message translates to:
  /// **'Yes. After scheduling deletion, you can export your data. Download it before the 30-day period ends.'**
  String get faqExportBeforeDeletionAnswer;

  /// No description provided for @iosAppAvailable.
  ///
  /// In en, this message translates to:
  /// **'Better Keep is available on the App Store. Get the app for notifications, widgets, and more.'**
  String get iosAppAvailable;

  /// No description provided for @openAppStore.
  ///
  /// In en, this message translates to:
  /// **'Open App Store'**
  String get openAppStore;

  /// No description provided for @tasks.
  ///
  /// In en, this message translates to:
  /// **'Tasks'**
  String get tasks;

  /// No description provided for @unknown.
  ///
  /// In en, this message translates to:
  /// **'Unknown'**
  String get unknown;

  /// No description provided for @exportAttachments.
  ///
  /// In en, this message translates to:
  /// **'Attachments'**
  String get exportAttachments;

  /// No description provided for @created.
  ///
  /// In en, this message translates to:
  /// **'Created'**
  String get created;

  /// No description provided for @updated.
  ///
  /// In en, this message translates to:
  /// **'Updated'**
  String get updated;

  /// No description provided for @oneTime.
  ///
  /// In en, this message translates to:
  /// **'One time'**
  String get oneTime;

  /// No description provided for @lockedExportExplanation.
  ///
  /// In en, this message translates to:
  /// **'These notes are locked. Their protected content is preserved in this export and can only be opened with the original PIN.'**
  String get lockedExportExplanation;

  /// No description provided for @dataExportReadme.
  ///
  /// In en, this message translates to:
  /// **'Better Keep - Data Export\n\nThis archive contains your exported notes, labels, attachments, and export details. Notes you can open are also provided as Markdown files. Locked notes remain protected and require their original PIN.\n\nFor help, contact contact@betterkeep.app.\n\nExported on: {exportedAt}'**
  String dataExportReadme(String exportedAt);

  /// No description provided for @paymentSuccessful.
  ///
  /// In en, this message translates to:
  /// **'Payment successful'**
  String get paymentSuccessful;

  /// No description provided for @paymentSuccessfulReturn.
  ///
  /// In en, this message translates to:
  /// **'You can close this window and return to Better Keep.'**
  String get paymentSuccessfulReturn;

  /// No description provided for @paymentCancelledClose.
  ///
  /// In en, this message translates to:
  /// **'Payment was cancelled. You can close this window.'**
  String get paymentCancelledClose;

  /// No description provided for @appleSignInVerificationFailed.
  ///
  /// In en, this message translates to:
  /// **'Apple sign-in could not be verified. Please try again.'**
  String get appleSignInVerificationFailed;

  /// No description provided for @reminderType.
  ///
  /// In en, this message translates to:
  /// **'Reminder type'**
  String get reminderType;

  /// No description provided for @notificationReminder.
  ///
  /// In en, this message translates to:
  /// **'Notification'**
  String get notificationReminder;

  /// No description provided for @notificationReminderDescription.
  ///
  /// In en, this message translates to:
  /// **'Shows a standard time-sensitive notification'**
  String get notificationReminderDescription;

  /// No description provided for @alarmReminder.
  ///
  /// In en, this message translates to:
  /// **'Alarm'**
  String get alarmReminder;

  /// No description provided for @alarmReminderDescription.
  ///
  /// In en, this message translates to:
  /// **'Rings continuously until you stop it'**
  String get alarmReminderDescription;

  /// No description provided for @alarmUnsupportedPlatform.
  ///
  /// In en, this message translates to:
  /// **'Alarms are not supported on this platform. The reminder will sync and become an alarm on Android or iOS.'**
  String get alarmUnsupportedPlatform;

  /// No description provided for @notificationUnsupportedPlatform.
  ///
  /// In en, this message translates to:
  /// **'Scheduled notifications are not available while Better Keep is closed on this platform. The reminder will still sync and appear in the app when due.'**
  String get notificationUnsupportedPlatform;

  /// No description provided for @alarmRequiresSpecificTime.
  ///
  /// In en, this message translates to:
  /// **'Alarms require a specific time; All day is available for notifications only.'**
  String get alarmRequiresSpecificTime;

  /// No description provided for @reminderDue.
  ///
  /// In en, this message translates to:
  /// **'Reminder due'**
  String get reminderDue;

  /// No description provided for @overdueReminderTitle.
  ///
  /// In en, this message translates to:
  /// **'Overdue reminder'**
  String get overdueReminderTitle;

  /// No description provided for @overdueReminderMessage.
  ///
  /// In en, this message translates to:
  /// **'This reminder is overdue. Mark it as done now?'**
  String get overdueReminderMessage;

  /// No description provided for @markReminderDoneFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn’t mark this reminder as done. Please try again.'**
  String get markReminderDoneFailed;

  /// No description provided for @markAsDone.
  ///
  /// In en, this message translates to:
  /// **'Mark as Done'**
  String get markAsDone;

  /// No description provided for @reminderSavedPermissionRequired.
  ///
  /// In en, this message translates to:
  /// **'Reminder saved, but permission is required to schedule it on this device.'**
  String get reminderSavedPermissionRequired;

  /// No description provided for @reminderSavedAlreadyDue.
  ///
  /// In en, this message translates to:
  /// **'Reminder saved and is already due.'**
  String get reminderSavedAlreadyDue;

  /// No description provided for @reminderScheduleFailed.
  ///
  /// In en, this message translates to:
  /// **'Reminder saved, but this device could not schedule it.'**
  String get reminderScheduleFailed;

  /// No description provided for @reminderCapacityExceeded.
  ///
  /// In en, this message translates to:
  /// **'Reminder saved, but this device has too many pending reminders to schedule another one.'**
  String get reminderCapacityExceeded;

  /// No description provided for @reminderTimeZoneUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Reminder saved, but this device\'s timezone could not be resolved. Check the device time settings and try again.'**
  String get reminderTimeZoneUnavailable;

  /// Cancel button text
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get cancel;

  /// OK button text
  ///
  /// In en, this message translates to:
  /// **'OK'**
  String get ok;

  /// Save button text
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get save;

  /// Delete button text
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get delete;

  /// Close button text
  ///
  /// In en, this message translates to:
  /// **'Close'**
  String get close;

  /// Retry button text
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get retry;

  /// Title for a protected sketch that could not be recovered
  ///
  /// In en, this message translates to:
  /// **'Protected sketch'**
  String get protectedSketchTitle;

  /// Explanation shown when an older protected sketch is preserved for a later recovery attempt
  ///
  /// In en, this message translates to:
  /// **'This older protected sketch could not be recovered yet. Its original encrypted drawing has been preserved and the app will retry after the next successful unlock.'**
  String get protectedSketchRecoveryMessage;

  /// Message shown when an image sketch background is unavailable but its drawing data is preserved
  ///
  /// In en, this message translates to:
  /// **'Background unavailable; drawing preserved'**
  String get sketchBackgroundUnavailable;

  /// Discard an uncommitted local item
  ///
  /// In en, this message translates to:
  /// **'Discard'**
  String get discard;

  /// Title shown when an attachment could not be committed to a note
  ///
  /// In en, this message translates to:
  /// **'Couldn’t add attachment'**
  String get attachmentCommitFailedTitle;

  /// Retry-or-discard explanation for an attachment commit failure
  ///
  /// In en, this message translates to:
  /// **'The original file is still safe. Retry adding it, or discard it from this device.'**
  String get attachmentCommitFailedMessage;

  /// Done button text
  ///
  /// In en, this message translates to:
  /// **'Done'**
  String get done;

  /// Remove button text
  ///
  /// In en, this message translates to:
  /// **'Remove'**
  String get remove;

  /// Open button text
  ///
  /// In en, this message translates to:
  /// **'Open'**
  String get open;

  /// Select button text
  ///
  /// In en, this message translates to:
  /// **'Select'**
  String get select;

  /// Verify button text
  ///
  /// In en, this message translates to:
  /// **'Verify'**
  String get verify;

  /// Link button text
  ///
  /// In en, this message translates to:
  /// **'Link'**
  String get link;

  /// Unlink button text
  ///
  /// In en, this message translates to:
  /// **'Unlink'**
  String get unlink;

  /// Approve button text
  ///
  /// In en, this message translates to:
  /// **'Approve'**
  String get approve;

  /// Deny button text
  ///
  /// In en, this message translates to:
  /// **'Deny'**
  String get deny;

  /// Primary label
  ///
  /// In en, this message translates to:
  /// **'Primary'**
  String get primary;

  /// Sign out button text
  ///
  /// In en, this message translates to:
  /// **'Sign Out'**
  String get signOut;

  /// Sign out anyway button text
  ///
  /// In en, this message translates to:
  /// **'Sign Out Anyway'**
  String get signOutAnyway;

  /// Continue offline button text
  ///
  /// In en, this message translates to:
  /// **'Continue Offline'**
  String get continueOffline;

  /// Cancel sign in button text
  ///
  /// In en, this message translates to:
  /// **'Cancel Sign In'**
  String get cancelSignIn;

  /// Sign in cancelled message
  ///
  /// In en, this message translates to:
  /// **'Sign in cancelled'**
  String get signInCancelled;

  /// Facebook sign in tooltip
  ///
  /// In en, this message translates to:
  /// **'Sign in with Facebook'**
  String get signInWithFacebook;

  /// GitHub sign in tooltip
  ///
  /// In en, this message translates to:
  /// **'Sign in with GitHub'**
  String get signInWithGithub;

  /// Email sign in tooltip
  ///
  /// In en, this message translates to:
  /// **'Sign in with Email'**
  String get signInWithEmail;

  /// About page title
  ///
  /// In en, this message translates to:
  /// **'About'**
  String get about;

  /// Help page title
  ///
  /// In en, this message translates to:
  /// **'Help'**
  String get help;

  /// Settings page title
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get settings;

  /// Labels dialog title
  ///
  /// In en, this message translates to:
  /// **'Labels'**
  String get labels;

  /// Add link dialog title
  ///
  /// In en, this message translates to:
  /// **'Add Link'**
  String get addLink;

  /// Edit link dialog title
  ///
  /// In en, this message translates to:
  /// **'Edit Link'**
  String get editLink;

  /// Set reminder dialog title
  ///
  /// In en, this message translates to:
  /// **'Set Reminder'**
  String get setReminder;

  /// Display text field label
  ///
  /// In en, this message translates to:
  /// **'Display Text'**
  String get displayText;

  /// Display text field hint
  ///
  /// In en, this message translates to:
  /// **'Enter the text to display'**
  String get enterDisplayText;

  /// Display text validation error
  ///
  /// In en, this message translates to:
  /// **'Please enter display text'**
  String get pleaseEnterDisplayText;

  /// URL field label
  ///
  /// In en, this message translates to:
  /// **'URL'**
  String get url;

  /// URL field hint
  ///
  /// In en, this message translates to:
  /// **'https://example.com'**
  String get urlHint;

  /// Note title hint text
  ///
  /// In en, this message translates to:
  /// **'Title your thought'**
  String get titleYourThought;

  /// Email field label
  ///
  /// In en, this message translates to:
  /// **'Email'**
  String get email;

  /// Email field hint
  ///
  /// In en, this message translates to:
  /// **'you@example.com'**
  String get emailHint;

  /// Email field hint for password reset
  ///
  /// In en, this message translates to:
  /// **'Enter your email address'**
  String get enterEmailAddress;

  /// Password field label
  ///
  /// In en, this message translates to:
  /// **'Password'**
  String get password;

  /// Confirm password field label
  ///
  /// In en, this message translates to:
  /// **'Confirm Password'**
  String get confirmPassword;

  /// New password field label
  ///
  /// In en, this message translates to:
  /// **'New Password'**
  String get newPassword;

  /// New password field hint
  ///
  /// In en, this message translates to:
  /// **'Enter new password'**
  String get enterNewPassword;

  /// Confirm password field hint
  ///
  /// In en, this message translates to:
  /// **'Re-enter new password'**
  String get reenterNewPassword;

  /// Current passphrase field label
  ///
  /// In en, this message translates to:
  /// **'Current Passphrase'**
  String get currentPassphrase;

  /// Passphrase field hint
  ///
  /// In en, this message translates to:
  /// **'Enter your passphrase'**
  String get enterYourPassphrase;

  /// Current passphrase field hint
  ///
  /// In en, this message translates to:
  /// **'Enter your current passphrase'**
  String get enterCurrentPassphrase;

  /// Recovery passphrase field label
  ///
  /// In en, this message translates to:
  /// **'Recovery Passphrase'**
  String get recoveryPassphrase;

  /// Strong passphrase hint
  ///
  /// In en, this message translates to:
  /// **'Enter a strong passphrase'**
  String get enterStrongPassphrase;

  /// Confirm passphrase field label
  ///
  /// In en, this message translates to:
  /// **'Confirm Passphrase'**
  String get confirmPassphrase;

  /// Confirm passphrase hint
  ///
  /// In en, this message translates to:
  /// **'Re-enter your passphrase'**
  String get reenterPassphrase;

  /// New passphrase field label
  ///
  /// In en, this message translates to:
  /// **'New Passphrase'**
  String get newPassphrase;

  /// Confirm new passphrase field label
  ///
  /// In en, this message translates to:
  /// **'Confirm New Passphrase'**
  String get confirmNewPassphrase;

  /// Confirm new passphrase hint
  ///
  /// In en, this message translates to:
  /// **'Re-enter your new passphrase'**
  String get reenterNewPassphrase;

  /// Optional hint field label
  ///
  /// In en, this message translates to:
  /// **'Hint (Optional)'**
  String get hintOptional;

  /// Hint field hint text
  ///
  /// In en, this message translates to:
  /// **'A hint to help you remember'**
  String get hintToRemember;

  /// PIN field label
  ///
  /// In en, this message translates to:
  /// **'PIN'**
  String get pin;

  /// PIN field hint
  ///
  /// In en, this message translates to:
  /// **'Enter PIN'**
  String get enterPin;

  /// New label name hint
  ///
  /// In en, this message translates to:
  /// **'New label name'**
  String get newLabelName;

  /// Add label tooltip
  ///
  /// In en, this message translates to:
  /// **'Add label'**
  String get addLabel;

  /// Search logs hint text
  ///
  /// In en, this message translates to:
  /// **'Search logs...'**
  String get searchLogs;

  /// Audio recording dialog title
  ///
  /// In en, this message translates to:
  /// **'Audio Recording'**
  String get audioRecording;

  /// Delete recording dialog title
  ///
  /// In en, this message translates to:
  /// **'Delete Recording'**
  String get deleteRecording;

  /// Title field label
  ///
  /// In en, this message translates to:
  /// **'Title'**
  String get title;

  /// Recording title hint
  ///
  /// In en, this message translates to:
  /// **'Enter a title for this recording'**
  String get enterRecordingTitle;

  /// Theme settings section title
  ///
  /// In en, this message translates to:
  /// **'Theme'**
  String get theme;

  /// Theme settings subtitle
  ///
  /// In en, this message translates to:
  /// **'Customize app appearance'**
  String get customizeAppearance;

  /// Follow system theme toggle label
  ///
  /// In en, this message translates to:
  /// **'Follow System Theme'**
  String get followSystemTheme;

  /// Follow system theme toggle subtitle
  ///
  /// In en, this message translates to:
  /// **'Automatically switch between light and dark'**
  String get autoSwitchLightDark;

  /// Follow system animation preference toggle label
  ///
  /// In en, this message translates to:
  /// **'Follow system animation preference'**
  String get followSystemAnimations;

  /// Follow system animation preference toggle subtitle
  ///
  /// In en, this message translates to:
  /// **'Reduce animations when enabled in your device or browser settings'**
  String get reduceAnimationsFromSystem;

  /// Dark mode toggle label
  ///
  /// In en, this message translates to:
  /// **'Dark Mode'**
  String get darkMode;

  /// Dark theme label
  ///
  /// In en, this message translates to:
  /// **'Dark Theme'**
  String get darkTheme;

  /// Light theme label
  ///
  /// In en, this message translates to:
  /// **'Light Theme'**
  String get lightTheme;

  /// Show sync progress toggle label
  ///
  /// In en, this message translates to:
  /// **'Show Sync Progress'**
  String get showSyncProgress;

  /// Show sync progress toggle subtitle
  ///
  /// In en, this message translates to:
  /// **'Display sync status indicator'**
  String get displaySyncStatus;

  /// Alarm sound setting label
  ///
  /// In en, this message translates to:
  /// **'Alarm Sound'**
  String get alarmSound;

  /// Reminder time settings section title
  ///
  /// In en, this message translates to:
  /// **'Reminder Time Settings'**
  String get reminderTimeSettings;

  /// Reminder time settings subtitle
  ///
  /// In en, this message translates to:
  /// **'Set default times for reminders'**
  String get setDefaultTimes;

  /// Morning time label
  ///
  /// In en, this message translates to:
  /// **'Morning'**
  String get morning;

  /// Afternoon time label
  ///
  /// In en, this message translates to:
  /// **'Afternoon'**
  String get afternoon;

  /// Evening time label
  ///
  /// In en, this message translates to:
  /// **'Evening'**
  String get evening;

  /// Local data protection section title
  ///
  /// In en, this message translates to:
  /// **'Local Data Protection'**
  String get localDataProtection;

  /// Local data protection subtitle
  ///
  /// In en, this message translates to:
  /// **'Encrypt data stored on this device'**
  String get encryptDeviceData;

  /// Encrypt notes toggle label
  ///
  /// In en, this message translates to:
  /// **'Encrypt Notes'**
  String get encryptNotes;

  /// Encrypt files toggle label
  ///
  /// In en, this message translates to:
  /// **'Encrypt Files'**
  String get encryptFiles;

  /// Locked notes section title
  ///
  /// In en, this message translates to:
  /// **'Locked Notes Security'**
  String get lockedNotesSecurity;

  /// Locked notes section subtitle
  ///
  /// In en, this message translates to:
  /// **'Privacy settings for locked notes'**
  String get privacyLockedNotes;

  /// Forget password toggle label
  ///
  /// In en, this message translates to:
  /// **'Forget password on close'**
  String get forgetPasswordOnClose;

  /// Forget password toggle subtitle
  ///
  /// In en, this message translates to:
  /// **'Require password each time the app is opened'**
  String get requirePasswordAgain;

  /// Nerd stats page title
  ///
  /// In en, this message translates to:
  /// **'Nerd Stats'**
  String get nerdStats;

  /// Developer section subtitle
  ///
  /// In en, this message translates to:
  /// **'Developer'**
  String get developer;

  /// Contact us title
  ///
  /// In en, this message translates to:
  /// **'Contact Us'**
  String get contactUs;

  /// Developed by label
  ///
  /// In en, this message translates to:
  /// **'Developed by'**
  String get developedBy;

  /// View on GitHub button label
  ///
  /// In en, this message translates to:
  /// **'View on GitHub'**
  String get viewOnGithub;

  /// Archive action
  ///
  /// In en, this message translates to:
  /// **'Archive'**
  String get archive;

  /// Unarchive action
  ///
  /// In en, this message translates to:
  /// **'Unarchive'**
  String get unarchive;

  /// Read only mode label
  ///
  /// In en, this message translates to:
  /// **'Read Only'**
  String get readOnly;

  /// Locked note label
  ///
  /// In en, this message translates to:
  /// **'Locked'**
  String get locked;

  /// Save as menu item
  ///
  /// In en, this message translates to:
  /// **'Save as'**
  String get saveAs;

  /// Copy as menu item
  ///
  /// In en, this message translates to:
  /// **'Copy as'**
  String get copyAs;

  /// Share action
  ///
  /// In en, this message translates to:
  /// **'Share'**
  String get share;

  /// Duplicate action
  ///
  /// In en, this message translates to:
  /// **'Duplicate'**
  String get duplicate;

  /// Markdown format label
  ///
  /// In en, this message translates to:
  /// **'Markdown'**
  String get markdown;

  /// Markdown file format
  ///
  /// In en, this message translates to:
  /// **'Markdown (.md)'**
  String get markdownFile;

  /// HTML format label
  ///
  /// In en, this message translates to:
  /// **'HTML'**
  String get html;

  /// HTML file format
  ///
  /// In en, this message translates to:
  /// **'HTML (.html)'**
  String get htmlFile;

  /// Plain text format label
  ///
  /// In en, this message translates to:
  /// **'Plain Text'**
  String get plainText;

  /// Plain text file format
  ///
  /// In en, this message translates to:
  /// **'Plain Text (.txt)'**
  String get plainTextFile;

  /// Restore action tooltip
  ///
  /// In en, this message translates to:
  /// **'Restore'**
  String get restore;

  /// Reminder action tooltip
  ///
  /// In en, this message translates to:
  /// **'Reminder'**
  String get reminder;

  /// Hide keyboard tooltip
  ///
  /// In en, this message translates to:
  /// **'Hide keyboard'**
  String get hideKeyboard;

  /// Refresh tooltip
  ///
  /// In en, this message translates to:
  /// **'Refresh'**
  String get refresh;

  /// Dismiss tooltip
  ///
  /// In en, this message translates to:
  /// **'Dismiss'**
  String get dismiss;

  /// Back tooltip
  ///
  /// In en, this message translates to:
  /// **'Back'**
  String get back;

  /// Copy to clipboard tooltip
  ///
  /// In en, this message translates to:
  /// **'Copy to clipboard'**
  String get copyToClipboard;

  /// Copied to clipboard snackbar message
  ///
  /// In en, this message translates to:
  /// **'Copied to clipboard'**
  String get copiedToClipboard;

  /// Scribble tooltip
  ///
  /// In en, this message translates to:
  /// **'Scribble'**
  String get scribble;

  /// Revoke link tooltip
  ///
  /// In en, this message translates to:
  /// **'Revoke link'**
  String get revokeLink;

  /// Expand toolbar tooltip
  ///
  /// In en, this message translates to:
  /// **'Expand toolbar'**
  String get expandToolbar;

  /// Collapse toolbar tooltip
  ///
  /// In en, this message translates to:
  /// **'Collapse toolbar'**
  String get collapseToolbar;

  /// Align tooltip
  ///
  /// In en, this message translates to:
  /// **'Align'**
  String get align;

  /// Text size tooltip
  ///
  /// In en, this message translates to:
  /// **'Text Size'**
  String get textSize;

  /// Indent tooltip
  ///
  /// In en, this message translates to:
  /// **'Indent'**
  String get indent;

  /// Attach tooltip
  ///
  /// In en, this message translates to:
  /// **'Attach'**
  String get attach;

  /// Paper color tooltip
  ///
  /// In en, this message translates to:
  /// **'Paper Color'**
  String get paperColor;

  /// Page pattern tooltip
  ///
  /// In en, this message translates to:
  /// **'Page Pattern'**
  String get pagePattern;

  /// More options tooltip
  ///
  /// In en, this message translates to:
  /// **'More options'**
  String get moreOptions;

  /// Move tooltip
  ///
  /// In en, this message translates to:
  /// **'Move'**
  String get move;

  /// View all pages tooltip
  ///
  /// In en, this message translates to:
  /// **'View all pages'**
  String get viewAllPages;

  /// Insert tooltip
  ///
  /// In en, this message translates to:
  /// **'Insert'**
  String get insert;

  /// Import as note tooltip
  ///
  /// In en, this message translates to:
  /// **'Import as Note'**
  String get importAsNote;

  /// Remove device tooltip
  ///
  /// In en, this message translates to:
  /// **'Remove device'**
  String get removeDevice;

  /// Note JSON dialog title
  ///
  /// In en, this message translates to:
  /// **'Note JSON'**
  String get noteJson;

  /// Password reset success message
  ///
  /// In en, this message translates to:
  /// **'Password reset successfully! Please sign in.'**
  String get passwordResetSuccess;

  /// Email verified success message
  ///
  /// In en, this message translates to:
  /// **'Email verified successfully!'**
  String get emailVerifiedSuccess;

  /// Use different account button label
  ///
  /// In en, this message translates to:
  /// **'Use a different account'**
  String get useDifferentAccount;

  /// Recovery successful message
  ///
  /// In en, this message translates to:
  /// **'Recovery successful! Access restored.'**
  String get recoverySuccessful;

  /// Device approved message
  ///
  /// In en, this message translates to:
  /// **'Device approved!'**
  String get deviceApproved;

  /// Waiting for approval message
  ///
  /// In en, this message translates to:
  /// **'Still waiting for approval...'**
  String get waitingForApproval;

  /// Re-approval request sent message
  ///
  /// In en, this message translates to:
  /// **'Re-approval request sent. Waiting for approval...'**
  String get reapprovalRequestSent;

  /// Failed to request re-approval message
  ///
  /// In en, this message translates to:
  /// **'Failed to request re-approval: {error}'**
  String failedReapproval(String error);

  /// Remember device checkbox label
  ///
  /// In en, this message translates to:
  /// **'Remember this device'**
  String get rememberDevice;

  /// Recover with passphrase button label
  ///
  /// In en, this message translates to:
  /// **'Recover with Passphrase'**
  String get recoverWithPassphrase;

  /// Start fresh button label
  ///
  /// In en, this message translates to:
  /// **'Start Fresh'**
  String get startFresh;

  /// Start fresh instead button label
  ///
  /// In en, this message translates to:
  /// **'Start Fresh Instead'**
  String get startFreshInstead;

  /// Request re-approval button label
  ///
  /// In en, this message translates to:
  /// **'Request Re-approval'**
  String get requestReapproval;

  /// Access approved message
  ///
  /// In en, this message translates to:
  /// **'Access approved'**
  String get accessApproved;

  /// Failed to approve message
  ///
  /// In en, this message translates to:
  /// **'Failed to approve: {error}'**
  String failedToApprove(String error);

  /// Access denied message
  ///
  /// In en, this message translates to:
  /// **'Access denied'**
  String get accessDenied;

  /// Failed to deny message
  ///
  /// In en, this message translates to:
  /// **'Failed to deny: {error}'**
  String failedToDeny(String error);

  /// All up to date message
  ///
  /// In en, this message translates to:
  /// **'All up to date'**
  String get allUpToDate;

  /// Upgrade now button label
  ///
  /// In en, this message translates to:
  /// **'Upgrade Now'**
  String get upgradeNow;

  /// Continue trial button label
  ///
  /// In en, this message translates to:
  /// **'Continue Trial'**
  String get continueTrial;

  /// Cancel subscription dialog title/button
  ///
  /// In en, this message translates to:
  /// **'Cancel Subscription'**
  String get cancelSubscription;

  /// Keep subscription button label
  ///
  /// In en, this message translates to:
  /// **'Keep Subscription'**
  String get keepSubscription;

  /// Linking account message
  ///
  /// In en, this message translates to:
  /// **'Linking account...'**
  String get linkingAccount;

  /// Unlink provider dialog title
  ///
  /// In en, this message translates to:
  /// **'Unlink {provider}?'**
  String unlinkProvider(String provider);

  /// Unlinked provider message
  ///
  /// In en, this message translates to:
  /// **'Unlinked {provider}'**
  String unlinkedProvider(String provider);

  /// Successfully linked provider message
  ///
  /// In en, this message translates to:
  /// **'Successfully linked {provider} account'**
  String successfullyLinked(String provider);

  /// Unknown provider error
  ///
  /// In en, this message translates to:
  /// **'Unknown provider: {provider}'**
  String unknownProvider(String provider);

  /// Recovery key title
  ///
  /// In en, this message translates to:
  /// **'Recovery Key'**
  String get recoveryKey;

  /// Recovery key subtitle
  ///
  /// In en, this message translates to:
  /// **'Manage your recovery passphrase'**
  String get manageRecoveryPassphrase;

  /// Enable E2EE button label
  ///
  /// In en, this message translates to:
  /// **'Enable End-to-End Encryption'**
  String get enableE2EE;

  /// Failed to save recovery key error
  ///
  /// In en, this message translates to:
  /// **'Failed to save recovery key: {error}'**
  String failedSaveRecoveryKey(String error);

  /// Recovery success welcome message
  ///
  /// In en, this message translates to:
  /// **'Recovery successful! Welcome back.'**
  String get recoverySuccessWelcome;

  /// Confirm consequences message
  ///
  /// In en, this message translates to:
  /// **'Please confirm that you understand the consequences'**
  String get confirmConsequences;

  /// Account reset success message
  ///
  /// In en, this message translates to:
  /// **'Account reset successfully. Welcome!'**
  String get accountResetSuccess;

  /// Failed to reset account error
  ///
  /// In en, this message translates to:
  /// **'Failed to reset account: {error}'**
  String failedResetAccount(String error);

  /// Error signing out message
  ///
  /// In en, this message translates to:
  /// **'Error signing out: {error}'**
  String errorSigningOut(String error);

  /// Error playing sound message
  ///
  /// In en, this message translates to:
  /// **'Error playing sound: {error}'**
  String errorPlayingSound(String error);

  /// Check nested items dialog title
  ///
  /// In en, this message translates to:
  /// **'Check nested items?'**
  String get checkNestedItems;

  /// Uncheck nested items dialog title
  ///
  /// In en, this message translates to:
  /// **'Uncheck nested items?'**
  String get uncheckNestedItems;

  /// Yes button text
  ///
  /// In en, this message translates to:
  /// **'Yes'**
  String get yes;

  /// No button text
  ///
  /// In en, this message translates to:
  /// **'No'**
  String get no;

  /// Clipboard empty message
  ///
  /// In en, this message translates to:
  /// **'Clipboard is empty'**
  String get clipboardEmpty;

  /// Note deleted permanently message
  ///
  /// In en, this message translates to:
  /// **'Note deleted permanently'**
  String get noteDeletedPermanently;

  /// Reminder removed message
  ///
  /// In en, this message translates to:
  /// **'Reminder removed'**
  String get reminderRemoved;

  /// Reminder completed message
  ///
  /// In en, this message translates to:
  /// **'Reminder completed'**
  String get reminderCompleted;

  /// Reminder set message
  ///
  /// In en, this message translates to:
  /// **'Reminder set'**
  String get reminderSet;

  /// Failed to create image note message
  ///
  /// In en, this message translates to:
  /// **'Failed to create image note'**
  String get failedCreateImageNote;

  /// Error saving sketch with error message
  ///
  /// In en, this message translates to:
  /// **'Error saving sketch: {error}'**
  String errorSavingSketchWithError(String error);

  /// Failed to save note message
  ///
  /// In en, this message translates to:
  /// **'Failed to save the note'**
  String get failedSaveNote;

  /// Failed to save with error message
  ///
  /// In en, this message translates to:
  /// **'Failed to save: {error}'**
  String failedSave(String error);

  /// Copied as format message
  ///
  /// In en, this message translates to:
  /// **'Copied as {format}'**
  String copiedAs(String format);

  /// Failed to copy with error message
  ///
  /// In en, this message translates to:
  /// **'Failed to copy: {error}'**
  String failedCopy(String error);

  /// Pasted as plain text message
  ///
  /// In en, this message translates to:
  /// **'Pasted as plain text'**
  String get pastedAsPlainText;

  /// Failed to paste with error message
  ///
  /// In en, this message translates to:
  /// **'Failed to paste: {error}'**
  String failedPaste(String error);

  /// Content inserted message
  ///
  /// In en, this message translates to:
  /// **'Content inserted'**
  String get contentInserted;

  /// Failed to insert content with error message
  ///
  /// In en, this message translates to:
  /// **'Failed to insert content: {error}'**
  String failedInsertContent(String error);

  /// Action cancelled message
  ///
  /// In en, this message translates to:
  /// **'Action cancelled'**
  String get actionCancelled;

  /// Note locked message
  ///
  /// In en, this message translates to:
  /// **'Note locked'**
  String get noteLocked;

  /// Failed to lock note with error message
  ///
  /// In en, this message translates to:
  /// **'Failed to lock note: {error}'**
  String failedLockNote(String error);

  /// Lock removed message
  ///
  /// In en, this message translates to:
  /// **'Lock removed'**
  String get lockRemoved;

  /// Failed to remove lock with error message
  ///
  /// In en, this message translates to:
  /// **'Failed to remove lock: {error}'**
  String failedRemoveLock(String error);

  /// Note duplicated message
  ///
  /// In en, this message translates to:
  /// **'Note duplicated'**
  String get noteDuplicated;

  /// Error saving note message
  ///
  /// In en, this message translates to:
  /// **'Error saving note'**
  String get errorSavingNote;

  /// Content shared message
  ///
  /// In en, this message translates to:
  /// **'Content shared'**
  String get contentShared;

  /// Failed to share message
  ///
  /// In en, this message translates to:
  /// **'Failed to share'**
  String get failedShare;

  /// Notes label
  ///
  /// In en, this message translates to:
  /// **'Notes'**
  String get notes;

  /// All notes filter
  ///
  /// In en, this message translates to:
  /// **'All Notes'**
  String get allNotes;

  /// Archived notes filter
  ///
  /// In en, this message translates to:
  /// **'Archived'**
  String get archivedNotes;

  /// Deleted notes filter
  ///
  /// In en, this message translates to:
  /// **'Deleted'**
  String get deletedNotes;

  /// Pinned notes section
  ///
  /// In en, this message translates to:
  /// **'Pinned'**
  String get pinnedNotes;

  /// Other notes section
  ///
  /// In en, this message translates to:
  /// **'Others'**
  String get otherNotes;

  /// Empty state message
  ///
  /// In en, this message translates to:
  /// **'No notes yet'**
  String get noNotes;

  /// Empty archived state message
  ///
  /// In en, this message translates to:
  /// **'No archived notes'**
  String get noArchivedNotes;

  /// Empty deleted state message
  ///
  /// In en, this message translates to:
  /// **'No deleted notes'**
  String get noDeletedNotes;

  /// Search notes hint
  ///
  /// In en, this message translates to:
  /// **'Search notes'**
  String get searchNotes;

  /// Number of notes selected
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 note selected} other{{count} notes selected}}'**
  String nSelectedNotes(int count);

  /// Delete note dialog title
  ///
  /// In en, this message translates to:
  /// **'Delete Note'**
  String get deleteNote;

  /// Delete notes dialog title
  ///
  /// In en, this message translates to:
  /// **'Delete Notes'**
  String get deleteNotes;

  /// Move to trash action
  ///
  /// In en, this message translates to:
  /// **'Move to trash'**
  String get moveToTrash;

  /// Delete permanently action
  ///
  /// In en, this message translates to:
  /// **'Delete permanently'**
  String get deletePermanently;

  /// Pin note action
  ///
  /// In en, this message translates to:
  /// **'Pin'**
  String get pinNote;

  /// Unpin note action
  ///
  /// In en, this message translates to:
  /// **'Unpin'**
  String get unpinNote;

  /// New note button
  ///
  /// In en, this message translates to:
  /// **'New Note'**
  String get newNote;

  /// New sketch button
  ///
  /// In en, this message translates to:
  /// **'New Sketch'**
  String get newSketch;

  /// New folder option
  ///
  /// In en, this message translates to:
  /// **'New Folder'**
  String get newFolder;

  /// Rename folder option
  ///
  /// In en, this message translates to:
  /// **'Rename Folder'**
  String get renameFolder;

  /// Delete folder option
  ///
  /// In en, this message translates to:
  /// **'Delete Folder'**
  String get deleteFolder;

  /// Folder name field hint
  ///
  /// In en, this message translates to:
  /// **'Folder name'**
  String get folderName;

  /// Camera option
  ///
  /// In en, this message translates to:
  /// **'Camera'**
  String get camera;

  /// Gallery option
  ///
  /// In en, this message translates to:
  /// **'Gallery'**
  String get gallery;

  /// Audio recorder option
  ///
  /// In en, this message translates to:
  /// **'Audio Recorder'**
  String get audioRecorder;

  /// Import file option
  ///
  /// In en, this message translates to:
  /// **'Import File'**
  String get importFile;

  /// Language setting label
  ///
  /// In en, this message translates to:
  /// **'Language'**
  String get language;

  /// System default language option
  ///
  /// In en, this message translates to:
  /// **'System Default'**
  String get systemDefault;

  /// Select language dialog title
  ///
  /// In en, this message translates to:
  /// **'Select Language'**
  String get selectLanguage;

  /// English language name
  ///
  /// In en, this message translates to:
  /// **'English'**
  String get english;

  /// Japanese language name
  ///
  /// In en, this message translates to:
  /// **'日本語'**
  String get japanese;

  /// Korean language name
  ///
  /// In en, this message translates to:
  /// **'한국어'**
  String get korean;

  /// Indonesian language name
  ///
  /// In en, this message translates to:
  /// **'Bahasa Indonesia'**
  String get indonesian;

  /// Brazilian Portuguese language name
  ///
  /// In en, this message translates to:
  /// **'Português (Brasil)'**
  String get portugueseBrazil;

  /// Chinese language name
  ///
  /// In en, this message translates to:
  /// **'中文'**
  String get chinese;

  /// Today label
  ///
  /// In en, this message translates to:
  /// **'Today'**
  String get today;

  /// Tomorrow label
  ///
  /// In en, this message translates to:
  /// **'Tomorrow'**
  String get tomorrow;

  /// Next week label
  ///
  /// In en, this message translates to:
  /// **'Next week'**
  String get nextWeek;

  /// Next month label
  ///
  /// In en, this message translates to:
  /// **'Next month'**
  String get nextMonth;

  /// Pick date and time option
  ///
  /// In en, this message translates to:
  /// **'Pick date & time'**
  String get pickDateTime;

  /// Time label
  ///
  /// In en, this message translates to:
  /// **'Time'**
  String get time;

  /// Empty reminder time field hint
  ///
  /// In en, this message translates to:
  /// **'Select time'**
  String get selectTime;

  /// All-day reminder option
  ///
  /// In en, this message translates to:
  /// **'All day'**
  String get allDay;

  /// Date label
  ///
  /// In en, this message translates to:
  /// **'Date'**
  String get date;

  /// Repeat label
  ///
  /// In en, this message translates to:
  /// **'Repeat'**
  String get repeat;

  /// Reminder repeat frequency field label
  ///
  /// In en, this message translates to:
  /// **'Frequency'**
  String get frequency;

  /// Never repeat option
  ///
  /// In en, this message translates to:
  /// **'Never'**
  String get never;

  /// Daily repeat option
  ///
  /// In en, this message translates to:
  /// **'Daily'**
  String get daily;

  /// Weekly repeat option
  ///
  /// In en, this message translates to:
  /// **'Weekly'**
  String get weekly;

  /// Monthly repeat option
  ///
  /// In en, this message translates to:
  /// **'Monthly'**
  String get monthly;

  /// Yearly repeat option
  ///
  /// In en, this message translates to:
  /// **'Yearly'**
  String get yearly;

  /// Snooze button
  ///
  /// In en, this message translates to:
  /// **'Snooze'**
  String get snooze;

  /// 5 minutes option
  ///
  /// In en, this message translates to:
  /// **'5 minutes'**
  String get fiveMinutes;

  /// 10 minutes option
  ///
  /// In en, this message translates to:
  /// **'10 minutes'**
  String get tenMinutes;

  /// 30 minutes option
  ///
  /// In en, this message translates to:
  /// **'30 minutes'**
  String get thirtyMinutes;

  /// 1 hour option
  ///
  /// In en, this message translates to:
  /// **'1 hour'**
  String get oneHour;

  /// Grid view option
  ///
  /// In en, this message translates to:
  /// **'Grid view'**
  String get gridView;

  /// List view option
  ///
  /// In en, this message translates to:
  /// **'List view'**
  String get listView;

  /// Gallery view option
  ///
  /// In en, this message translates to:
  /// **'Gallery view'**
  String get galleryView;

  /// Undo tooltip
  ///
  /// In en, this message translates to:
  /// **'Undo'**
  String get undo;

  /// Redo tooltip
  ///
  /// In en, this message translates to:
  /// **'Redo'**
  String get redo;

  /// Bold tooltip
  ///
  /// In en, this message translates to:
  /// **'Bold'**
  String get bold;

  /// Italic tooltip
  ///
  /// In en, this message translates to:
  /// **'Italic'**
  String get italic;

  /// Underline tooltip
  ///
  /// In en, this message translates to:
  /// **'Underline'**
  String get underline;

  /// Strikethrough tooltip
  ///
  /// In en, this message translates to:
  /// **'Strikethrough'**
  String get strikethrough;

  /// Bullet list tooltip
  ///
  /// In en, this message translates to:
  /// **'Bullet list'**
  String get bulletList;

  /// Numbered list tooltip
  ///
  /// In en, this message translates to:
  /// **'Numbered list'**
  String get numberedList;

  /// Checklist tooltip
  ///
  /// In en, this message translates to:
  /// **'Checklist'**
  String get checklist;

  /// Action that opens the focused checklist editor
  ///
  /// In en, this message translates to:
  /// **'Open list view'**
  String get openChecklistView;

  /// Converts a checklist item subtree into rich-text paragraphs
  ///
  /// In en, this message translates to:
  /// **'Convert to normal text'**
  String get convertToNormalText;

  /// Converts the focused checklist block into rich-text paragraphs
  ///
  /// In en, this message translates to:
  /// **'Convert entire checklist to text'**
  String get convertEntireChecklistToText;

  /// Explains why a mixed document cannot open in the focused checklist editor
  ///
  /// In en, this message translates to:
  /// **'Focused list view is available only when every line is a checklist item.'**
  String get focusedChecklistRequiresChecklistOnly;

  /// Explains that focused checklist view does not support embeds or incompatible blocks
  ///
  /// In en, this message translates to:
  /// **'Attachments and block formatting are available only in the rich-text editor.'**
  String get focusedChecklistUnsupportedContent;

  /// Guidance for malformed checklist content that cannot safely open in focused view
  ///
  /// In en, this message translates to:
  /// **'This checklist can’t be opened in focused view. Continue editing it here.'**
  String get focusedChecklistInvalidContent;

  /// Heading for completed checklist items
  ///
  /// In en, this message translates to:
  /// **'Completed'**
  String get completedTasks;

  /// Action that removes all completed root checklist items
  ///
  /// In en, this message translates to:
  /// **'Clear completed'**
  String get clearCompletedTasks;

  /// Move a checklist item one nesting level outward
  ///
  /// In en, this message translates to:
  /// **'Outdent'**
  String get outdent;

  /// Shown when an embed is pasted into the focused checklist editor
  ///
  /// In en, this message translates to:
  /// **'Attachments can only be pasted in the rich-text editor.'**
  String get checklistEmbedUnsupported;

  /// Conflict warning in the focused checklist editor
  ///
  /// In en, this message translates to:
  /// **'This note changed elsewhere. Reload it or keep your local edits.'**
  String get checklistChangedElsewhere;

  /// Reload externally changed checklist content
  ///
  /// In en, this message translates to:
  /// **'Reload'**
  String get reloadChecklist;

  /// Resolve a checklist conflict in favor of local changes
  ///
  /// In en, this message translates to:
  /// **'Keep my edits'**
  String get keepChecklistEdits;

  /// Quote tooltip
  ///
  /// In en, this message translates to:
  /// **'Quote'**
  String get quote;

  /// Code block tooltip
  ///
  /// In en, this message translates to:
  /// **'Code block'**
  String get codeBlock;

  /// Text color tooltip
  ///
  /// In en, this message translates to:
  /// **'Text color'**
  String get textColor;

  /// Highlight color tooltip
  ///
  /// In en, this message translates to:
  /// **'Highlight color'**
  String get highlightColor;

  /// Align left option
  ///
  /// In en, this message translates to:
  /// **'Align left'**
  String get alignLeft;

  /// Align center option
  ///
  /// In en, this message translates to:
  /// **'Align center'**
  String get alignCenter;

  /// Align right option
  ///
  /// In en, this message translates to:
  /// **'Align right'**
  String get alignRight;

  /// Justify option
  ///
  /// In en, this message translates to:
  /// **'Justify'**
  String get alignJustify;

  /// Increase indent option
  ///
  /// In en, this message translates to:
  /// **'Increase indent'**
  String get increaseIndent;

  /// Decrease indent option
  ///
  /// In en, this message translates to:
  /// **'Decrease indent'**
  String get decreaseIndent;

  /// Heading 1 option
  ///
  /// In en, this message translates to:
  /// **'Heading 1'**
  String get heading1;

  /// Heading 2 option
  ///
  /// In en, this message translates to:
  /// **'Heading 2'**
  String get heading2;

  /// Heading 3 option
  ///
  /// In en, this message translates to:
  /// **'Heading 3'**
  String get heading3;

  /// Normal text option
  ///
  /// In en, this message translates to:
  /// **'Normal text'**
  String get normalText;

  /// Pen tool
  ///
  /// In en, this message translates to:
  /// **'Pen'**
  String get pen;

  /// Pencil tool
  ///
  /// In en, this message translates to:
  /// **'Pencil'**
  String get pencil;

  /// Brush tool
  ///
  /// In en, this message translates to:
  /// **'Brush'**
  String get brush;

  /// Highlighter tool
  ///
  /// In en, this message translates to:
  /// **'Highlighter'**
  String get highlighter;

  /// Eraser tool
  ///
  /// In en, this message translates to:
  /// **'Eraser'**
  String get eraser;

  /// Lasso tool
  ///
  /// In en, this message translates to:
  /// **'Lasso'**
  String get lasso;

  /// Add page button
  ///
  /// In en, this message translates to:
  /// **'Add page'**
  String get addPage;

  /// Delete page button
  ///
  /// In en, this message translates to:
  /// **'Delete page'**
  String get deletePage;

  /// Page label
  ///
  /// In en, this message translates to:
  /// **'Page'**
  String get page;

  /// Page number label
  ///
  /// In en, this message translates to:
  /// **'Page {number}'**
  String pageNumber(int number);

  /// Connected accounts section title
  ///
  /// In en, this message translates to:
  /// **'Connected Accounts'**
  String get connectedAccounts;

  /// Subscription section title
  ///
  /// In en, this message translates to:
  /// **'Subscription'**
  String get subscription;

  /// Free plan label
  ///
  /// In en, this message translates to:
  /// **'Free'**
  String get free;

  /// Pro plan label
  ///
  /// In en, this message translates to:
  /// **'Pro'**
  String get pro;

  /// Trial label
  ///
  /// In en, this message translates to:
  /// **'Trial'**
  String get trial;

  /// Trial ends message
  ///
  /// In en, this message translates to:
  /// **'Trial ends in {days} days'**
  String trialEndsIn(int days);

  /// Devices section title
  ///
  /// In en, this message translates to:
  /// **'Devices'**
  String get devices;

  /// This device label
  ///
  /// In en, this message translates to:
  /// **'This device'**
  String get thisDevice;

  /// Last active time
  ///
  /// In en, this message translates to:
  /// **'Last active: {time}'**
  String lastActive(String time);

  /// Pending approval label
  ///
  /// In en, this message translates to:
  /// **'Pending approval'**
  String get pendingApproval;

  /// Security section title
  ///
  /// In en, this message translates to:
  /// **'Security'**
  String get security;

  /// E2EE section title
  ///
  /// In en, this message translates to:
  /// **'End-to-End Encryption'**
  String get endToEndEncryption;

  /// E2EE enabled status
  ///
  /// In en, this message translates to:
  /// **'Enabled'**
  String get e2eeEnabled;

  /// E2EE disabled status
  ///
  /// In en, this message translates to:
  /// **'Not enabled'**
  String get e2eeDisabled;

  /// Setup recovery key page title
  ///
  /// In en, this message translates to:
  /// **'Set Up Recovery Key'**
  String get setupRecoveryKey;

  /// Change recovery key dialog title
  ///
  /// In en, this message translates to:
  /// **'Change Recovery Key'**
  String get changeRecoveryKey;

  /// Verify recovery key dialog title
  ///
  /// In en, this message translates to:
  /// **'Verify Recovery Key'**
  String get verifyRecoveryKey;

  /// Error label
  ///
  /// In en, this message translates to:
  /// **'Error'**
  String get error;

  /// Error with message
  ///
  /// In en, this message translates to:
  /// **'Error: {message}'**
  String errorWithMessage(String message);

  /// Loading message
  ///
  /// In en, this message translates to:
  /// **'Loading...'**
  String get loading;

  /// Syncing message
  ///
  /// In en, this message translates to:
  /// **'Syncing...'**
  String get syncing;

  /// Sync complete message
  ///
  /// In en, this message translates to:
  /// **'Sync complete'**
  String get syncComplete;

  /// Sync failed message
  ///
  /// In en, this message translates to:
  /// **'Sync failed'**
  String get syncFailed;

  /// Offline status
  ///
  /// In en, this message translates to:
  /// **'Offline'**
  String get offline;

  /// Online status
  ///
  /// In en, this message translates to:
  /// **'Online'**
  String get online;

  /// Get the app dialog title
  ///
  /// In en, this message translates to:
  /// **'Get the App'**
  String get getApp;

  /// Session expired message
  ///
  /// In en, this message translates to:
  /// **'Your session has expired. Please sign in again.'**
  String get sessionExpired;

  /// Confirm sign out message
  ///
  /// In en, this message translates to:
  /// **'Are you sure you want to sign out?'**
  String get confirmSignOut;

  /// Unsynced changes warning
  ///
  /// In en, this message translates to:
  /// **'You have unsynced changes that will be lost.'**
  String get unsyncedChanges;

  /// Delete confirmation message
  ///
  /// In en, this message translates to:
  /// **'Are you sure you want to delete this?'**
  String get deleteConfirmation;

  /// Permanent action warning
  ///
  /// In en, this message translates to:
  /// **'This action cannot be undone.'**
  String get permanentAction;

  /// Encrypt note content toggle title
  ///
  /// In en, this message translates to:
  /// **'Encrypt Note Content'**
  String get encryptNoteContent;

  /// Encrypt note content toggle subtitle
  ///
  /// In en, this message translates to:
  /// **'Encrypt notes in local database'**
  String get encryptNotesInDatabase;

  /// Encrypt attachments toggle title
  ///
  /// In en, this message translates to:
  /// **'Encrypt Attachments'**
  String get encryptAttachments;

  /// Encrypt attachments toggle subtitle
  ///
  /// In en, this message translates to:
  /// **'Encrypt images, sketches, and files'**
  String get encryptImagesSketchesFiles;

  /// Local encryption info text
  ///
  /// In en, this message translates to:
  /// **'Local encryption protects your data if your device is compromised. Uses AES-256-GCM encryption.'**
  String get localEncryptionInfo;

  /// Locked notes section title
  ///
  /// In en, this message translates to:
  /// **'Locked Notes'**
  String get lockedNotes;

  /// Forget password on close subtitle
  ///
  /// In en, this message translates to:
  /// **'Require re-entering PIN when reopening a locked note'**
  String get requireReenterPin;

  /// Help subtitle
  ///
  /// In en, this message translates to:
  /// **'FAQ and contact support'**
  String get faqAndSupport;

  /// About subtitle
  ///
  /// In en, this message translates to:
  /// **'App info and credits'**
  String get appInfoCredits;

  /// Advanced settings section title
  ///
  /// In en, this message translates to:
  /// **'Advanced Settings'**
  String get advancedSettings;

  /// Speech recognition model settings title
  ///
  /// In en, this message translates to:
  /// **'Speech Recognition Model'**
  String get speechRecognitionModel;

  /// Whisper model downloaded with size
  ///
  /// In en, this message translates to:
  /// **'Downloaded ({size})'**
  String whisperModelDownloaded(String size);

  /// Whisper model not downloaded
  ///
  /// In en, this message translates to:
  /// **'Not downloaded ({size}) - tap to download'**
  String whisperModelNotDownloaded(String size);

  /// Delete whisper model confirmation
  ///
  /// In en, this message translates to:
  /// **'Delete the speech recognition model? You can re-download it later.'**
  String get deleteWhisperModelConfirm;

  /// Whisper model deleted message
  ///
  /// In en, this message translates to:
  /// **'Speech recognition model deleted'**
  String get whisperModelDeleted;

  /// Delete model button tooltip
  ///
  /// In en, this message translates to:
  /// **'Delete Model'**
  String get deleteModel;

  /// Download button text
  ///
  /// In en, this message translates to:
  /// **'Download'**
  String get download;

  /// Nerd stats subtitle
  ///
  /// In en, this message translates to:
  /// **'View database and sync statistics'**
  String get viewDatabaseStats;

  /// Select dark theme dialog title
  ///
  /// In en, this message translates to:
  /// **'Select Dark Theme'**
  String get selectDarkTheme;

  /// Select light theme dialog title
  ///
  /// In en, this message translates to:
  /// **'Select Light Theme'**
  String get selectLightTheme;

  /// Encrypting notes progress message
  ///
  /// In en, this message translates to:
  /// **'Encrypting existing notes...'**
  String get encryptingNotes;

  /// Note encryption enabled success message with count
  ///
  /// In en, this message translates to:
  /// **'Note encryption enabled. {count} notes encrypted.'**
  String noteEncryptionEnabled(int count);

  /// Note encryption enabled success message without count
  ///
  /// In en, this message translates to:
  /// **'Note encryption enabled.'**
  String get noteEncryptionEnabledSimple;

  /// Error encrypting notes message
  ///
  /// In en, this message translates to:
  /// **'Error encrypting notes: {error}'**
  String errorEncryptingNotes(String error);

  /// Note encryption disabled message
  ///
  /// In en, this message translates to:
  /// **'Note encryption disabled.'**
  String get noteEncryptionDisabled;

  /// File encryption enabled message
  ///
  /// In en, this message translates to:
  /// **'File encryption enabled. New attachments will be encrypted.'**
  String get fileEncryptionEnabled;

  /// File encryption disabled message
  ///
  /// In en, this message translates to:
  /// **'File encryption disabled.'**
  String get fileEncryptionDisabled;

  /// Local data protection subtitle alternative
  ///
  /// In en, this message translates to:
  /// **'Encrypt data stored on this device'**
  String get encryptDataOnDevice;

  /// Sign in cancelled snackbar message
  ///
  /// In en, this message translates to:
  /// **'Sign in cancelled'**
  String get signInCancelledMessage;

  /// Starting sign in status message
  ///
  /// In en, this message translates to:
  /// **'Starting sign in...'**
  String get startingSignIn;

  /// Continue with Google button text
  ///
  /// In en, this message translates to:
  /// **'Continue with Google'**
  String get continueWithGoogle;

  /// Continue with Apple button text
  ///
  /// In en, this message translates to:
  /// **'Continue with Apple'**
  String get continueWithApple;

  /// Sign in with Apple tooltip
  ///
  /// In en, this message translates to:
  /// **'Sign in with Apple'**
  String get signInWithApple;

  /// Sign in method hint text
  ///
  /// In en, this message translates to:
  /// **'Choose your preferred sign-in method'**
  String get chooseSignInMethod;

  /// Login page tagline
  ///
  /// In en, this message translates to:
  /// **'Your notes, secured and synced'**
  String get yourNoteSecuredAndSynced;

  /// E2EE feature title on login page
  ///
  /// In en, this message translates to:
  /// **'End-to-End Encryption'**
  String get endToEndEncryptionFeature;

  /// E2EE feature description on login page
  ///
  /// In en, this message translates to:
  /// **'Your notes are encrypted on your device before syncing. Only you can read them — not even we can access your data.'**
  String get endToEndEncryptionDescription;

  /// Sync feature title on login page
  ///
  /// In en, this message translates to:
  /// **'Seamless Sync'**
  String get seamlessSync;

  /// Sync feature description on login page
  ///
  /// In en, this message translates to:
  /// **'Access your notes on any device. Changes sync instantly and securely across all your devices.'**
  String get seamlessSyncDescription;

  /// Rich formatting feature title on login page
  ///
  /// In en, this message translates to:
  /// **'Rich Formatting'**
  String get richFormatting;

  /// Rich formatting feature description on login page
  ///
  /// In en, this message translates to:
  /// **'Express yourself with rich text, checklists, images, drawings, and voice notes. Your notes, your way.'**
  String get richFormattingDescription;

  /// Got it button text
  ///
  /// In en, this message translates to:
  /// **'Got it'**
  String get gotIt;

  /// Or divider text
  ///
  /// In en, this message translates to:
  /// **'or'**
  String get or;

  /// Sign in with Google tooltip
  ///
  /// In en, this message translates to:
  /// **'Sign in with Google'**
  String get signInWithGoogle;

  /// Reset password page title
  ///
  /// In en, this message translates to:
  /// **'Reset Password'**
  String get resetPassword;

  /// Reset password description
  ///
  /// In en, this message translates to:
  /// **'Enter your email address and we\'ll send you a verification code to reset your password.'**
  String get resetPasswordDescription;

  /// Send verification code button text
  ///
  /// In en, this message translates to:
  /// **'Send Verification Code'**
  String get sendVerificationCode;

  /// Sending status text
  ///
  /// In en, this message translates to:
  /// **'Sending...'**
  String get sending;

  /// Enter verification code title
  ///
  /// In en, this message translates to:
  /// **'Enter Verification Code'**
  String get enterVerificationCode;

  /// Enter code description
  ///
  /// In en, this message translates to:
  /// **'Enter the 6-digit code sent to:'**
  String get enterCodeSentTo;

  /// Validation error for incomplete OTP
  ///
  /// In en, this message translates to:
  /// **'Please enter the complete 6-digit code'**
  String get pleaseEnterCompleteCode;

  /// Verifying status text
  ///
  /// In en, this message translates to:
  /// **'Verifying...'**
  String get verifying;

  /// Continue button text
  ///
  /// In en, this message translates to:
  /// **'Continue'**
  String get continue_;

  /// Resend code button text
  ///
  /// In en, this message translates to:
  /// **'Resend code'**
  String get resendCode;

  /// Resend code countdown text
  ///
  /// In en, this message translates to:
  /// **'Resend code in {seconds}s'**
  String resendCodeIn(int seconds);

  /// Code expiration note
  ///
  /// In en, this message translates to:
  /// **'Code expires in 10 minutes'**
  String get codeExpiresIn;

  /// Create new password title
  ///
  /// In en, this message translates to:
  /// **'Create New Password'**
  String get createNewPassword;

  /// Enter new password description
  ///
  /// In en, this message translates to:
  /// **'Enter a new password for your account.'**
  String get enterNewPasswordDescription;

  /// New password field hint
  ///
  /// In en, this message translates to:
  /// **'Enter new password'**
  String get enterNewPasswordHint;

  /// Confirm new password field hint
  ///
  /// In en, this message translates to:
  /// **'Re-enter new password'**
  String get reenterNewPasswordHint;

  /// Resetting password status
  ///
  /// In en, this message translates to:
  /// **'Resetting Password...'**
  String get resettingPassword;

  /// Please enter new password validation error
  ///
  /// In en, this message translates to:
  /// **'Please enter a new password'**
  String get pleaseEnterNewPassword;

  /// Email address validation error
  ///
  /// In en, this message translates to:
  /// **'Please enter your email address'**
  String get pleaseEnterEmailAddress;

  /// Valid email validation error
  ///
  /// In en, this message translates to:
  /// **'Please enter a valid email address'**
  String get pleaseEnterValidEmail;

  /// Failed to send verification code error
  ///
  /// In en, this message translates to:
  /// **'Failed to send verification code. Please try again.'**
  String get failedSendVerificationCode;

  /// Invalid verification code error
  ///
  /// In en, this message translates to:
  /// **'Invalid verification code'**
  String get invalidVerificationCode;

  /// Verification failed error
  ///
  /// In en, this message translates to:
  /// **'Verification failed. Please try again.'**
  String get verificationFailed;

  /// Password reset failed error
  ///
  /// In en, this message translates to:
  /// **'Password reset failed. Please try again.'**
  String get passwordResetFailed;

  /// Verify your email title
  ///
  /// In en, this message translates to:
  /// **'Verify Your Email'**
  String get verifyYourEmail;

  /// Sending verification code status
  ///
  /// In en, this message translates to:
  /// **'Sending verification code...'**
  String get sendingVerificationCode;

  /// Email verified success message
  ///
  /// In en, this message translates to:
  /// **'Email verified successfully!'**
  String get emailVerifiedSuccessfully;

  /// Device revoked title
  ///
  /// In en, this message translates to:
  /// **'Device Revoked'**
  String get deviceRevoked;

  /// Waiting for approval title
  ///
  /// In en, this message translates to:
  /// **'Waiting for Approval'**
  String get waitingForApprovalTitle;

  /// Device revoked description
  ///
  /// In en, this message translates to:
  /// **'This device has been revoked and can no longer access your notes. Please sign in again from an approved device to re-authorize.'**
  String get deviceRevokedDescription;

  /// Please approve from text
  ///
  /// In en, this message translates to:
  /// **'Please approve from:'**
  String get pleaseApproveFrom;

  /// Waiting for approval from another device text
  ///
  /// In en, this message translates to:
  /// **'Waiting for approval from another device...'**
  String get waitingForApprovalFromDevice;

  /// Remember this device checkbox label
  ///
  /// In en, this message translates to:
  /// **'Remember this device'**
  String get rememberThisDevice;

  /// Device removed on sign out description
  ///
  /// In en, this message translates to:
  /// **'If unchecked, this device will be removed when you sign out'**
  String get deviceRemovedOnSignOut;

  /// Checking status text
  ///
  /// In en, this message translates to:
  /// **'Checking...'**
  String get checkingStatus;

  /// Check status button text
  ///
  /// In en, this message translates to:
  /// **'Check Status'**
  String get checkStatus;

  /// Cancel request button text
  ///
  /// In en, this message translates to:
  /// **'Cancel Request'**
  String get cancelRequest;

  /// Please wait text
  ///
  /// In en, this message translates to:
  /// **'Please wait...'**
  String get pleaseWait;

  /// Update recovery key page title
  ///
  /// In en, this message translates to:
  /// **'Update Recovery Key'**
  String get updateRecoveryKey;

  /// Recovery passphrase description
  ///
  /// In en, this message translates to:
  /// **'Create a recovery passphrase that can restore access to your notes if you lose all your devices.'**
  String get recoveryPassphraseDescription;

  /// Recovery passphrase warning
  ///
  /// In en, this message translates to:
  /// **'Store this passphrase securely. Without it, you cannot recover your notes if you lose all devices.'**
  String get recoveryPassphraseWarning;

  /// Strong passphrase hint
  ///
  /// In en, this message translates to:
  /// **'Enter a strong passphrase'**
  String get enterAStrongPassphrase;

  /// Please enter passphrase validation error
  ///
  /// In en, this message translates to:
  /// **'Please enter a passphrase'**
  String get pleaseEnterPassphrase;

  /// Passphrase minimum length error
  ///
  /// In en, this message translates to:
  /// **'Passphrase must be at least 6 characters'**
  String get passphraseMinLength;

  /// Passphrases do not match error
  ///
  /// In en, this message translates to:
  /// **'Passphrases do not match'**
  String get passphrasesDoNotMatch;

  /// Passphrase too common warning
  ///
  /// In en, this message translates to:
  /// **'This passphrase is too common and easy to guess'**
  String get passphraseTooCommon;

  /// Passphrase strength advice
  ///
  /// In en, this message translates to:
  /// **'Consider adding uppercase, lowercase, numbers, or symbols for a stronger passphrase'**
  String get passphraseStrengthAdvice;

  /// Saving status text
  ///
  /// In en, this message translates to:
  /// **'Saving...'**
  String get saving;

  /// Save recovery key button text
  ///
  /// In en, this message translates to:
  /// **'Save Recovery Key'**
  String get saveRecoveryKey;

  /// Password short warning
  ///
  /// In en, this message translates to:
  /// **'Password is quite short. Consider using at least 6 characters.'**
  String get passwordShortWarning;

  /// Password longer advice
  ///
  /// In en, this message translates to:
  /// **'Consider using a longer password for better security.'**
  String get passwordLongerAdvice;

  /// Password mix advice
  ///
  /// In en, this message translates to:
  /// **'Consider adding both letters and numbers for stronger security.'**
  String get passwordMixAdvice;

  /// App version display
  ///
  /// In en, this message translates to:
  /// **'Version {version} ({buildNumber})'**
  String version(String version, String buildNumber);

  /// Source availability section title
  ///
  /// In en, this message translates to:
  /// **'Source Available'**
  String get openSource;

  /// Source availability and license description
  ///
  /// In en, this message translates to:
  /// **'Inspect the source under CC BY-NC 4.0. Commercial reuse is restricted, so this is source-available rather than OSI-approved open source.'**
  String get openSourceDescription;

  /// FAQ section title
  ///
  /// In en, this message translates to:
  /// **'Frequently Asked Questions'**
  String get frequentlyAskedQuestions;

  /// Need more help section title
  ///
  /// In en, this message translates to:
  /// **'Need More Help?'**
  String get needMoreHelp;

  /// Need more help description
  ///
  /// In en, this message translates to:
  /// **'If you have any questions or need assistance, feel free to reach out to us.'**
  String get needMoreHelpDescription;

  /// Delete image dialog title
  ///
  /// In en, this message translates to:
  /// **'Delete Image'**
  String get deleteImage;

  /// Delete image confirmation message
  ///
  /// In en, this message translates to:
  /// **'Are you sure you want to delete this image?'**
  String get deleteImageConfirmation;

  /// Import as note tooltip
  ///
  /// In en, this message translates to:
  /// **'Import as Note'**
  String get importAsNoteTooltip;

  /// Insert tooltip
  ///
  /// In en, this message translates to:
  /// **'Insert'**
  String get insertTooltip;

  /// Failed to import error message
  ///
  /// In en, this message translates to:
  /// **'Failed to import: {error}'**
  String failedToImport(String error);

  /// Notes stat label
  ///
  /// In en, this message translates to:
  /// **'Notes'**
  String get notes_;

  /// Media stat label
  ///
  /// In en, this message translates to:
  /// **'Media'**
  String get media;

  /// Plan name display
  ///
  /// In en, this message translates to:
  /// **'{planName} Plan'**
  String plan(String planName);

  /// Free trial active label
  ///
  /// In en, this message translates to:
  /// **'Free Trial Active'**
  String get freeTrialActive;

  /// Expiration message with days left
  ///
  /// In en, this message translates to:
  /// **'Expires {date} ({days} days left)'**
  String expiresOnDaysLeft(String date, int days);

  /// Trial features message
  ///
  /// In en, this message translates to:
  /// **'Enjoy all Pro features during your trial!'**
  String get enjoyProFeatures;

  /// Billing label
  ///
  /// In en, this message translates to:
  /// **'Billing'**
  String get billing;

  /// Renews label
  ///
  /// In en, this message translates to:
  /// **'Renews'**
  String get renews;

  /// Expires label
  ///
  /// In en, this message translates to:
  /// **'Expires'**
  String get expires;

  /// Monthly subscription label
  ///
  /// In en, this message translates to:
  /// **'Monthly subscription'**
  String get monthlySubscription;

  /// Yearly subscription label
  ///
  /// In en, this message translates to:
  /// **'Yearly subscription'**
  String get yearlySubscription;

  /// Free trial label
  ///
  /// In en, this message translates to:
  /// **'Free Trial'**
  String get freeTrial;

  /// Subscription grace period warning
  ///
  /// In en, this message translates to:
  /// **'Your subscription is in a grace period. Please update your payment method.'**
  String get subscriptionInGracePeriod;

  /// Subscription cancelled info message
  ///
  /// In en, this message translates to:
  /// **'Your Pro access will end on {date}. You can subscribe again after it expires.'**
  String subscriptionCancelledInfo(String date);

  /// Subscription cancelled title
  ///
  /// In en, this message translates to:
  /// **'Subscription Cancelled'**
  String get subscriptionCancelled;

  /// Upgrade to pro description
  ///
  /// In en, this message translates to:
  /// **'Upgrade to Pro for unlimited locked notes, cloud sync, and more.'**
  String get upgradeToProDescription;

  /// Cancelling subscription status
  ///
  /// In en, this message translates to:
  /// **'Cancelling...'**
  String get cancellingSubscription;

  /// Manage subscription button
  ///
  /// In en, this message translates to:
  /// **'Manage Subscription'**
  String get manageSubscription;

  /// Renew cancelled subscription button
  ///
  /// In en, this message translates to:
  /// **'Renew Subscription'**
  String get renewSubscription;

  /// Info text explaining automatic restore on paywall
  ///
  /// In en, this message translates to:
  /// **'Subscribing will automatically restore any active subscriptions or previous purchases.'**
  String get restoreInfoText;

  /// Cancel subscription confirmation message
  ///
  /// In en, this message translates to:
  /// **'Are you sure you want to cancel your subscription?\n\nYour subscription will remain active until the end of the current billing period. After that, you will lose access to Pro features.'**
  String get cancelSubscriptionConfirmation;

  /// Snackbar message shown after returning from platform subscription management
  ///
  /// In en, this message translates to:
  /// **'If you made changes, they may take a moment to appear.'**
  String get subscriptionChangesMayTakeMoment;

  /// Snackbar message when subscription is restored
  ///
  /// In en, this message translates to:
  /// **'Your subscription has been restored!'**
  String get subscriptionRestored;

  /// Snackbar message when user already has active subscription
  ///
  /// In en, this message translates to:
  /// **'You already have an active subscription.'**
  String get subscriptionAlreadyActive;

  /// Snackbar message when subscription is activated
  ///
  /// In en, this message translates to:
  /// **'Subscription activated successfully!'**
  String get subscriptionActivated;

  /// Snackbar message when purchase is cancelled by user
  ///
  /// In en, this message translates to:
  /// **'Purchase was cancelled.'**
  String get purchaseCancelled;

  /// Snackbar message when payment fails
  ///
  /// In en, this message translates to:
  /// **'Payment failed.'**
  String get paymentFailed;

  /// Error when unable to open platform subscription management
  ///
  /// In en, this message translates to:
  /// **'Could not open subscription management.'**
  String get couldNotOpenSubscriptionManagement;

  /// Support guidance when a legacy subscription has no known billing provider
  ///
  /// In en, this message translates to:
  /// **'We could not identify your billing provider. Contact contact@betterkeep.app for help.'**
  String get subscriptionProviderUnknownContactSupport;

  /// Message shown when redirecting to store subscription management
  ///
  /// In en, this message translates to:
  /// **'Manage your subscription in the {store}.'**
  String manageSubscriptionInStore(String store);

  /// Button label when price loading fails
  ///
  /// In en, this message translates to:
  /// **'Loading failed — Try again'**
  String get loadingFailedTryAgain;

  /// Button to reload subscription prices
  ///
  /// In en, this message translates to:
  /// **'Reload prices'**
  String get reloadPrices;

  /// Subscribe button label with price
  ///
  /// In en, this message translates to:
  /// **'Subscribe — {price}'**
  String subscribeWithPrice(String price);

  /// Trust message on paywall
  ///
  /// In en, this message translates to:
  /// **'No ads, no data selling — your subscription funds secure servers & ongoing development.'**
  String get noAdsDescription;

  /// Loading message while detecting user location for currency
  ///
  /// In en, this message translates to:
  /// **'Detecting your location...'**
  String get detectingLocation;

  /// Help text for currency selector on paywall
  ///
  /// In en, this message translates to:
  /// **'Use INR for Indian cards, USD for international cards.'**
  String get currencyHelpText;

  /// Self-host contact info on paywall
  ///
  /// In en, this message translates to:
  /// **'Want to self-host? Contact us at contact@betterkeep.app'**
  String get selfHostContact;

  /// Snackbar message shown when user successfully subscribes via subscription listener
  ///
  /// In en, this message translates to:
  /// **'Welcome to Better Keep Pro!'**
  String get welcomeToProMessage;

  /// No description provided for @paymentConfirmedTitle.
  ///
  /// In en, this message translates to:
  /// **'Payment confirmed'**
  String get paymentConfirmedTitle;

  /// No description provided for @paymentConfirmedActivationPending.
  ///
  /// In en, this message translates to:
  /// **'Payment was confirmed, but Pro activation is taking longer. Do not purchase again. Recheck your status or manage the subscription in Google Play.'**
  String get paymentConfirmedActivationPending;

  /// No description provided for @recheckStatus.
  ///
  /// In en, this message translates to:
  /// **'Recheck Status'**
  String get recheckStatus;

  /// No description provided for @subscriptionAccountMismatchTitle.
  ///
  /// In en, this message translates to:
  /// **'Subscription linked to another account'**
  String get subscriptionAccountMismatchTitle;

  /// No description provided for @subscriptionAccountMismatchMessage.
  ///
  /// In en, this message translates to:
  /// **'This Google Play subscription is linked to another Better Keep account. Sign in to that account or contact support; access has not been granted here.'**
  String get subscriptionAccountMismatchMessage;

  /// Loading text shown while subscription prices are being fetched
  ///
  /// In en, this message translates to:
  /// **'Loading prices...'**
  String get loadingPrices;

  /// Button label shown while a subscription purchase is in progress
  ///
  /// In en, this message translates to:
  /// **'Processing...'**
  String get processingSubscription;

  /// Legal auto-renew terms shown on the paywall
  ///
  /// In en, this message translates to:
  /// **'Payment will be charged to your account. Subscription automatically renews unless auto-renew is turned off at least 24 hours before the end of the current period.'**
  String get subscriptionAutoRenewTerms;

  /// Badge on yearly plan button showing savings percentage
  ///
  /// In en, this message translates to:
  /// **'Save {percent}%'**
  String savePercent(int percent);

  /// Snackbar message after subscription is cancelled via Razorpay
  ///
  /// In en, this message translates to:
  /// **'Subscription cancelled successfully.'**
  String get subscriptionCancelledSuccessfully;

  /// Snackbar message after a cancelled subscription is resumed
  ///
  /// In en, this message translates to:
  /// **'Subscription resumed successfully.'**
  String get subscriptionResumedSuccessfully;

  /// Error message when subscription cancellation fails
  ///
  /// In en, this message translates to:
  /// **'Failed to cancel subscription.'**
  String get failedToCancelSubscription;

  /// Error message when subscription resumption fails
  ///
  /// In en, this message translates to:
  /// **'Failed to resume subscription.'**
  String get failedToResumeSubscription;

  /// Column header for the feature name column in the paywall comparison table
  ///
  /// In en, this message translates to:
  /// **'Feature'**
  String get featureTableHeader;

  /// Unlimited quantity label used in feature comparison table
  ///
  /// In en, this message translates to:
  /// **'Unlimited'**
  String get unlimited;

  /// Feature row label for local notes in the paywall comparison table
  ///
  /// In en, this message translates to:
  /// **'Local notes'**
  String get paywallLocalNotes;

  /// Free tier limit for locked notes shown in paywall comparison table
  ///
  /// In en, this message translates to:
  /// **'5 max'**
  String get lockedNotesFreeLimit;

  /// Connected accounts subtitle
  ///
  /// In en, this message translates to:
  /// **'Sign in with any linked account'**
  String get signInWithAnyLinked;

  /// Linking authentication notice
  ///
  /// In en, this message translates to:
  /// **'Linking requires authentication with each platform to verify ownership.'**
  String get linkingRequiresAuth;

  /// Connected status
  ///
  /// In en, this message translates to:
  /// **'Connected'**
  String get connected;

  /// Cannot unlink primary tooltip
  ///
  /// In en, this message translates to:
  /// **'Cannot unlink the original sign-in method'**
  String get cannotUnlinkPrimary;

  /// Verify account link dialog title
  ///
  /// In en, this message translates to:
  /// **'Verify Account Link'**
  String get verifyAccountLink;

  /// Verify and link button
  ///
  /// In en, this message translates to:
  /// **'Verify & Link'**
  String get verifyAndLink;

  /// E2EE ready status
  ///
  /// In en, this message translates to:
  /// **'Your notes are protected'**
  String get yourNotesAreProtected;

  /// E2EE pending approval status
  ///
  /// In en, this message translates to:
  /// **'Waiting for device approval'**
  String get waitingForDeviceApproval;

  /// E2EE not set up status
  ///
  /// In en, this message translates to:
  /// **'Protection not enabled'**
  String get protectionNotEnabled;

  /// E2EE error status
  ///
  /// In en, this message translates to:
  /// **'Something went wrong'**
  String get somethingWentWrong;

  /// E2EE revoked status
  ///
  /// In en, this message translates to:
  /// **'Device access removed'**
  String get deviceAccessRemoved;

  /// E2EE initializing status
  ///
  /// In en, this message translates to:
  /// **'Getting ready...'**
  String get gettingReady;

  /// E2EE encryption info
  ///
  /// In en, this message translates to:
  /// **'Your notes and attachments are encrypted'**
  String get notesAndAttachmentsEncrypted;

  /// Encryption label
  ///
  /// In en, this message translates to:
  /// **'Encryption'**
  String get encryption;

  /// Key exchange label
  ///
  /// In en, this message translates to:
  /// **'Key Exchange'**
  String get keyExchange;

  /// Key size label
  ///
  /// In en, this message translates to:
  /// **'Key Size'**
  String get keySize;

  /// Number of authorized devices
  ///
  /// In en, this message translates to:
  /// **'{count} authorized'**
  String nDevicesAuthorized(int count);

  /// Important label
  ///
  /// In en, this message translates to:
  /// **'Important'**
  String get important;

  /// Pending approval instruction
  ///
  /// In en, this message translates to:
  /// **'Open Better Keep on an already-authorized device to approve this device.'**
  String get approveOnOtherDevice;

  /// Your devices section title
  ///
  /// In en, this message translates to:
  /// **'Your Devices'**
  String get yourDevices;

  /// Pending approval section title
  ///
  /// In en, this message translates to:
  /// **'Pending Approval'**
  String get pendingApprovalSection;

  /// Authorized devices section title
  ///
  /// In en, this message translates to:
  /// **'Authorized Devices'**
  String get authorizedDevices;

  /// No internet connection error
  ///
  /// In en, this message translates to:
  /// **'No internet connection. Please check your network and try again.'**
  String get noInternetConnection;

  /// Danger zone section title
  ///
  /// In en, this message translates to:
  /// **'Danger Zone'**
  String get dangerZone;

  /// Danger zone description
  ///
  /// In en, this message translates to:
  /// **'Permanently delete your account and all associated data. This action will be completed after a 30-day grace period.'**
  String get dangerZoneDescription;

  /// Delete my account button
  ///
  /// In en, this message translates to:
  /// **'Delete My Account'**
  String get deleteMyAccount;

  /// Unsynced notes warning message
  ///
  /// In en, this message translates to:
  /// **'You have notes that haven\'t been synced to the cloud yet. If you sign out now, these notes will be LOST FOREVER.\n\nConsider waiting for sync to complete or exporting your data first.'**
  String get unsyncedNotesWarning;

  /// Number of notes not synced
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 note not synced} other{{count} notes not synced}}'**
  String notesNotSynced(int count);

  /// Data loss warning title
  ///
  /// In en, this message translates to:
  /// **'DATA LOSS WARNING'**
  String get dataLossWarning;

  /// No recovery key set up warning
  ///
  /// In en, this message translates to:
  /// **'No recovery key set up'**
  String get noRecoveryKeySet;

  /// Sign out without recovery key warning
  ///
  /// In en, this message translates to:
  /// **'If you sign out and lose access to all your approved devices, you will PERMANENTLY lose access to ALL your encrypted notes.\n\nThis action cannot be undone.'**
  String get signOutNoRecoveryKeyWarning;

  /// Sign out confirmation message
  ///
  /// In en, this message translates to:
  /// **'Are you sure you want to sign out?\n\nYou will need to sign in again to access your notes.'**
  String get signOutConfirmation;

  /// Number of devices waiting for approval
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 Device Waiting for Approval} other{{count} Devices Waiting for Approval}}'**
  String nDevicesWaitingForApproval(int count);

  /// Review and approve subtitle
  ///
  /// In en, this message translates to:
  /// **'Review and approve to grant access'**
  String get reviewAndApprove;

  /// Number of share access requests
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 Share Access Request} other{{count} Share Access Requests}}'**
  String nShareAccessRequests(int count);

  /// Share request subtitle
  ///
  /// In en, this message translates to:
  /// **'Someone wants to view your shared note'**
  String get someoneWantsToView;

  /// Device approved snackbar message
  ///
  /// In en, this message translates to:
  /// **'Device approved'**
  String get deviceApproved_;

  /// Failed to approve device error
  ///
  /// In en, this message translates to:
  /// **'Failed to approve device: {error}'**
  String failedApproveDevice(String error);

  /// Device removed message
  ///
  /// In en, this message translates to:
  /// **'Device removed'**
  String get deviceRemoved;

  /// Number of devices removed
  ///
  /// In en, this message translates to:
  /// **'{count} devices removed'**
  String nDevicesRemoved(int count);

  /// Failed to remove device error
  ///
  /// In en, this message translates to:
  /// **'Failed to remove device: {error}'**
  String failedRemoveDevice(String error);

  /// Remove device dialog title
  ///
  /// In en, this message translates to:
  /// **'Remove Device'**
  String get removeDevice_;

  /// Remove device confirmation message
  ///
  /// In en, this message translates to:
  /// **'Are you sure you want to remove \"{deviceName}\"?\n\nThis device will no longer have access to your notes.'**
  String removeDeviceConfirmation(String deviceName);

  /// Enable E2EE confirmation message
  ///
  /// In en, this message translates to:
  /// **'This will encrypt all your notes and attachments. Only devices you authorize will be able to read them.\n\nMake sure to set up a recovery key after enabling E2EE, or you may lose access to your notes if you lose all your devices.'**
  String get enableE2EEConfirmation;

  /// Enable E2EE button text
  ///
  /// In en, this message translates to:
  /// **'Enable E2EE'**
  String get enableE2EE_;

  /// Failed to enable E2EE error
  ///
  /// In en, this message translates to:
  /// **'Failed to enable E2EE: {error}'**
  String failedEnableE2EE(String error);

  /// Recovery key saved message
  ///
  /// In en, this message translates to:
  /// **'Recovery key saved successfully!'**
  String get recoveryKeySavedSuccessfully;

  /// No recovery key warning message
  ///
  /// In en, this message translates to:
  /// **'Warning: Without a recovery key, you may lose access to your notes if you lose all devices.'**
  String get noRecoveryKeyWarning;

  /// Recovery key options message
  ///
  /// In en, this message translates to:
  /// **'You have a recovery key set up. What would you like to do?'**
  String get recoveryKeySetUp;

  /// Update button
  ///
  /// In en, this message translates to:
  /// **'Update'**
  String get update;

  /// Recovery key updated message
  ///
  /// In en, this message translates to:
  /// **'Recovery key updated!'**
  String get recoveryKeyUpdated;

  /// Recovery key removed message
  ///
  /// In en, this message translates to:
  /// **'Recovery key removed'**
  String get recoveryKeyRemoved;

  /// Recovery key saved message
  ///
  /// In en, this message translates to:
  /// **'Recovery key saved!'**
  String get recoveryKeySaved;

  /// Upgrade now dialog title
  ///
  /// In en, this message translates to:
  /// **'Upgrade Now?'**
  String get upgradeNowQuestion;

  /// Trial time remaining message
  ///
  /// In en, this message translates to:
  /// **'You still have {timeLeft} on your free trial.'**
  String trialTimeLeft(String timeLeft);

  /// Subscribe now trial ends message
  ///
  /// In en, this message translates to:
  /// **'If you subscribe now, your trial will end immediately and billing will start right away.'**
  String get subscribeNowTrialEnds;

  /// Already have subscription message
  ///
  /// In en, this message translates to:
  /// **'You already have an active {planName} subscription!'**
  String alreadyHaveSubscription(String planName);

  /// Unlink provider dialog title
  ///
  /// In en, this message translates to:
  /// **'Unlink {provider}?'**
  String unlinkProviderQuestion(String provider);

  /// Unlink provider warning message
  ///
  /// In en, this message translates to:
  /// **'You will no longer be able to sign in with this account. Make sure you have another way to access your account.'**
  String get unlinkProviderWarning;

  /// Unlinked provider successfully message
  ///
  /// In en, this message translates to:
  /// **'Unlinked {provider}'**
  String unlinkedSuccessfully(String provider);

  /// Failed to unlink account error
  ///
  /// In en, this message translates to:
  /// **'Failed to unlink account'**
  String get failedUnlinkAccount;

  /// Cannot unlink only method error
  ///
  /// In en, this message translates to:
  /// **'Cannot unlink the only sign-in method.'**
  String get cannotUnlinkOnlyMethod;

  /// Unknown provider error
  ///
  /// In en, this message translates to:
  /// **'Unknown provider: {provider}'**
  String unknownProviderError(String provider);

  /// Taking too long message
  ///
  /// In en, this message translates to:
  /// **'Taking too long. You can cancel and try again.'**
  String get takingTooLong;

  /// Failed to send verification code error
  ///
  /// In en, this message translates to:
  /// **'Failed to send verification code'**
  String get failedSendCode;

  /// Please try again message
  ///
  /// In en, this message translates to:
  /// **'Please try again.'**
  String get pleaseTryAgain;

  /// Please sign in again message
  ///
  /// In en, this message translates to:
  /// **'Please sign in again and try.'**
  String get pleaseSignInAgain;

  /// No email associated error
  ///
  /// In en, this message translates to:
  /// **'No email associated with your account.'**
  String get noEmailAssociated;

  /// Provider already linked error
  ///
  /// In en, this message translates to:
  /// **'{provider} is already linked to your account.'**
  String providerAlreadyLinked(String provider);

  /// Rate limit message
  ///
  /// In en, this message translates to:
  /// **'Please wait before requesting again.'**
  String get pleaseWaitBeforeRequesting;

  /// Session expired message
  ///
  /// In en, this message translates to:
  /// **'Session expired. Please try again.'**
  String get sessionExpired_;

  /// Failed to link account error
  ///
  /// In en, this message translates to:
  /// **'Failed to link account'**
  String get failedLinkAccount;

  /// Provider linked to another user error
  ///
  /// In en, this message translates to:
  /// **'This {provider} account is already linked to another user.'**
  String providerLinkedToAnother(String provider);

  /// Email already in use error
  ///
  /// In en, this message translates to:
  /// **'An account with this email already exists. Sign in with that account first, then link from there.'**
  String get emailAlreadyInUse;

  /// Linking cancelled message
  ///
  /// In en, this message translates to:
  /// **'Linking was cancelled.'**
  String get linkingCancelled;

  /// Successfully linked provider message
  ///
  /// In en, this message translates to:
  /// **'Successfully linked {provider} account'**
  String successfullyLinkedProvider(String provider);

  /// Delete account dialog title
  ///
  /// In en, this message translates to:
  /// **'Delete Your Account?'**
  String get deleteYourAccount;

  /// Action irreversible warning
  ///
  /// In en, this message translates to:
  /// **'This action is irreversible'**
  String get actionIrreversible;

  /// All notes deleted warning
  ///
  /// In en, this message translates to:
  /// **'All your notes will be permanently deleted'**
  String get allNotesDeleted;

  /// All attachments removed warning
  ///
  /// In en, this message translates to:
  /// **'All attachments and media will be removed'**
  String get allAttachmentsRemoved;

  /// Logged out all devices warning
  ///
  /// In en, this message translates to:
  /// **'You will be logged out from all devices'**
  String get loggedOutAllDevices;

  /// Account cannot be recovered warning
  ///
  /// In en, this message translates to:
  /// **'Your account cannot be recovered'**
  String get accountCannotBeRecovered;

  /// Grace period info message
  ///
  /// In en, this message translates to:
  /// **'30-day grace period: Sign back in to cancel deletion.'**
  String get gracePeriodInfo;

  /// Verification code via email message
  ///
  /// In en, this message translates to:
  /// **'You will receive a verification code via email.'**
  String get verificationCodeViaEmail;

  /// Keep my account button
  ///
  /// In en, this message translates to:
  /// **'Keep My Account'**
  String get keepMyAccount;

  /// Delete account button
  ///
  /// In en, this message translates to:
  /// **'Delete Account'**
  String get deleteAccount;

  /// Verify identity dialog title
  ///
  /// In en, this message translates to:
  /// **'Verify Your Identity'**
  String get verifyYourIdentity;

  /// User not signed in error
  ///
  /// In en, this message translates to:
  /// **'User not signed in'**
  String get userNotSignedIn;

  /// Failed to schedule deletion error
  ///
  /// In en, this message translates to:
  /// **'Failed to schedule deletion'**
  String get failedScheduleDeletion;

  /// Deletion scheduled dialog title
  ///
  /// In en, this message translates to:
  /// **'Deletion Scheduled'**
  String get deletionScheduled;

  /// Account deletion date message
  ///
  /// In en, this message translates to:
  /// **'Your account will be deleted on {date}.'**
  String accountWillBeDeletedOn(String date);

  /// Export before sign out message
  ///
  /// In en, this message translates to:
  /// **'Would you like to export your data before signing out?'**
  String get exportBeforeSignOut;

  /// Skip button
  ///
  /// In en, this message translates to:
  /// **'Skip'**
  String get skip;

  /// Export data button
  ///
  /// In en, this message translates to:
  /// **'Export Data'**
  String get exportData;

  /// Exporting data dialog title
  ///
  /// In en, this message translates to:
  /// **'Exporting Data'**
  String get exportingData;

  /// Export cancelled message
  ///
  /// In en, this message translates to:
  /// **'Export cancelled'**
  String get exportCancelled;

  /// Export failed message
  ///
  /// In en, this message translates to:
  /// **'Export failed'**
  String get exportFailed;

  /// Export complete dialog title
  ///
  /// In en, this message translates to:
  /// **'Export Complete'**
  String get exportComplete;

  /// Export complete message
  ///
  /// In en, this message translates to:
  /// **'Your data has been exported successfully.\n\nFile saved to:\n{path}\n\nWould you like to share the export file?'**
  String exportCompleteMessage(String path);

  /// Deletion scheduled snackbar message
  ///
  /// In en, this message translates to:
  /// **'Account deletion scheduled for {date}. Sign in again to cancel.'**
  String deletionScheduledMessage(String date);

  /// iPhone/iPad platform name
  ///
  /// In en, this message translates to:
  /// **'iPhone/iPad'**
  String get iphoneIpad;

  /// Web browser platform name
  ///
  /// In en, this message translates to:
  /// **'Web Browser'**
  String get webBrowser;

  /// Fallback name for an unidentified device
  ///
  /// In en, this message translates to:
  /// **'Unknown device'**
  String get unknownDevice;

  /// Debug delete subscription button
  ///
  /// In en, this message translates to:
  /// **'DEBUG: Delete Subscription'**
  String get debugDeleteSubscription;

  /// Debug delete subscription warning
  ///
  /// In en, this message translates to:
  /// **'This will immediately delete your subscription from the database.\n\nThis is for TESTING ONLY and will not cancel the actual Razorpay subscription.'**
  String get debugDeleteSubscriptionWarning;

  /// Debug subscription deleted message
  ///
  /// In en, this message translates to:
  /// **'DEBUG: Subscription deleted successfully'**
  String get debugSubscriptionDeleted;

  /// Debug subscription delete failed message
  ///
  /// In en, this message translates to:
  /// **'DEBUG: Failed to delete subscription'**
  String get debugSubscriptionDeleteFailed;

  /// Remove link button text
  ///
  /// In en, this message translates to:
  /// **'Remove Link'**
  String get removeLink;

  /// Add button text
  ///
  /// In en, this message translates to:
  /// **'Add'**
  String get add;

  /// Recent section label
  ///
  /// In en, this message translates to:
  /// **'Recent'**
  String get recent;

  /// Custom option label
  ///
  /// In en, this message translates to:
  /// **'Custom'**
  String get custom;

  /// Empty labels state description
  ///
  /// In en, this message translates to:
  /// **'Create a label above to organize your notes'**
  String get createLabelToOrganize;

  /// Edit label dialog title
  ///
  /// In en, this message translates to:
  /// **'Edit {labelName}'**
  String editLabelName(String labelName);

  /// Edit label placeholder
  ///
  /// In en, this message translates to:
  /// **'Enter new name'**
  String get enterNewName;

  /// Delete label dialog title
  ///
  /// In en, this message translates to:
  /// **'Delete Label'**
  String get deleteLabel;

  /// Delete label confirmation message
  ///
  /// In en, this message translates to:
  /// **'Are you sure you want to delete this label ({labelName})?'**
  String deleteLabelConfirmation(String labelName);

  /// Paste as dialog title
  ///
  /// In en, this message translates to:
  /// **'Paste as'**
  String get pasteAs;

  /// Formatted text paste option
  ///
  /// In en, this message translates to:
  /// **'Formatted text'**
  String get formattedText;

  /// Formatted text paste option subtitle
  ///
  /// In en, this message translates to:
  /// **'Preview and insert as formatted content'**
  String get previewAndInsertFormatted;

  /// Plain text paste option subtitle
  ///
  /// In en, this message translates to:
  /// **'Insert as plain text without formatting'**
  String get insertAsPlainText;

  /// Prompt dialog default title
  ///
  /// In en, this message translates to:
  /// **'Prompt'**
  String get prompt;

  /// Confirm field not matched error
  ///
  /// In en, this message translates to:
  /// **'Not matched'**
  String get notMatched;

  /// Confirm field placeholder
  ///
  /// In en, this message translates to:
  /// **'Confirm {placeholder}'**
  String confirmPlaceholder(String placeholder);

  /// Notification permissions required message
  ///
  /// In en, this message translates to:
  /// **'Notification and alarm permissions are required for reminders'**
  String get notificationPermissionsRequired;

  /// Check all button text
  ///
  /// In en, this message translates to:
  /// **'Check All'**
  String get checkAll;

  /// Uncheck all button text
  ///
  /// In en, this message translates to:
  /// **'Uncheck All'**
  String get uncheckAll;

  /// Check nested items confirmation message
  ///
  /// In en, this message translates to:
  /// **'This will check {count} nested {count, plural, =1{item} other{items}}.'**
  String checkNestedItemsCount(int count);

  /// Uncheck nested items confirmation message
  ///
  /// In en, this message translates to:
  /// **'This will uncheck {count} nested {count, plural, =1{item} other{items}}.'**
  String uncheckNestedItemsCount(int count);

  /// Generic error message with try again
  ///
  /// In en, this message translates to:
  /// **'Something went wrong. Please try again.'**
  String get somethingWentWrongTryAgain;

  /// Verifying passphrase status message
  ///
  /// In en, this message translates to:
  /// **'Verifying passphrase...'**
  String get verifyingPassphrase;

  /// Setting as primary device status message
  ///
  /// In en, this message translates to:
  /// **'Setting as primary device...'**
  String get settingAsPrimaryDevice;

  /// Finalizing status message
  ///
  /// In en, this message translates to:
  /// **'Finalizing...'**
  String get finalizing;

  /// Incorrect passphrase error message
  ///
  /// In en, this message translates to:
  /// **'Incorrect passphrase. Please try again.'**
  String get incorrectPassphrase;

  /// Recovery timed out error message
  ///
  /// In en, this message translates to:
  /// **'Recovery timed out. Please check your connection and try again.'**
  String get recoveryTimedOut;

  /// Recovery key mobile only error message
  ///
  /// In en, this message translates to:
  /// **'This recovery key was created on a mobile or desktop app and cannot be used in the browser. Please use the mobile or desktop app to recover.'**
  String get recoveryKeyMobileOnly;

  /// Generic error message with connection check
  ///
  /// In en, this message translates to:
  /// **'Something went wrong. Please check your connection and try again.'**
  String get somethingWentWrongCheckConnection;

  /// Recover button text
  ///
  /// In en, this message translates to:
  /// **'Recover'**
  String get recover;

  /// Recover info tooltip
  ///
  /// In en, this message translates to:
  /// **'Recover your encryption keys using your recovery passphrase'**
  String get recoverInfoTooltip;

  /// Hint label with value
  ///
  /// In en, this message translates to:
  /// **'Hint: {hint}'**
  String hintLabel(String hint);

  /// Set as primary device toggle label
  ///
  /// In en, this message translates to:
  /// **'Set as primary device'**
  String get setAsPrimaryDevice;

  /// Please enter recovery passphrase error
  ///
  /// In en, this message translates to:
  /// **'Please enter your recovery passphrase'**
  String get pleaseEnterRecoveryPassphrase;

  /// Current passphrase incorrect error
  ///
  /// In en, this message translates to:
  /// **'Current passphrase is incorrect'**
  String get currentPassphraseIncorrect;

  /// Please enter current passphrase error
  ///
  /// In en, this message translates to:
  /// **'Please enter your current passphrase'**
  String get pleaseEnterCurrentPassphrase;

  /// Please enter new passphrase error
  ///
  /// In en, this message translates to:
  /// **'Please enter a new passphrase'**
  String get pleaseEnterNewPassphrase;

  /// Remove recovery key dialog title
  ///
  /// In en, this message translates to:
  /// **'Remove Recovery Key'**
  String get removeRecoveryKey;

  /// Remove recovery key warning
  ///
  /// In en, this message translates to:
  /// **'Warning: Without a recovery key, you cannot recover your notes if you lose all your devices!'**
  String get removeRecoveryKeyWarning;

  /// Enter passphrase to confirm removal message
  ///
  /// In en, this message translates to:
  /// **'Enter your current passphrase to confirm removal:'**
  String get enterPassphraseToConfirmRemoval;

  /// Passphrase incorrect error
  ///
  /// In en, this message translates to:
  /// **'Passphrase is incorrect'**
  String get passphraseIncorrect;

  /// Unlock note dialog title
  ///
  /// In en, this message translates to:
  /// **'Unlock Note'**
  String get unlockNote;

  /// Please enter PIN validation error
  ///
  /// In en, this message translates to:
  /// **'Please enter the PIN'**
  String get pleaseEnterPin;

  /// Too many attempts wait message
  ///
  /// In en, this message translates to:
  /// **'Too many attempts. Wait {seconds} seconds.'**
  String tooManyAttemptsWait(int seconds);

  /// Attempts remaining error message
  ///
  /// In en, this message translates to:
  /// **'{message}. {remaining} attempts remaining.'**
  String attemptsRemaining(String message, int remaining);

  /// Failed to unlock note error
  ///
  /// In en, this message translates to:
  /// **'Failed to unlock note'**
  String get failedToUnlockNote;

  /// Locked with countdown
  ///
  /// In en, this message translates to:
  /// **'Locked ({seconds} s)'**
  String lockedSeconds(int seconds);

  /// Unlock button text
  ///
  /// In en, this message translates to:
  /// **'Unlock'**
  String get unlock;

  /// Lock note dialog title
  ///
  /// In en, this message translates to:
  /// **'Lock Note'**
  String get lockNote;

  /// PIN forgot warning message
  ///
  /// In en, this message translates to:
  /// **'If you forget this PIN, there is no way to recover the note.'**
  String get pinForgotWarning;

  /// Please enter PIN validation error
  ///
  /// In en, this message translates to:
  /// **'Please enter a PIN'**
  String get pleaseEnterAPin;

  /// PIN minimum length error
  ///
  /// In en, this message translates to:
  /// **'PIN must be at least 4 characters'**
  String get pinMinLength;

  /// PIN too weak error
  ///
  /// In en, this message translates to:
  /// **'PIN is too weak (all same characters)'**
  String get pinTooWeak;

  /// PIN too common error
  ///
  /// In en, this message translates to:
  /// **'PIN is too common'**
  String get pinTooCommon;

  /// Confirm PIN field label
  ///
  /// In en, this message translates to:
  /// **'Confirm PIN'**
  String get confirmPin;

  /// Re-enter PIN field hint
  ///
  /// In en, this message translates to:
  /// **'Re-enter PIN'**
  String get reenterPin;

  /// PINs do not match error
  ///
  /// In en, this message translates to:
  /// **'PINs do not match'**
  String get pinsDoNotMatch;

  /// Lock button text
  ///
  /// In en, this message translates to:
  /// **'Lock'**
  String get lock;

  /// Record audio dialog title
  ///
  /// In en, this message translates to:
  /// **'Record Audio'**
  String get recordAudio;

  /// Microphone permission required message
  ///
  /// In en, this message translates to:
  /// **'Microphone permission is required to record audio.'**
  String get microphonePermissionRequired;

  /// Open settings button text
  ///
  /// In en, this message translates to:
  /// **'Open Settings'**
  String get openSettings;

  /// Stop recording button text
  ///
  /// In en, this message translates to:
  /// **'Stop recording'**
  String get stopRecording;

  /// Start recording button text
  ///
  /// In en, this message translates to:
  /// **'Start recording'**
  String get startRecording;

  /// Transcription unavailable label
  ///
  /// In en, this message translates to:
  /// **'Transcription unavailable'**
  String get transcriptionUnavailable;

  /// Live transcription label
  ///
  /// In en, this message translates to:
  /// **'Live transcription'**
  String get liveTranscription;

  /// Recording continues without transcription message
  ///
  /// In en, this message translates to:
  /// **'Recording will continue without transcription'**
  String get recordingContinuesWithoutTranscription;

  /// Listening status
  ///
  /// In en, this message translates to:
  /// **'Listening...'**
  String get listening;

  /// Allow microphone access message
  ///
  /// In en, this message translates to:
  /// **'Allow microphone access to start recording.'**
  String get allowMicAccess;

  /// Tap start to record message
  ///
  /// In en, this message translates to:
  /// **'Tap start to begin recording.'**
  String get tapStartToRecord;

  /// Transcribe while recording subtitle
  ///
  /// In en, this message translates to:
  /// **'Transcribe while recording'**
  String get transcribeWhileRecording;

  /// Transcription field label
  ///
  /// In en, this message translates to:
  /// **'Transcription'**
  String get transcription;

  /// Edit transcription hint
  ///
  /// In en, this message translates to:
  /// **'Edit transcription if needed'**
  String get editTranscriptionHint;

  /// Add transcription to note checkbox
  ///
  /// In en, this message translates to:
  /// **'Add transcription to note'**
  String get addTranscriptionToNote;

  /// No speech detected message
  ///
  /// In en, this message translates to:
  /// **'No speech detected during recording.'**
  String get noSpeechDetected;

  /// Title optional field label
  ///
  /// In en, this message translates to:
  /// **'Title (optional)'**
  String get titleOptional;

  /// Enter title for recording hint
  ///
  /// In en, this message translates to:
  /// **'Enter a title for this recording'**
  String get enterTitleForRecording;

  /// Okay button text
  ///
  /// In en, this message translates to:
  /// **'Okay'**
  String get okay;

  /// Failed to start recording error
  ///
  /// In en, this message translates to:
  /// **'Failed to start recording'**
  String get failedToStartRecording;

  /// Transcription disabled on web for privacy
  ///
  /// In en, this message translates to:
  /// **'Voice transcription is disabled on web for privacy. Your audio stays on your device.'**
  String get transcriptionDisabledWebPrivacy;

  /// Whisper model required title
  ///
  /// In en, this message translates to:
  /// **'Speech recognition model required'**
  String get whisperModelRequired;

  /// Whisper model description
  ///
  /// In en, this message translates to:
  /// **'Download a small ({size}) AI model for on-device speech-to-text. Your audio never leaves your device.'**
  String whisperModelDescription(String size);

  /// Download model button
  ///
  /// In en, this message translates to:
  /// **'Download Model'**
  String get downloadModel;

  /// Use fallback speech-to-text button
  ///
  /// In en, this message translates to:
  /// **'Use device default'**
  String get useFallback;

  /// Whisper transcription active subtitle
  ///
  /// In en, this message translates to:
  /// **'On-device AI transcription (private)'**
  String get whisperTranscriptionActive;

  /// Model download complete message
  ///
  /// In en, this message translates to:
  /// **'Speech model downloaded successfully'**
  String get modelDownloadComplete;

  /// Model download failed message
  ///
  /// In en, this message translates to:
  /// **'Failed to download speech model'**
  String get modelDownloadFailed;

  /// Transcribing audio loading message
  ///
  /// In en, this message translates to:
  /// **'Transcribing audio...'**
  String get transcribingAudio;

  /// Message shown while Whisper refines the live transcription
  ///
  /// In en, this message translates to:
  /// **'Polishing transcription...'**
  String get polishingTranscription;

  /// Transcription failed error message
  ///
  /// In en, this message translates to:
  /// **'Transcription failed. Please try again.'**
  String get transcriptionFailed;

  /// Delete question dialog title
  ///
  /// In en, this message translates to:
  /// **'Delete?'**
  String get deleteQuestion;

  /// Action cannot be undone warning
  ///
  /// In en, this message translates to:
  /// **'This action cannot be undone.'**
  String get actionCannotBeUndone;

  /// Permanent delete warning
  ///
  /// In en, this message translates to:
  /// **'This will permanently delete all data and cannot be recovered.'**
  String get permanentDeleteWarning;

  /// Sent verification code message
  ///
  /// In en, this message translates to:
  /// **'We sent a verification code to:'**
  String get sentVerificationCodeTo;

  /// Code expires in minutes message
  ///
  /// In en, this message translates to:
  /// **'Code expires in {minutes} minutes'**
  String codeExpiresInMinutes(int minutes);

  /// Verification failed try again error
  ///
  /// In en, this message translates to:
  /// **'Verification failed. Please try again.'**
  String get verificationFailedTryAgain;

  /// Share note dialog title
  ///
  /// In en, this message translates to:
  /// **'Share Note'**
  String get shareNote;

  /// Untitled note placeholder
  ///
  /// In en, this message translates to:
  /// **'Untitled Note'**
  String get untitledNote;

  /// Share as text option title
  ///
  /// In en, this message translates to:
  /// **'Share as Text'**
  String get shareAsText;

  /// Share as text option subtitle
  ///
  /// In en, this message translates to:
  /// **'Plain text content'**
  String get plainTextContent;

  /// Share as markdown option title
  ///
  /// In en, this message translates to:
  /// **'Share as Markdown'**
  String get shareAsMarkdown;

  /// Share as markdown option subtitle
  ///
  /// In en, this message translates to:
  /// **'Formatted with markdown syntax'**
  String get formattedWithMarkdown;

  /// Create secure link option title
  ///
  /// In en, this message translates to:
  /// **'Create Secure Link'**
  String get createSecureLink;

  /// Create secure link option subtitle
  ///
  /// In en, this message translates to:
  /// **'Encrypted link with access approval'**
  String get encryptedLinkWithApproval;

  /// Link created dialog title
  ///
  /// In en, this message translates to:
  /// **'Link Created'**
  String get linkCreated;

  /// Active links dialog title with count
  ///
  /// In en, this message translates to:
  /// **'Active Links ({count})'**
  String activeLinks(int count);

  /// Secure link dialog title
  ///
  /// In en, this message translates to:
  /// **'Secure Link'**
  String get secureLink;

  /// Create new link button text
  ///
  /// In en, this message translates to:
  /// **'Create New Link'**
  String get createNewLink;

  /// Revoke link tooltip
  ///
  /// In en, this message translates to:
  /// **'Revoke link'**
  String get revokeLink_;

  /// Copy button text
  ///
  /// In en, this message translates to:
  /// **'Copy'**
  String get copy;

  /// Link not available message
  ///
  /// In en, this message translates to:
  /// **'Link not available (created on another device)'**
  String get linkNotAvailable;

  /// Revoke link dialog title
  ///
  /// In en, this message translates to:
  /// **'Revoke Link?'**
  String get revokeLinkQuestion;

  /// Revoke link warning message
  ///
  /// In en, this message translates to:
  /// **'This will permanently disable this share link. Anyone with the link will no longer be able to access the note.'**
  String get revokeLinkWarning;

  /// Revoke button text
  ///
  /// In en, this message translates to:
  /// **'Revoke'**
  String get revoke;

  /// Link revoked snackbar message
  ///
  /// In en, this message translates to:
  /// **'Link revoked'**
  String get linkRevoked;

  /// Failed to revoke error
  ///
  /// In en, this message translates to:
  /// **'Failed to revoke: {error}'**
  String failedToRevoke(String error);

  /// Link copied snackbar message
  ///
  /// In en, this message translates to:
  /// **'Link copied to clipboard'**
  String get linkCopied;

  /// Link expires after label
  ///
  /// In en, this message translates to:
  /// **'Link expires after'**
  String get linkExpiresAfter;

  /// Options label
  ///
  /// In en, this message translates to:
  /// **'Options'**
  String get options;

  /// Include attachments checkbox label
  ///
  /// In en, this message translates to:
  /// **'Include attachments'**
  String get includeAttachments;

  /// Number of attachments
  ///
  /// In en, this message translates to:
  /// **'{count} attachment(s)'**
  String nAttachments(int count);

  /// Create link button text
  ///
  /// In en, this message translates to:
  /// **'Create Link'**
  String get createLink;

  /// Creating status text
  ///
  /// In en, this message translates to:
  /// **'Creating...'**
  String get creating;

  /// E2EE approval info message
  ///
  /// In en, this message translates to:
  /// **'End-to-end encrypted. You\'ll approve each access request.'**
  String get e2eeApprovalInfo;

  /// Link created success message
  ///
  /// In en, this message translates to:
  /// **'Link Created!'**
  String get linkCreatedSuccess;

  /// Expires in duration message
  ///
  /// In en, this message translates to:
  /// **'Expires in {duration}'**
  String expiresIn(String duration);

  /// Access notification info
  ///
  /// In en, this message translates to:
  /// **'You\'ll get a notification when someone requests access.'**
  String get accessNotification;

  /// Please unlock note first message
  ///
  /// In en, this message translates to:
  /// **'Please unlock the note first to share it'**
  String get pleaseUnlockNoteFirst;

  /// Shared note title
  ///
  /// In en, this message translates to:
  /// **'Shared Note: {title}'**
  String sharedNote(String title);

  /// Session problem banner title
  ///
  /// In en, this message translates to:
  /// **'Session Problem'**
  String get sessionProblem;

  /// Session invalid banner message
  ///
  /// In en, this message translates to:
  /// **'Sync is disabled. Please sign out and sign in again.'**
  String get syncDisabledPleaseSignOut;

  /// Sign out confirmation message with note access info
  ///
  /// In en, this message translates to:
  /// **'Are you sure you want to sign out?\n\nYou will need to sign in again to access your notes.'**
  String get signOutConfirmationWithNote;

  /// Sketch tool section label
  ///
  /// In en, this message translates to:
  /// **'Tool'**
  String get sketchTool;

  /// Sketch size section label
  ///
  /// In en, this message translates to:
  /// **'Size'**
  String get sketchSize;

  /// Sketch color section label
  ///
  /// In en, this message translates to:
  /// **'Color'**
  String get sketchColor;

  /// Transcript section title
  ///
  /// In en, this message translates to:
  /// **'Transcript'**
  String get transcript;

  /// Duration label
  ///
  /// In en, this message translates to:
  /// **'Duration'**
  String get duration;

  /// Delete recording confirmation message
  ///
  /// In en, this message translates to:
  /// **'Are you sure you want to delete this audio recording?'**
  String get deleteRecordingConfirmation;

  /// Encrypted note dialog title
  ///
  /// In en, this message translates to:
  /// **'Encrypted Note'**
  String get encryptedNote;

  /// Decryption failed label
  ///
  /// In en, this message translates to:
  /// **'Decryption failed'**
  String get decryptionFailed;

  /// Message shown when a note fails to decrypt, offering retry
  ///
  /// In en, this message translates to:
  /// **'This note could not be decrypted. This can happen when encryption keys are temporarily unavailable. You can try syncing again, or delete the note permanently.'**
  String get decryptionFailedRetryMessage;

  /// Warning that deleting a decryption-failed note destroys the server copy
  ///
  /// In en, this message translates to:
  /// **'Deleting will remove this note from all your devices, including the encrypted copy on the server.'**
  String get deletingNoteFromAllDevicesWarning;

  /// Button to retry decrypting a failed note
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get retryDecryption;

  /// Snackbar message when retrying decryption
  ///
  /// In en, this message translates to:
  /// **'Retrying sync...'**
  String get retryingDecryption;

  /// Message when E2EE is not ready for retry
  ///
  /// In en, this message translates to:
  /// **'Encryption is not ready. Please check your device approval status.'**
  String get e2eeNotReady;

  /// Locked note label
  ///
  /// In en, this message translates to:
  /// **'This note is locked'**
  String get thisNoteIsLocked;

  /// Audio fallback label
  ///
  /// In en, this message translates to:
  /// **'Audio'**
  String get audio;

  /// Number of protected audio attachments shown on a locked note card
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 audio} other{{count} audios}}'**
  String audioCount(int count);

  /// Number of sync failures
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 failed} other{{count} failed}}'**
  String syncFailedCount(int count);

  /// Open in app banner message for Android
  ///
  /// In en, this message translates to:
  /// **'Open in the app for the best experience'**
  String get openInAppForBestExperience;

  /// Use app banner message for iOS/other
  ///
  /// In en, this message translates to:
  /// **'Use the app for a better experience'**
  String get useAppForBetterExperience;

  /// Note marked as done snackbar message
  ///
  /// In en, this message translates to:
  /// **'Note marked as done'**
  String get noteMarkedAsDone;

  /// Text color picker dialog title
  ///
  /// In en, this message translates to:
  /// **'Pick Text Color'**
  String get pickTextColor;

  /// Image attachment option
  ///
  /// In en, this message translates to:
  /// **'Image'**
  String get image;

  /// Sketch attachment option
  ///
  /// In en, this message translates to:
  /// **'Sketch'**
  String get sketch;

  /// Tiny text size option
  ///
  /// In en, this message translates to:
  /// **'Tiny'**
  String get textSizeTiny;

  /// Small text size option
  ///
  /// In en, this message translates to:
  /// **'Small'**
  String get textSizeSmall;

  /// Normal text size option
  ///
  /// In en, this message translates to:
  /// **'Normal'**
  String get textSizeNormal;

  /// Big text size option
  ///
  /// In en, this message translates to:
  /// **'Big'**
  String get textSizeBig;

  /// Huge text size option
  ///
  /// In en, this message translates to:
  /// **'Huge'**
  String get textSizeHuge;

  /// Line spacing tooltip
  ///
  /// In en, this message translates to:
  /// **'Line Spacing'**
  String get lineSpacing;

  /// Tight line spacing option
  ///
  /// In en, this message translates to:
  /// **'Tight'**
  String get lineSpacingTight;

  /// Normal line spacing option
  ///
  /// In en, this message translates to:
  /// **'Normal'**
  String get lineSpacingNormal;

  /// Relaxed line spacing option
  ///
  /// In en, this message translates to:
  /// **'Relaxed'**
  String get lineSpacingRelaxed;

  /// Double line spacing option
  ///
  /// In en, this message translates to:
  /// **'Double'**
  String get lineSpacingDouble;

  /// Remove line spacing option
  ///
  /// In en, this message translates to:
  /// **'Remove Spacing'**
  String get lineSpacingRemove;

  /// Note editor placeholder text
  ///
  /// In en, this message translates to:
  /// **'Start writing...'**
  String get startWriting;

  /// Error message when image fails to load
  ///
  /// In en, this message translates to:
  /// **'Image failed to load'**
  String get imageFailedToLoad;

  /// Warning when max attachments limit reached
  ///
  /// In en, this message translates to:
  /// **'Maximum {count} attachments per note reached'**
  String maxAttachmentsReached(int count);

  /// Loading text while processing image
  ///
  /// In en, this message translates to:
  /// **'Processing image...'**
  String get processingImage;

  /// Note color picker dialog title
  ///
  /// In en, this message translates to:
  /// **'Pick Note Color'**
  String get pickNoteColor;

  /// Error when paste fails
  ///
  /// In en, this message translates to:
  /// **'Failed to paste: {error}'**
  String failedToPaste(String error);

  /// Error when inserting content fails
  ///
  /// In en, this message translates to:
  /// **'Failed to insert content: {error}'**
  String failedToInsertContent(String error);

  /// Error when locking note fails
  ///
  /// In en, this message translates to:
  /// **'Failed to lock note: {error}'**
  String failedToLockNote(String error);

  /// Error when removing lock fails
  ///
  /// In en, this message translates to:
  /// **'Failed to remove lock: {error}'**
  String failedToRemoveLock(String error);

  /// Warning when note is duplicated but locking failed
  ///
  /// In en, this message translates to:
  /// **'Note duplicated but failed to lock: {error}'**
  String noteDuplicatedButFailedToLock(String error);

  /// Title for pasted content preview page
  ///
  /// In en, this message translates to:
  /// **'Pasted Content'**
  String get pastedContent;

  /// Trash navigation item
  ///
  /// In en, this message translates to:
  /// **'Trash'**
  String get trash;

  /// Reminders navigation item
  ///
  /// In en, this message translates to:
  /// **'Reminders'**
  String get reminders;

  /// Snackbar message after enabling notification permissions
  ///
  /// In en, this message translates to:
  /// **'Notifications enabled! Your reminders are set.'**
  String get notificationsEnabled;

  /// Share app menu item
  ///
  /// In en, this message translates to:
  /// **'Share App'**
  String get shareApp;

  /// Share app message text
  ///
  /// In en, this message translates to:
  /// **'Check out Better Keep Notes - a secure note-taking app!\nhttps://play.google.com/store/apps/details?id=io.foxbiz.better_keep'**
  String get shareAppMessage;

  /// Install Better Keep dialog title
  ///
  /// In en, this message translates to:
  /// **'Install Better Keep'**
  String get installBetterKeep;

  /// Install app button label
  ///
  /// In en, this message translates to:
  /// **'Install App'**
  String get installApp;

  /// Get Android app button label
  ///
  /// In en, this message translates to:
  /// **'Get Android App'**
  String get getAndroidApp;

  /// Get Windows app button label
  ///
  /// In en, this message translates to:
  /// **'Get Windows App'**
  String get getWindowsApp;

  /// Select view dialog title
  ///
  /// In en, this message translates to:
  /// **'Select View'**
  String get selectView;

  /// Grid view mode option
  ///
  /// In en, this message translates to:
  /// **'Grid'**
  String get viewModeGrid;

  /// List view mode option
  ///
  /// In en, this message translates to:
  /// **'List'**
  String get viewModeList;

  /// Colors view mode option
  ///
  /// In en, this message translates to:
  /// **'Colors'**
  String get viewModeColors;

  /// Clear button/chip label
  ///
  /// In en, this message translates to:
  /// **'Clear'**
  String get clear;

  /// No matching notes empty state
  ///
  /// In en, this message translates to:
  /// **'No matching notes'**
  String get noMatchingNotes;

  /// No notes yet empty state
  ///
  /// In en, this message translates to:
  /// **'No notes yet'**
  String get noNotesYet;

  /// Trash is empty empty state
  ///
  /// In en, this message translates to:
  /// **'Trash is empty'**
  String get trashIsEmpty;

  /// No pinned notes empty state
  ///
  /// In en, this message translates to:
  /// **'No pinned notes'**
  String get noPinnedNotes;

  /// No locked notes empty state
  ///
  /// In en, this message translates to:
  /// **'No locked notes'**
  String get noLockedNotes;

  /// No reminders set empty state
  ///
  /// In en, this message translates to:
  /// **'No reminders set'**
  String get noRemindersSet;

  /// Create your first note button
  ///
  /// In en, this message translates to:
  /// **'Create your first note'**
  String get createYourFirstNote;

  /// No labels yet empty state
  ///
  /// In en, this message translates to:
  /// **'No labels yet'**
  String get noLabelsYet;

  /// No colored notes yet empty state
  ///
  /// In en, this message translates to:
  /// **'No colored notes yet'**
  String get noColoredNotesYet;

  /// Add labels hint message
  ///
  /// In en, this message translates to:
  /// **'Add labels to your notes to organize them into folders'**
  String get addLabelsToOrganize;

  /// Add colors hint message
  ///
  /// In en, this message translates to:
  /// **'Add colors to your notes to organize them into folders'**
  String get addColorsToOrganize;

  /// Get the Android app dialog title
  ///
  /// In en, this message translates to:
  /// **'Get the Android App'**
  String get getTheAndroidApp;

  /// Android app available message
  ///
  /// In en, this message translates to:
  /// **'Better Keep is available on Google Play! Get the native app for the best experience with notifications, widgets, and more.'**
  String get androidAppAvailable;

  /// Open Play Store button
  ///
  /// In en, this message translates to:
  /// **'Open Play Store'**
  String get openPlayStore;

  /// Get the Windows app dialog title
  ///
  /// In en, this message translates to:
  /// **'Get the Windows App'**
  String get getTheWindowsApp;

  /// Windows app available message
  ///
  /// In en, this message translates to:
  /// **'Better Keep is available on Microsoft Store! Get the native app for the best experience with system integration and offline access.'**
  String get windowsAppAvailable;

  /// Open Microsoft Store button
  ///
  /// In en, this message translates to:
  /// **'Open Microsoft Store'**
  String get openMicrosoftStore;

  /// Install for quick access message
  ///
  /// In en, this message translates to:
  /// **'Install Better Keep for quick access from your home screen and offline support!'**
  String get installForQuickAccess;

  /// Install button label
  ///
  /// In en, this message translates to:
  /// **'Install'**
  String get install;

  /// Not now button label
  ///
  /// In en, this message translates to:
  /// **'Not now'**
  String get notNow;

  /// No recovery key dialog title
  ///
  /// In en, this message translates to:
  /// **'No Recovery Key'**
  String get noRecoveryKey;

  /// I understand button label
  ///
  /// In en, this message translates to:
  /// **'I understand'**
  String get iUnderstand;

  /// Delete forever dialog title
  ///
  /// In en, this message translates to:
  /// **'Delete Forever'**
  String get deleteForever;

  /// Delete all trash confirmation message
  ///
  /// In en, this message translates to:
  /// **'Do you really want to delete all notes in the trash forever, this can\'t be undone.'**
  String get deleteAllTrashForever;

  /// Delete selected notes confirmation message
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{Do you really want to delete this note forever? This can\'t be undone.} other{Do you really want to delete {count} notes forever? This can\'t be undone.}}'**
  String deleteSelectedNotesForever(int count);

  /// Search hint text
  ///
  /// In en, this message translates to:
  /// **'Search'**
  String get search;

  /// Todo bubble menu item
  ///
  /// In en, this message translates to:
  /// **'Todo'**
  String get todo;

  /// Audio note default title
  ///
  /// In en, this message translates to:
  /// **'Audio Note'**
  String get audioNote;

  /// Failed to create image note error message
  ///
  /// In en, this message translates to:
  /// **'Failed to create image note'**
  String get failedToCreateImageNote;

  /// Email validation error message
  ///
  /// In en, this message translates to:
  /// **'Please enter your email'**
  String get pleaseEnterYourEmail;

  /// Email format validation error message
  ///
  /// In en, this message translates to:
  /// **'Please enter a valid email'**
  String get pleaseEnterAValidEmail;

  /// Password validation error message
  ///
  /// In en, this message translates to:
  /// **'Please enter your password'**
  String get pleaseEnterYourPassword;

  /// Password length validation error message
  ///
  /// In en, this message translates to:
  /// **'Password must be at least 6 characters'**
  String get passwordMustBeAtLeast6Characters;

  /// Confirm password validation error message
  ///
  /// In en, this message translates to:
  /// **'Please confirm your password'**
  String get pleaseConfirmYourPassword;

  /// Password mismatch error message
  ///
  /// In en, this message translates to:
  /// **'Passwords do not match'**
  String get passwordsDoNotMatch;

  /// Creating account status message
  ///
  /// In en, this message translates to:
  /// **'Creating account...'**
  String get creatingAccount;

  /// Signing in status message
  ///
  /// In en, this message translates to:
  /// **'Signing in...'**
  String get signingIn;

  /// Create account button text
  ///
  /// In en, this message translates to:
  /// **'Create Account'**
  String get createAccount;

  /// Welcome back heading text
  ///
  /// In en, this message translates to:
  /// **'Welcome Back'**
  String get welcomeBack;

  /// Sign up subtitle text
  ///
  /// In en, this message translates to:
  /// **'Sign up with your email'**
  String get signUpWithYourEmail;

  /// Sign in subtitle text
  ///
  /// In en, this message translates to:
  /// **'Sign in to continue'**
  String get signInToContinue;

  /// Forgot password link text
  ///
  /// In en, this message translates to:
  /// **'Forgot Password?'**
  String get forgotPassword;

  /// Sign in button text
  ///
  /// In en, this message translates to:
  /// **'Sign In'**
  String get signIn;

  /// Sign up button text
  ///
  /// In en, this message translates to:
  /// **'Sign Up'**
  String get signUp;

  /// Already have an account prompt
  ///
  /// In en, this message translates to:
  /// **'Already have an account?'**
  String get alreadyHaveAnAccount;

  /// Don't have an account prompt
  ///
  /// In en, this message translates to:
  /// **'Don\'t have an account?'**
  String get dontHaveAnAccount;

  /// Recovery successful message
  ///
  /// In en, this message translates to:
  /// **'Recovery successful! Welcome back.'**
  String get recoverySuccessfulWelcomeBack;

  /// Approval request sent message
  ///
  /// In en, this message translates to:
  /// **'Approval request sent! Approve from another device.'**
  String get approvalRequestSent;

  /// Checking account status message
  ///
  /// In en, this message translates to:
  /// **'Checking account status...'**
  String get checkingAccountStatus;

  /// Recover your account heading
  ///
  /// In en, this message translates to:
  /// **'Recover Your Account'**
  String get recoverYourAccount;

  /// Account recovery required heading
  ///
  /// In en, this message translates to:
  /// **'Account Recovery Required'**
  String get accountRecoveryRequired;

  /// No active devices with recovery key message
  ///
  /// In en, this message translates to:
  /// **'No active devices found. Use your recovery passphrase to restore access to your encrypted notes.'**
  String get noActiveDevicesRecoveryKey;

  /// No active devices without recovery key message
  ///
  /// In en, this message translates to:
  /// **'No active devices found and no recovery key is set up. You can start fresh with a new account, but your previous notes cannot be recovered.'**
  String get noActiveDevicesNoRecoveryKey;

  /// Previous notes encrypted warning message
  ///
  /// In en, this message translates to:
  /// **'Your previous notes are encrypted and cannot be recovered without a recovery key.'**
  String get previousNotesEncryptedWarning;

  /// Not your main device question
  ///
  /// In en, this message translates to:
  /// **'Not your main device?'**
  String get notYourMainDevice;

  /// Another device approval hint message
  ///
  /// In en, this message translates to:
  /// **'If you have another device with access to your notes, you can request approval from that device.'**
  String get anotherDeviceApprovalHint;

  /// Requesting status message
  ///
  /// In en, this message translates to:
  /// **'Requesting...'**
  String get requesting;

  /// Request approval from another device button text
  ///
  /// In en, this message translates to:
  /// **'Request Approval from Another Device'**
  String get requestApprovalFromAnotherDevice;

  /// Signing out status message
  ///
  /// In en, this message translates to:
  /// **'Signing out...'**
  String get signingOut;

  /// Taking too long timeout message
  ///
  /// In en, this message translates to:
  /// **'Taking too long. You can cancel and try again.'**
  String get takingTooLongTryAgain;

  /// Request timed out message
  ///
  /// In en, this message translates to:
  /// **'Request timed out. Please try again.'**
  String get requestTimedOut;

  /// Failed to send verification code error message
  ///
  /// In en, this message translates to:
  /// **'Failed to send verification code'**
  String get failedToSendVerificationCode;

  /// Your email fallback text
  ///
  /// In en, this message translates to:
  /// **'your email'**
  String get yourEmail;

  /// Continue button label
  ///
  /// In en, this message translates to:
  /// **'Continue'**
  String get continueLabel;

  /// Please confirm consequences message
  ///
  /// In en, this message translates to:
  /// **'Please confirm that you understand the consequences'**
  String get pleaseConfirmConsequences;

  /// Account reset successfully message
  ///
  /// In en, this message translates to:
  /// **'Account reset successfully. Welcome!'**
  String get accountResetSuccessfully;

  /// Failed to reset account error message
  ///
  /// In en, this message translates to:
  /// **'Failed to reset account'**
  String get failedToResetAccount;

  /// Failed to reset account with error message
  ///
  /// In en, this message translates to:
  /// **'Failed to reset account: {error}'**
  String failedToResetAccountError(String error);

  /// Start fresh confirmation title
  ///
  /// In en, this message translates to:
  /// **'Start Fresh?'**
  String get startFreshQuestion;

  /// This action will heading
  ///
  /// In en, this message translates to:
  /// **'This action will:'**
  String get thisActionWill;

  /// Remove all device authorizations consequence
  ///
  /// In en, this message translates to:
  /// **'Remove all device authorizations'**
  String get removeAllDeviceAuthorizations;

  /// Make old notes unrecoverable consequence
  ///
  /// In en, this message translates to:
  /// **'Make your old notes unrecoverable'**
  String get makeOldNotesUnrecoverable;

  /// Create new encryption key consequence
  ///
  /// In en, this message translates to:
  /// **'Create a new encryption key'**
  String get createNewEncryptionKey;

  /// Start with blank account consequence
  ///
  /// In en, this message translates to:
  /// **'Start with a blank account'**
  String get startWithBlankAccount;

  /// I understand old notes inaccessible checkbox text
  ///
  /// In en, this message translates to:
  /// **'I understand that my old notes will be permanently inaccessible'**
  String get iUnderstandOldNotesInaccessible;

  /// Save to gallery menu item
  ///
  /// In en, this message translates to:
  /// **'Save to Gallery'**
  String get saveToGallery;

  /// New label for add page button
  ///
  /// In en, this message translates to:
  /// **'New'**
  String get newLabel;

  /// Pick paper color dialog title
  ///
  /// In en, this message translates to:
  /// **'Pick Paper Color'**
  String get pickPaperColor;

  /// Pick pen color dialog title
  ///
  /// In en, this message translates to:
  /// **'Pick Pen Color'**
  String get pickPenColor;

  /// Saved to gallery success message
  ///
  /// In en, this message translates to:
  /// **'Saved to Gallery'**
  String get savedToGallery;

  /// Sketch downloaded success message for web
  ///
  /// In en, this message translates to:
  /// **'Sketch downloaded'**
  String get sketchDownloaded;

  /// Failed to save sketch error message
  ///
  /// In en, this message translates to:
  /// **'Failed to save sketch'**
  String get failedToSaveSketch;

  /// Error saving sketch with details
  ///
  /// In en, this message translates to:
  /// **'Error saving sketch: {error}'**
  String errorSavingSketch(String error);

  /// Free plan name for display
  ///
  /// In en, this message translates to:
  /// **'Free'**
  String get planFree;

  /// Pro plan name for display
  ///
  /// In en, this message translates to:
  /// **'Pro'**
  String get planPro;

  /// Error message when user has reached the locked notes limit
  ///
  /// In en, this message translates to:
  /// **'You\'ve reached the limit of {count} locked notes'**
  String lockedNotesLimitReached(int count);

  /// Error message when free user tries to use real-time cloud sync
  ///
  /// In en, this message translates to:
  /// **'Real-time cloud sync requires a Pro subscription'**
  String get realtimeCloudSyncRequiresPro;

  /// Description of unlimited locked notes feature
  ///
  /// In en, this message translates to:
  /// **'Unlimited locked notes'**
  String get unlimitedLockedNotes;

  /// Description of real-time cloud sync feature
  ///
  /// In en, this message translates to:
  /// **'Real-time cloud sync'**
  String get realtimeCloudSync;

  /// Upgrade button text
  ///
  /// In en, this message translates to:
  /// **'Upgrade'**
  String get upgrade;

  /// Upgrade to Pro heading/button text
  ///
  /// In en, this message translates to:
  /// **'Upgrade to Pro'**
  String get upgradeToPro;

  /// Unlock a specific feature message
  ///
  /// In en, this message translates to:
  /// **'Unlock {feature}'**
  String unlockFeature(String feature);

  /// Message indicating a feature requires Pro subscription
  ///
  /// In en, this message translates to:
  /// **'{feature} requires Pro'**
  String featureRequiresPro(String feature);

  /// Generic message that a feature requires Pro
  ///
  /// In en, this message translates to:
  /// **'This feature requires Pro'**
  String get thisFeatureRequiresPro;

  /// Message indicating a feature is a Pro feature
  ///
  /// In en, this message translates to:
  /// **'{feature} is a Pro feature.'**
  String featureIsProFeature(String feature);

  /// Message encouraging upgrade to unlock all features
  ///
  /// In en, this message translates to:
  /// **'Unlock all features and support development.'**
  String get unlockAllFeatures;

  /// Description of unlimited PIN locks feature
  ///
  /// In en, this message translates to:
  /// **'Protect unlimited notes with PIN locks'**
  String get protectUnlimitedNotesWithPin;

  /// Description of secure sync feature
  ///
  /// In en, this message translates to:
  /// **'Sync across all your devices securely'**
  String get syncAcrossDevicesSecurely;

  /// Combined description of Pro features
  ///
  /// In en, this message translates to:
  /// **'Unlimited locked notes and real-time cloud sync'**
  String get unlimitedLockedNotesAndSync;

  /// Paywall heading to unlock full experience
  ///
  /// In en, this message translates to:
  /// **'Unlock the Full Experience'**
  String get unlockTheFullExperience;

  /// Dismiss/skip button text for paywall
  ///
  /// In en, this message translates to:
  /// **'Maybe later'**
  String get maybeLater;

  /// Title for the dialog prompting notification permissions after sync restores reminders
  ///
  /// In en, this message translates to:
  /// **'Enable Notifications'**
  String get enableNotificationsTitle;

  /// Body text for the notification permission dialog after sync restores reminders
  ///
  /// In en, this message translates to:
  /// **'Your synced notes have reminders. Enable notifications so you don\'t miss them.'**
  String get enableNotificationsForReminders;

  /// Button to enable notifications in the reminder permission dialog
  ///
  /// In en, this message translates to:
  /// **'Enable'**
  String get enableNotifications;

  /// Sidebar item to rate the app on the App Store (iOS)
  ///
  /// In en, this message translates to:
  /// **'Rate on App Store'**
  String get rateOnAppStore;

  /// Sidebar item to rate the app on the Play Store (Android)
  ///
  /// In en, this message translates to:
  /// **'Rate on Play Store'**
  String get rateOnPlayStore;

  /// Sidebar item to rate the app on the Microsoft Store (Windows)
  ///
  /// In en, this message translates to:
  /// **'Rate on Microsoft Store'**
  String get rateOnMicrosoftStore;

  /// Tooltip and menu title for note sorting
  ///
  /// In en, this message translates to:
  /// **'Sort by'**
  String get sortBy;

  /// Manual note ordering option
  ///
  /// In en, this message translates to:
  /// **'Custom'**
  String get sortCustom;

  /// Newest-created note sorting option
  ///
  /// In en, this message translates to:
  /// **'Date created'**
  String get sortCreatedNewest;

  /// Most-recently-updated note sorting option
  ///
  /// In en, this message translates to:
  /// **'Date updated'**
  String get sortUpdatedNewest;

  /// Accessible label for whole-card note reordering
  ///
  /// In en, this message translates to:
  /// **'Press and hold to reorder'**
  String get dragToReorder;

  /// Accessible action to move a note earlier in its section
  ///
  /// In en, this message translates to:
  /// **'Move note before'**
  String get moveNoteBefore;

  /// Accessible action to move a note later in its section
  ///
  /// In en, this message translates to:
  /// **'Move note after'**
  String get moveNoteAfter;

  /// Message shown for an invalid cross-section note move
  ///
  /// In en, this message translates to:
  /// **'Pinned and unpinned notes are arranged separately.'**
  String get pinnedReorderBoundary;

  /// Message shown when manual note ordering cannot be saved
  ///
  /// In en, this message translates to:
  /// **'Could not save the new note order. Your previous order was restored.'**
  String get reorderSaveFailed;

  /// Title and tooltip for configuring note view and sorting
  ///
  /// In en, this message translates to:
  /// **'Note display options'**
  String get noteDisplayOptions;

  /// Error shown when note display options cannot be saved
  ///
  /// In en, this message translates to:
  /// **'Could not save the note display options. Please try again.'**
  String get noteDisplayOptionsSaveFailed;

  /// Accessibility announcement after note display options are saved
  ///
  /// In en, this message translates to:
  /// **'Note display options saved'**
  String get noteDisplayOptionsSaved;

  /// Guidance shown when custom note sorting enables manual reordering
  ///
  /// In en, this message translates to:
  /// **'Press and hold a note, then drag to rearrange it.'**
  String get reorderCustomHint;

  /// Guidance explaining why manual reordering is unavailable in date sort modes
  ///
  /// In en, this message translates to:
  /// **'Manual rearranging is unavailable while sorting by date. Choose Custom to rearrange notes.'**
  String get reorderDateSortHint;

  /// Title for the Google Keep import flow
  ///
  /// In en, this message translates to:
  /// **'Import from Google Keep'**
  String get googleKeepImportTitle;

  /// Help-page summary for Google Keep import
  ///
  /// In en, this message translates to:
  /// **'Move a Google Takeout archive locally—no upload required.'**
  String get googleKeepImportHelpSubtitle;

  /// Privacy heading in the Google Keep importer
  ///
  /// In en, this message translates to:
  /// **'Your archive stays on this device'**
  String get googleKeepImportPrivacyTitle;

  /// Local-processing explanation in the Google Keep importer
  ///
  /// In en, this message translates to:
  /// **'Better Keep validates and converts the Google Takeout archive locally. It does not upload the ZIP to a conversion service. Notes only enter the normal optional sync flow after the import commits successfully.'**
  String get googleKeepImportPrivacyDescription;

  /// Heading before Google Keep export instructions
  ///
  /// In en, this message translates to:
  /// **'Before you start'**
  String get googleKeepImportBeforeStart;

  /// Steps for preparing a Google Keep export
  ///
  /// In en, this message translates to:
  /// **'1. Open Google Takeout and select only Keep.\n2. Create and download the export.\n3. Choose the ZIP below. Exact re-imports are skipped by default.'**
  String get googleKeepImportInstructions;

  /// Action to choose a Google Takeout ZIP
  ///
  /// In en, this message translates to:
  /// **'Choose Takeout ZIP'**
  String get googleKeepChooseZip;

  /// Action to open Google Takeout help
  ///
  /// In en, this message translates to:
  /// **'Open Google Takeout instructions'**
  String get googleKeepOpenTakeoutInstructions;

  /// Action to cancel a Google Keep import
  ///
  /// In en, this message translates to:
  /// **'Cancel import'**
  String get googleKeepCancelImport;

  /// Message after cancelling a Google Keep import
  ///
  /// In en, this message translates to:
  /// **'Import cancelled. No notes were saved.'**
  String get googleKeepImportCancelled;

  /// Generic Google Keep import failure message
  ///
  /// In en, this message translates to:
  /// **'The import failed. Check your selection and try again.'**
  String get googleKeepImportFailed;

  /// Title for a shared Google Keep import report
  ///
  /// In en, this message translates to:
  /// **'Better Keep Google Keep import report'**
  String get googleKeepImportReportTitle;

  /// Google Keep import validation progress
  ///
  /// In en, this message translates to:
  /// **'Validating Google Takeout archive…'**
  String get googleKeepImportValidating;

  /// Google Keep import parsing progress
  ///
  /// In en, this message translates to:
  /// **'Reading Google Keep notes…'**
  String get googleKeepImportParsing;

  /// Google Keep attachment preparation progress
  ///
  /// In en, this message translates to:
  /// **'Preparing imported attachments…'**
  String get googleKeepImportPreparingAttachments;

  /// Google Keep import save progress
  ///
  /// In en, this message translates to:
  /// **'Saving imported notes…'**
  String get googleKeepImportSaving;

  /// Initial Google Keep import progress
  ///
  /// In en, this message translates to:
  /// **'Starting import…'**
  String get googleKeepImportStarting;

  /// Google Keep import completion heading
  ///
  /// In en, this message translates to:
  /// **'Import complete'**
  String get googleKeepImportComplete;

  /// Google Keep import safety limits heading
  ///
  /// In en, this message translates to:
  /// **'Safety limits'**
  String get googleKeepSafetyLimits;

  /// Google Keep import safety limit explanation
  ///
  /// In en, this message translates to:
  /// **'ZIP files are limited to 100 MB compressed, 500 MB expanded, 20,000 files, and 50 MB per file. Unsafe paths, symbolic links, and malformed archives are rejected before notes are saved.'**
  String get googleKeepSafetyDescription;

  /// Imported-note count label
  ///
  /// In en, this message translates to:
  /// **'Imported'**
  String get googleKeepImported;

  /// Skipped-note count label
  ///
  /// In en, this message translates to:
  /// **'Skipped'**
  String get googleKeepSkipped;

  /// Google Keep import warning count label
  ///
  /// In en, this message translates to:
  /// **'Warnings'**
  String get googleKeepWarnings;

  /// Unsupported-item count label
  ///
  /// In en, this message translates to:
  /// **'Unsupported'**
  String get googleKeepUnsupported;

  /// Failed-item count label
  ///
  /// In en, this message translates to:
  /// **'Failed'**
  String get googleKeepFailed;

  /// Heading for Google Keep import issues
  ///
  /// In en, this message translates to:
  /// **'Review import details'**
  String get googleKeepReviewDetails;

  /// Action to share a Google Keep import report
  ///
  /// In en, this message translates to:
  /// **'Share full report'**
  String get googleKeepShareReport;

  /// Action and search-field label for finding text in the open note
  ///
  /// In en, this message translates to:
  /// **'Find in note'**
  String get findInNote;

  /// Replace the current search match
  ///
  /// In en, this message translates to:
  /// **'Replace'**
  String get replace;

  /// Replace every search match
  ///
  /// In en, this message translates to:
  /// **'Replace all'**
  String get replaceAll;

  /// Expand the replacement controls
  ///
  /// In en, this message translates to:
  /// **'Show replace'**
  String get showReplace;

  /// Collapse the replacement controls
  ///
  /// In en, this message translates to:
  /// **'Hide replace'**
  String get hideReplace;

  /// Navigate to the previous in-note search match
  ///
  /// In en, this message translates to:
  /// **'Previous match'**
  String get previousMatch;

  /// Navigate to the next in-note search match
  ///
  /// In en, this message translates to:
  /// **'Next match'**
  String get nextMatch;

  /// Open advanced in-note search options
  ///
  /// In en, this message translates to:
  /// **'Search options'**
  String get searchOptions;

  /// Case-sensitive search option
  ///
  /// In en, this message translates to:
  /// **'Match case'**
  String get matchCase;

  /// Whole-word search option
  ///
  /// In en, this message translates to:
  /// **'Match whole word'**
  String get matchWholeWord;

  /// Fuzzy in-note search mode
  ///
  /// In en, this message translates to:
  /// **'Smart match'**
  String get smartMatch;

  /// Explanation of smart in-note search
  ///
  /// In en, this message translates to:
  /// **'Find typos and abbreviations'**
  String get smartMatchDescription;

  /// Advanced regular-expression search mode
  ///
  /// In en, this message translates to:
  /// **'Regular expression (advanced)'**
  String get regularExpressionAdvanced;

  /// Invalid regex search error
  ///
  /// In en, this message translates to:
  /// **'Invalid regular expression'**
  String get invalidRegularExpression;

  /// Unsupported empty regex match error
  ///
  /// In en, this message translates to:
  /// **'Patterns that only match empty text aren\'t supported'**
  String get zeroLengthRegexUnsupported;

  /// Invalid regex replacement capture error
  ///
  /// In en, this message translates to:
  /// **'Replacement refers to a missing capture group'**
  String get invalidReplacementReference;

  /// Empty state for in-note search
  ///
  /// In en, this message translates to:
  /// **'No matches'**
  String get noMatches;

  /// Accessible label while in-note search is running
  ///
  /// In en, this message translates to:
  /// **'Searching'**
  String get searching;

  /// Current and total in-note search match count
  ///
  /// In en, this message translates to:
  /// **'{current} of {total}'**
  String searchResultCount(int current, int total);

  /// Result after replacing all in-note search matches
  ///
  /// In en, this message translates to:
  /// **'Replaced {count} occurrences'**
  String replacedOccurrences(int count);

  /// No description provided for @labelFiltering.
  ///
  /// In en, this message translates to:
  /// **'Label filtering'**
  String get labelFiltering;

  /// No description provided for @strict.
  ///
  /// In en, this message translates to:
  /// **'Strict'**
  String get strict;

  /// No description provided for @matchAllSelectedLabelsHint.
  ///
  /// In en, this message translates to:
  /// **'Only show notes containing every selected label.'**
  String get matchAllSelectedLabelsHint;

  /// No description provided for @matchAnySelectedLabelHint.
  ///
  /// In en, this message translates to:
  /// **'Show notes containing at least one selected label.'**
  String get matchAnySelectedLabelHint;

  /// Confirm creating a pending label from the sidebar labels dialog
  ///
  /// In en, this message translates to:
  /// **'Create “{name}”?'**
  String createLabelConfirmation(String name);

  /// Confirm creating a pending label and selecting it for the current note
  ///
  /// In en, this message translates to:
  /// **'Create “{name}” and add it to this note?'**
  String createAndApplyLabelConfirmation(String name);

  /// Label save failure shown without discarding the pending name
  ///
  /// In en, this message translates to:
  /// **'Couldn’t save label. Try again.'**
  String get couldNotSaveLabel;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) => <String>[
    'en',
    'id',
    'ja',
    'ko',
    'pt',
    'tr',
    'zh',
  ].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
    case 'id':
      return AppLocalizationsId();
    case 'ja':
      return AppLocalizationsJa();
    case 'ko':
      return AppLocalizationsKo();
    case 'pt':
      return AppLocalizationsPt();
    case 'tr':
      return AppLocalizationsTr();
    case 'zh':
      return AppLocalizationsZh();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
