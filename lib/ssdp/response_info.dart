import 'datagram.dart';

class SsdpResponseInfo {
  final String sourceAddress;
  final int sourcePort;
  final SsdpDatagram datagram;
  final String ssdpVersion;
  final int statusCode;
  final String status;

  SsdpResponseInfo({
    required this.sourceAddress,
    required this.sourcePort,
    required this.datagram,
    required this.ssdpVersion,
    required this.statusCode,
    required this.status,
  });

  String? operator [](String key) => datagram[key];

  @override
  String toString() {
    return 'SsdpResponseInfo(source: $sourceAddress:$sourcePort, version: $ssdpVersion, status: $statusCode $status)';
  }
}
