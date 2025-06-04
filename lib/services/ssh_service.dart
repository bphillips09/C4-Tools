import 'dart:async';
import 'dart:convert';
import 'package:c4_tools/services/app_logger.dart' show appLogger;
import 'package:dartssh2/dartssh2.dart';
import 'package:xterm/xterm.dart';

class SSHService {
  final String host;
  final String username;
  final String password;
  SSHClient? _client;
  SSHSession? _session;
  SSHSocket? _socket;
  bool _isConnected = false;
  bool _isConnecting = false;
  bool _isDisconnecting = false;
  final _sessionEndController = StreamController<void>.broadcast();
  Timer? _reconnectTimer;
  final int _maxReconnectAttempts = 3;
  int _reconnectAttempts = 0;
  StreamSubscription? _stdoutSubscription;
  StreamSubscription? _stderrSubscription;

  Stream<void> get onSessionEnd => _sessionEndController.stream;

  SSHService({
    required this.host,
    required this.username,
    required this.password,
  });

  bool get isConnected => _isConnected;

  Future<void> connect(Terminal terminal) async {
    if (_isConnecting) return;
    _isConnecting = true;

    try {
      await _disconnect();
      _socket = await SSHSocket.connect(host, 22);
      _client = SSHClient(
        _socket!,
        username: username,
        onPasswordRequest: () => password,
      );

      _session = await _client!.shell(
        pty: SSHPtyConfig(
          width: terminal.viewWidth,
          height: terminal.viewHeight,
        ),
      );

      terminal.buffer.clear();
      terminal.buffer.setCursor(0, 0);

      terminal.onResize = (width, height, pixelWidth, pixelHeight) {
        if (_session != null && !_isDisconnecting) {
          try {
            _session?.resizeTerminal(width, height, pixelWidth, pixelHeight);
          } catch (e) {
            appLogger.e('Error resizing terminal: $e');
            _handleTransportError();
          }
        }
      };

      terminal.onOutput = (data) {
        if (_session != null && !_isDisconnecting) {
          try {
            _session?.write(utf8.encode(data));
          } catch (e) {
            appLogger.e('Error writing to terminal: $e');
            _handleTransportError();
          }
        }
      };

      _stdoutSubscription?.cancel();
      _stderrSubscription?.cancel();

      _stdoutSubscription =
          _session!.stdout.cast<List<int>>().transform(Utf8Decoder()).listen(
        terminal.write,
        onError: (error) {
          appLogger.e('Error in stdout stream: $error');
          _handleTransportError();
        },
      );

      _stderrSubscription =
          _session!.stderr.cast<List<int>>().transform(Utf8Decoder()).listen(
        terminal.write,
        onError: (error) {
          appLogger.e('Error in stderr stream: $error');
          _handleTransportError();
        },
      );

      // Listen for session end
      _session!.done.then((_) {
        _handleTransportError();
      });

      _isConnected = true;
      _reconnectAttempts = 0;
    } catch (e) {
      appLogger.e('Failed to connect to SSH: $e');
      _isConnected = false;
      await _disconnect();
      _scheduleReconnect();
      throw Exception('Failed to connect to SSH: $e');
    } finally {
      _isConnecting = false;
    }
  }

  Future<void> _disconnect() async {
    if (_isDisconnecting) return;
    _isDisconnecting = true;

    try {
      _stdoutSubscription?.cancel();
      _stderrSubscription?.cancel();
      _stdoutSubscription = null;
      _stderrSubscription = null;

      _session?.close();
      _client?.close();
      _socket?.close();
    } catch (e) {
      appLogger.e('Error during disconnect: $e');
    } finally {
      _session = null;
      _client = null;
      _socket = null;
      _isConnected = false;
      _isDisconnecting = false;
    }
  }

  void _scheduleReconnect() {
    if (_reconnectAttempts >= _maxReconnectAttempts) {
      appLogger.w('Max reconnection attempts reached');
      return;
    }

    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 5), () {
      _reconnectAttempts++;
      appLogger.i(
          'Attempting reconnection (${_reconnectAttempts}/$_maxReconnectAttempts)');
      _sessionEndController.add(null); // Notify UI to attempt reconnection
    });
  }

  Future<void> disconnect() async {
    _reconnectTimer?.cancel();
    await _disconnect();
  }

  void dispose() {
    _reconnectTimer?.cancel();
    _stdoutSubscription?.cancel();
    _stderrSubscription?.cancel();
    _sessionEndController.close();
  }

  void _handleTransportError() {
    _isConnected = false;
    _sessionEndController.add(null);
    _scheduleReconnect();
  }
}
