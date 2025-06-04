import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

HttpClient httpClient() {
  return HttpClient();
}

http.Client httpIOClient() {
  return IOClient(HttpClient()..userAgent = 'Control4 Tools');
}

class WebOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    return super.createHttpClient(context)
      ..connectionTimeout = const Duration(seconds: 10)
      ..badCertificateCallback = (cert, host, port) => true;
  }
}
