class SsdpConstants {
  /// UDP multicast address
  static const String multicastAddress = '239.255.255.250';
  static const int port = 1900;
  static const double defaultResponseWaitTime = 5.0;

  /// Look only for C4 Director for now
  static const String searchMessage = 'M-SEARCH * HTTP/1.1\r\n'
      'HOST: 239.255.255.250:1900\r\n'
      'MAN: "ssdp:discover"\r\n'
      'MX: 5\r\n'
      'ST: c4:director\r\n'
      '\r\n';
}
