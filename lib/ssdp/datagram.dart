import 'dart:convert';

class SsdpDatagram {
  final String statementLine;
  final Map<String, String> headers;

  SsdpDatagram({
    required this.statementLine,
    required this.headers,
  });

  String? operator [](String key) => headers[key];

  factory SsdpDatagram.fromBytes(List<int> bytes) {
    final lines = utf8.decode(bytes).split('\r\n');
    if (lines.isEmpty) {
      throw FormatException('Empty datagram');
    }

    final statementLine = lines[0];
    final headers = <String, String>{};

    for (var i = 1; i < lines.length; i++) {
      final line = lines[i].trim();
      if (line.isEmpty) continue;

      final colonIndex = line.indexOf(':');
      if (colonIndex == -1) continue;

      final key = line.substring(0, colonIndex).trim();
      final value = line.substring(colonIndex + 1).trim();
      headers[key] = value;
    }

    return SsdpDatagram(
      statementLine: statementLine,
      headers: headers,
    );
  }

  List<int> toBytes() {
    final buffer = StringBuffer();
    buffer.writeln(statementLine);

    for (final entry in headers.entries) {
      buffer.writeln('${entry.key}: ${entry.value}');
    }
    buffer.writeln();

    return utf8.encode(buffer.toString());
  }

  @override
  String toString() {
    return 'SsdpDatagram(statement: $statementLine, headers: $headers)';
  }
}
