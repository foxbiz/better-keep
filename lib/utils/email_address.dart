final _emailAddress = RegExp(r'^[^\s@]+@[^\s@.]+(?:\.[^\s@.]+)+$');

bool isValidEmailAddress(String value) => _emailAddress.hasMatch(value);
