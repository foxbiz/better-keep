import 'package:better_keep/services/iphone_duo.dart';
import 'package:flutter/material.dart';

/// Keeps [child] clear of the status area at the side of an iPhone Duo. Other
/// devices show [child] as it is.
class DuoSafeArea extends StatelessWidget {
  const DuoSafeArea({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) =>
      isIPhoneDuo ? SafeArea(top: false, bottom: false, child: child) : child;
}
