import 'package:better_keep/pages/google_keep_import_page.dart';
import 'package:better_keep/utils/l10n_helper.dart';
import 'package:better_keep/utils/utils.dart';
import 'package:flutter/material.dart';

class GoogleKeepImportCard extends StatelessWidget {
  const GoogleKeepImportCard({super.key});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        leading: const Icon(Icons.move_to_inbox_outlined),
        title: Text(context.l10n.googleKeepImportTitle),
        subtitle: Text(context.l10n.googleKeepImportHelpSubtitle),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => showPage(context, const GoogleKeepImportPage()),
      ),
    );
  }
}
