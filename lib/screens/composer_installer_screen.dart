import 'dart:io';
import 'package:archive/archive.dart';
import 'package:c4_tools/main.dart';
import 'package:c4_tools/services/app_logger.dart' show appLogger;
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as path;

class ComposerInstallerScreen extends StatefulWidget {
  const ComposerInstallerScreen({Key? key}) : super(key: key);

  @override
  State<ComposerInstallerScreen> createState() =>
      _ComposerInstallerScreenState();
}

class _ComposerInstallerScreenState extends State<ComposerInstallerScreen> {
  bool _isInstalling = false;
  String _status = '';
  double _progress = 0.0;
  final TextEditingController _urlController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _urlController.text =
        'https://d.apkpure.com/b/APK/com.control4.composerexpressent?versionCode=154486';
    _checkIfInstalled().then((installed) {
      if (installed) {
        // If already installed, close this screen
        if (mounted) {
          Navigator.of(context).pop();
        }
      }
    });
  }

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  Future<String> get _composerExpressPath async {
    final appDir = await getApplicationSupportDirectory();
    return path.join(appDir.path, 'ComposerExpress');
  }

  Future<bool> _checkIfInstalled() async {
    final composerPath = await _composerExpressPath;
    final indexPath = path.join(composerPath, 'assets', 'www', 'index.html');
    return File(indexPath).existsSync();
  }

  Future<void> _installComposer() async {
    setState(() {
      _isInstalling = true;
      _status = 'Downloading Composer Express...';
      _progress = 0.0;
    });

    appLogger.i('Installing Composer Express...');

    try {
      final apkUrl = _urlController.text;
      final response =
          await http.Client().send(http.Request('GET', Uri.parse(apkUrl)));

      if (response.statusCode != 200) {
        throw Exception('Failed to download APK: ${response.statusCode}');
      }

      final contentLength = response.contentLength ?? 0;
      int received = 0;

      final composerPath = await _composerExpressPath;
      final tempDir = Directory(composerPath);
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
      await tempDir.create(recursive: true);

      final apkFile = File(path.join(composerPath, 'composer_express.apk'));
      final sink = apkFile.openWrite();

      await for (var chunk in response.stream) {
        sink.add(chunk);
        received += chunk.length;
        if (contentLength > 0) {
          setState(() {
            _progress = received / contentLength;
          });
        }
      }
      await sink.close();

      setState(() {
        _status = 'Extracting APK...';
      });

      // Read the APK
      final bytes = await apkFile.readAsBytes();
      final archive = ZipDecoder().decodeBytes(bytes);

      // Extract the archive
      for (final file in archive) {
        final filename = file.name;
        if (file.isFile) {
          final data = file.content as List<int>;
          final extractedFile = File(path.join(composerPath, filename));
          await extractedFile.create(recursive: true);
          await extractedFile.writeAsBytes(data);
        }
      }

      // Rename cordova.js to cordova.js.old to prevent it from being used
      final cordovaPath =
          path.join(composerPath, 'assets', 'www', 'cordova.js');
      final cordovaFile = File(cordovaPath);
      if (await cordovaFile.exists()) {
        await cordovaFile.rename('${cordovaPath}.old');
      }

      // Clean up the files
      await apkFile.delete();

      setState(() {
        _isInstalling = false;
        _status = 'Installation complete!';
        _progress = 1.0;
      });
      Navigator.of(context).pop();
    } catch (e) {
      appLogger.e('Error: $e');
      MainApp.showSnackBar('Error: $e', isError: true);
      setState(() {
        _isInstalling = false;
        _status = 'Error: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        centerTitle: true,
        title: const Text('Composer Express Installer'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () {
            // Pop all screens until we reach home screen
            Navigator.of(context).popUntil((route) => route.isFirst);
          },
        ),
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (_isInstalling)
                Column(
                  children: [
                    Text(_status),
                    const SizedBox(height: 20),
                    LinearProgressIndicator(value: _progress),
                  ],
                )
              else
                Column(
                  children: [
                    const Text(
                      'Composer Express needs to be installed before use.',
                      style: TextStyle(fontSize: 18),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 20),
                    TextField(
                      controller: _urlController,
                      decoration: const InputDecoration(
                        labelText: 'Composer Express APK URL',
                        border: OutlineInputBorder(),
                        hintText: 'Enter the URL to download Composer Express',
                      ),
                    ),
                    const SizedBox(height: 20),
                    ElevatedButton(
                      onPressed: _installComposer,
                      child: const Text('Install Composer Express'),
                    ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}
