// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Chinese (`zh`).
class AppLocalizationsZh extends AppLocalizations {
  AppLocalizationsZh([String locale = 'zh']) : super(locale);

  @override
  String get appTitle => 'Better Keep';

  @override
  String get unableToStartApp => '无法启动 Better Keep';

  @override
  String get startupRetryMessage => '打开应用时出现问题。请重试。';

  @override
  String get startupRestartMessage => '打开应用时出现问题。请关闭并重新打开应用后重试。';

  @override
  String get accountNotFound => '未找到使用此电子邮件的账户。';

  @override
  String get invalidCredentials => '电子邮件或密码不正确。请重试。';

  @override
  String get accountDisabled => '此账户当前不可用。请联系支持人员。';

  @override
  String get paymentInProgress => '正在付款';

  @override
  String get completePaymentInBrowser => '请在浏览器中完成付款。完成后，此消息会自动关闭。';

  @override
  String get legal => '法律信息';

  @override
  String get termsOfUse => '使用条款';

  @override
  String get privacyPolicy => '隐私政策';

  @override
  String get appLogoSemantics => 'Better Keep 应用徽标';

  @override
  String get selectColor => '选择颜色';

  @override
  String get unsupportedTextFile => '不支持此文件类型。请选择 .txt 或 .md 文件。';

  @override
  String get sharedFileEmpty => '此文件为空。';

  @override
  String get fileNotFound => '找不到此文件。';

  @override
  String get fileTooLarge => '此文件太大。请选择小于 5 MB 的文件。';

  @override
  String get couldNotReadFile => '无法读取此文件。请尝试其他文件。';

  @override
  String get couldNotOpenFile => '无法打开此文件。请重试。';

  @override
  String get noteSaved => '笔记已保存';

  @override
  String get untitled => '无标题';

  @override
  String get failedToExportNote => '无法导出笔记。请重试。';

  @override
  String get failedToCopyNote => '无法复制笔记。请重试。';

  @override
  String get failedToDeleteSketch => '无法删除绘图。请重试。';

  @override
  String get lockedNoteReminder => '已锁定笔记的提醒';

  @override
  String get notesReminder => 'Better Keep 笔记提醒';

  @override
  String get blankPage => '空白';

  @override
  String get linedPage => '横线';

  @override
  String get doubleLinedPage => '双横线';

  @override
  String get gridPage => '方格';

  @override
  String get dotGridPage => '点阵';

  @override
  String get dataExportTitle => 'Better Keep 数据导出';

  @override
  String get dataExportShareText => '我的 Better Keep 数据导出';

  @override
  String get noteReminders => '笔记提醒';

  @override
  String get noteRemindersDescription => '笔记的定时提醒';

  @override
  String get deviceApproval => '设备批准';

  @override
  String get deviceApprovalDescription => '设备批准请求通知';

  @override
  String get newDeviceApprovalRequest => '新的设备批准请求';

  @override
  String deviceWantsAccess(String deviceName, String platform) {
    return '$deviceName（$platform）想要访问你的笔记';
  }

  @override
  String get sharedText => '共享文本';

  @override
  String get sharedFile => '共享文件';

  @override
  String get user => '用户';

  @override
  String get thirtyDaysFromNow => '30 天后';

  @override
  String get helpRequestSubject => 'Better Keep - 帮助请求';

  @override
  String get faqCreateNoteQuestion => '如何新建笔记？';

  @override
  String get faqCreateNoteAnswer => '点击主屏幕底部的 + 按钮。你可以添加文本、图片、音频等内容。';

  @override
  String get faqShortcutsQuestion => '如何使用快捷方式？';

  @override
  String get faqShortcutsAnswer =>
      '长按 + 按钮可显示图片、音频、绘图或待办事项快捷方式。滑动到所需选项后松开。轻点则会打开空白笔记。';

  @override
  String get faqLabelsQuestion => '如何使用标签整理笔记？';

  @override
  String get faqLabelsAnswer => '打开笔记并点击标签图标即可添加或创建标签。你可以从侧边菜单按标签筛选笔记。';

  @override
  String get faqReminderQuestion => '如何设置提醒？';

  @override
  String get faqReminderAnswer => '打开笔记并点击提醒图标，然后选择日期和时间。';

  @override
  String get faqArchiveDeleteQuestion => '如何归档或删除笔记？';

  @override
  String get faqArchiveDeleteAnswer =>
      '长按笔记进行选择，然后使用归档或删除操作。删除的笔记会先移到回收站，并可在回收站中永久删除。';

  @override
  String get faqThemeQuestion => '如何更改应用主题？';

  @override
  String get faqThemeAnswer => '打开设置并选择你喜欢的主题选项。';

  @override
  String get faqSyncQuestion => '如何在设备间同步笔记？';

  @override
  String get faqSyncAnswer => '登录后即可在你的所有设备上安全同步笔记。';

  @override
  String get faqReminderTimesQuestion => '如何设置上午、下午和晚上的时间？';

  @override
  String get faqReminderTimesAnswer => '打开设置并选择提醒时间设置，即可调整这些时间。';

  @override
  String get faqAlarmSoundQuestion => '如何更改闹钟声音？';

  @override
  String get faqAlarmSoundAnswer => '打开设置，选择闹钟声音，然后从可用声音中选择。';

  @override
  String get faqSecurityQuestion => '我的数据安全吗？';

  @override
  String get faqSecurityAnswer => '你的笔记会被安全存储。启用同步保护后，端到端加密会保护同步的数据。';

  @override
  String get faqApproveDeviceQuestion => '如何批准新设备？';

  @override
  String get faqApproveDeviceAnswer =>
      '在已批准的设备上打开 Better Keep。在个人资料中查看等待批准的设备，然后批准或拒绝请求。';

  @override
  String get faqDeleteAccountQuestion => '如何删除我的账户？';

  @override
  String get faqDeleteAccountAnswer =>
      '打开个人资料并选择删除账户。完成电子邮件验证后，账户将在 30 天后删除，并在所有设备上退出登录。';

  @override
  String get faqCancelDeletionQuestion => '可以取消删除账户吗？';

  @override
  String get faqCancelDeletionAnswer => '可以。在 30 天内重新登录，即可取消计划的删除并恢复账户访问。';

  @override
  String get faqDeletionEffectsQuestion => '删除账户后会怎样？';

  @override
  String get faqDeletionEffectsAnswer =>
      '所有设备会立即退出登录。30 天后，你的笔记、附件、标签和个人数据将被永久删除且无法恢复。';

  @override
  String get faqExportBeforeDeletionQuestion => '删除账户前可以导出数据吗？';

  @override
  String get faqExportBeforeDeletionAnswer =>
      '可以。计划删除后，你可以导出数据。请在 30 天期限结束前下载。';

  @override
  String get iosAppAvailable =>
      'Better Keep 已在 App Store 上架。下载应用即可使用通知、小组件等功能。';

  @override
  String get openAppStore => '打开 App Store';

  @override
  String get tasks => '任务';

  @override
  String get unknown => '未知';

  @override
  String get exportAttachments => '附件';

  @override
  String get created => '创建时间';

  @override
  String get updated => '更新时间';

  @override
  String get oneTime => '一次';

  @override
  String get lockedExportExplanation =>
      '这些笔记已锁定。受保护的内容会保留在此导出中，并且只能使用原 PIN 打开。';

  @override
  String dataExportReadme(String exportedAt) {
    return 'Better Keep - 数据导出\n\n此归档包含导出的笔记、标签、附件和导出信息。可打开的笔记也会以 Markdown 文件提供。已锁定的笔记仍受保护，需要原 PIN 才能打开。\n\n如需帮助，请联系 contact@betterkeep.app。\n\n导出时间：$exportedAt';
  }

  @override
  String get paymentSuccessful => '付款成功';

  @override
  String get paymentSuccessfulReturn => '你可以关闭此窗口并返回 Better Keep。';

  @override
  String get paymentCancelledClose => '付款已取消。你可以关闭此窗口。';

  @override
  String get appleSignInVerificationFailed => '无法验证 Apple 登录。请重试。';

  @override
  String get reminderType => '提醒类型';

  @override
  String get notificationReminder => '通知';

  @override
  String get notificationReminderDescription => '显示标准的时效性通知';

  @override
  String get alarmReminder => '闹钟';

  @override
  String get alarmReminderDescription => '持续响铃，直到你将其停止';

  @override
  String get alarmUnsupportedPlatform =>
      '此平台不支持闹钟。提醒将同步，并在 Android 或 iOS 上设置为闹钟。';

  @override
  String get notificationUnsupportedPlatform =>
      '在此平台上，Better Keep 关闭时无法发送定时通知。提醒仍会同步，并在到期时显示在应用中。';

  @override
  String get alarmRequiresSpecificTime => '闹钟需要具体时间；全天仅适用于通知。';

  @override
  String get reminderDue => '提醒已到期';

  @override
  String get overdueReminderTitle => '逾期提醒';

  @override
  String get overdueReminderMessage => '此提醒已逾期。现在标记为完成吗？';

  @override
  String get markReminderDoneFailed => '无法将此提醒标记为完成。请重试。';

  @override
  String get markAsDone => '标记为完成';

  @override
  String get reminderSavedPermissionRequired => '提醒已保存，但需要权限才能在此设备上进行定时。';

  @override
  String get reminderSavedAlreadyDue => '提醒已保存，并且已经到期。';

  @override
  String get reminderScheduleFailed => '提醒已保存，但此设备无法安排通知。';

  @override
  String get reminderCapacityExceeded => '提醒已保存，但此设备的待处理提醒过多，无法再安排新的提醒。';

  @override
  String get reminderTimeZoneUnavailable =>
      '提醒已保存，但无法识别此设备的时区。请检查设备的日期和时间设置后重试。';

  @override
  String get cancel => '取消';

  @override
  String get ok => '确定';

  @override
  String get save => '保存';

  @override
  String get delete => '删除';

  @override
  String get close => '关闭';

  @override
  String get retry => '重试';

  @override
  String get protectedSketchTitle => '受保护的草图';

  @override
  String get protectedSketchRecoveryMessage =>
      '暂时无法恢复这个旧版受保护草图。原始加密绘图已保留，应用会在下次成功解锁后重试。';

  @override
  String get sketchBackgroundUnavailable => '背景不可用；绘图已保留';

  @override
  String get discard => '丢弃';

  @override
  String get attachmentCommitFailedTitle => '无法添加附件';

  @override
  String get attachmentCommitFailedMessage => '原始文件仍然安全。请重试添加，或从此设备丢弃。';

  @override
  String get done => '完成';

  @override
  String get remove => '移除';

  @override
  String get open => '打开';

  @override
  String get select => '选择';

  @override
  String get verify => '验证';

  @override
  String get link => '链接';

  @override
  String get unlink => '取消链接';

  @override
  String get approve => '批准';

  @override
  String get deny => '拒绝';

  @override
  String get primary => '主要';

  @override
  String get signOut => '退出登录';

  @override
  String get signOutAnyway => '仍然退出';

  @override
  String get continueOffline => '离线继续';

  @override
  String get cancelSignIn => '取消登录';

  @override
  String get signInCancelled => '登录已取消';

  @override
  String get signInWithFacebook => '使用 Facebook 登录';

  @override
  String get signInWithGithub => '使用 GitHub 登录';

  @override
  String get signInWithEmail => '使用邮箱登录';

  @override
  String get about => '关于';

  @override
  String get help => '帮助';

  @override
  String get settings => '设置';

  @override
  String get labels => '标签';

  @override
  String get addLink => '添加链接';

  @override
  String get editLink => '编辑链接';

  @override
  String get setReminder => '设置提醒';

  @override
  String get displayText => '显示文字';

  @override
  String get enterDisplayText => '输入要显示的文字';

  @override
  String get pleaseEnterDisplayText => '请输入显示文字';

  @override
  String get url => '网址';

  @override
  String get urlHint => 'https://example.com';

  @override
  String get titleYourThought => '为你的想法命名';

  @override
  String get email => '邮箱';

  @override
  String get emailHint => 'you@example.com';

  @override
  String get enterEmailAddress => '输入你的邮箱地址';

  @override
  String get password => '密码';

  @override
  String get confirmPassword => '确认密码';

  @override
  String get newPassword => '新密码';

  @override
  String get enterNewPassword => '输入新密码';

  @override
  String get reenterNewPassword => '再次输入新密码';

  @override
  String get currentPassphrase => '当前密码短语';

  @override
  String get enterYourPassphrase => '输入你的密码短语';

  @override
  String get enterCurrentPassphrase => '输入你的当前密码短语';

  @override
  String get recoveryPassphrase => '恢复密码短语';

  @override
  String get enterStrongPassphrase => '输入一个强密码短语';

  @override
  String get confirmPassphrase => '确认密码短语';

  @override
  String get reenterPassphrase => '再次输入你的密码短语';

  @override
  String get newPassphrase => '新密码短语';

  @override
  String get confirmNewPassphrase => '确认新密码短语';

  @override
  String get reenterNewPassphrase => '再次输入你的新密码短语';

  @override
  String get hintOptional => '提示（可选）';

  @override
  String get hintToRemember => '帮助你记住的提示';

  @override
  String get pin => 'PIN 码';

  @override
  String get enterPin => '输入 PIN 码';

  @override
  String get newLabelName => '新标签名称';

  @override
  String get addLabel => '添加标签';

  @override
  String get searchLogs => '搜索日志...';

  @override
  String get audioRecording => '音频录音';

  @override
  String get deleteRecording => '删除录音';

  @override
  String get title => '标题';

  @override
  String get enterRecordingTitle => '输入此录音的标题';

  @override
  String get theme => '主题';

  @override
  String get customizeAppearance => '自定义应用外观';

  @override
  String get followSystemTheme => '跟随系统主题';

  @override
  String get autoSwitchLightDark => '自动切换浅色和深色模式';

  @override
  String get followSystemAnimations => '跟随系统动画偏好';

  @override
  String get reduceAnimationsFromSystem => '当设备或浏览器设置启用时减少动画';

  @override
  String get darkMode => '深色模式';

  @override
  String get darkTheme => '深色主题';

  @override
  String get lightTheme => '浅色主题';

  @override
  String get showSyncProgress => '显示同步进度';

  @override
  String get displaySyncStatus => '显示同步状态指示器';

  @override
  String get alarmSound => '闹钟铃声';

  @override
  String get reminderTimeSettings => '提醒时间设置';

  @override
  String get setDefaultTimes => '设置提醒的默认时间';

  @override
  String get morning => '上午';

  @override
  String get afternoon => '下午';

  @override
  String get evening => '晚上';

  @override
  String get localDataProtection => '本地数据保护';

  @override
  String get encryptDeviceData => '加密存储在此设备上的数据';

  @override
  String get encryptNotes => '加密笔记';

  @override
  String get encryptFiles => '加密文件';

  @override
  String get lockedNotesSecurity => '锁定笔记安全';

  @override
  String get privacyLockedNotes => '锁定笔记的隐私设置';

  @override
  String get forgetPasswordOnClose => '关闭时忘记密码';

  @override
  String get requirePasswordAgain => '每次打开应用时需要密码';

  @override
  String get nerdStats => '开发者统计';

  @override
  String get developer => '开发者';

  @override
  String get contactUs => '联系我们';

  @override
  String get developedBy => '开发者';

  @override
  String get viewOnGithub => '在 GitHub 上查看';

  @override
  String get archive => '归档';

  @override
  String get unarchive => '取消归档';

  @override
  String get readOnly => '只读';

  @override
  String get locked => '已锁定';

  @override
  String get saveAs => '另存为';

  @override
  String get copyAs => '复制为';

  @override
  String get share => '分享';

  @override
  String get duplicate => '复制';

  @override
  String get markdown => 'Markdown';

  @override
  String get markdownFile => 'Markdown (.md)';

  @override
  String get html => 'HTML';

  @override
  String get htmlFile => 'HTML (.html)';

  @override
  String get plainText => '纯文本';

  @override
  String get plainTextFile => '纯文本 (.txt)';

  @override
  String get restore => '恢复';

  @override
  String get reminder => '提醒';

  @override
  String get hideKeyboard => '隐藏键盘';

  @override
  String get refresh => '刷新';

  @override
  String get dismiss => '关闭';

  @override
  String get back => '返回';

  @override
  String get copyToClipboard => '复制到剪贴板';

  @override
  String get copiedToClipboard => '已复制到剪贴板';

  @override
  String get scribble => '涂鸦';

  @override
  String get revokeLink => '撤销链接';

  @override
  String get expandToolbar => '展开工具栏';

  @override
  String get collapseToolbar => '收起工具栏';

  @override
  String get align => '对齐';

  @override
  String get textSize => '文字大小';

  @override
  String get indent => '缩进';

  @override
  String get attach => '附加';

  @override
  String get paperColor => '纸张颜色';

  @override
  String get pagePattern => '页面图案';

  @override
  String get moreOptions => '更多选项';

  @override
  String get move => '移动';

  @override
  String get viewAllPages => '查看所有页面';

  @override
  String get insert => '插入';

  @override
  String get importAsNote => '作为笔记导入';

  @override
  String get removeDevice => '移除设备';

  @override
  String get noteJson => '笔记 JSON';

  @override
  String get passwordResetSuccess => '密码重置成功！请登录。';

  @override
  String get emailVerifiedSuccess => '邮箱验证成功！';

  @override
  String get useDifferentAccount => '使用其他账户';

  @override
  String get recoverySuccessful => '恢复成功！访问已恢复。';

  @override
  String get deviceApproved => '设备已批准！';

  @override
  String get waitingForApproval => '等待批准中...';

  @override
  String get reapprovalRequestSent => '重新批准请求已发送。等待批准中...';

  @override
  String failedReapproval(String error) {
    return '请求重新批准失败：$error';
  }

  @override
  String get rememberDevice => '记住此设备';

  @override
  String get recoverWithPassphrase => '使用密码短语恢复';

  @override
  String get startFresh => '重新开始';

  @override
  String get startFreshInstead => '改为重新开始';

  @override
  String get requestReapproval => '请求重新批准';

  @override
  String get accessApproved => '访问已批准';

  @override
  String failedToApprove(String error) {
    return '批准失败：$error';
  }

  @override
  String get accessDenied => '访问被拒绝';

  @override
  String failedToDeny(String error) {
    return '拒绝失败：$error';
  }

  @override
  String get allUpToDate => '全部已是最新';

  @override
  String get upgradeNow => '立即升级';

  @override
  String get continueTrial => '继续试用';

  @override
  String get cancelSubscription => '取消订阅';

  @override
  String get keepSubscription => '保留订阅';

  @override
  String get linkingAccount => '正在链接账户...';

  @override
  String unlinkProvider(String provider) {
    return '取消链接 $provider？';
  }

  @override
  String unlinkedProvider(String provider) {
    return '已取消链接 $provider';
  }

  @override
  String successfullyLinked(String provider) {
    return '成功链接 $provider 账户';
  }

  @override
  String unknownProvider(String provider) {
    return '未知的提供商：$provider';
  }

  @override
  String get recoveryKey => '恢复密钥';

  @override
  String get manageRecoveryPassphrase => '管理你的恢复密码短语';

  @override
  String get enableE2EE => '启用端到端加密';

  @override
  String failedSaveRecoveryKey(String error) {
    return '保存恢复密钥失败：$error';
  }

  @override
  String get recoverySuccessWelcome => '恢复成功！欢迎回来。';

  @override
  String get confirmConsequences => '请确认你了解后果';

  @override
  String get accountResetSuccess => '账户重置成功。欢迎！';

  @override
  String failedResetAccount(String error) {
    return '重置账户失败：$error';
  }

  @override
  String errorSigningOut(String error) {
    return '退出登录错误：$error';
  }

  @override
  String errorPlayingSound(String error) {
    return '播放声音错误：$error';
  }

  @override
  String get checkNestedItems => '勾选嵌套项目？';

  @override
  String get uncheckNestedItems => '取消勾选嵌套项目？';

  @override
  String get yes => '是';

  @override
  String get no => '否';

  @override
  String get clipboardEmpty => '剪贴板为空';

  @override
  String get noteDeletedPermanently => '笔记已永久删除';

  @override
  String get reminderRemoved => '提醒已移除';

  @override
  String get reminderCompleted => '提醒已完成';

  @override
  String get reminderSet => '提醒已设置';

  @override
  String get failedCreateImageNote => '创建图片笔记失败';

  @override
  String errorSavingSketchWithError(String error) {
    return '保存草图错误：$error';
  }

  @override
  String get failedSaveNote => '保存笔记失败';

  @override
  String failedSave(String error) {
    return '保存失败：$error';
  }

  @override
  String copiedAs(String format) {
    return '已复制为 $format';
  }

  @override
  String failedCopy(String error) {
    return '复制失败：$error';
  }

  @override
  String get pastedAsPlainText => '已粘贴为纯文本';

  @override
  String failedPaste(String error) {
    return '粘贴失败：$error';
  }

  @override
  String get contentInserted => '内容已插入';

  @override
  String failedInsertContent(String error) {
    return '插入内容失败：$error';
  }

  @override
  String get actionCancelled => '操作已取消';

  @override
  String get noteLocked => '笔记已锁定';

  @override
  String failedLockNote(String error) {
    return '锁定笔记失败：$error';
  }

  @override
  String get lockRemoved => '锁定已移除';

  @override
  String failedRemoveLock(String error) {
    return '移除锁定失败：$error';
  }

  @override
  String get noteDuplicated => '笔记已复制';

  @override
  String get errorSavingNote => '保存笔记错误';

  @override
  String get contentShared => '内容已分享';

  @override
  String get failedShare => '分享失败';

  @override
  String get notes => '笔记';

  @override
  String get allNotes => '所有笔记';

  @override
  String get archivedNotes => '已归档';

  @override
  String get deletedNotes => '已删除';

  @override
  String get pinnedNotes => '已固定';

  @override
  String get otherNotes => '其他';

  @override
  String get noNotes => '还没有笔记';

  @override
  String get noArchivedNotes => '没有归档的笔记';

  @override
  String get noDeletedNotes => '没有删除的笔记';

  @override
  String get searchNotes => '搜索笔记';

  @override
  String nSelectedNotes(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '已选择 $count 条笔记',
      one: '已选择 1 条笔记',
    );
    return '$_temp0';
  }

  @override
  String get deleteNote => '删除笔记';

  @override
  String get deleteNotes => '删除笔记';

  @override
  String get moveToTrash => '移到回收站';

  @override
  String get deletePermanently => '永久删除';

  @override
  String get pinNote => '固定';

  @override
  String get unpinNote => '取消固定';

  @override
  String get newNote => '新建笔记';

  @override
  String get newSketch => '新建草图';

  @override
  String get newFolder => '新建文件夹';

  @override
  String get renameFolder => '重命名文件夹';

  @override
  String get deleteFolder => '删除文件夹';

  @override
  String get folderName => '文件夹名称';

  @override
  String get camera => '相机';

  @override
  String get gallery => '图库';

  @override
  String get audioRecorder => '录音机';

  @override
  String get importFile => '导入文件';

  @override
  String get language => '语言';

  @override
  String get systemDefault => '系统默认';

  @override
  String get selectLanguage => '选择语言';

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
  String get today => '今天';

  @override
  String get tomorrow => '明天';

  @override
  String get nextWeek => '下周';

  @override
  String get nextMonth => '下个月';

  @override
  String get pickDateTime => '选择日期和时间';

  @override
  String get time => '时间';

  @override
  String get selectTime => '选择时间';

  @override
  String get allDay => '全天';

  @override
  String get date => '日期';

  @override
  String get repeat => '重复';

  @override
  String get frequency => '频率';

  @override
  String get never => '从不';

  @override
  String get daily => '每天';

  @override
  String get weekly => '每周';

  @override
  String get monthly => '每月';

  @override
  String get yearly => '每年';

  @override
  String get snooze => '稍后提醒';

  @override
  String get fiveMinutes => '5 分钟';

  @override
  String get tenMinutes => '10 分钟';

  @override
  String get thirtyMinutes => '30 分钟';

  @override
  String get oneHour => '1 小时';

  @override
  String get gridView => '网格视图';

  @override
  String get listView => '列表视图';

  @override
  String get galleryView => '画廊视图';

  @override
  String get undo => '撤销';

  @override
  String get redo => '重做';

  @override
  String get bold => '粗体';

  @override
  String get italic => '斜体';

  @override
  String get underline => '下划线';

  @override
  String get strikethrough => '删除线';

  @override
  String get bulletList => '项目符号列表';

  @override
  String get numberedList => '编号列表';

  @override
  String get checklist => '清单';

  @override
  String get openChecklistView => '打开列表视图';

  @override
  String get convertToNormalText => '转换为普通文本';

  @override
  String get convertEntireChecklistToText => '将整个清单转换为文本';

  @override
  String get focusedChecklistRequiresChecklistOnly =>
      '仅当每一行都是清单项目时，才可使用专注列表视图。';

  @override
  String get focusedChecklistUnsupportedContent => '附件和块格式仅可在富文本编辑器中使用。';

  @override
  String get focusedChecklistInvalidContent => '无法在专注视图中打开此清单。请继续在此处编辑。';

  @override
  String get completedTasks => '已完成';

  @override
  String get clearCompletedTasks => '清除已完成项';

  @override
  String get outdent => '减少缩进';

  @override
  String get checklistEmbedUnsupported => '附件只能粘贴到富文本编辑器中。';

  @override
  String get checklistChangedElsewhere => '此笔记已在其他位置更改。请重新加载或保留本地编辑。';

  @override
  String get reloadChecklist => '重新加载';

  @override
  String get keepChecklistEdits => '保留我的编辑';

  @override
  String get quote => '引用';

  @override
  String get codeBlock => '代码块';

  @override
  String get textColor => '文字颜色';

  @override
  String get highlightColor => '高亮颜色';

  @override
  String get alignLeft => '左对齐';

  @override
  String get alignCenter => '居中对齐';

  @override
  String get alignRight => '右对齐';

  @override
  String get alignJustify => '两端对齐';

  @override
  String get increaseIndent => '增加缩进';

  @override
  String get decreaseIndent => '减少缩进';

  @override
  String get heading1 => '标题 1';

  @override
  String get heading2 => '标题 2';

  @override
  String get heading3 => '标题 3';

  @override
  String get normalText => '正文';

  @override
  String get pen => '钢笔';

  @override
  String get pencil => '铅笔';

  @override
  String get brush => '画笔';

  @override
  String get highlighter => '荧光笔';

  @override
  String get eraser => '橡皮擦';

  @override
  String get lasso => '套索';

  @override
  String get addPage => '添加页面';

  @override
  String get deletePage => '删除页面';

  @override
  String get page => '页面';

  @override
  String pageNumber(int number) {
    return '第 $number 页';
  }

  @override
  String get connectedAccounts => '已连接的账户';

  @override
  String get subscription => '订阅';

  @override
  String get free => '免费';

  @override
  String get pro => '专业版';

  @override
  String get trial => '试用';

  @override
  String trialEndsIn(int days) {
    return '试用还剩 $days 天';
  }

  @override
  String get devices => '设备';

  @override
  String get thisDevice => '此设备';

  @override
  String lastActive(String time) {
    return '上次活动：$time';
  }

  @override
  String get pendingApproval => '等待批准';

  @override
  String get security => '安全';

  @override
  String get endToEndEncryption => '端到端加密';

  @override
  String get e2eeEnabled => '已启用';

  @override
  String get e2eeDisabled => '未启用';

  @override
  String get setupRecoveryKey => '设置恢复密钥';

  @override
  String get changeRecoveryKey => '更改恢复密钥';

  @override
  String get verifyRecoveryKey => '验证恢复密钥';

  @override
  String get error => '错误';

  @override
  String errorWithMessage(String message) {
    return '错误：$message';
  }

  @override
  String get loading => '加载中...';

  @override
  String get syncing => '同步中...';

  @override
  String get syncComplete => '同步完成';

  @override
  String get syncFailed => '同步失败';

  @override
  String get offline => '离线';

  @override
  String get online => '在线';

  @override
  String get getApp => '获取应用';

  @override
  String get sessionExpired => '你的会话已过期。请重新登录。';

  @override
  String get confirmSignOut => '确定要退出登录吗？';

  @override
  String get unsyncedChanges => '你有未同步的更改将会丢失。';

  @override
  String get deleteConfirmation => '确定要删除吗？';

  @override
  String get permanentAction => '此操作无法撤销。';

  @override
  String get encryptNoteContent => '加密笔记内容';

  @override
  String get encryptNotesInDatabase => '加密本地数据库中的笔记';

  @override
  String get encryptAttachments => '加密附件';

  @override
  String get encryptImagesSketchesFiles => '加密图片、草图和文件';

  @override
  String get localEncryptionInfo => '本地加密在设备被盗时保护您的数据。使用 AES-256-GCM 加密。';

  @override
  String get lockedNotes => '锁定的笔记';

  @override
  String get requireReenterPin => '重新打开锁定笔记时需要重新输入 PIN 码';

  @override
  String get faqAndSupport => '常见问题和联系支持';

  @override
  String get appInfoCredits => '应用信息和致谢';

  @override
  String get advancedSettings => '高级设置';

  @override
  String get speechRecognitionModel => '语音识别模型';

  @override
  String whisperModelDownloaded(String size) {
    return '已下载 ($size)';
  }

  @override
  String whisperModelNotDownloaded(String size) {
    return '未下载 ($size) - 点击下载';
  }

  @override
  String get deleteWhisperModelConfirm => '删除语音识别模型？您可以稍后重新下载。';

  @override
  String get whisperModelDeleted => '语音识别模型已删除';

  @override
  String get deleteModel => '删除模型';

  @override
  String get download => '下载';

  @override
  String get viewDatabaseStats => '查看数据库和同步统计';

  @override
  String get selectDarkTheme => '选择深色主题';

  @override
  String get selectLightTheme => '选择浅色主题';

  @override
  String get encryptingNotes => '正在加密现有笔记...';

  @override
  String noteEncryptionEnabled(int count) {
    return '笔记加密已启用。已加密 $count 条笔记。';
  }

  @override
  String get noteEncryptionEnabledSimple => '笔记加密已启用。';

  @override
  String errorEncryptingNotes(String error) {
    return '加密笔记时出错：$error';
  }

  @override
  String get noteEncryptionDisabled => '笔记加密已禁用。';

  @override
  String get fileEncryptionEnabled => '文件加密已启用。新附件将被加密。';

  @override
  String get fileEncryptionDisabled => '文件加密已禁用。';

  @override
  String get encryptDataOnDevice => '加密存储在此设备上的数据';

  @override
  String get signInCancelledMessage => '登录已取消';

  @override
  String get startingSignIn => '正在开始登录...';

  @override
  String get continueWithGoogle => '使用 Google 继续';

  @override
  String get continueWithApple => '使用 Apple 继续';

  @override
  String get signInWithApple => '使用 Apple 登录';

  @override
  String get chooseSignInMethod => '选择您偏好的登录方式';

  @override
  String get yourNoteSecuredAndSynced => '您的笔记，安全同步';

  @override
  String get endToEndEncryptionFeature => '端到端加密';

  @override
  String get endToEndEncryptionDescription =>
      '您的笔记在同步前会在设备上加密。只有您能阅读它们——即使我们也无法访问您的数据。';

  @override
  String get seamlessSync => '无缝同步';

  @override
  String get seamlessSyncDescription => '在任何设备上访问您的笔记。更改会即时安全地同步到所有设备。';

  @override
  String get richFormatting => '丰富格式';

  @override
  String get richFormattingDescription => '使用富文本、清单、图片、绘图和语音笔记表达自己。您的笔记，您做主。';

  @override
  String get gotIt => '知道了';

  @override
  String get or => '或';

  @override
  String get signInWithGoogle => '使用 Google 登录';

  @override
  String get resetPassword => '重置密码';

  @override
  String get resetPasswordDescription => '输入您的邮箱地址，我们将向您发送验证码以重置密码。';

  @override
  String get sendVerificationCode => '发送验证码';

  @override
  String get sending => '发送中...';

  @override
  String get enterVerificationCode => '输入验证码';

  @override
  String get enterCodeSentTo => '输入发送到以下邮箱的 6 位验证码：';

  @override
  String get pleaseEnterCompleteCode => '请输入完整的 6 位验证码';

  @override
  String get verifying => '验证中...';

  @override
  String get continue_ => '继续';

  @override
  String get resendCode => '重新发送验证码';

  @override
  String resendCodeIn(int seconds) {
    return '$seconds 秒后重新发送';
  }

  @override
  String get codeExpiresIn => '验证码 10 分钟后过期';

  @override
  String get createNewPassword => '创建新密码';

  @override
  String get enterNewPasswordDescription => '为您的账户输入新密码。';

  @override
  String get enterNewPasswordHint => '输入新密码';

  @override
  String get reenterNewPasswordHint => '再次输入新密码';

  @override
  String get resettingPassword => '正在重置密码...';

  @override
  String get pleaseEnterNewPassword => '请输入新密码';

  @override
  String get pleaseEnterEmailAddress => '请输入您的邮箱地址';

  @override
  String get pleaseEnterValidEmail => '请输入有效的邮箱地址';

  @override
  String get failedSendVerificationCode => '发送验证码失败。请重试。';

  @override
  String get invalidVerificationCode => '验证码无效';

  @override
  String get verificationFailed => '验证失败。请重试。';

  @override
  String get passwordResetFailed => '密码重置失败。请重试。';

  @override
  String get verifyYourEmail => '验证您的邮箱';

  @override
  String get sendingVerificationCode => '正在发送验证码...';

  @override
  String get emailVerifiedSuccessfully => '邮箱验证成功！';

  @override
  String get deviceRevoked => '设备已撤销';

  @override
  String get waitingForApprovalTitle => '等待批准';

  @override
  String get deviceRevokedDescription => '此设备已被撤销，无法再访问您的笔记。请从已批准的设备重新登录以重新授权。';

  @override
  String get pleaseApproveFrom => '请从以下设备批准：';

  @override
  String get waitingForApprovalFromDevice => '等待另一设备的批准...';

  @override
  String get rememberThisDevice => '记住此设备';

  @override
  String get deviceRemovedOnSignOut => '如果取消勾选，此设备将在您退出登录时被移除';

  @override
  String get checkingStatus => '检查中...';

  @override
  String get checkStatus => '检查状态';

  @override
  String get cancelRequest => '取消请求';

  @override
  String get pleaseWait => '请稍候...';

  @override
  String get updateRecoveryKey => '更新恢复密钥';

  @override
  String get recoveryPassphraseDescription =>
      '创建一个恢复密码短语，如果您丢失所有设备，可以用它恢复对笔记的访问。';

  @override
  String get recoveryPassphraseWarning => '请安全保存此密码短语。没有它，如果您丢失所有设备，将无法恢复笔记。';

  @override
  String get enterAStrongPassphrase => '输入一个强密码短语';

  @override
  String get pleaseEnterPassphrase => '请输入密码短语';

  @override
  String get passphraseMinLength => '密码短语至少需要 6 个字符';

  @override
  String get passphrasesDoNotMatch => '密码短语不匹配';

  @override
  String get passphraseTooCommon => '此密码短语太常见且容易被猜到';

  @override
  String get passphraseStrengthAdvice => '考虑添加大写字母、小写字母、数字或符号以增强密码短语';

  @override
  String get saving => '保存中...';

  @override
  String get saveRecoveryKey => '保存恢复密钥';

  @override
  String get passwordShortWarning => '密码较短。建议使用至少 6 个字符。';

  @override
  String get passwordLongerAdvice => '建议使用更长的密码以提高安全性。';

  @override
  String get passwordMixAdvice => '建议同时使用字母和数字以增强安全性。';

  @override
  String version(String version, String buildNumber) {
    return '版本 $version ($buildNumber)';
  }

  @override
  String get openSource => '源码可查看';

  @override
  String get openSourceDescription =>
      '源码按 CC BY-NC 4.0 许可提供。由于商业复用受限，应称为源码可查看软件，而不是经 OSI 认可的开源软件。';

  @override
  String get frequentlyAskedQuestions => '常见问题';

  @override
  String get needMoreHelp => '需要更多帮助？';

  @override
  String get needMoreHelpDescription => '如果您有任何问题或需要帮助，请随时联系我们。';

  @override
  String get deleteImage => '删除图片';

  @override
  String get deleteImageConfirmation => '确定要删除此图片吗？';

  @override
  String get importAsNoteTooltip => '作为笔记导入';

  @override
  String get insertTooltip => '插入';

  @override
  String failedToImport(String error) {
    return '导入失败：$error';
  }

  @override
  String get notes_ => '笔记';

  @override
  String get media => '媒体';

  @override
  String plan(String planName) {
    return '$planName 计划';
  }

  @override
  String get freeTrialActive => '免费试用中';

  @override
  String expiresOnDaysLeft(String date, int days) {
    return '到期日 $date（还剩 $days 天）';
  }

  @override
  String get enjoyProFeatures => '在试用期间享受所有专业版功能！';

  @override
  String get billing => '账单';

  @override
  String get renews => '续订';

  @override
  String get expires => '到期';

  @override
  String get monthlySubscription => '月度订阅';

  @override
  String get yearlySubscription => '年度订阅';

  @override
  String get freeTrial => '免费试用';

  @override
  String get subscriptionInGracePeriod => '您的订阅处于宽限期。请更新您的付款方式。';

  @override
  String subscriptionCancelledInfo(String date) {
    return '您的专业版访问权限将于 $date 结束。您可以在到期后重新订阅。';
  }

  @override
  String get subscriptionCancelled => '订阅已取消';

  @override
  String get upgradeToProDescription => '升级到专业版以获得无限锁定笔记、云同步等功能。';

  @override
  String get cancellingSubscription => '正在取消...';

  @override
  String get manageSubscription => '管理订阅';

  @override
  String get renewSubscription => '续订';

  @override
  String get restoreInfoText => '订阅时将自动恢复任何活跃订阅或之前的购买。';

  @override
  String get cancelSubscriptionConfirmation =>
      '确定要取消订阅吗？\n\n您的订阅将保持有效直到当前计费周期结束。之后，您将失去对专业版功能的访问权限。';

  @override
  String get subscriptionChangesMayTakeMoment => '如果您做了更改，可能需要一些时间才能显示。';

  @override
  String get subscriptionRestored => '您的订阅已恢复！';

  @override
  String get subscriptionAlreadyActive => '您已有活跃的订阅。';

  @override
  String get subscriptionActivated => '订阅激活成功！';

  @override
  String get purchaseCancelled => '购买已取消。';

  @override
  String get paymentFailed => '支付失败。';

  @override
  String get couldNotOpenSubscriptionManagement => '无法打开订阅管理。';

  @override
  String get subscriptionProviderUnknownContactSupport =>
      '我们无法识别您的计费服务商。请联系 contact@betterkeep.app 获取帮助。';

  @override
  String manageSubscriptionInStore(String store) {
    return '在$store中管理您的订阅。';
  }

  @override
  String get loadingFailedTryAgain => '加载失败 — 重试';

  @override
  String get reloadPrices => '重新加载价格';

  @override
  String subscribeWithPrice(String price) {
    return '订阅 — $price';
  }

  @override
  String get noAdsDescription => '无广告、不出售数据 — 您的订阅用于资助安全服务器和持续开发。';

  @override
  String get detectingLocation => '正在检测您的位置...';

  @override
  String get currencyHelpText => '印度银行卡请使用INR，国际银行卡请使用USD。';

  @override
  String get selfHostContact => '想要自托管？请联系 contact@betterkeep.app';

  @override
  String get welcomeToProMessage => '欢迎使用 Better Keep Pro！';

  @override
  String get paymentConfirmedTitle => '付款已确认';

  @override
  String get paymentConfirmedActivationPending =>
      '付款已确认，但 Pro 激活需要更长时间。请勿再次购买。请重新检查状态或在 Google Play 中管理订阅。';

  @override
  String get recheckStatus => '重新检查状态';

  @override
  String get subscriptionAccountMismatchTitle => '订阅已关联到其他账号';

  @override
  String get subscriptionAccountMismatchMessage =>
      '此 Google Play 订阅已关联到另一个 Better Keep 账号。请登录该账号或联系支持；此账号尚未获得访问权限。';

  @override
  String get loadingPrices => '正在加载价格...';

  @override
  String get processingSubscription => '处理中...';

  @override
  String get subscriptionAutoRenewTerms =>
      '费用将从您的账户扣除。除非在当前周期结束前至少24小时关闭自动续费，否则订阅将自动续费。';

  @override
  String savePercent(int percent) {
    return '节省$percent%';
  }

  @override
  String get subscriptionCancelledSuccessfully => '订阅已成功取消。';

  @override
  String get subscriptionResumedSuccessfully => '订阅已成功恢复。';

  @override
  String get failedToCancelSubscription => '取消订阅失败。';

  @override
  String get failedToResumeSubscription => '恢复订阅失败。';

  @override
  String get featureTableHeader => '功能';

  @override
  String get unlimited => '无限制';

  @override
  String get paywallLocalNotes => '本地笔记';

  @override
  String get lockedNotesFreeLimit => '最多5个';

  @override
  String get signInWithAnyLinked => '使用任何已链接的账户登录';

  @override
  String get linkingRequiresAuth => '链接需要对每个平台进行身份验证以验证所有权。';

  @override
  String get connected => '已连接';

  @override
  String get cannotUnlinkPrimary => '无法取消链接原始登录方式';

  @override
  String get verifyAccountLink => '验证账户链接';

  @override
  String get verifyAndLink => '验证并链接';

  @override
  String get yourNotesAreProtected => '您的笔记已受保护';

  @override
  String get waitingForDeviceApproval => '等待设备批准';

  @override
  String get protectionNotEnabled => '保护未启用';

  @override
  String get somethingWentWrong => '出现问题';

  @override
  String get deviceAccessRemoved => '设备访问权限已移除';

  @override
  String get gettingReady => '正在准备...';

  @override
  String get notesAndAttachmentsEncrypted => '您的笔记和附件已加密';

  @override
  String get encryption => '加密';

  @override
  String get keyExchange => '密钥交换';

  @override
  String get keySize => '密钥大小';

  @override
  String nDevicesAuthorized(int count) {
    return '已授权 $count 个';
  }

  @override
  String get important => '重要';

  @override
  String get approveOnOtherDevice => '在已授权的设备上打开 Better Keep 以批准此设备。';

  @override
  String get yourDevices => '您的设备';

  @override
  String get pendingApprovalSection => '待批准';

  @override
  String get authorizedDevices => '已授权的设备';

  @override
  String get noInternetConnection => '没有网络连接。请检查您的网络并重试。';

  @override
  String get dangerZone => '危险区域';

  @override
  String get dangerZoneDescription => '永久删除您的账户和所有相关数据。此操作将在 30 天宽限期后完成。';

  @override
  String get deleteMyAccount => '删除我的账户';

  @override
  String get unsyncedNotesWarning =>
      '您有尚未同步到云端的笔记。如果您现在退出登录，这些笔记将永久丢失。\n\n建议等待同步完成或先导出您的数据。';

  @override
  String notesNotSynced(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count 条笔记未同步',
      one: '1 条笔记未同步',
    );
    return '$_temp0';
  }

  @override
  String get dataLossWarning => '数据丢失警告';

  @override
  String get noRecoveryKeySet => '未设置恢复密钥';

  @override
  String get signOutNoRecoveryKeyWarning =>
      '如果您退出登录并失去对所有已批准设备的访问权限，您将永久失去对所有加密笔记的访问权限。\n\n此操作无法撤销。';

  @override
  String get signOutConfirmation => '确定要退出登录吗？\n\n您需要重新登录才能访问您的笔记。';

  @override
  String nDevicesWaitingForApproval(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count 个设备等待批准',
      one: '1 个设备等待批准',
    );
    return '$_temp0';
  }

  @override
  String get reviewAndApprove => '审核并批准以授予访问权限';

  @override
  String nShareAccessRequests(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count 个共享访问请求',
      one: '1 个共享访问请求',
    );
    return '$_temp0';
  }

  @override
  String get someoneWantsToView => '有人想查看您的共享笔记';

  @override
  String get deviceApproved_ => '设备已批准';

  @override
  String failedApproveDevice(String error) {
    return '批准设备失败：$error';
  }

  @override
  String get deviceRemoved => '设备已移除';

  @override
  String nDevicesRemoved(int count) {
    return '已移除 $count 个设备';
  }

  @override
  String failedRemoveDevice(String error) {
    return '移除设备失败：$error';
  }

  @override
  String get removeDevice_ => '移除设备';

  @override
  String removeDeviceConfirmation(String deviceName) {
    return '确定要移除 \"$deviceName\" 吗？\n\n此设备将无法再访问您的笔记。';
  }

  @override
  String get enableE2EEConfirmation =>
      '这将加密您的所有笔记和附件。只有您授权的设备才能读取它们。\n\n请确保在启用端到端加密后设置恢复密钥，否则如果您丢失所有设备，可能会失去对笔记的访问权限。';

  @override
  String get enableE2EE_ => '启用端到端加密';

  @override
  String failedEnableE2EE(String error) {
    return '启用端到端加密失败：$error';
  }

  @override
  String get recoveryKeySavedSuccessfully => '恢复密钥保存成功！';

  @override
  String get noRecoveryKeyWarning => '警告：没有恢复密钥，如果您丢失所有设备，可能会失去对笔记的访问权限。';

  @override
  String get recoveryKeySetUp => '您已设置恢复密钥。您想做什么？';

  @override
  String get update => '更新';

  @override
  String get recoveryKeyUpdated => '恢复密钥已更新！';

  @override
  String get recoveryKeyRemoved => '恢复密钥已移除';

  @override
  String get recoveryKeySaved => '恢复密钥已保存！';

  @override
  String get upgradeNowQuestion => '立即升级？';

  @override
  String trialTimeLeft(String timeLeft) {
    return '您的免费试用还剩 $timeLeft。';
  }

  @override
  String get subscribeNowTrialEnds => '如果您现在订阅，试用将立即结束并开始计费。';

  @override
  String alreadyHaveSubscription(String planName) {
    return '您已经拥有有效的 $planName 订阅！';
  }

  @override
  String unlinkProviderQuestion(String provider) {
    return '取消链接 $provider？';
  }

  @override
  String get unlinkProviderWarning => '您将无法再使用此账户登录。请确保您有其他方式访问您的账户。';

  @override
  String unlinkedSuccessfully(String provider) {
    return '已取消链接 $provider';
  }

  @override
  String get failedUnlinkAccount => '取消链接账户失败';

  @override
  String get cannotUnlinkOnlyMethod => '无法取消链接唯一的登录方式。';

  @override
  String unknownProviderError(String provider) {
    return '未知的提供商：$provider';
  }

  @override
  String get takingTooLong => '耗时过长。您可以取消并重试。';

  @override
  String get failedSendCode => '发送验证码失败';

  @override
  String get pleaseTryAgain => '请重试。';

  @override
  String get pleaseSignInAgain => '请重新登录并重试。';

  @override
  String get noEmailAssociated => '您的账户没有关联的邮箱。';

  @override
  String providerAlreadyLinked(String provider) {
    return '$provider 已链接到您的账户。';
  }

  @override
  String get pleaseWaitBeforeRequesting => '请稍后再请求。';

  @override
  String get sessionExpired_ => '会话已过期。请重试。';

  @override
  String get failedLinkAccount => '链接账户失败';

  @override
  String providerLinkedToAnother(String provider) {
    return '此 $provider 账户已链接到另一个用户。';
  }

  @override
  String get emailAlreadyInUse => '使用此邮箱的账户已存在。请先登录该账户，然后从那里链接。';

  @override
  String get linkingCancelled => '链接已取消。';

  @override
  String successfullyLinkedProvider(String provider) {
    return '成功链接 $provider 账户';
  }

  @override
  String get deleteYourAccount => '删除您的账户？';

  @override
  String get actionIrreversible => '此操作不可逆';

  @override
  String get allNotesDeleted => '您的所有笔记将被永久删除';

  @override
  String get allAttachmentsRemoved => '所有附件和媒体将被移除';

  @override
  String get loggedOutAllDevices => '您将从所有设备退出登录';

  @override
  String get accountCannotBeRecovered => '您的账户无法恢复';

  @override
  String get gracePeriodInfo => '30 天宽限期：重新登录以取消删除。';

  @override
  String get verificationCodeViaEmail => '您将通过邮箱收到验证码。';

  @override
  String get keepMyAccount => '保留我的账户';

  @override
  String get deleteAccount => '删除账户';

  @override
  String get verifyYourIdentity => '验证您的身份';

  @override
  String get userNotSignedIn => '用户未登录';

  @override
  String get failedScheduleDeletion => '计划删除失败';

  @override
  String get deletionScheduled => '删除已计划';

  @override
  String accountWillBeDeletedOn(String date) {
    return '您的账户将于 $date 被删除。';
  }

  @override
  String get exportBeforeSignOut => '您想在退出登录前导出数据吗？';

  @override
  String get skip => '跳过';

  @override
  String get exportData => '导出数据';

  @override
  String get exportingData => '正在导出数据';

  @override
  String get exportCancelled => '导出已取消';

  @override
  String get exportFailed => '导出失败';

  @override
  String get exportComplete => '导出完成';

  @override
  String exportCompleteMessage(String path) {
    return '您的数据已成功导出。\n\n文件保存到：\n$path\n\n您想分享导出文件吗？';
  }

  @override
  String deletionScheduledMessage(String date) {
    return '账户删除计划于 $date。重新登录以取消。';
  }

  @override
  String get iphoneIpad => 'iPhone/iPad';

  @override
  String get webBrowser => '网页浏览器';

  @override
  String get unknownDevice => '未知设备';

  @override
  String get debugDeleteSubscription => '调试：删除订阅';

  @override
  String get debugDeleteSubscriptionWarning =>
      '这将立即从数据库中删除您的订阅。\n\n这仅用于测试，不会取消实际的 Razorpay 订阅。';

  @override
  String get debugSubscriptionDeleted => '调试：订阅删除成功';

  @override
  String get debugSubscriptionDeleteFailed => '调试：删除订阅失败';

  @override
  String get removeLink => '移除链接';

  @override
  String get add => '添加';

  @override
  String get recent => '最近';

  @override
  String get custom => '自定义';

  @override
  String get createLabelToOrganize => '在上方创建标签以整理您的笔记';

  @override
  String editLabelName(String labelName) {
    return '编辑 $labelName';
  }

  @override
  String get enterNewName => '输入新名称';

  @override
  String get deleteLabel => '删除标签';

  @override
  String deleteLabelConfirmation(String labelName) {
    return '确定要删除此标签（$labelName）吗？';
  }

  @override
  String get pasteAs => '粘贴为';

  @override
  String get formattedText => '格式化文本';

  @override
  String get previewAndInsertFormatted => '预览并插入为格式化内容';

  @override
  String get insertAsPlainText => '插入为无格式的纯文本';

  @override
  String get prompt => '提示';

  @override
  String get notMatched => '不匹配';

  @override
  String confirmPlaceholder(String placeholder) {
    return '确认 $placeholder';
  }

  @override
  String get notificationPermissionsRequired => '提醒需要通知和闹钟权限';

  @override
  String get checkAll => '全部勾选';

  @override
  String get uncheckAll => '全部取消勾选';

  @override
  String checkNestedItemsCount(int count) {
    return '这将勾选 $count 个嵌套项目。';
  }

  @override
  String uncheckNestedItemsCount(int count) {
    return '这将取消勾选 $count 个嵌套项目。';
  }

  @override
  String get somethingWentWrongTryAgain => '出现问题。请重试。';

  @override
  String get verifyingPassphrase => '正在验证密码短语...';

  @override
  String get settingAsPrimaryDevice => '正在设置为主设备...';

  @override
  String get finalizing => '正在完成...';

  @override
  String get incorrectPassphrase => '密码短语不正确。请重试。';

  @override
  String get recoveryTimedOut => '恢复超时。请检查您的连接并重试。';

  @override
  String get recoveryKeyMobileOnly =>
      '此恢复密钥是在移动端或桌面端应用上创建的，无法在浏览器中使用。请使用移动端或桌面端应用进行恢复。';

  @override
  String get somethingWentWrongCheckConnection => '出现问题。请检查您的连接并重试。';

  @override
  String get recover => '恢复';

  @override
  String get recoverInfoTooltip => '使用您的恢复密码短语恢复加密密钥';

  @override
  String hintLabel(String hint) {
    return '提示：$hint';
  }

  @override
  String get setAsPrimaryDevice => '设为主设备';

  @override
  String get pleaseEnterRecoveryPassphrase => '请输入您的恢复密码短语';

  @override
  String get currentPassphraseIncorrect => '当前密码短语不正确';

  @override
  String get pleaseEnterCurrentPassphrase => '请输入您的当前密码短语';

  @override
  String get pleaseEnterNewPassphrase => '请输入新密码短语';

  @override
  String get removeRecoveryKey => '移除恢复密钥';

  @override
  String get removeRecoveryKeyWarning => '警告：没有恢复密钥，如果您丢失所有设备，将无法恢复笔记！';

  @override
  String get enterPassphraseToConfirmRemoval => '输入您的当前密码短语以确认移除：';

  @override
  String get passphraseIncorrect => '密码短语不正确';

  @override
  String get unlockNote => '解锁笔记';

  @override
  String get pleaseEnterPin => '请输入 PIN 码';

  @override
  String tooManyAttemptsWait(int seconds) {
    return '尝试次数过多。请等待 $seconds 秒。';
  }

  @override
  String attemptsRemaining(String message, int remaining) {
    return '$message。剩余 $remaining 次尝试。';
  }

  @override
  String get failedToUnlockNote => '解锁笔记失败';

  @override
  String lockedSeconds(int seconds) {
    return '已锁定（$seconds 秒）';
  }

  @override
  String get unlock => '解锁';

  @override
  String get lockNote => '锁定笔记';

  @override
  String get pinForgotWarning => '如果您忘记此 PIN 码，将无法恢复笔记。';

  @override
  String get pleaseEnterAPin => '请输入 PIN 码';

  @override
  String get pinMinLength => 'PIN 码至少需要 4 个字符';

  @override
  String get pinTooWeak => 'PIN 码太弱（全部相同字符）';

  @override
  String get pinTooCommon => 'PIN 码太常见';

  @override
  String get confirmPin => '确认 PIN 码';

  @override
  String get reenterPin => '再次输入 PIN 码';

  @override
  String get pinsDoNotMatch => 'PIN 码不匹配';

  @override
  String get lock => '锁定';

  @override
  String get recordAudio => '录制音频';

  @override
  String get microphonePermissionRequired => '需要麦克风权限才能录制音频。';

  @override
  String get openSettings => '打开设置';

  @override
  String get stopRecording => '停止录制';

  @override
  String get startRecording => '开始录制';

  @override
  String get transcriptionUnavailable => '转录不可用';

  @override
  String get liveTranscription => '实时转录';

  @override
  String get recordingContinuesWithoutTranscription => '录制将在没有转录的情况下继续';

  @override
  String get listening => '正在听...';

  @override
  String get allowMicAccess => '允许麦克风访问以开始录制。';

  @override
  String get tapStartToRecord => '点击开始按钮开始录制。';

  @override
  String get transcribeWhileRecording => '录音时转录';

  @override
  String get transcription => '转录';

  @override
  String get editTranscriptionHint => '如有需要，编辑转录';

  @override
  String get addTranscriptionToNote => '将转录添加到笔记';

  @override
  String get noSpeechDetected => '录制期间未检测到语音。';

  @override
  String get titleOptional => '标题（可选）';

  @override
  String get enterTitleForRecording => '输入此录音的标题';

  @override
  String get okay => '好的';

  @override
  String get failedToStartRecording => '开始录制失败';

  @override
  String get transcriptionDisabledWebPrivacy => '出于隐私考虑，网页版已禁用语音转录。您的音频保留在设备上。';

  @override
  String get whisperModelRequired => '需要语音识别模型';

  @override
  String whisperModelDescription(String size) {
    return '下载一个小型 AI 模型（$size）用于设备端语音转文字。您的音频不会离开设备。';
  }

  @override
  String get downloadModel => '下载模型';

  @override
  String get useFallback => '使用设备默认';

  @override
  String get whisperTranscriptionActive => '设备端 AI 转录（私密）';

  @override
  String get modelDownloadComplete => '语音模型下载成功';

  @override
  String get modelDownloadFailed => '语音模型下载失败';

  @override
  String get transcribingAudio => '正在转录音频...';

  @override
  String get polishingTranscription => '正在润色转录...';

  @override
  String get transcriptionFailed => '转录失败，请重试。';

  @override
  String get deleteQuestion => '删除？';

  @override
  String get actionCannotBeUndone => '此操作无法撤销。';

  @override
  String get permanentDeleteWarning => '这将永久删除所有数据且无法恢复。';

  @override
  String get sentVerificationCodeTo => '我们已发送验证码到：';

  @override
  String codeExpiresInMinutes(int minutes) {
    return '验证码 $minutes 分钟后过期';
  }

  @override
  String get verificationFailedTryAgain => '验证失败。请重试。';

  @override
  String get shareNote => '分享笔记';

  @override
  String get untitledNote => '无标题笔记';

  @override
  String get shareAsText => '作为文本分享';

  @override
  String get plainTextContent => '纯文本内容';

  @override
  String get shareAsMarkdown => '作为 Markdown 分享';

  @override
  String get formattedWithMarkdown => '使用 Markdown 语法格式化';

  @override
  String get createSecureLink => '创建安全链接';

  @override
  String get encryptedLinkWithApproval => '带访问审批的加密链接';

  @override
  String get linkCreated => '链接已创建';

  @override
  String activeLinks(int count) {
    return '活动链接（$count）';
  }

  @override
  String get secureLink => '安全链接';

  @override
  String get createNewLink => '创建新链接';

  @override
  String get revokeLink_ => '撤销链接';

  @override
  String get copy => '复制';

  @override
  String get linkNotAvailable => '链接不可用（在其他设备上创建）';

  @override
  String get revokeLinkQuestion => '撤销链接？';

  @override
  String get revokeLinkWarning => '这将永久禁用此共享链接。拥有该链接的任何人将无法再访问笔记。';

  @override
  String get revoke => '撤销';

  @override
  String get linkRevoked => '链接已撤销';

  @override
  String failedToRevoke(String error) {
    return '撤销失败：$error';
  }

  @override
  String get linkCopied => '链接已复制到剪贴板';

  @override
  String get linkExpiresAfter => '链接过期时间';

  @override
  String get options => '选项';

  @override
  String get includeAttachments => '包含附件';

  @override
  String nAttachments(int count) {
    return '$count 个附件';
  }

  @override
  String get createLink => '创建链接';

  @override
  String get creating => '创建中...';

  @override
  String get e2eeApprovalInfo => '端到端加密。您将审批每个访问请求。';

  @override
  String get linkCreatedSuccess => '链接已创建！';

  @override
  String expiresIn(String duration) {
    return '$duration 后过期';
  }

  @override
  String get accessNotification => '当有人请求访问时，您将收到通知。';

  @override
  String get pleaseUnlockNoteFirst => '请先解锁笔记再分享';

  @override
  String sharedNote(String title) {
    return '共享笔记：$title';
  }

  @override
  String get sessionProblem => '会话问题';

  @override
  String get syncDisabledPleaseSignOut => '同步已禁用。请退出登录并重新登录。';

  @override
  String get signOutConfirmationWithNote => '确定要退出登录吗？\n\n您需要重新登录才能访问您的笔记。';

  @override
  String get sketchTool => '工具';

  @override
  String get sketchSize => '大小';

  @override
  String get sketchColor => '颜色';

  @override
  String get transcript => '转录';

  @override
  String get duration => '时长';

  @override
  String get deleteRecordingConfirmation => '确定要删除此音频录音吗？';

  @override
  String get encryptedNote => '加密笔记';

  @override
  String get decryptionFailed => '解密失败';

  @override
  String get decryptionFailedRetryMessage =>
      '此笔记无法解密。这可能是因为加密密钥暂时不可用。您可以尝试重新同步，或永久删除该笔记。';

  @override
  String get deletingNoteFromAllDevicesWarning =>
      '删除将从您所有设备中移除此笔记，包括服务器上的加密副本。';

  @override
  String get retryDecryption => '重试';

  @override
  String get retryingDecryption => '正在重新同步...';

  @override
  String get e2eeNotReady => '加密未就绪。请检查您的设备授权状态。';

  @override
  String get thisNoteIsLocked => '此笔记已锁定';

  @override
  String get audio => '音频';

  @override
  String audioCount(int count) {
    return '$count 个音频';
  }

  @override
  String syncFailedCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count 个失败',
      one: '1 个失败',
    );
    return '$_temp0';
  }

  @override
  String get openInAppForBestExperience => '在应用中打开以获得最佳体验';

  @override
  String get useAppForBetterExperience => '使用应用以获得更好的体验';

  @override
  String get noteMarkedAsDone => '笔记已标记为完成';

  @override
  String get pickTextColor => '选择文字颜色';

  @override
  String get image => '图片';

  @override
  String get sketch => '草图';

  @override
  String get textSizeTiny => '极小';

  @override
  String get textSizeSmall => '小';

  @override
  String get textSizeNormal => '正常';

  @override
  String get textSizeBig => '大';

  @override
  String get textSizeHuge => '超大';

  @override
  String get lineSpacing => '行距';

  @override
  String get lineSpacingTight => '紧凑';

  @override
  String get lineSpacingNormal => '正常';

  @override
  String get lineSpacingRelaxed => '宽松';

  @override
  String get lineSpacingDouble => '双倍';

  @override
  String get lineSpacingRemove => '移除行距';

  @override
  String get startWriting => '开始书写...';

  @override
  String get imageFailedToLoad => '图片加载失败';

  @override
  String maxAttachmentsReached(int count) {
    return '每条笔记最多 $count 个附件';
  }

  @override
  String get processingImage => '正在处理图片...';

  @override
  String get pickNoteColor => '选择笔记颜色';

  @override
  String failedToPaste(String error) {
    return '粘贴失败：$error';
  }

  @override
  String failedToInsertContent(String error) {
    return '插入内容失败：$error';
  }

  @override
  String failedToLockNote(String error) {
    return '锁定笔记失败：$error';
  }

  @override
  String failedToRemoveLock(String error) {
    return '移除锁定失败：$error';
  }

  @override
  String noteDuplicatedButFailedToLock(String error) {
    return '笔记已复制但锁定失败：$error';
  }

  @override
  String get pastedContent => '粘贴的内容';

  @override
  String get trash => '回收站';

  @override
  String get reminders => '提醒';

  @override
  String get notificationsEnabled => '通知已启用！您的提醒已设置。';

  @override
  String get shareApp => '分享应用';

  @override
  String get shareAppMessage =>
      '看看 Better Keep Notes - 一款安全的笔记应用！\nhttps://play.google.com/store/apps/details?id=io.foxbiz.better_keep';

  @override
  String get installBetterKeep => '安装 Better Keep';

  @override
  String get installApp => '安装应用';

  @override
  String get getAndroidApp => '获取 Android 应用';

  @override
  String get getWindowsApp => '获取 Windows 应用';

  @override
  String get selectView => '选择视图';

  @override
  String get viewModeGrid => '网格';

  @override
  String get viewModeList => '列表';

  @override
  String get viewModeColors => '颜色';

  @override
  String get clear => '清除';

  @override
  String get noMatchingNotes => '没有匹配的笔记';

  @override
  String get noNotesYet => '还没有笔记';

  @override
  String get trashIsEmpty => '回收站为空';

  @override
  String get noPinnedNotes => '没有固定的笔记';

  @override
  String get noLockedNotes => '没有锁定的笔记';

  @override
  String get noRemindersSet => '没有设置提醒';

  @override
  String get createYourFirstNote => '创建您的第一条笔记';

  @override
  String get noLabelsYet => '还没有标签';

  @override
  String get noColoredNotesYet => '还没有彩色笔记';

  @override
  String get addLabelsToOrganize => '为笔记添加标签以便整理';

  @override
  String get addColorsToOrganize => '为笔记添加颜色以便整理';

  @override
  String get getTheAndroidApp => '获取 Android 应用';

  @override
  String get androidAppAvailable =>
      'Better Keep 已在 Google Play 上架！获取原生应用以获得最佳体验，包括通知、小部件等。';

  @override
  String get openPlayStore => '打开 Play 商店';

  @override
  String get getTheWindowsApp => '获取 Windows 应用';

  @override
  String get windowsAppAvailable =>
      'Better Keep 已在 Microsoft Store 上架！获取原生应用以获得最佳体验，包括系统集成和离线访问。';

  @override
  String get openMicrosoftStore => '打开 Microsoft 商店';

  @override
  String get installForQuickAccess => '安装 Better Keep 以便从主屏幕快速访问和离线支持！';

  @override
  String get install => '安装';

  @override
  String get notNow => '以后再说';

  @override
  String get noRecoveryKey => '没有恢复密钥';

  @override
  String get iUnderstand => '我明白了';

  @override
  String get deleteForever => '永久删除';

  @override
  String get deleteAllTrashForever => '确定要永久删除回收站中的所有笔记吗？此操作无法撤销。';

  @override
  String deleteSelectedNotesForever(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '确定要永久删除 $count 条笔记吗？此操作无法撤销。',
      one: '确定要永久删除此笔记吗？此操作无法撤销。',
    );
    return '$_temp0';
  }

  @override
  String get search => '搜索';

  @override
  String get todo => '待办';

  @override
  String get audioNote => '音频笔记';

  @override
  String get failedToCreateImageNote => '创建图片笔记失败';

  @override
  String get pleaseEnterYourEmail => '请输入您的邮箱';

  @override
  String get pleaseEnterAValidEmail => '请输入有效的邮箱';

  @override
  String get pleaseEnterYourPassword => '请输入您的密码';

  @override
  String get passwordMustBeAtLeast6Characters => '密码至少需要 6 个字符';

  @override
  String get pleaseConfirmYourPassword => '请确认您的密码';

  @override
  String get passwordsDoNotMatch => '密码不匹配';

  @override
  String get creatingAccount => '正在创建账户...';

  @override
  String get signingIn => '正在登录...';

  @override
  String get createAccount => '创建账户';

  @override
  String get welcomeBack => '欢迎回来';

  @override
  String get signUpWithYourEmail => '使用您的邮箱注册';

  @override
  String get signInToContinue => '登录以继续';

  @override
  String get forgotPassword => '忘记密码？';

  @override
  String get signIn => '登录';

  @override
  String get signUp => '注册';

  @override
  String get alreadyHaveAnAccount => '已有账户？';

  @override
  String get dontHaveAnAccount => '没有账户？';

  @override
  String get recoverySuccessfulWelcomeBack => '恢复成功！欢迎回来。';

  @override
  String get approvalRequestSent => '批准请求已发送！请在另一设备上批准。';

  @override
  String get checkingAccountStatus => '正在检查账户状态...';

  @override
  String get recoverYourAccount => '恢复您的账户';

  @override
  String get accountRecoveryRequired => '需要账户恢复';

  @override
  String get noActiveDevicesRecoveryKey => '未找到活动设备。使用您的恢复密码短语恢复对加密笔记的访问。';

  @override
  String get noActiveDevicesNoRecoveryKey =>
      '未找到活动设备且未设置恢复密钥。您可以使用新账户重新开始，但无法恢复之前的笔记。';

  @override
  String get previousNotesEncryptedWarning => '您之前的笔记已加密，没有恢复密钥无法恢复。';

  @override
  String get notYourMainDevice => '不是您的主设备？';

  @override
  String get anotherDeviceApprovalHint => '如果您有另一台可以访问笔记的设备，可以从该设备请求批准。';

  @override
  String get requesting => '正在请求...';

  @override
  String get requestApprovalFromAnotherDevice => '从另一设备请求批准';

  @override
  String get signingOut => '正在退出登录...';

  @override
  String get takingTooLongTryAgain => '耗时过长。您可以取消并重试。';

  @override
  String get requestTimedOut => '请求超时。请重试。';

  @override
  String get failedToSendVerificationCode => '发送验证码失败';

  @override
  String get yourEmail => '您的邮箱';

  @override
  String get continueLabel => '继续';

  @override
  String get pleaseConfirmConsequences => '请确认您了解后果';

  @override
  String get accountResetSuccessfully => '账户重置成功。欢迎！';

  @override
  String get failedToResetAccount => '重置账户失败';

  @override
  String failedToResetAccountError(String error) {
    return '重置账户失败：$error';
  }

  @override
  String get startFreshQuestion => '重新开始？';

  @override
  String get thisActionWill => '此操作将：';

  @override
  String get removeAllDeviceAuthorizations => '移除所有设备授权';

  @override
  String get makeOldNotesUnrecoverable => '使您的旧笔记无法恢复';

  @override
  String get createNewEncryptionKey => '创建新的加密密钥';

  @override
  String get startWithBlankAccount => '使用空白账户开始';

  @override
  String get iUnderstandOldNotesInaccessible => '我明白我的旧笔记将永久无法访问';

  @override
  String get saveToGallery => '保存到图库';

  @override
  String get newLabel => '新建';

  @override
  String get pickPaperColor => '选择纸张颜色';

  @override
  String get pickPenColor => '选择画笔颜色';

  @override
  String get savedToGallery => '已保存到图库';

  @override
  String get sketchDownloaded => '草图已下载';

  @override
  String get failedToSaveSketch => '保存草图失败';

  @override
  String errorSavingSketch(String error) {
    return '保存草图错误：$error';
  }

  @override
  String get planFree => '免费版';

  @override
  String get planPro => '专业版';

  @override
  String lockedNotesLimitReached(int count) {
    return '您已达到 $count 条锁定笔记的限制';
  }

  @override
  String get realtimeCloudSyncRequiresPro => '实时云同步需要专业版订阅';

  @override
  String get unlimitedLockedNotes => '无限锁定笔记';

  @override
  String get realtimeCloudSync => '实时云同步';

  @override
  String get upgrade => '升级';

  @override
  String get upgradeToPro => '升级到专业版';

  @override
  String unlockFeature(String feature) {
    return '解锁$feature';
  }

  @override
  String featureRequiresPro(String feature) {
    return '$feature需要专业版';
  }

  @override
  String get thisFeatureRequiresPro => '此功能需要专业版';

  @override
  String featureIsProFeature(String feature) {
    return '$feature是专业版功能。';
  }

  @override
  String get unlockAllFeatures => '解锁所有功能并支持开发。';

  @override
  String get protectUnlimitedNotesWithPin => '使用 PIN 码保护无限笔记';

  @override
  String get syncAcrossDevicesSecurely => '在所有设备间安全同步';

  @override
  String get unlimitedLockedNotesAndSync => '无限锁定笔记和实时云同步';

  @override
  String get unlockTheFullExperience => '解锁完整体验';

  @override
  String get maybeLater => '以后再说';

  @override
  String get enableNotificationsTitle => '启用通知';

  @override
  String get enableNotificationsForReminders => '您同步的笔记包含提醒。启用通知以免错过。';

  @override
  String get enableNotifications => '启用';

  @override
  String get rateOnAppStore => '在 App Store 上评分';

  @override
  String get rateOnPlayStore => '在 Play Store 上评分';

  @override
  String get rateOnMicrosoftStore => '在 Microsoft Store 上评分';

  @override
  String get sortBy => '排序方式';

  @override
  String get sortCustom => '自定义';

  @override
  String get sortCreatedNewest => '创建日期';

  @override
  String get sortUpdatedNewest => '更新日期';

  @override
  String get dragToReorder => '长按以重新排序';

  @override
  String get moveNoteBefore => '将笔记移到前面';

  @override
  String get moveNoteAfter => '将笔记移到后面';

  @override
  String get pinnedReorderBoundary => '置顶和未置顶笔记需分别排序。';

  @override
  String get reorderSaveFailed => '无法保存新的笔记顺序，已恢复之前的顺序。';

  @override
  String get noteDisplayOptions => '笔记显示选项';

  @override
  String get noteDisplayOptionsSaveFailed => '无法保存笔记显示选项。请重试。';

  @override
  String get noteDisplayOptionsSaved => '已保存笔记显示选项';

  @override
  String get reorderCustomHint => '长按笔记，然后拖动以重新排列。';

  @override
  String get reorderDateSortHint => '按日期排序时无法手动重新排列。请选择“自定义”以重新排列笔记。';

  @override
  String get googleKeepImportTitle => '从 Google Keep 导入';

  @override
  String get googleKeepImportHelpSubtitle => '在本地迁移 Google Takeout 归档，无需上传。';

  @override
  String get googleKeepImportPrivacyTitle => '归档始终保留在此设备上';

  @override
  String get googleKeepImportPrivacyDescription =>
      'Better Keep 会在本地验证并转换 Google Takeout 归档，不会将 ZIP 上传到转换服务。只有在导入成功提交后，笔记才会进入常规的可选同步流程。';

  @override
  String get googleKeepImportBeforeStart => '开始之前';

  @override
  String get googleKeepImportInstructions =>
      '1. 打开 Google Takeout，并仅选择 Keep。\n2. 创建并下载导出文件。\n3. 在下方选择 ZIP。默认会跳过完全相同的重复导入。';

  @override
  String get googleKeepChooseZip => '选择 Takeout ZIP';

  @override
  String get googleKeepOpenTakeoutInstructions => '打开 Google Takeout 说明';

  @override
  String get googleKeepCancelImport => '取消导入';

  @override
  String get googleKeepImportCancelled => '导入已取消，未保存任何笔记。';

  @override
  String get googleKeepImportFailed => '导入失败。请检查所选内容并重试。';

  @override
  String get googleKeepImportReportTitle => 'Better Keep Google Keep 导入报告';

  @override
  String get googleKeepImportValidating => '正在验证 Google Takeout 归档…';

  @override
  String get googleKeepImportParsing => '正在读取 Google Keep 笔记…';

  @override
  String get googleKeepImportPreparingAttachments => '正在准备导入的附件…';

  @override
  String get googleKeepImportSaving => '正在保存导入的笔记…';

  @override
  String get googleKeepImportStarting => '正在开始导入…';

  @override
  String get googleKeepImportComplete => '导入完成';

  @override
  String get googleKeepSafetyLimits => '安全限制';

  @override
  String get googleKeepSafetyDescription =>
      'ZIP 压缩文件上限为 100 MB，解压后上限为 500 MB，最多 20,000 个文件，单个文件上限为 50 MB。不安全路径、符号链接和格式错误的归档会在保存笔记前被拒绝。';

  @override
  String get googleKeepImported => '已导入';

  @override
  String get googleKeepSkipped => '已跳过';

  @override
  String get googleKeepWarnings => '警告';

  @override
  String get googleKeepUnsupported => '不支持';

  @override
  String get googleKeepFailed => '失败';

  @override
  String get googleKeepReviewDetails => '查看导入详情';

  @override
  String get googleKeepShareReport => '分享完整报告';

  @override
  String get findInNote => '在笔记中查找';

  @override
  String get replace => '替换';

  @override
  String get replaceAll => '全部替换';

  @override
  String get showReplace => '显示替换';

  @override
  String get hideReplace => '隐藏替换';

  @override
  String get previousMatch => '上一个匹配项';

  @override
  String get nextMatch => '下一个匹配项';

  @override
  String get searchOptions => '搜索选项';

  @override
  String get matchCase => '区分大小写';

  @override
  String get matchWholeWord => '全字匹配';

  @override
  String get smartMatch => '智能匹配';

  @override
  String get smartMatchDescription => '查找拼写错误和缩写';

  @override
  String get regularExpressionAdvanced => '正则表达式（高级）';

  @override
  String get invalidRegularExpression => '无效的正则表达式';

  @override
  String get zeroLengthRegexUnsupported => '不支持仅匹配空文本的模式';

  @override
  String get invalidReplacementReference => '替换内容引用了不存在的捕获组';

  @override
  String get noMatches => '没有匹配项';

  @override
  String get searching => '正在搜索';

  @override
  String searchResultCount(int current, int total) {
    return '第 $current 项，共 $total 项';
  }

  @override
  String replacedOccurrences(int count) {
    return '已替换 $count 处';
  }
}
