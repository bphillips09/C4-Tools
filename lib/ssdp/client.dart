import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:c4_tools/services/app_logger.dart' show appLogger;

import 'constants.dart';
import 'datagram.dart';
import 'response_info.dart';

class SsdpClient {
  final String _multicastAddress;
  final int _port;
  final double _responseWaitTime;
  final List<InternetAddress> _bindAddresses;
  final bool _includeLoopback;

  RawDatagramSocket? _socket;
  StreamController<SsdpResponseInfo>? _responseController;
  Timer? _timeoutTimer;
  Timer? _searchTimer;
  bool _isSearching = false;

  SsdpClient({
    String multicastAddress = SsdpConstants.multicastAddress,
    int port = SsdpConstants.port,
    double responseWaitTime = SsdpConstants.defaultResponseWaitTime,
    List<InternetAddress>? bindAddresses,
    bool includeLoopback = false,
  })  : _multicastAddress = multicastAddress,
        _port = port,
        _responseWaitTime = responseWaitTime,
        _bindAddresses = bindAddresses ?? [],
        _includeLoopback = includeLoopback;

  Future<void> start() async {
    if (_socket != null) {
      appLogger.d('SSDP: Client already started');
      return;
    }

    try {
      appLogger.i('SSDP: Starting client...');
      final socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        0,
        reuseAddress: true,
      );

      appLogger
          .t('SSDP: Socket bound to ${socket.address.address}:${socket.port}');

      _responseController = StreamController<SsdpResponseInfo>.broadcast();

      final multicastAddress = InternetAddress(_multicastAddress);
      appLogger.t(
          'SSDP: Joining multicast group ${multicastAddress.address}:$_port');

      final interfaces = await NetworkInterface.list();
      appLogger.t('SSDP: Found ${interfaces.length} network interfaces');

      if (_bindAddresses.isEmpty) {
        for (final interface in interfaces) {
          if (!_includeLoopback && interface.name == 'lo') continue;
          appLogger.t('SSDP: Joining multicast on interface ${interface.name}');
          socket.joinMulticast(multicastAddress, interface);
        }
      } else {
        for (final address in _bindAddresses) {
          final interface = interfaces.firstWhere(
            (iface) =>
                iface.addresses.any((addr) => addr.address == address.address),
            orElse: () => interfaces.first,
          );
          appLogger.t(
              'SSDP: Joining multicast on interface ${interface.name} for address ${address.address}');
          socket.joinMulticast(multicastAddress, interface);
        }
      }

      socket.listen((RawSocketEvent event) {
        if (event == RawSocketEvent.read) {
          final datagram = socket.receive();
          if (datagram != null) {
            appLogger.t(
                'SSDP: Received datagram from ${datagram.address.address}:${datagram.port}');
            _handleDatagram(datagram);
          }
        }
      });

      _socket = socket;
      appLogger.i('SSDP: Client started successfully');
    } catch (e, stackTrace) {
      appLogger.e('SSDP: Error starting client',
          error: e, stackTrace: stackTrace);
      rethrow;
    }
  }

  Future<void> stop() async {
    appLogger.i('SSDP: Stopping client...');
    _timeoutTimer?.cancel();
    _searchTimer?.cancel();
    _isSearching = false;
    final socket = _socket;
    if (socket != null) {
      socket.close();
      _socket = null;
    }
    await _responseController?.close();
    _responseController = null;
    appLogger.i('SSDP: Client stopped');
  }

  void _handleDatagram(Datagram datagram) {
    try {
      final response = String.fromCharCodes(datagram.data);
      appLogger.t('SSDP: Processing response: $response');

      // Check if this is a Control4 director response
      if (response.contains('c4:director')) {
        if (response.contains('c4:director:audio') ||
            response.contains('c4:director:ryff') ||
            response.contains('c4:director:luma') ||
            response.contains('c4:director:sndbr')) {
          appLogger
              .t('SSDP: Device is a Triad, RYFF, LUMA, or sound bar, ignoring');
          return;
        }

        // Extract USN if available
        final usnMatch = RegExp(r'USN:\s*(.*?)\s').firstMatch(response);
        final usn = usnMatch?.group(1) ?? '';

        // Extract device type from USN
        final deviceType = usn.split(':').last;

        final responseInfo = SsdpResponseInfo(
          sourceAddress: datagram.address.address,
          sourcePort: datagram.port,
          datagram: SsdpDatagram(
            statementLine: 'SSDP/1.0 200 OK',
            headers: {
              'USN': usn,
              'Type': deviceType,
              'Response': response,
            },
          ),
          ssdpVersion: '1.0',
          statusCode: 200,
          status: 'OK',
        );

        if (_responseController?.isClosed == false) {
          _responseController?.add(responseInfo);
          appLogger.d(
              'SSDP: Found Control4 director at ${datagram.address.address}');
        }
      } else {
        appLogger.t('SSDP: Device was not a director, ignoring');
      }
    } catch (e, stackTrace) {
      appLogger.e('SSDP: Error handling datagram',
          error: e, stackTrace: stackTrace);
    }
  }

  Future<void> startDiscovery() async {
    if (_isSearching) return;

    if (_socket == null) {
      await start();
    }

    _isSearching = true;
    appLogger.i('SSDP: Starting continuous discovery');

    _sendSearchRequest();

    _searchTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      _sendSearchRequest();
    });
  }

  void _sendSearchRequest() {
    if (_socket == null || !_isSearching) return;

    final socket = _socket!;
    final multicastAddress = InternetAddress(_multicastAddress);

    final requestBytes = utf8.encode(SsdpConstants.searchMessage);
    appLogger.t('SSDP: Sending search request: ${SsdpConstants.searchMessage}');

    final bytesSent = socket.send(
      requestBytes,
      multicastAddress,
      _port,
    );

    if (bytesSent == -1) {
      appLogger.w('SSDP: Failed to send search request');
    } else {
      appLogger.t('SSDP: Search request sent successfully');
    }
  }

  void stopDiscovery() {
    _searchTimer?.cancel();
    _isSearching = false;
    appLogger.d('SSDP: Discovery stopped');
  }

  Stream<SsdpResponseInfo> get discoveredDevices {
    if (_responseController == null) {
      start();
    }
    return _responseController!.stream;
  }

  Future<List<SsdpResponseInfo>> simpleSearch({
    String searchPattern = '*',
    double? responseWaitTime,
    int maxResponses = 0,
    bool includeErrorResponses = false,
  }) async {
    appLogger.i('SSDP: Starting simple search');
    final responses = <SsdpResponseInfo>[];

    final timeout = responseWaitTime ?? _responseWaitTime;
    _timeoutTimer?.cancel();
    _timeoutTimer = Timer(Duration(seconds: timeout.toInt()), () {
      appLogger.t('SSDP: Response timeout reached');
      stop();
    });

    _sendSearchRequest();

    await for (final response in discoveredDevices) {
      if (!includeErrorResponses && response.statusCode != 200) {
        appLogger.t('SSDP: Skipping error response: ${response.statusCode}');
        continue;
      }

      responses.add(response);
      appLogger.t('SSDP: Found response: $response');

      if (maxResponses > 0 && responses.length >= maxResponses) {
        appLogger.d('SSDP: Maximum responses reached');
        break;
      }
    }

    _timeoutTimer?.cancel();
    appLogger
        .i('SSDP: Simple search completed with ${responses.length} responses');

    return responses;
  }
}
