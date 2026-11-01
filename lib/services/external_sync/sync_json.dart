import 'dart:convert';

/// Stable JSON for authenticated fingerprints on native and JavaScript runtimes.
/// JSON numbers have no integer/double distinction; Dart's default encoder does.
String canonicalSyncJson(Object? value, {bool legacyNumbers = false}) {
  if (value is _LegacyNumber) return value.text;
  if (value is num) {
    if (!value.isFinite) throw const FormatException('Non-finite sync number');
    if (legacyNumbers) return jsonEncode(value);
    if (value == 0) return '0';
    if (value.abs() <= 9007199254740991 && value == value.truncateToDouble()) {
      return value.toInt().toString();
    }
    return value.toDouble().toStringAsExponential(16);
  }
  if (value is Map) {
    final keys = value.keys.cast<String>().toList()..sort();
    return '{${keys.map((key) => '${jsonEncode(key)}:${canonicalSyncJson(value[key], legacyNumbers: legacyNumbers)}').join(',')}}';
  }
  if (value is List) {
    return '[${value.map((item) => canonicalSyncJson(item, legacyNumbers: legacyNumbers)).join(',')}]';
  }
  return jsonEncode(value);
}

/// The portable schema's sketch ratio is a double on native and a JavaScript
/// number on web. Reproduce both old encodings when forwarding existing edits.
Object legacySyncDouble(num value, {required bool native}) {
  if (!value.isFinite) throw const FormatException('Non-finite sync number');
  var text = value.toDouble().toString();
  if (native) {
    if (!text.contains('.') && !text.contains('e')) text += '.0';
  } else {
    if (value == 0) return const _LegacyNumber('0');
    if (text.endsWith('.0')) text = text.substring(0, text.length - 2);
  }
  return _LegacyNumber(text);
}

/// Older fingerprints used the producer's JSON number spelling. Preserve the
/// authenticated payload's numeric lexemes when validating those fingerprints,
/// rather than guessing whether a JavaScript number used to be a native double.
Object? decodeLegacyFingerprintJson(String source) {
  final numbers = RegExp(
    r'"(?:[^"\\]|\\.)*"|(-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?)',
  ).allMatches(source).where((match) => match.group(1) != null).iterator;
  return jsonDecode(
    source,
    reviver: (key, value) {
      if (value is num) {
        if (!numbers.moveNext()) throw const FormatException('Invalid number');
        return _LegacyNumber(numbers.current.group(1)!);
      }
      return value;
    },
  );
}

class _LegacyNumber {
  const _LegacyNumber(this.text);
  final String text;
}
