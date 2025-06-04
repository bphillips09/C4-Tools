import 'package:c4_tools/services/app_logger.dart' show appLogger;
import 'package:flutter/material.dart';
import 'package:xterm/xterm.dart';
import '../services/ssh_service.dart';

class SSHScreen extends StatefulWidget {
  final String host;
  final String username;
  final String password;

  const SSHScreen({
    Key? key,
    required this.host,
    required this.username,
    required this.password,
  }) : super(key: key);

  @override
  State<SSHScreen> createState() => _SSHScreenState();
}

class _SSHScreenState extends State<SSHScreen> {
  late SSHService _sshService;
  late final Terminal _terminal;
  bool _isConnecting = true;
  bool _isConnected = false;
  String _title = '';
  String _errorMessage = 'Connection error occurred';
  String _currentPassword = '';
  final TextEditingController _passwordController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _currentPassword = widget.password;
    _sshService = SSHService(
      host: widget.host,
      username: widget.username,
      password: _currentPassword,
    );
    _terminal = Terminal(
      maxLines: 10000,
    );
    _setupTerminal();
    _connect();
  }

  void _setupTerminal() {
    _terminal.onTitleChange = (title) {
      setState(() => _title = title);
    };
  }

  Future<void> _connect() async {
    setState(() {
      _isConnecting = true;
      _isConnected = false;
      _errorMessage = '';
    });

    try {
      await _sshService.connect(_terminal);
      setState(() {
        _isConnecting = false;
        _isConnected = true;
        _errorMessage = '';
      });

      _sshService.onSessionEnd.listen((_) {
        if (mounted) {
          setState(() {
            _isConnected = false;
            _errorMessage = 'Connection lost.';
          });
        }
      });
    } catch (e) {
      appLogger.e(e);
      setState(() {
        _isConnecting = false;
        _isConnected = false;

        String errorString = e.toString();
        if (errorString.contains('SSHAuthFailError') ||
            errorString.contains('authentication')) {
          _errorMessage = 'Invalid username or password';
          _showPasswordDialog();
        } else if (errorString.contains('timeout') ||
            errorString.contains('timed out')) {
          _errorMessage = 'Connection timed out';
        } else if (errorString.contains('refused') ||
            errorString.contains('unreachable')) {
          _errorMessage =
              'Connection refused - server may be down or unreachable';
        } else if (errorString.contains('Transport is closed')) {
          _errorMessage = 'Connection lost.';
        } else {
          _errorMessage = errorString;
        }
      });
    }
  }

  Future<void> _showPasswordDialog() async {
    _passwordController.clear();

    return showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Authentication Failed'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Please enter a different password.\n'
                  '\nIf you don\'t know the password, you\'ll need to reset it '
                  'using this tool.'),
              const SizedBox(height: 16),
              TextField(
                controller: _passwordController,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'Password',
                  border: OutlineInputBorder(),
                ),
                onSubmitted: (_) => _handlePasswordEntry(context),
              ),
            ],
          ),
          actions: <Widget>[
            TextButton(
              child: const Text('Cancel'),
              onPressed: () {
                Navigator.of(context).pop();
              },
            ),
            TextButton(
              child: const Text('Connect'),
              onPressed: () => _handlePasswordEntry(context),
            ),
          ],
        );
      },
    );
  }

  void _handlePasswordEntry(BuildContext context) {
    if (_passwordController.text.isEmpty) return;

    _currentPassword = _passwordController.text;

    // Create a new SSH service with the updated password
    _sshService = SSHService(
      host: widget.host,
      username: widget.username,
      password: _currentPassword,
    );

    Navigator.of(context).pop();
    _connect();
  }

  @override
  void dispose() {
    _passwordController.dispose();
    _sshService.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_isConnecting) {
      return const Scaffold(
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              CircularProgressIndicator(),
              SizedBox(height: 16),
              Text('Connecting to SSH...'),
            ],
          ),
        ),
      );
    }

    if (!_isConnected) {
      return Scaffold(
        appBar: AppBar(
          centerTitle: true,
          title: const Text('SSH Error'),
        ),
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error_outline, size: 48, color: Colors.red),
              const SizedBox(height: 16),
              const Text(
                'Failed to connect to SSH',
                style: TextStyle(fontSize: 18),
              ),
              const SizedBox(height: 8),
              Text(
                _errorMessage,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.red),
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  ElevatedButton(
                    onPressed: _connect,
                    child: const Text('Retry Connection'),
                  ),
                  const SizedBox(width: 16),
                  ElevatedButton(
                    onPressed: _showPasswordDialog,
                    child: const Text('Try Different Password'),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        centerTitle: true,
        title: Text(_title.isNotEmpty ? _title : 'SSH Terminal'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _connect,
            tooltip: 'Reconnect',
          ),
        ],
      ),
      body: Container(
        color: Colors.black,
        padding: const EdgeInsets.all(8.0),
        child: TerminalView(
          _terminal,
          backgroundOpacity: 1.0,
        ),
      ),
    );
  }
}
