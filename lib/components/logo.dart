import 'package:better_keep/config.dart';
import 'package:flutter/material.dart';

/// A wrapper widget that adds a subtle glow effect behind the logo
/// to make the bright yellow icon look better on light backgrounds.
/// Uses the same deep purple radial glow style as the login page.
class LogoImage extends StatelessWidget {
  final double size;

  const LogoImage({super.key, this.size = 24});

  @override
  Widget build(BuildContext context) {
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: Colors.deepPurple.withValues(alpha: isDarkMode ? 0.4 : 0.25),
            blurRadius: size * 0.3,
            spreadRadius: size * 0.05,
          ),
          BoxShadow(
            color: Colors.deepPurple.withValues(alpha: isDarkMode ? 0.2 : 0.1),
            blurRadius: size * 0.6,
            spreadRadius: size * 0.15,
          ),
        ],
      ),
      child: Image.asset(
        'assets/better_keep-512.png',
        height: size,
        semanticLabel: 'Better Keep logo',
      ),
    );
  }
}

class Logo extends StatelessWidget {
  const Logo({super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.all(10),
      child: Row(
        children: [
          LogoImage(size: 24),
          SizedBox(width: 10),
          Text(
            appLabel,
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          ),
        ],
      ),
    );
  }
}
