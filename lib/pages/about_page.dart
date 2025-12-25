import 'package:better_keep/components/logo.dart';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

class AboutPage extends StatefulWidget {
  const AboutPage({super.key});

  @override
  State<AboutPage> createState() => _AboutPageState();
}

class _AboutPageState extends State<AboutPage> {
  String _version = '';
  String _buildNumber = '';

  @override
  void initState() {
    super.initState();
    _loadPackageInfo();
  }

  Future<void> _loadPackageInfo() async {
    final packageInfo = await PackageInfo.fromPlatform();
    setState(() {
      _version = packageInfo.version;
      _buildNumber = packageInfo.buildNumber;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('About')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // App Info Section
          const SizedBox(height: 24),
          Center(
            child: Column(
              children: [
                LogoImage(size: 80),
                const SizedBox(height: 16),
                const Text(
                  'Better Keep',
                  style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                Text(
                  'Version $_version ($_buildNumber)',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).textTheme.bodySmall?.color,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 32),
          const Divider(),
          const SizedBox(height: 16),

          // Company Info Section
          Center(
            child: Column(
              children: [
                const Text('Developed by', style: TextStyle(fontSize: 14)),
                const SizedBox(height: 12),
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.asset(
                    'assets/foxbiz.png',
                    width: 80,
                    height: 80,
                    errorBuilder: (context, error, stackTrace) {
                      return Image.asset(
                        'assets/foxbiz-1024.png',
                        width: 80,
                        height: 80,
                        errorBuilder: (context, error, stackTrace) {
                          return const Icon(Icons.business, size: 80);
                        },
                      );
                    },
                  ),
                ),
                const SizedBox(height: 12),
                const Text(
                  'Foxbiz Software Pvt. Ltd.',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 16),
                OutlinedButton.icon(
                  onPressed: () async {
                    final uri = Uri.parse('https://foxbiz.io');
                    if (await canLaunchUrl(uri)) {
                      await launchUrl(
                        uri,
                        mode: LaunchMode.externalApplication,
                      );
                    }
                  },
                  icon: const Icon(Icons.language),
                  label: const Text('foxbiz.io'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 32),
          const Divider(),
          const SizedBox(height: 16),

          // Open Source Section
          Center(
            child: Column(
              children: [
                Icon(
                  Icons.code,
                  size: 48,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(height: 12),
                const Text(
                  'Open Source',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                Text(
                  'Better Keep is open source! View the code,\ncontribute, or report issues on GitHub.',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).textTheme.bodySmall?.color,
                  ),
                ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: () async {
                    final uri = Uri.parse(
                      'https://github.com/foxbiz/better-keep',
                    );
                    if (await canLaunchUrl(uri)) {
                      await launchUrl(
                        uri,
                        mode: LaunchMode.externalApplication,
                      );
                    }
                  },
                  icon: const Icon(Icons.open_in_new),
                  label: const Text('View on GitHub'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
