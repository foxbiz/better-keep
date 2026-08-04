import 'package:better_keep/utils/l10n_helper.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

class HelpPage extends StatelessWidget {
  const HelpPage({super.key});

  @override
  Widget build(BuildContext context) {
    final faqs = <({String question, String answer})>[
      (
        question: context.l10n.faqCreateNoteQuestion,
        answer: context.l10n.faqCreateNoteAnswer,
      ),
      (
        question: context.l10n.faqShortcutsQuestion,
        answer: context.l10n.faqShortcutsAnswer,
      ),
      (
        question: context.l10n.faqLabelsQuestion,
        answer: context.l10n.faqLabelsAnswer,
      ),
      (
        question: context.l10n.faqReminderQuestion,
        answer: context.l10n.faqReminderAnswer,
      ),
      (
        question: context.l10n.faqArchiveDeleteQuestion,
        answer: context.l10n.faqArchiveDeleteAnswer,
      ),
      (
        question: context.l10n.faqThemeQuestion,
        answer: context.l10n.faqThemeAnswer,
      ),
      (
        question: context.l10n.faqSyncQuestion,
        answer: context.l10n.faqSyncAnswer,
      ),
      (
        question: context.l10n.faqReminderTimesQuestion,
        answer: context.l10n.faqReminderTimesAnswer,
      ),
      (
        question: context.l10n.faqAlarmSoundQuestion,
        answer: context.l10n.faqAlarmSoundAnswer,
      ),
      (
        question: context.l10n.faqSecurityQuestion,
        answer: context.l10n.faqSecurityAnswer,
      ),
      (
        question: context.l10n.faqApproveDeviceQuestion,
        answer: context.l10n.faqApproveDeviceAnswer,
      ),
      (
        question: context.l10n.faqDeleteAccountQuestion,
        answer: context.l10n.faqDeleteAccountAnswer,
      ),
      (
        question: context.l10n.faqCancelDeletionQuestion,
        answer: context.l10n.faqCancelDeletionAnswer,
      ),
      (
        question: context.l10n.faqDeletionEffectsQuestion,
        answer: context.l10n.faqDeletionEffectsAnswer,
      ),
      (
        question: context.l10n.faqExportBeforeDeletionQuestion,
        answer: context.l10n.faqExportBeforeDeletionAnswer,
      ),
    ];
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
          ...faqs.map((faq) => _buildFaqItem(context, faq)),
          const SizedBox(height: 24),
          const Divider(),
          const SizedBox(height: 16),
          _buildContactSection(context),
        ],
      ),
    );
  }

  Widget _buildFaqItem(
    BuildContext context,
    ({String question, String answer}) faq,
  ) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ExpansionTile(
        title: Text(
          faq.question,
          style: const TextStyle(fontWeight: FontWeight.w500),
        ),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                faq.answer,
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
                queryParameters: {'subject': context.l10n.helpRequestSubject},
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
