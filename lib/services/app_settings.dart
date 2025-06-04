import 'dart:io';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:logger/logger.dart' show Level;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:c4_tools/services/app_logger.dart' show AppLogger, appLogger;
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:android_intent_plus/android_intent.dart';
import 'package:open_file/open_file.dart';

class AppSettings {
  static final AppSettings _instance = AppSettings._internal();
  factory AppSettings() => _instance;
  AppSettings._internal();

  static AppSettings get instance => _instance;

  static VoidCallback? onDataCleared;

  bool _isInitialized = false;
  Map<String, dynamic> _cachedSettings = {};

  Future<void> init() async {
    if (_isInitialized) return;

    try {
      await clearLogFile();

      // Load settings from SharedPreferences
      await _loadGlobalSettings();

      final savedLogLevel = await getSavedLogLevel();
      appLogger.d(
          'Initialized with saved log level: ${savedLogLevel != null ? logLevelToString(savedLogLevel) : "none"}');

      _isInitialized = true;
      appLogger.i('AppSettings initialized');
    } catch (e) {
      appLogger.e('Error initializing AppSettings', error: e);
    }
  }

  Future<void> _loadGlobalSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();

      // Extract known directors from saved credentials
      final allKeys = prefs.getKeys();
      final credentialKeys =
          allKeys.where((key) => key.startsWith('credentials_')).toList();

      final knownDirectors = <String>[];
      final directorIPs = <String, String>{};

      for (final key in credentialKeys) {
        final directorName =
            key.replaceFirst('credentials_', '').replaceAll('_', '-');
        knownDirectors.add(directorName);

        try {
          final credentialsJson = prefs.getString(key);
          if (credentialsJson != null) {
            final data = jsonDecode(credentialsJson);
            if (data['ipAddress'] != null) {
              directorIPs[directorName] = data['ipAddress'];
            }
          }
        } catch (e) {
          appLogger.e('Error extracting IP for $directorName', error: e);
        }
      }

      _cachedSettings = {
        'knownDirectors': knownDirectors,
        'directorIPs': directorIPs,
      };

      appLogger.d(
          'Global settings loaded with ${knownDirectors.length} known directors');
    } catch (e) {
      appLogger.e('Error loading global settings', error: e);
      _cachedSettings = {
        'knownDirectors': [],
        'directorIPs': {},
      };
    }
  }

  Future<Level?> getSavedLogLevel() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedLevelValue = prefs.getInt('log_level_preference');

      if (savedLevelValue != null) {
        return AppLogger.instance.intToLogLevel(savedLevelValue);
      }
      return null;
    } catch (e) {
      appLogger.e('Error getting saved log level', error: e);
      return null;
    }
  }

  List<String> getKnownDirectors() {
    return List<String>.from(_cachedSettings['knownDirectors'] ?? []);
  }

  String? getDirectorIP(String directorName) {
    final directorIPs = _cachedSettings['directorIPs'] as Map<String, String>?;
    return directorIPs?[directorName];
  }

  bool hasCredentialsFor(String directorName) {
    final knownDirectors = getKnownDirectors();
    return knownDirectors.contains(directorName);
  }

  static String logLevelToString(Level level) {
    switch (level) {
      case Level.trace:
        return 'Trace';
      case Level.debug:
        return 'Debug';
      case Level.info:
        return 'Info';
      case Level.warning:
        return 'Warning';
      case Level.error:
        return 'Error';
      case Level.fatal:
        return 'Fatal';
      case Level.off:
        return 'Off';
      default:
        return 'Unknown';
    }
  }

  static String getLogLevelDescription(Level level) {
    switch (level) {
      case Level.trace:
        return 'Most detailed logging, includes all levels';
      case Level.debug:
        return 'Development information and everything above';
      case Level.info:
        return 'General information and everything above';
      case Level.warning:
        return 'Warnings, errors and fatal issues only';
      case Level.error:
        return 'Errors and fatal issues only';
      case Level.fatal:
        return 'Only fatal/critical issues';
      case Level.off:
        return 'Logging disabled';
      default:
        return '';
    }
  }

  Future<void> setLogLevel(Level level) async {
    try {
      final prefs = await SharedPreferences.getInstance();

      int levelValue;
      switch (level) {
        case Level.trace:
          levelValue = 0;
          break;
        case Level.debug:
          levelValue = 1;
          break;
        case Level.info:
          levelValue = 2;
          break;
        case Level.warning:
          levelValue = 3;
          break;
        case Level.error:
          levelValue = 4;
          break;
        case Level.fatal:
          levelValue = 5;
          break;
        case Level.off:
          levelValue = 6;
          break;
        default:
          levelValue = 2;
      }

      await prefs.setInt('log_level_preference', levelValue);

      // Update logger with new level using AppLogger
      await AppLogger.instance.setLogLevel(level);
      appLogger.i('Log level changed to ${logLevelToString(level)}');
    } catch (e) {
      appLogger.e('Error setting log level', error: e);
    }
  }

  Future<void> saveCredentials(
      String directorName, String username, String password,
      {String? ipAddress}) async {
    try {
      if (directorName.isEmpty) return;

      final prefs = await SharedPreferences.getInstance();

      final directorKey =
          'credentials_${directorName.replaceAll(RegExp(r'[^\w]'), '_')}';

      final credentials = {
        'username': username,
        'password': password,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
        'ipAddress': ipAddress,
      };

      await prefs.setString(directorKey, jsonEncode(credentials));
      appLogger.i(
          'Credentials saved for $directorName${ipAddress != null ? " with IP $ipAddress" : ""}');

      await _loadGlobalSettings();
    } catch (e) {
      appLogger.e('Error saving credentials', error: e);
    }
  }

  Future<Map<String, String>?> loadCredentials(String directorName) async {
    try {
      if (directorName.isEmpty) return null;

      final prefs = await SharedPreferences.getInstance();

      final directorKey =
          'credentials_${directorName.replaceAll(RegExp(r'[^\w]'), '_')}';

      if (prefs.containsKey(directorKey)) {
        final credentialsJson = prefs.getString(directorKey);
        if (credentialsJson != null) {
          final data = jsonDecode(credentialsJson);
          return {
            'username': data['username'] ?? '',
            'password': data['password'] ?? '',
            'ipAddress': data['ipAddress'] ?? '',
          };
        }
      }
      return null;
    } catch (e) {
      appLogger.e('Error loading credentials', error: e);
      return null;
    }
  }

  Future<List<Map<String, dynamic>>> getAllSavedCredentials() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final allKeys = prefs.getKeys();
      final credentialKeys =
          allKeys.where((key) => key.startsWith('credentials_')).toList();

      if (credentialKeys.isEmpty) {
        return [];
      }

      final credentials = credentialKeys.map((key) {
        final data = jsonDecode(prefs.getString(key) ?? '{}');
        final directorName =
            key.replaceFirst('credentials_', '').replaceAll('_', '-');
        return {
          'key': key,
          'directorName': directorName,
          'username': data['username'] ?? 'Unknown',
          'timestamp': data['timestamp'] ?? 0,
          'ipAddress': data['ipAddress'] ?? '',
        };
      }).toList();

      credentials.sort(
          (a, b) => (b['timestamp'] as int).compareTo(a['timestamp'] as int));

      return credentials;
    } catch (e) {
      appLogger.e('Error getting saved credentials', error: e);
      return [];
    }
  }

  Future<bool> deleteCredential(String key) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final result = await prefs.remove(key);

      await _loadGlobalSettings();

      return result;
    } catch (e) {
      appLogger.e('Error deleting credential', error: e);
      return false;
    }
  }

  Future<void> clearAllData() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.clear();

      await AppLogger.instance.setLogLevel(Level.info);

      _cachedSettings = {};
      await _loadGlobalSettings();

      appLogger.i('All saved credentials and settings cleared successfully');
    } catch (e) {
      appLogger.e('Error clearing all data', error: e);
    }
  }

  Future<bool> clearBrowserData() async {
    try {
      if (!Platform.isWindows) {
        await InAppWebViewController.clearAllCache();
      }

      final cookieManager = CookieManager.instance();
      await cookieManager.deleteAllCookies();

      appLogger.i('Browser data and cookies cleared successfully');
      return true;
    } catch (e) {
      appLogger.e('Error clearing browser data', error: e);
      return false;
    }
  }

  Future<bool> clearAllAppData() async {
    try {
      await clearAllData();

      await clearBrowserData();

      return true;
    } catch (e) {
      appLogger.e('Error clearing all app data', error: e);
      return false;
    }
  }

  Future<bool> openSupportDirectory() async {
    try {
      final appDir = await getApplicationSupportDirectory();
      final supportDir = Directory('${appDir.path}');
      if (!await supportDir.exists()) {
        await supportDir.create(recursive: true);
      }

      if (Platform.isWindows) {
        await Process.run('explorer', [supportDir.path]);
      } else if (Platform.isMacOS) {
        await Process.run('open', [supportDir.path]);
      } else if (Platform.isLinux) {
        await Process.run('xdg-open', [supportDir.path]);
      } else if (Platform.isAndroid) {
        bool success = false;

        // Try to open directory with intent approach
        try {
          appLogger
              .i('Trying to open directory with ACTION_OPEN_DOCUMENT_TREE');
          final intent = AndroidIntent(
            action: 'android.intent.action.OPEN_DOCUMENT_TREE',
            flags: <int>[0x10000000], // FLAG_ACTIVITY_NEW_TASK
          );

          await intent.launch();
          success = true;
          appLogger.i('Opened file picker using ACTION_OPEN_DOCUMENT_TREE');
        } catch (e) {
          appLogger.w('Failed to open directory with ACTION_OPEN_DOCUMENT_TREE',
              error: e);
        }

        return success;
      }
      return true;
    } catch (e) {
      appLogger.e('Error opening support directory', error: e);
      return false;
    }
  }

  Future<bool> openLogFile() async {
    try {
      final logFilePath = AppLogger.instance.logFilePath;
      final logFile = File(logFilePath);

      if (!await logFile.exists()) {
        await logFile.parent.create(recursive: true);
        await logFile.writeAsString('Log file created at ${DateTime.now()}\n');
      }

      appLogger.i('Opening log file at: ${logFile.path}');

      if (Platform.isAndroid) {
        if (await logFile.exists()) {
          try {
            final result = await OpenFile.open(logFile.path);
            if (result.type == ResultType.done) {
              return true;
            } else {
              appLogger.w('OpenFile result: ${result.message}');
            }
          } catch (e) {
            appLogger.w(
                'Failed to open with OpenFile, trying intent approaches',
                error: e);
          }

          return false;
        } else {
          appLogger.w('Log file does not exist at: ${logFile.path}');
          return false;
        }
      } else {
        final uri = Uri.file(logFile.path);
        if (await canLaunchUrl(uri)) {
          await launchUrl(uri);
          return true;
        } else {
          throw 'Could not launch $uri';
        }
      }
    } catch (e) {
      appLogger.e('Error opening log file', error: e);
      return false;
    }
  }

  static Future<void> showSettingsMenu(BuildContext context) async {
    final currentLogLevel = AppLogger.instance.currentLogLevel;

    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Settings'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.folder),
                title: const Text('Open Data Folder'),
                onTap: () {
                  Navigator.pop(context);
                  AppSettings.instance.openSupportDirectory();
                },
              ),
              ListTile(
                leading: const Icon(Icons.description),
                title: const Text('Open Log File'),
                onTap: () {
                  Navigator.pop(context);
                  AppSettings.instance.openLogFile();
                },
              ),
              ListTile(
                leading: const Icon(Icons.list_alt),
                title: const Text('Log Level'),
                subtitle: Text('Current: ${logLevelToString(currentLogLevel)}'),
                onTap: () {
                  Navigator.pop(context);
                  showLogLevelDialog(context);
                },
              ),
              ListTile(
                leading: const Icon(Icons.key),
                title: const Text('Manage Saved Credentials'),
                onTap: () {
                  Navigator.pop(context);
                  showSavedCredentials(context);
                },
              ),
              ListTile(
                leading: const Icon(Icons.delete_forever),
                title: const Text('Clear Data'),
                onTap: () {
                  Navigator.pop(context);
                  showClearDataConfirmation(context);
                },
              ),
            ],
          ),
          actions: [
            TextButton(
              child: const Text('Close'),
              onPressed: () {
                Navigator.pop(context);
              },
            ),
          ],
        );
      },
    );
  }

  static Future<void> showLogLevelDialog(BuildContext context) async {
    Level selectedLevel = AppLogger.instance.currentLogLevel;

    return showDialog<void>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Log Level'),
          content: StatefulBuilder(
            builder: (context, setState) {
              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Select the minimum log level to record:'),
                  const SizedBox(height: 16),
                  _buildLogLevelRadio(context, Level.trace, selectedLevel,
                      (value) {
                    setState(() => selectedLevel = value);
                  }),
                  _buildLogLevelRadio(context, Level.debug, selectedLevel,
                      (value) {
                    setState(() => selectedLevel = value);
                  }),
                  _buildLogLevelRadio(context, Level.info, selectedLevel,
                      (value) {
                    setState(() => selectedLevel = value);
                  }),
                  _buildLogLevelRadio(context, Level.warning, selectedLevel,
                      (value) {
                    setState(() => selectedLevel = value);
                  }),
                  _buildLogLevelRadio(context, Level.error, selectedLevel,
                      (value) {
                    setState(() => selectedLevel = value);
                  }),
                  _buildLogLevelRadio(context, Level.fatal, selectedLevel,
                      (value) {
                    setState(() => selectedLevel = value);
                  }),
                  const SizedBox(height: 16),
                  Text(
                    'Description: ${getLogLevelDescription(selectedLevel)}',
                    style: const TextStyle(
                        fontStyle: FontStyle.italic, fontSize: 12),
                  ),
                ],
              );
            },
          ),
          actions: <Widget>[
            TextButton(
              child: const Text('Cancel'),
              onPressed: () {
                Navigator.of(context).pop();
              },
            ),
            TextButton(
              child: const Text('Apply'),
              onPressed: () async {
                await instance.setLogLevel(selectedLevel);
                Navigator.of(context).pop();
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                        'Log level set to ${logLevelToString(selectedLevel)}'),
                  ),
                );
              },
            ),
          ],
        );
      },
    );
  }

  static Widget _buildLogLevelRadio(BuildContext context, Level level,
      Level groupValue, Function(Level) onChanged) {
    return RadioListTile<Level>(
      title: Text(logLevelToString(level)),
      value: level,
      groupValue: groupValue,
      onChanged: (Level? value) {
        if (value != null) {
          onChanged(value);
        }
      },
      dense: true,
    );
  }

  static Future<void> showSavedCredentials(BuildContext context) async {
    try {
      final credentials = await instance.getAllSavedCredentials();

      if (credentials.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No saved credentials found')),
        );
        return;
      }

      showDialog(
        context: context,
        builder: (BuildContext context) {
          return AlertDialog(
            title: const Text('Saved Credentials'),
            content: SizedBox(
              width: double.maxFinite,
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: credentials.length,
                itemBuilder: (context, index) {
                  final cred = credentials[index];
                  return ListTile(
                    title: Text(cred['directorName'] as String),
                    subtitle: Text(cred['username'] as String),
                    trailing: IconButton(
                      icon: const Icon(Icons.delete),
                      onPressed: () async {
                        await instance.deleteCredential(cred['key'] as String);
                        Navigator.pop(context);
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Credentials deleted')),
                        );
                        showSavedCredentials(context); // Refresh the list
                      },
                    ),
                  );
                },
              ),
            ),
            actions: [
              TextButton(
                child: const Text('Close'),
                onPressed: () {
                  Navigator.pop(context);
                },
              ),
            ],
          );
        },
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error loading credentials: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  static Future<void> showClearDataConfirmation(BuildContext context) async {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Clear All Data?'),
          content: const Text(
            'This will delete all saved credentials and application data. This action cannot be undone.',
          ),
          actions: [
            TextButton(
              child: const Text('Cancel'),
              onPressed: () {
                Navigator.pop(context);
              },
            ),
            TextButton(
              child: const Text('Clear Data'),
              style: TextButton.styleFrom(
                foregroundColor: Colors.red,
              ),
              onPressed: () async {
                Navigator.pop(context);
                final success = await instance.clearAllAppData();
                if (context.mounted) {
                  if (onDataCleared != null) {
                    onDataCleared!();
                  }

                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(success
                          ? 'All saved credentials and settings cleared successfully'
                          : 'Error clearing data'),
                      backgroundColor: success ? null : Colors.red,
                    ),
                  );
                }
              },
            ),
          ],
        );
      },
    );
  }

  Future<bool> clearLogFile() async {
    try {
      final logFilePath = AppLogger.instance.logFilePath;
      final logFile = File(logFilePath);

      if (await logFile.exists()) {
        final backupPath = '${logFilePath}.bak';
        final backupFile = File(backupPath);

        if (await backupFile.exists()) {
          await backupFile.delete();
        }

        await logFile.copy(backupPath);

        await logFile.writeAsString('Log file cleared at ${DateTime.now()}\n');

        appLogger.i('Log file cleared');
        return true;
      }

      return false;
    } catch (e) {
      appLogger.e('Error clearing log file', error: e);
      return false;
    }
  }
}
