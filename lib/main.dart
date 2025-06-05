import 'dart:io';
import 'package:c4_tools/services/app_logger.dart' show AppLogger, appLogger;
import 'package:c4_tools/services/app_settings.dart';
import 'package:c4_tools/tools/http_client.dart';
import 'package:flutter/material.dart';
import 'dart:convert';
import 'package:pointycastle/key_derivators/pbkdf2.dart';
import 'package:pointycastle/macs/hmac.dart';
import 'package:pointycastle/pointycastle.dart' hide Padding;
import 'dart:async';
import 'tools/director_tools.dart';
import 'models/data_models.dart';
import 'ssdp/ssdp.dart';
import 'package:window_manager/window_manager.dart';
import 'package:logger/logger.dart' show Level;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:version/version.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:pointycastle/export.dart'
    show
        MD5Digest,
        SHA1Digest,
        SHA224Digest,
        SHA256Digest,
        SHA384Digest,
        SHA512Digest;

void main() async {
  HttpOverrides.global = WebOverrides();
  WidgetsFlutterBinding.ensureInitialized();

  await AppLogger.instance.init();

  await AppSettings.instance.init();

  final savedLogLevel = await AppSettings.instance.getSavedLogLevel();
  await AppLogger.instance.setLogLevel(savedLogLevel ?? Level.info);

  // Only set window size on desktop platforms
  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    await windowManager.ensureInitialized();

    const windowHeight = 800.0;
    const windowWidth = windowHeight * 9 / 16;

    WindowOptions windowOptions = WindowOptions(
      size: Size(windowWidth, windowHeight),
      minimumSize: Size(windowWidth * 0.8, windowHeight * 0.8),
      backgroundColor: Colors.transparent,
      skipTaskbar: false,
      title: 'C4 Tools',
      titleBarStyle: TitleBarStyle.normal,
    );

    windowManager.waitUntilReadyToShow(windowOptions, () async {
      await windowManager.show();
      await windowManager.focus();
    });
  }

  runApp(const MainApp());
}

class MainApp extends StatelessWidget {
  const MainApp({super.key});

  static final GlobalKey<ScaffoldMessengerState> scaffoldMessengerKey =
      GlobalKey<ScaffoldMessengerState>();

  static void showSnackBar(String message, {bool isError = false}) {
    scaffoldMessengerKey.currentState?.showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? Colors.red : null,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: ThemeData(
          brightness: Brightness.dark,
          scrollbarTheme: ScrollbarThemeData(
            thumbVisibility: WidgetStateProperty.all<bool>(true),
          )),
      scaffoldMessengerKey: scaffoldMessengerKey,
      home: C4Tools(),
    );
  }
}

class C4Tools extends StatefulWidget {
  @override
  _C4ToolsState createState() => _C4ToolsState();
}

class _C4ToolsState extends State<C4Tools> with SingleTickerProviderStateMixin {
  final TextEditingController _ipController = TextEditingController();
  final TextEditingController _manualPasswordController =
      TextEditingController();
  static const String _salt = "STlqJGd1fTkjI25CWz1hK1YuMURseXA/UnU5QGp6cF4=";
  static const String _defaultPassword = "t0talc0ntr0l4!";
  static const String _apiKey = "78f6791373d61bea49fdb9fb8897f1f3af193f11";
  bool _isLoading = false;
  String? _errorMessage;
  String? _jwtToken;
  String? _macAddress;
  String? _generatedPassword;
  String? _successfulPassword;
  String? _directorVersion;
  String? _directorName;
  String? _directorUUID;
  List<SsdpResponseInfo> _discoveredDevices = [];
  bool _isDiscovering = false;
  SsdpClient? _sddpClient;
  StreamSubscription<SsdpResponseInfo>? _discoverySubscription;
  bool _rememberCredentials = true;

  final TextEditingController _accountEmailController = TextEditingController();
  final TextEditingController _accountPasswordController =
      TextEditingController();

  @override
  void initState() {
    super.initState();
    _startDiscovery();
    AppSettings.onDataCleared = onDataCleared;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      checkForUpdates();
    });
  }

  @override
  void dispose() {
    _ipController.dispose();
    _manualPasswordController.dispose();
    _accountEmailController.dispose();
    _accountPasswordController.dispose();
    _discoverySubscription?.cancel();
    _sddpClient?.stop();

    AppSettings.onDataCleared = null;

    super.dispose();
  }

  Future<void> checkForUpdates() async {
    try {
      final packageInfo = await PackageInfo.fromPlatform();
      final currentVersion = Version.parse(packageInfo.version);

      final client = httpIOClient();
      final response = await client.get(
        Uri.parse(
            'https://api.github.com/repos/bphillips09/C4-Tools/releases/latest'),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final latestVersion =
            Version.parse(data['tag_name'].toString().replaceAll('v', ''));
        final downloadUrl = data['html_url'] as String;

        if (latestVersion > currentVersion) {
          if (context.mounted) {
            showDialog(
              context: context,
              builder: (BuildContext context) {
                return AlertDialog(
                  title: const Text('Update Available'),
                  content: Text(
                      'A new version is available.\nDo you want to update?'
                      '\n\nv${currentVersion.toString()} --> v${latestVersion.toString()}'),
                  actions: <Widget>[
                    TextButton(
                      child: const Text('No'),
                      onPressed: () {
                        Navigator.of(context).pop();
                      },
                    ),
                    TextButton(
                      child: const Text('Yes'),
                      onPressed: () async {
                        Navigator.of(context).pop();
                        if (await canLaunchUrl(Uri.parse(downloadUrl))) {
                          await launchUrl(Uri.parse(downloadUrl));
                        }
                      },
                    ),
                  ],
                );
              },
            );
          }
        }
      }
    } catch (e) {
      appLogger.e('Error checking for updates', error: e);
    }
  }

  int getHmacBlockSize(Digest digest) {
    if (digest is SHA1Digest) return 64;
    if (digest is SHA224Digest) return 64;
    if (digest is SHA256Digest) return 64;
    if (digest is SHA384Digest) return 128;
    if (digest is SHA512Digest) return 128;
    if (digest is MD5Digest) return 64;

    return 64;
  }

  String? getDirectorRootPassword(String mac) {
    try {
      final saltBytes = base64Decode(_salt);
      final macBytes = utf8.encode(mac);
      final digest = SHA384Digest();

      final blockSize = getHmacBlockSize(digest);
      appLogger.d('Using HMAC block size: $blockSize for SHA384');

      final pbkdf2 = PBKDF2KeyDerivator(HMac(digest, blockSize));
      pbkdf2.init(Pbkdf2Parameters(saltBytes, mac.length * 397, 33));

      final key = pbkdf2.process(macBytes);

      return base64Encode(key);
    } catch (e) {
      appLogger.e('Error generating root password', error: e);
      return null;
    }
  }

  Future<JwtResponse?> _getJwtToken(String password) async {
    try {
      final directorIP = _ipController.text;
      if (directorIP.isEmpty) {
        return JwtResponse(
            error: ErrorResponse(message: 'Director IP address is required'));
      }

      final url = 'https://$directorIP:443/api/v1/localjwt';

      final client = httpIOClient();
      final response = await client.post(
        Uri.parse(url),
        headers: {
          'Accept': 'application/json',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'username': 'root',
          'password': password,
        }),
      );

      if (response.statusCode == 200) {
        return JwtResponse.fromJson(jsonDecode(response.body));
      } else {
        final errorJson = jsonDecode(response.body);
        appLogger.d(errorJson);

        if (errorJson['error'] == 'Unauthorized' &&
            errorJson['details'] != 'Incorrect password') {
          // Device is already bound to an account, prompt for account login
          return JwtResponse(
            error: ErrorResponse(message: 'CONTROLLER_IDENTIFIED'),
            token: null,
          );
        }

        return JwtResponse(
            error: ErrorResponse(
                message: 'Failed to get JWT (Status: ${response.statusCode})'));
      }
    } catch (e) {
      return JwtResponse(
          error: ErrorResponse(message: 'Error getting JWT: ${e.toString()}'));
    }
  }

  Future<JwtResponse?> _getAccountJwtToken(
      String email, String password) async {
    appLogger.i('Trying account services login...');

    try {
      final directorIP = _ipController.text;
      if (directorIP.isEmpty) {
        return JwtResponse(
            error: ErrorResponse(message: 'Director IP address is required'));
      }

      final url = 'https://$directorIP:443/api/v1/jwt';

      final client = httpIOClient();
      final response = await client.post(
        Uri.parse(url),
        headers: {
          'Accept': 'application/json',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'applicationkey': _apiKey,
          'env': 'Prod',
          'email': email,
          'pwd': password,
          'dev': false
        }),
      );

      appLogger.d('JWT response: ${response.statusCode} - ${response.body}');

      if (response.statusCode == 200) {
        return JwtResponse.fromJson(jsonDecode(response.body));
      } else {
        try {
          final errorJson = jsonDecode(response.body);
          return JwtResponse(
              error: ErrorResponse(
            code: errorJson['code'],
            details: errorJson['details'],
            message: errorJson['message'],
            subCode: errorJson['subCode'],
          ));
        } catch (e) {
          // Fallback if parsing fails
          return JwtResponse(
              error: ErrorResponse(
                  message:
                      'Failed to get JWT (Status: ${response.statusCode})'));
        }
      }
    } catch (e) {
      appLogger.e('Error getting JWT token', error: e);
      return JwtResponse(
          error: ErrorResponse(message: 'Error getting JWT: ${e.toString()}'));
    }
  }

  Future<bool> _tryAuthentication(String password) async {
    appLogger.i('Trying password authentication with password: $password');
    final jwtResponse = await _getJwtToken(password);

    if (jwtResponse?.token != null) {
      setState(() {
        _jwtToken = jwtResponse!.token;
        _errorMessage = null;
        _isLoading = false;
        _successfulPassword = password;
      });
      // Stop discovery when successfully authenticated
      _sddpClient?.stopDiscovery();
      return true;
    } else if (jwtResponse?.error?.message == 'CONTROLLER_IDENTIFIED') {
      // Device is bound to an account
      appLogger.i('Director is bound to a Control4 account');

      // First try to use saved credentials if available
      if (_accountEmailController.text.isNotEmpty &&
          _accountPasswordController.text.isNotEmpty) {
        appLogger.i('Attempting to use saved credentials automatically');
        if (await _tryAccountAuthentication()) {
          return true;
        }
        // If saved credentials didn't work, show the dialog
        appLogger.i('Saved credentials failed, showing login dialog');
      }

      // Show account login dialog if no credentials or if they failed
      await _showAccountLoginDialog();
      return true;
    }

    appLogger.d('Authentication failed', error: jwtResponse?.error);
    return false;
  }

  Future<void> _showPasswordDialog() async {
    setState(() {
      _isLoading = false;
    });

    return showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Enter Password'),
          content: TextField(
            controller: _manualPasswordController,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: 'Password',
              border: OutlineInputBorder(),
            ),
            onSubmitted: (_) => _handleManualPasswordLogin(context),
          ),
          actions: <Widget>[
            TextButton(
              child: const Text('Cancel'),
              onPressed: () {
                Navigator.of(context).pop();
              },
            ),
            TextButton(
              child: const Text('Login'),
              onPressed: () => _handleManualPasswordLogin(context),
            ),
          ],
        );
      },
    );
  }

  void _handleManualPasswordLogin(BuildContext context) async {
    setState(() {
      _isLoading = true;
    });

    Navigator.of(context).pop();

    if (await _tryAuthentication(_manualPasswordController.text)) {
      MainApp.showSnackBar('Successfully authenticated!');
    } else {
      setState(() {
        _isLoading = false;
      });
      MainApp.showSnackBar('Invalid password. Please try again.',
          isError: true);
    }
  }

  Future<void> _showAccountLoginDialog() async {
    setState(() {
      _isLoading = false;
    });

    return showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return StatefulBuilder(builder: (context, setDialogState) {
          return AlertDialog(
            title: const Text('Enter Account Credentials'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'This director is bound to a Control4 account. Please enter your account credentials.',
                  style: TextStyle(fontSize: 14),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _accountEmailController,
                  decoration: const InputDecoration(
                    labelText: 'Email',
                    border: OutlineInputBorder(),
                  ),
                  keyboardType: TextInputType.emailAddress,
                  onSubmitted: (_) => _handleAccountLogin(setDialogState),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _accountPasswordController,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'Password',
                    border: OutlineInputBorder(),
                  ),
                  onSubmitted: (_) => _handleAccountLogin(setDialogState),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Checkbox(
                      value: _rememberCredentials,
                      onChanged: (bool? value) {
                        setDialogState(() {
                          _rememberCredentials = value ?? false;
                        });
                      },
                    ),
                    const Text('Remember credentials'),
                  ],
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
                child: const Text('Login'),
                onPressed: () => _handleAccountLogin(setDialogState),
              ),
            ],
          );
        });
      },
    );
  }

  // Save credentials for the current director
  Future<void> _saveCredentials() async {
    if (!_rememberCredentials || _directorName == null) return;

    await AppSettings.instance.saveCredentials(
      _directorName!,
      _accountEmailController.text,
      _accountPasswordController.text,
      ipAddress: _ipController.text,
    );

    appLogger.i(
        'Credentials saved for $_directorName with IP ${_ipController.text}');
  }

  // Load credentials for the current director, if available
  Future<void> _loadDirectorCredentials() async {
    if (_directorName == null) {
      appLogger.i('Cannot load credentials: Director name is null');
      return;
    }

    appLogger.i('Attempting to load credentials for director: $_directorName');

    try {
      // First check if we have credentials for this director
      final hasCredentials =
          AppSettings.instance.hasCredentialsFor(_directorName!);
      appLogger.i('Director has saved credentials: $hasCredentials');

      final credentials =
          await AppSettings.instance.loadCredentials(_directorName!);

      if (credentials != null) {
        appLogger.i(
            'Successfully loaded credentials for $_directorName: ${credentials['username']}');

        setState(() {
          _accountEmailController.text = credentials['username'] ?? '';
          _accountPasswordController.text = credentials['password'] ?? '';
          _rememberCredentials = true;
        });
        appLogger.i(
            'Applied credentials to text fields: ${_accountEmailController.text}');
      } else {
        appLogger.i('No credentials found for $_directorName');
        setState(() {
          _accountEmailController.clear();
          _accountPasswordController.clear();
          _rememberCredentials = false;
        });
      }
    } catch (e) {
      appLogger.e('Error loading credentials for $_directorName', error: e);
    }
  }

  // Try to login using saved account credentials
  Future<bool> _tryAccountAuthentication() async {
    if (_accountEmailController.text.isEmpty ||
        _accountPasswordController.text.isEmpty) {
      appLogger.i('No saved credentials to try');
      return false;
    }

    appLogger.i(
        'Attempting to login with saved credentials for: ${_accountEmailController.text}');

    final jwtResponse = await _getAccountJwtToken(
        _accountEmailController.text, _accountPasswordController.text);

    if (jwtResponse?.token != null) {
      appLogger.i('Automatic login with saved credentials succeeded!');
      setState(() {
        _jwtToken = jwtResponse!.token;
        _errorMessage = null;
        _isLoading = false;
      });

      // Stop discovery when successfully authenticated
      _sddpClient?.stopDiscovery();

      WidgetsBinding.instance.addPostFrameCallback((_) {
        MainApp.showSnackBar(
            'Successfully authenticated with saved credentials!');
      });

      return true;
    }

    appLogger.i('Automatic login with saved credentials failed',
        error: jwtResponse?.error);
    return false;
  }

  Future<void> _connectToDirector() async {
    if (_ipController.text.isEmpty || _isLoading) {
      return;
    }

    appLogger.i('Connecting to director');
    setState(() {
      _isLoading = true;
      _errorMessage = null;
      _jwtToken = null;
      _macAddress = null;
      _generatedPassword = null;
      _successfulPassword = null;
      _directorVersion = null;
      _directorName = null;
      _directorUUID = null;
      _manualPasswordController.clear();
    });

    try {
      final directorIP = _ipController.text;
      final url = 'https://$directorIP:443/api/v1/platform_status';

      final client = httpIOClient();
      final response = await client.get(
        Uri.parse(url),
        headers: {
          'Accept': 'application/json',
          'Content-Type': 'application/json',
        },
      );

      if (response.statusCode == 200) {
        final platformStatus = PlatformStatus.fromJson(
          jsonDecode(response.body),
        );

        appLogger.d('Platform Status Response: ${response.body}');

        if (platformStatus.directorMAC != null) {
          setState(() {
            _macAddress = platformStatus.directorMAC!;
            _generatedPassword =
                getDirectorRootPassword(platformStatus.directorMAC!);
            _directorVersion = platformStatus.directorVersion;
            _directorName = platformStatus.directorName;
            _directorUUID = platformStatus.directorUUID;
          });

          // Load credentials for this director if available
          await _loadDirectorCredentials();

          // First try using saved account credentials if available
          if (await _tryAccountAuthentication()) {
            return;
          }

          // Then try generated password
          if (_generatedPassword != null &&
              await _tryAuthentication(_generatedPassword!)) {
            _sddpClient?.stopDiscovery();
            return;
          }

          // Then try default password
          if (await _tryAuthentication(_defaultPassword)) {
            _sddpClient?.stopDiscovery();
            return;
          }

          // If CONTROLLER_IDENTIFIED was returned during authentication attempts,
          // and we have credentials but they didn't work, show the account login dialog
          await _showPasswordDialog();
        } else {
          setState(() {
            _isLoading = false;
            _errorMessage = 'MAC address not found in response';
          });
        }
      } else {
        String errorMessage =
            'Failed to connect to director (Status: ${response.statusCode})';
        try {
          final errorJson = jsonDecode(response.body);
          if (errorJson['error'] != null) {
            errorMessage = errorJson['error']['details'] ?? errorMessage;
          }
        } catch (e) {
          appLogger.e('Error parsing response body', error: e);
        }
        setState(() {
          _isLoading = false;
          _errorMessage = errorMessage;
        });
      }
    } catch (e) {
      appLogger.e('Connection error', error: e);
      setState(() {
        _isLoading = false;
        _errorMessage = 'Error: ${e.toString()}';
      });
    }
  }

  Future<void> _disconnect() async {
    setState(() {
      _jwtToken = null;
      _macAddress = null;
      _generatedPassword = null;
      _successfulPassword = null;
      _directorVersion = null;
      _directorName = null;
      _directorUUID = null;
      _errorMessage = null;
    });

    // Stop discovery when disconnecting
    _sddpClient?.stopDiscovery();
  }

  Future<void> _startDiscovery() async {
    if (_isDiscovering) return;

    setState(() {
      _isDiscovering = true;
      _discoveredDevices = [];
      _errorMessage = null;
    });

    try {
      appLogger.i('Starting SSDP discovery...');
      _sddpClient = SsdpClient(
        includeLoopback: true,
      );

      await _sddpClient!.start();
      await _sddpClient!.startDiscovery();

      // Listen for discovered devices
      _discoverySubscription = _sddpClient!.discoveredDevices.listen((device) {
        setState(() {
          // Check if device already exists
          final existingIndex = _discoveredDevices.indexWhere(
            (d) => d.sourceAddress == device.sourceAddress,
          );

          if (existingIndex == -1) {
            _discoveredDevices.add(device);
          } else {
            // Update existing device
            _discoveredDevices[existingIndex] = device;
          }
        });
      });

      setState(() {
        _isDiscovering = false;
      });
    } catch (e, stackTrace) {
      appLogger.e('Error during discovery', error: e, stackTrace: stackTrace);
      setState(() {
        _isDiscovering = false;
        _errorMessage = 'Error discovering devices: ${e.toString()}';
      });
    }
  }

  void _selectDevice(SsdpResponseInfo device) {
    final ip = device.sourceAddress;
    setState(() {
      _ipController.text = ip;
    });
  }

  void _selectAndConnectDevice(SsdpResponseInfo device) {
    _selectDevice(device);
    _connectToDirector();
  }

  Future<void> onDataCleared() async {
    if (_jwtToken != null) {
      _disconnect();
    }

    setState(() {
      _accountEmailController.clear();
      _accountPasswordController.clear();
      _rememberCredentials = false;
    });

    MainApp.showSnackBar(
        'All saved credentials and settings cleared successfully');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        centerTitle: true,
        title: const Text('Dashboard'),
        automaticallyImplyLeading: false,
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: 'Settings',
            onPressed: () => _showSettingsMenu(context),
          ),
        ],
      ),
      body: _jwtToken == null
          ? Center(
              child: Card(
                margin: const EdgeInsets.all(32.0),
                child: Padding(
                  padding: const EdgeInsets.all(24.0),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text(
                        'Connect to Director',
                        style: TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 24),
                      _buildIPAddressInput(),
                      const SizedBox(height: 16),
                      if (_errorMessage != null) ...[
                        Text(
                          _errorMessage!,
                          style: const TextStyle(color: Colors.red),
                        ),
                        const SizedBox(height: 16),
                      ],
                      SizedBox(
                        width: double.infinity,
                        child: ValueListenableBuilder<TextEditingValue>(
                          valueListenable: _ipController,
                          builder: (context, value, child) {
                            return ElevatedButton.icon(
                              onPressed: _isLoading || value.text.isEmpty
                                  ? null
                                  : _connectToDirector,
                              icon: _isLoading
                                  ? Stack(
                                      alignment: Alignment.center,
                                      children: [
                                        const SizedBox(
                                          width: 20,
                                          height: 20,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                          ),
                                        ),
                                        IconButton(
                                          icon:
                                              const Icon(Icons.close, size: 16),
                                          tooltip: 'Cancel',
                                          onPressed: () {
                                            setState(() {
                                              _isLoading = false;
                                            });
                                          },
                                          padding: EdgeInsets.zero,
                                          constraints: const BoxConstraints(),
                                        ),
                                      ],
                                    )
                                  : const Icon(Icons.link),
                              label: Text(
                                  _isLoading ? 'Connecting...' : 'Connect'),
                              style: ElevatedButton.styleFrom(
                                padding:
                                    const EdgeInsets.symmetric(vertical: 16),
                              ),
                            );
                          },
                        ),
                      ),
                      const SizedBox(height: 24),
                      const Divider(),
                      const SizedBox(height: 16),
                      _buildDiscoveredDevicesSection(),
                    ],
                  ),
                ),
              ),
            )
          : SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16.0, 0.0, 16.0, 16.0),
              child: DirectorTools(
                jwtToken: _jwtToken,
                macAddress: _macAddress,
                generatedPassword: _generatedPassword,
                errorMessage: _errorMessage,
                successfulPassword: _successfulPassword,
                directorIP: _ipController.text.trim(),
                isLoading: _isLoading,
                onConnect: _connectToDirector,
                ipController: _ipController,
                directorVersion: _directorVersion,
                directorUUID: _directorUUID,
              ),
            ),
      bottomNavigationBar: _jwtToken != null
          ? Container(
              padding: const EdgeInsets.all(8.0),
              decoration: BoxDecoration(
                color: Theme.of(context).cardColor,
                border: Border(
                  top: BorderSide(
                    color: Theme.of(context).dividerColor,
                    width: 1.0,
                  ),
                ),
              ),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (_directorName != null)
                        Text(
                          'Connected to $_directorName',
                          style: const TextStyle(
                            color: Colors.green,
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                          ),
                        ),
                      if (_directorVersion != null)
                        Text(
                          '$_directorVersion',
                          style: const TextStyle(
                            fontWeight: FontWeight.w500,
                            fontSize: 14,
                          ),
                        ),
                    ],
                  ),
                  Positioned(
                    right: 0,
                    child: IconButton(
                      icon: const Icon(Icons.close),
                      tooltip: 'Disconnect',
                      onPressed: _disconnect,
                      color: Colors.red,
                    ),
                  ),
                ],
              ),
            )
          : null,
    );
  }

  void _showSettingsMenu(BuildContext context) {
    AppSettings.showSettingsMenu(context);
  }

  void _handleAccountLogin(StateSetter setDialogState) async {
    setDialogState(() {
      _isLoading = true;
    });

    final email = _accountEmailController.text;
    final password = _accountPasswordController.text;

    if (email.isEmpty || password.isEmpty) {
      MainApp.showSnackBar(
        'Please enter both email and password',
        isError: true,
      );
      setDialogState(() {
        _isLoading = false;
      });
      return;
    }

    // Close dialog before making the network request
    Navigator.of(context).pop();

    if (mounted) {
      setState(() {
        _isLoading = true;
      });
    }

    final jwtResponse = await _getAccountJwtToken(email, password);

    if (mounted) {
      setState(() {
        _isLoading = false;
        if (jwtResponse?.token != null) {
          _jwtToken = jwtResponse!.token;
          _errorMessage = null;

          // Stop discovery when successfully authenticated
          _sddpClient?.stopDiscovery();

          if (_rememberCredentials) {
            _saveCredentials();
          }

          WidgetsBinding.instance.addPostFrameCallback((_) {
            MainApp.showSnackBar(
              'Successfully authenticated with account!',
            );
          });
        } else {
          _errorMessage =
              'Authentication failed. Please check your login details.';

          if (jwtResponse?.error?.message != null) {
            _errorMessage =
                _errorMessage! + ' (${jwtResponse?.error?.message})';
          }

          WidgetsBinding.instance.addPostFrameCallback((_) {
            MainApp.showSnackBar(
              _errorMessage!,
              isError: true,
            );
          });
        }
      });
    }
  }

  Widget _buildIPAddressInput() {
    final knownDirectors = AppSettings.instance.getKnownDirectors();

    return GestureDetector(
      onTap: () {
        if (knownDirectors.isNotEmpty) {
          _showSavedDirectorsMenu(context);
        }
      },
      child: TextField(
        controller: _ipController,
        decoration: InputDecoration(
          labelText: 'Director IP Address',
          border: const OutlineInputBorder(),
          prefixIcon: const Icon(Icons.computer),
          suffixIcon: knownDirectors.isNotEmpty
              ? IconButton(
                  icon: const Icon(Icons.history),
                  tooltip: 'Previously connected directors',
                  onPressed: _isLoading
                      ? null
                      : () => _showSavedDirectorsMenu(context),
                )
              : null,
        ),
        keyboardType: TextInputType.number,
        onSubmitted: (_) => _connectToDirector(),
      ),
    );
  }

  Widget _buildDiscoveredDevicesSection() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text(
              'Discovered Devices',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            IconButton(
              icon: Icon(
                _isDiscovering ? Icons.refresh : Icons.refresh,
                color: _isDiscovering ? Colors.grey : null,
              ),
              onPressed: _isDiscovering ? null : _startDiscovery,
            ),
          ],
        ),
        if (_isDiscovering)
          const Padding(
            padding: EdgeInsets.all(16.0),
            child: Center(
              child: CircularProgressIndicator(),
            ),
          )
        else if (_discoveredDevices.isEmpty)
          const Padding(
            padding: EdgeInsets.all(16.0),
            child: Center(
              child: Text('No devices found'),
            ),
          )
        else
          Container(
            height: 250, // Fixed height for the list
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: _discoveredDevices.length,
              itemBuilder: (context, index) {
                final device = _discoveredDevices[index];
                final isSelected = _ipController.text == device.sourceAddress;
                return Card(
                  margin: const EdgeInsets.symmetric(vertical: 4.0),
                  color: isSelected
                      ? Theme.of(context).primaryColor.withAlpha(0x1A)
                      : null,
                  child: ListTile(
                    leading: const Icon(Icons.devices),
                    title: Text(device.datagram['Type'] ?? 'Unknown Device'),
                    subtitle:
                        Text('${device.sourceAddress}:${device.sourcePort}'),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          device.datagram['Manufacturer'] ?? '',
                          style: const TextStyle(fontSize: 12),
                        ),
                        const SizedBox(width: 8),
                        IconButton(
                          icon: const Icon(Icons.connect_without_contact),
                          tooltip: 'Connect',
                          onPressed: _isLoading
                              ? null
                              : () => _selectAndConnectDevice(device),
                        ),
                      ],
                    ),
                    onTap: () => _selectDevice(device),
                    onLongPress: () {
                      _selectDevice(device);
                      _connectToDirector();
                    },
                  ),
                );
              },
            ),
          ),
      ],
    );
  }

  void _showSavedDirectorsMenu(BuildContext context) async {
    final knownDirectors = AppSettings.instance.getKnownDirectors();
    if (knownDirectors.isEmpty) return;

    final credentials = await AppSettings.instance.getAllSavedCredentials();
    if (credentials.isEmpty) return;

    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Saved Directors'),
          content: SizedBox(
            width: double.maxFinite,
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: credentials.length,
              itemBuilder: (context, index) {
                final cred = credentials[index];
                final directorName = cred['directorName'] as String;

                // Get the stored IP address if available
                final storedIP =
                    AppSettings.instance.getDirectorIP(directorName);
                final ipToShow = storedIP ?? directorName;

                return ListTile(
                  title: Text(directorName),
                  subtitle: Text('${cred['username'] as String} - $ipToShow'),
                  onTap: () {
                    Navigator.pop(context);

                    if (storedIP != null) {
                      _ipController.text = storedIP;
                    } else {
                      String ipAddress = directorName;
                      for (final device in _discoveredDevices) {
                        if (device.datagram['Name'] == directorName ||
                            device.sourceAddress == directorName) {
                          ipAddress = device.sourceAddress;
                          break;
                        }
                      }
                      _ipController.text = ipAddress;
                    }
                    _connectToDirector();
                  },
                );
              },
            ),
          ),
          actions: [
            TextButton(
              child: const Text('Cancel'),
              onPressed: () {
                Navigator.pop(context);
              },
            ),
          ],
        );
      },
    );
  }
}
