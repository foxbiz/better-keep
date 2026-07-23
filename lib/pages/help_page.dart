import 'package:better_keep/utils/l10n_helper.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

class HelpPage extends StatelessWidget {
  const HelpPage({super.key});

  static const List<Map<String, String>> _faqs = [
    {
      'question': 'How do I create a new note?',
      'answer':
          'Tap the + button at the bottom of the home screen to create a new note. You can add text, images, audio, and more.',
    },
    {
      'question': 'How do I use quick shortcuts?',
      'answer':
          'Press and hold the + button to reveal quick shortcuts for Image, Audio, Sketch, and Todo. While holding, slide your finger to the desired shortcut and release to activate it. A quick tap on the + button opens a blank note.',
    },
    {
      'question': 'How do I organize my notes with labels?',
      'answer':
          'Open a note and tap on the label icon to add or create labels. You can filter notes by labels from the side menu.',
    },
    {
      'question': 'How do I set a reminder for a note?',
      'answer':
          'Open a note and tap on the reminder icon (bell) to set a date and time for your reminder.',
    },
    {
      'question': 'How do I archive or delete a note?',
      'answer':
          'Tap and hold to select one or more notes, then use the menu options to archive or delete them. Deleted notes are moved to Trash first. To permanently delete notes, go to Trash and delete them from there.',
    },
    {
      'question': 'How do I change the app theme?',
      'answer':
          'Go to Settings and toggle the Dark Mode switch to change between light and dark themes.',
    },
    {
      'question': 'How do I sync my notes across devices?',
      'answer':
          'Sign in with your Google account to automatically sync your notes across all your devices.',
    },
    {
      'question': 'How do I set morning, afternoon, and evening times?',
      'answer':
          'Go to Settings and tap on the time settings section to customize when morning, afternoon, and evening start for your reminders.',
    },
    {
      'question': 'How do I change the alarm sound?',
      'answer':
          'Go to Settings and tap on "Alarm Sound" to select from available notification sounds.',
    },
    {
      'question': 'Is my data secure?',
      'answer':
          'Yes, your notes are encrypted and stored securely. We use end-to-end encryption to protect your data.',
    },
    {
      'question': 'How do I approve a device requesting approval?',
      'answer':
          'When a new device signs in to your account, you\'ll receive a notification on your existing devices. Open the app on your primary device (the first device you set up), and you\'ll see an orange alert at the top of your profile page showing "Devices Waiting for Approval". Tap "Approve" to grant access, or tap the X button to deny the request. You can also scroll down to the "Your Devices" section to see all pending and approved devices.',
    },
    {
      'question': 'How do I delete my account?',
      'answer':
          'Go to Settings, tap on your profile at the top, then select "Delete Account". You\'ll need to verify your identity with a one-time code sent to your email. After verification, your account will be scheduled for deletion in 30 days. During this period, you can cancel the deletion by simply signing back in. All your devices will be signed out immediately, and you\'ll receive email confirmations for scheduling, reminders, and cancellation.',
    },
    {
      'question': 'Can I cancel account deletion?',
      'answer':
          'Yes! If you change your mind within 30 days, simply sign back into your account. This will automatically cancel the scheduled deletion and restore your account with all data intact. You\'ll receive an email confirmation when the deletion is cancelled.',
    },
    {
      'question': 'What happens when I delete my account?',
      'answer':
          'When you delete your account: 1) You\'ll be signed out from all devices immediately. 2) Your account is scheduled for permanent deletion after 30 days. 3) You\'ll receive a confirmation email and a reminder email 1 day before deletion. 4) After 30 days, all your notes, attachments, labels, and personal data will be permanently deleted and cannot be recovered.',
    },
    {
      'question': 'Can I export my data before deleting my account?',
      'answer':
          'Yes! After scheduling account deletion, you\'ll be offered the option to export all your data. We recommend downloading your data before the 30-day period ends, as it cannot be recovered after permanent deletion.',
    },
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.help)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            context.l10n.frequentlyAskedQuestions,
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 16),
          _buildVoiceAssistantsSection(context),
          const SizedBox(height: 16),
          ..._faqs.map((faq) => _buildFaqItem(context, faq)),
          const SizedBox(height: 24),
          const Divider(),
          const SizedBox(height: 16),
          _buildContactSection(context),
        ],
      ),
    );
  }

  Widget _buildVoiceAssistantsSection(BuildContext context) {
    final isIOS = !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;
    final isAndroid =
        !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

    final description = isIOS
        ? 'Say “Siri, create a note in Better Keep.” Siri asks what the note '
              'should say and saves it after device authentication.'
        : isAndroid
        ? 'Say “Hey Google, take a note with Better Keep Notes.” Better Keep '
              'shows the dictated title and text so you can confirm before saving. '
              'Gemini support can vary because some quick voice actions are still '
              'handled by Google Assistant.'
        : 'On iPhone, say “Siri, create a note in Better Keep.” On Android, '
              'say “Hey Google, take a note with Better Keep Notes.”';

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              Icons.record_voice_over_outlined,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Voice assistants',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(description),
                  const SizedBox(height: 8),
                  Text(
                    'For privacy, Better Keep never includes dictated note '
                    'content in analytics or diagnostic logs.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFaqItem(BuildContext context, Map<String, String> faq) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ExpansionTile(
        title: Text(
          faq['question']!,
          style: const TextStyle(fontWeight: FontWeight.w500),
        ),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                faq['answer']!,
                textAlign: TextAlign.left,
                style: TextStyle(
                  color: Theme.of(context).textTheme.bodySmall?.color,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildContactSection(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          context.l10n.needMoreHelp,
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 12),
        Text(context.l10n.needMoreHelpDescription),
        const SizedBox(height: 16),
        Card(
          child: ListTile(
            leading: const Icon(Icons.email),
            title: Text(context.l10n.contactUs),
            subtitle: const Text('contact@betterkeep.app'),
            onTap: () async {
              final uri = Uri(
                scheme: 'mailto',
                path: 'contact@betterkeep.app',
                queryParameters: {'subject': 'Better Keep - Help Request'},
              );
              if (await canLaunchUrl(uri)) {
                await launchUrl(uri);
              }
            },
          ),
        ),
      ],
    );
  }
}
