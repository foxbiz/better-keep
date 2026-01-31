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
    Locale('zh'),
  ];

  /// The name of the application
  ///
  /// In en, this message translates to:
  /// **'Better Keep'**
  String get appTitle;

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

  /// Paste as dialog title
  ///
  /// In en, this message translates to:
  /// **'Paste as'**
  String get pasteAs;

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

  /// Upgrade to Pro heading/button text
  ///
  /// In en, this message translates to:
  /// **'Upgrade to Pro'**
  String get upgradeToPro;

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

  /// Request timed out message
  ///
  /// In en, this message translates to:
  /// **'Request timed out. Please try again.'**
  String get requestTimedOut;

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

  /// Error saving sketch with details
  ///
  /// In en, this message translates to:
  /// **'Error saving sketch: {error}'**
  String errorSavingSketch(String error);

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

  /// Install app button label
  ///
  /// In en, this message translates to:
  /// **'Install App'**
  String get installApp;

  /// Not now button label
  ///
  /// In en, this message translates to:
  /// **'Not now'**
  String get notNow;

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

  /// Password mismatch error message
  ///
  /// In en, this message translates to:
  /// **'Passwords do not match'**
  String get passwordsDoNotMatch;

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

  /// Sending verification code message
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

  /// Open source section title
  ///
  /// In en, this message translates to:
  /// **'Open Source'**
  String get openSource;

  /// Open source description
  ///
  /// In en, this message translates to:
  /// **'Better Keep is open source! View the code,\ncontribute, or report issues on GitHub.'**
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

  /// Reminders navigation item
  ///
  /// In en, this message translates to:
  /// **'Reminders'**
  String get reminders;

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

  /// Cancel subscription confirmation message
  ///
  /// In en, this message translates to:
  /// **'Are you sure you want to cancel your subscription?\n\nYour subscription will remain active until the end of the current billing period. After that, you will lose access to Pro features.'**
  String get cancelSubscriptionConfirmation;

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

  /// Recovery key saved success message
  ///
  /// In en, this message translates to:
  /// **'Recovery key saved successfully!'**
  String get recoveryKeySavedSuccessfully;

  /// No recovery key warning message
  ///
  /// In en, this message translates to:
  /// **'Without a recovery key, you will permanently lose access to all your encrypted notes if you lose all your devices.\n\nConsider setting up a recovery key later in Settings.'**
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

  /// Verify your identity dialog title
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

  /// No labels yet empty state
  ///
  /// In en, this message translates to:
  /// **'No labels yet'**
  String get noLabelsYet;

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

  /// Delete forever dialog title
  ///
  /// In en, this message translates to:
  /// **'Delete Forever'**
  String get deleteForever;

  /// Sent verification code message
  ///
  /// In en, this message translates to:
  /// **'We sent a verification code to:'**
  String get sentVerificationCodeTo;

  /// Please enter 6-digit code validation
  ///
  /// In en, this message translates to:
  /// **'Please enter a 6-digit code'**
  String get pleaseEnterSixDigitCode;

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

  /// Encrypted note cannot be decrypted message
  ///
  /// In en, this message translates to:
  /// **'This note could not be decrypted. The encryption keys are missing or invalid, and the note cannot be recovered.'**
  String get encryptedNoteCannotBeDecrypted;

  /// Decryption failed label
  ///
  /// In en, this message translates to:
  /// **'Decryption failed'**
  String get decryptionFailed;

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

  /// iOS app coming soon heading
  ///
  /// In en, this message translates to:
  /// **'📱 iOS App Coming Soon!'**
  String get iosAppComingSoon;

  /// iOS app being reviewed message
  ///
  /// In en, this message translates to:
  /// **'Our iOS app is being reviewed. In the meantime, you can install the web app:'**
  String get iosAppBeingReviewed;

  /// iOS install step 1
  ///
  /// In en, this message translates to:
  /// **'1. Tap the Share button in Safari'**
  String get iosInstallStep1;

  /// iOS install step 2
  ///
  /// In en, this message translates to:
  /// **'2. Scroll down and tap \"Add to Home Screen\"'**
  String get iosInstallStep2;

  /// iOS install step 3
  ///
  /// In en, this message translates to:
  /// **'3. Tap \"Add\" to install'**
  String get iosInstallStep3;

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

  /// iOS app coming soon dialog title
  ///
  /// In en, this message translates to:
  /// **'iOS App Coming Soon!'**
  String get iosAppComingSoonTitle;

  /// iOS app coming soon dialog message
  ///
  /// In en, this message translates to:
  /// **'Our iOS app is being reviewed by Apple. In the meantime, you can install Better Keep as a web app for quick access.\n\nTap Share → Add to Home Screen in Safari.'**
  String get iosAppComingSoonMessage;

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
