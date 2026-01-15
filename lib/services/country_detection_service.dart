import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// Service to detect user's country code for currency selection.
/// Uses IP-based geolocation with caching to minimize API calls.
class CountryDetectionService {
  static const String _cacheKey = 'cached_country_code';
  static const String _cacheTimestampKey = 'cached_country_timestamp';
  static const Duration _cacheDuration = Duration(days: 30);

  /// Detects the user's country code (e.g., 'IN', 'US', 'GB').
  /// Returns cached value if available and valid, otherwise fetches from API.
  /// Falls back to device locale if API fails.
  static Future<String> detectCountryCode() async {
    // Try to get cached country code first
    final cachedCountry = await _getCachedCountryCode();
    if (cachedCountry != null) {
      debugPrint('CountryDetection: Using cached country: $cachedCountry');
      return cachedCountry;
    }

    // If no cache, fetch from API
    try {
      debugPrint(
        'CountryDetection: Fetching country from IP geolocation API...',
      );
      final countryCode = await _fetchCountryFromIP();
      await _cacheCountryCode(countryCode);
      debugPrint('CountryDetection: Detected and cached country: $countryCode');
      return countryCode;
    } catch (e) {
      debugPrint(
        'CountryDetection: API failed, falling back to device locale: $e',
      );
      return _getCountryFromLocale();
    }
  }

  /// Fetches country code from IP geolocation API.
  /// Using ipapi.co (HTTPS, free tier: 1000 req/day, no API key required).
  static Future<String> _fetchCountryFromIP() async {
    try {
      final response = await http
          .get(Uri.parse('https://ipapi.co/country/'))
          .timeout(const Duration(seconds: 5));

      if (response.statusCode == 200) {
        final countryCode = response.body.trim();
        if (countryCode.isNotEmpty && countryCode.length == 2) {
          return countryCode.toUpperCase();
        }
      }
      throw Exception('Failed to get country code from API');
    } catch (e) {
      rethrow;
    }
  }

  /// Gets cached country code if valid (not expired).
  static Future<String?> _getCachedCountryCode() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final cachedCode = prefs.getString(_cacheKey);
      final cachedTimestamp = prefs.getInt(_cacheTimestampKey);

      if (cachedCode != null && cachedTimestamp != null) {
        final cacheTime = DateTime.fromMillisecondsSinceEpoch(cachedTimestamp);
        final now = DateTime.now();

        if (now.difference(cacheTime) < _cacheDuration) {
          return cachedCode;
        } else {
          debugPrint('CountryDetection: Cache expired');
        }
      }
    } catch (e) {
      debugPrint('CountryDetection: Error reading cache: $e');
    }
    return null;
  }

  /// Caches the country code with current timestamp.
  static Future<void> _cacheCountryCode(String countryCode) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_cacheKey, countryCode);
      await prefs.setInt(
        _cacheTimestampKey,
        DateTime.now().millisecondsSinceEpoch,
      );
    } catch (e) {
      debugPrint('CountryDetection: Error caching country: $e');
    }
  }

  /// Fallback: Gets country from device locale.
  /// Note: This may not be accurate if user changed language settings.
  static String _getCountryFromLocale() {
    try {
      final locale = PlatformDispatcher.instance.locale;
      final countryCode = locale.countryCode;
      if (countryCode != null && countryCode.isNotEmpty) {
        debugPrint('CountryDetection: Using locale country: $countryCode');
        return countryCode;
      }
    } catch (e) {
      debugPrint('CountryDetection: Error getting locale: $e');
    }
    // Ultimate fallback: return US
    debugPrint('CountryDetection: Using default country: US');
    return 'US';
  }

  /// Clears cached country code (useful for testing or user preference reset).
  static Future<void> clearCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_cacheKey);
      await prefs.remove(_cacheTimestampKey);
      debugPrint('CountryDetection: Cache cleared');
    } catch (e) {
      debugPrint('CountryDetection: Error clearing cache: $e');
    }
  }
}
