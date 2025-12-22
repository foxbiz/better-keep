import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:url_launcher/url_launcher.dart';

import 'package:http/http.dart' as http;

class WindowsAuthService {
  static const String _clientId = String.fromEnvironment(
    'WINDOWS_GOOGLE_CLIENT_ID',
  );
  static const String _clientSecret = String.fromEnvironment(
    'WINDOWS_GOOGLE_CLIENT_SECRET',
  );

  static Future<Map<String, String>> signIn() async {
    // 1. Start a local server on a random port
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final port = server.port;
    final redirectUri = 'http://127.0.0.1:$port/callback';

    // 2. Generate nonce and state
    final nonce = _generateRandomString();

    // 3. Construct the OAuth URL
    // Using 'code' (Authorization Code Flow) which is standard for Desktop apps
    final authUrl = Uri.parse(
      'https://accounts.google.com/o/oauth2/v2/auth?'
      'client_id=$_clientId&'
      'redirect_uri=$redirectUri&'
      'response_type=code&'
      'scope=openid email profile&'
      'nonce=$nonce',
    );

    // 4. Launch the browser
    if (await canLaunchUrl(authUrl)) {
      await launchUrl(authUrl, mode: LaunchMode.externalApplication);
    } else {
      await server.close();
      throw Exception('Could not launch authentication URL');
    }

    // 5. Wait for the callback
    final completer = Completer<Map<String, String>>();

    server.listen((HttpRequest request) async {
      if (request.uri.path == '/callback') {
        final code = request.uri.queryParameters['code'];
        final error = request.uri.queryParameters['error'];

        if (code != null) {
          request.response
            ..statusCode = HttpStatus.ok
            ..headers.contentType = ContentType.html
            ..write('''
<!DOCTYPE html>
<html>
<head><title>Authenticating...</title></head>
<body>
  <h2>Authentication Successful</h2>
  <p>You can close this window now.</p>
  <script>window.close();</script>
</body>
</html>
''');
          await request.response.close();
          server.close();

          // Exchange code for tokens
          try {
            final tokenResponse = await http.post(
              Uri.parse('https://oauth2.googleapis.com/token'),
              body: {
                'client_id': _clientId,
                'client_secret': _clientSecret,
                'code': code,
                'grant_type': 'authorization_code',
                'redirect_uri': redirectUri,
              },
            );

            final tokenData = jsonDecode(tokenResponse.body);
            if (tokenData['id_token'] != null &&
                tokenData['access_token'] != null) {
              completer.complete({
                'idToken': tokenData['id_token'],
                'accessToken': tokenData['access_token'],
              });
            } else {
              completer.completeError(
                Exception(
                  'Failed to exchange code for tokens: ${tokenResponse.body}',
                ),
              );
            }
          } catch (e) {
            completer.completeError(e);
          }
        } else if (error != null) {
          request.response
            ..statusCode = HttpStatus.badRequest
            ..headers.contentType = ContentType.html
            ..write('<h2>Authentication Error</h2><p>$error</p>');
          await request.response.close();
          server.close();
          completer.completeError(Exception('Authentication error: $error'));
        } else {
          request.response
            ..statusCode = HttpStatus.notFound
            ..write('Not Found');
          await request.response.close();
        }
      }
    });

    return completer.future;
  }

  static String _generateRandomString() {
    final random = Random.secure();
    final values = List<int>.generate(16, (i) => random.nextInt(255));
    return base64UrlEncode(values);
  }
}
