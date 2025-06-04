import 'dart:io';
import 'package:logger/logger.dart';
import 'package:path_provider/path_provider.dart';

AppLogger get appLogger => AppLogger.instance;

const String logLevelPreferenceKey = 'log_level_preference';

class AppLogger {
  static final AppLogger _instance = AppLogger._internal();
  static AppLogger get instance => _instance;

  late Logger logger;
  Level _currentLogLevel = Level.info;
  late File _logFile;
  bool _initialized = false;

  AppLogger._internal();

  void _safeLog(
      Function(String, {dynamic error, StackTrace? stackTrace}) logMethod,
      dynamic message,
      {dynamic error,
      StackTrace? stackTrace}) {
    try {
      final String safeMessage =
          message is String ? message : message.toString();
      logMethod(safeMessage, error: error, stackTrace: stackTrace);
    } catch (e) {
      try {
        print('[LOGGER ERROR] Failed to log message: $e');
        print('[ORIGINAL LOG] $message');
      } catch (_) {
        // Ignore if somehow print fails
      }
    }
  }

  // Safe wrappers because apparently we have to...

  void t(dynamic message, {dynamic error, StackTrace? stackTrace}) {
    _safeLog(logger.t, message, error: error, stackTrace: stackTrace);
  }

  void d(dynamic message, {dynamic error, StackTrace? stackTrace}) {
    _safeLog(logger.d, message, error: error, stackTrace: stackTrace);
  }

  void i(dynamic message, {dynamic error, StackTrace? stackTrace}) {
    _safeLog(logger.i, message, error: error, stackTrace: stackTrace);
  }

  void w(dynamic message, {dynamic error, StackTrace? stackTrace}) {
    _safeLog(logger.w, message, error: error, stackTrace: stackTrace);
  }

  void e(dynamic message, {dynamic error, StackTrace? stackTrace}) {
    _safeLog(logger.e, message, error: error, stackTrace: stackTrace);
    _safeLog(logger.e, 'Error Details: ${error.toString()}');
  }

  void f(dynamic message, {dynamic error, StackTrace? stackTrace}) {
    _safeLog(logger.f, message, error: error, stackTrace: stackTrace);
  }

  Future<void> init() async {
    if (_initialized) return;

    final appDir = await getApplicationSupportDirectory();
    _logFile = File('${appDir.path}/log.txt');

    if (!await _logFile.exists()) {
      await _logFile.parent.create(recursive: true);
      await _logFile.writeAsString('Log file created at ${DateTime.now()}\n');
    }

    bool isReleaseMode = true;
    assert(() {
      isReleaseMode = false;
      return true;
    }());
    logger = Logger(
      filter: ProductionFilter(),
      level: Level.trace,
      output: SimpleLogOutput(
        _logFile,
        writeToFile: true,
      ),
      printer: CustomLogPrinter(
        colors: false, // Avoid ESC characters depending on the terminal
      ),
    );

    logger.i(
        'Logger initialized. Running in ${isReleaseMode ? "release" : "debug"} mode with ${_logLevelToString(_currentLogLevel)} level.');
    _initialized = true;
  }

  Future<void> setLogLevel(Level level) async {
    _currentLogLevel = level;

    // Create new logger with updated level
    logger = Logger(
      filter: ProductionFilter(),
      level: level,
      output: SimpleLogOutput(
        _logFile,
        writeToFile: true,
      ),
      printer: CustomLogPrinter(
        colors: false,
      ),
    );

    logger.i('Log level changed to ${_logLevelToString(level)}');
  }

  Level get currentLogLevel => _currentLogLevel;

  String get logFilePath => _logFile.path;

  String _logLevelToString(Level level) {
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

  Level intToLogLevel(int value) {
    switch (value) {
      case 0:
        return Level.trace;
      case 1:
        return Level.debug;
      case 2:
        return Level.info;
      case 3:
        return Level.warning;
      case 4:
        return Level.error;
      case 5:
        return Level.fatal;
      case 6:
        return Level.off;
      default:
        return Level.info; // Default to info level
    }
  }
}

class CustomLogPrinter extends LogPrinter {
  final bool colors;
  final Map<Level, String> levelPrefixes = {
    Level.trace: '[T]',
    Level.debug: '[D]',
    Level.info: '[I]',
    Level.warning: '[W]',
    Level.error: '[E]',
    Level.fatal: '[F]',
  };

  CustomLogPrinter({this.colors = true});

  @override
  List<String> log(LogEvent event) {
    String levelStr = levelPrefixes[event.level] ?? '???';
    return [levelStr + ' ' + event.message];
  }
}

class SimpleLogOutput extends LogOutput {
  final File file;
  final bool writeToFile;

  SimpleLogOutput(this.file, {this.writeToFile = true});

  @override
  void output(OutputEvent event) {
    for (var line in event.lines) {
      // Use standard print for console output in the logger implementation
      // ignore: avoid_print
      print(line);
    }

    if (writeToFile) {
      try {
        final logEntry = event.lines.join('\n') + '\n';

        // Use synchronous file operations to ensure logs are written in order
        file.writeAsStringSync(logEntry, mode: FileMode.append);
      } catch (e) {
        // ignore: avoid_print
        print('Error writing to log file: $e');
      }
    }
  }
}

// Helper functions for external use
String logLevelToString(Level level) =>
    AppLogger.instance._logLevelToString(level);
Level intToLogLevel(int value) => AppLogger.instance.intToLogLevel(value);
