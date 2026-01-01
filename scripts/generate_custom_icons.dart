#!/usr/bin/env dart

import 'dart:io';
import 'package:flutter/cupertino.dart';

void main() async {
  final projectRoot = Directory.current.path;
  final cssFile = File('$projectRoot/assets/icon.data');
  final dartFile = File('$projectRoot/lib/ui/custom_icons.dart');

  if (!await cssFile.exists()) {
    debugPrint('Error: assets/icon.data not found');
    exit(1);
  }

  final cssContent = await cssFile.readAsString();
  final icons = parseCssIcons(cssContent);

  debugPrint('Found ${icons.length} unique icons');

  final dartContent = generateDartFile(icons);
  await dartFile.writeAsString(dartContent);

  debugPrint('Generated lib/ui/custom_icons.dart');
}

/// Represents an icon with its primary name, code point, and all aliases
class IconInfo {
  final String primaryName;
  final int codePoint;
  final List<String> aliases;

  IconInfo(this.primaryName, this.codePoint, this.aliases);
}

/// Parse CSS file and extract icon names with their unicode code points
/// Returns a list of IconInfo with primary name, code point, and aliases
List<IconInfo> parseCssIcons(String css) {
  final iconPattern = RegExp(
    r'\.icon-([a-zA-Z0-9_-]+):before\s*\{\s*content:\s*"\\([a-fA-F0-9]+)"',
    multiLine: true,
  );

  final codePointToNames = <int, List<String>>{};
  final allMatches = iconPattern.allMatches(css);

  for (final match in allMatches) {
    final iconName = match.group(1)!;
    final codePoint = int.parse(match.group(2)!, radix: 16);

    // Collect all names for each code point
    codePointToNames.putIfAbsent(codePoint, () => []).add(iconName);
  }

  // Convert to list of IconInfo
  final result = <IconInfo>[];
  for (final entry in codePointToNames.entries) {
    final names = entry.value;
    final primaryName = names.first;
    final aliases = names.length > 1 ? names.sublist(1) : <String>[];
    result.add(IconInfo(primaryName, entry.key, aliases));
  }

  return result;
}

/// Convert kebab-case to camelCase for Dart naming convention
String toCamelCase(String kebabCase) {
  final parts = kebabCase.split('-');
  if (parts.isEmpty) return kebabCase;

  final result = StringBuffer(parts.first);
  for (var i = 1; i < parts.length; i++) {
    final part = parts[i];
    if (part.isNotEmpty) {
      result.write(part[0].toUpperCase());
      if (part.length > 1) {
        result.write(part.substring(1));
      }
    }
  }

  // Handle Dart reserved keywords and invalid identifiers
  var camelCase = result.toString();

  // If starts with a number, prefix with underscore
  if (camelCase.isNotEmpty && RegExp(r'^[0-9]').hasMatch(camelCase)) {
    camelCase = 'icon$camelCase';
  }

  return camelCase;
}

/// Generate the Dart file content
String generateDartFile(List<IconInfo> icons) {
  final buffer = StringBuffer();

  buffer.writeln('import \'package:flutter/material.dart\';');
  buffer.writeln();
  buffer.writeln('/// Custom icon font for the application.');
  buffer.writeln('///');
  buffer.writeln('/// This class is auto-generated from `assets/icon.data`.');
  buffer.writeln(
    '/// Run `dart run scripts/generate_custom_icons.dart` to regenerate.',
  );
  buffer.writeln('///');
  buffer.writeln('/// {@category Icons}');
  buffer.writeln('abstract final class CustomIcons {');
  buffer.writeln('  static const String _fontFamily = \'CustomIcons\';');

  // Sort by code point for consistent ordering
  final sortedIcons = List<IconInfo>.from(icons)
    ..sort((a, b) => a.codePoint.compareTo(b.codePoint));

  for (final icon in sortedIcons) {
    final iconName = toCamelCase(icon.primaryName);
    final hex = icon.codePoint.toRadixString(16).padLeft(4, '0');

    buffer.writeln();
    buffer.writeln(
      '  /// Icon: **${icon.primaryName}** — `U+${hex.toUpperCase()}`',
    );
    if (icon.aliases.isNotEmpty) {
      buffer.writeln('  ///');
      buffer.writeln('  /// Also known as: ${icon.aliases.join(", ")}');
    }
    buffer.writeln(
      '  static const IconData $iconName = IconData(0x$hex, fontFamily: _fontFamily);',
    );
  }

  buffer.writeln('}');

  return buffer.toString();
}
