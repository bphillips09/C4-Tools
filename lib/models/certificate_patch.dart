import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:async';
import 'dart:io';
import 'jailbreak_step.dart';
import 'package:flutter/services.dart';
import 'package:xml/xml.dart';
import 'package:file_picker/file_picker.dart';
import 'package:c4_tools/services/app_logger.dart' show appLogger;

class CertificatePatch {
  final String directorIP;
  final String? jwtToken;
  final Function(int, StepStatus, [String?]) updateStepStatus;
  Directory? localCertDir;
  BuildContext? _context;
  String? _opensslPath;
  String? _composerPath;
  bool? skipCertGeneration;
  static const String ComposerCertName = 'cacert-c4tools.pem';
  static const String CertificateCN = 'Composer_C4Tools';
  static const String CertPassword = 'R8lvpqtgYiAeyO8j8Pyd';
  static const int CertificateExpireDays = 3650;

  CertificatePatch({
    required this.directorIP,
    required this.jwtToken,
    required this.updateStepStatus,
  });

  set context(BuildContext? value) {
    _context = value;
  }

  BuildContext? get context => _context;

  List<JailbreakStep> createSteps() {
    appLogger.i('\n=== Creating Certificate Steps ===');

    final steps = <JailbreakStep>[];

    final generateCertificatesSubSteps = [
      JailbreakSubStep(
          title: 'Checking Directory',
          description: 'Checking if directory for certificates exists',
          execute: () async {
            await _createCertDirectory();
            return true;
          }),
      JailbreakSubStep(
        title: 'Check Existing Certificates',
        description: 'Verifying if certificates already exist',
        execute: () async {
          try {
            appLogger.i('\nChecking for existing certificates...');
            final certFiles = [
              '${localCertDir!.path}/${ComposerCertName}',
              '${localCertDir!.path}/composer.p12',
              '${localCertDir!.path}/private.key',
              '${localCertDir!.path}/public.pem'
            ];

            bool allCertificatesExist = true;
            for (final file in certFiles) {
              final exists = File(file).existsSync();
              appLogger.d('$file exists: $exists');
              if (!exists) {
                allCertificatesExist = false;
              }
            }

            if (allCertificatesExist) {
              appLogger.i('Certificates already exist');

              // Prompt user to use existing certificates or recreate them
              if (_context != null) {
                skipCertGeneration = await showDialog<bool>(
                  context: _context!,
                  barrierDismissible: false,
                  builder: (BuildContext context) {
                    return AlertDialog(
                      title: const Text('Certificates Already Exist'),
                      content: const Text(
                        'Certificates already exist in the application directory. Would you like to use the existing certificates or generate new ones?',
                      ),
                      actions: <Widget>[
                        TextButton(
                          child: const Text('Generate New'),
                          onPressed: () => Navigator.of(context).pop(false),
                        ),
                        TextButton(
                          child: const Text('Use Existing'),
                          onPressed: () => Navigator.of(context).pop(true),
                        ),
                      ],
                    );
                  },
                );

                if (skipCertGeneration == true) {
                  appLogger.i('Using existing certificates');
                  return true;
                } else {
                  appLogger.i('User chose to regenerate certificates');
                  for (final file in certFiles) {
                    try {
                      if (File(file).existsSync()) {
                        await File(file).delete();
                        appLogger.d('Deleted $file');
                      }
                    } catch (e) {
                      appLogger.w('Failed to delete $file: $e');
                    }
                  }
                }
              } else {
                appLogger.i(
                    'Using existing certificates (no context to prompt user)');
                skipCertGeneration = true;
                return true;
              }
            }

            appLogger.i('Certificates not found or will be regenerated');
            return true;
          } catch (e) {
            appLogger.e('Failed to check existing certificates', error: e);
            return false;
          }
        },
      ),
      JailbreakSubStep(
        title: 'Verify OpenSSL',
        description: 'Checking OpenSSL installation',
        execute: () async {
          try {
            appLogger.i('\nVerifying OpenSSL installation...');
            final composerPath = await _findComposerPro();
            if (composerPath == null) {
              throw Exception('Could not find Composer Pro installation');
            }

            _composerPath = composerPath;

            final opensslPath = '$composerPath\\RemoteAccess\\bin\\openssl.exe';
            if (!File(opensslPath).existsSync()) {
              throw Exception('Could not find OpenSSL at $opensslPath');
            }

            final configPath = '${localCertDir!.path}/openssl.cfg';
            if (!File(configPath).existsSync()) {
              throw Exception('Could not find OpenSSL config at $configPath');
            }

            _opensslPath = opensslPath;
            appLogger.i('OpenSSL verification successful');
            return true;
          } catch (e) {
            appLogger.e('Failed to verify OpenSSL', error: e);
            return false;
          }
        },
      ),
      JailbreakSubStep(
        title: 'Generate Keys',
        description: 'Creating private and public keys',
        execute: () async {
          if (skipCertGeneration == true) {
            appLogger.i('Skipping key generation');
            return true;
          }

          try {
            appLogger.i('\nGenerating private + public keys...');
            final result = await _runOpenSSL([
              'req',
              '-new',
              '-x509',
              '-sha1',
              '-nodes',
              '-days',
              CertificateExpireDays.toString(),
              '-newkey',
              'rsa:1024',
              '-keyout',
              '${localCertDir!.path}/private.key',
              '-subj',
              '/C=US/ST=Utah/L=Draper/O=Control4 Corporation/CN=Control4 Corporation CA/emailAddress=pki@control4.com/',
              '-out',
              '${localCertDir!.path}/public.pem',
            ]);

            if (result.exitCode != 0) {
              throw Exception('Failed to generate keys: ${result.stderr}');
            }

            appLogger.i('Generated private + public keys successfully');
            return true;
          } catch (e) {
            appLogger.e('Failed to generate keys', error: e);
            return false;
          }
        },
      ),
      JailbreakSubStep(
        title: 'Create Composer Certificate',
        description: 'Generating Composer Certificate',
        execute: () async {
          if (skipCertGeneration == true) {
            appLogger.i('Skipping certificate creation');
            return true;
          }

          try {
            appLogger.i('\nExecuting Create Composer Certificate');
            final result = await _runOpenSSL(
                ['x509', '-in', '${localCertDir!.path}/public.pem', '-text']);

            if (result.exitCode != 0) {
              appLogger
                  .e('Failed to create composer certificate: ${result.stderr}');
              appLogger.e('OpenSSL stdout: ${result.stdout}');
              throw Exception(
                  'Failed to create composer certificate: ${result.stderr}');
            }

            await File('${localCertDir!.path}/${ComposerCertName}')
                .writeAsString(result.stdout);
            appLogger.i('Created ${ComposerCertName} successfully');
            return true;
          } catch (e) {
            appLogger.e('Failed to create composer certificate', error: e);
            return false;
          }
        },
      ),
    ];

    final generateCertificatesStep = ComposerStep(
      title: 'Generate Certificates',
      subSteps: generateCertificatesSubSteps,
      updateStepStatus: updateStepStatus,
    );

    steps.add(generateCertificatesStep);

    final patchComposerProSubSteps = [
      JailbreakSubStep(
        title: 'Check Administrator',
        description: 'Verifying administrator privileges',
        execute: () async {
          try {
            appLogger.i('\nExecuting Check Administrator');

            // Try to write to Program Files to check admin rights
            final testFile = File('C:\\Program Files (x86)\\test.tmp');
            try {
              await testFile.writeAsString('test');
              await testFile.delete();
              appLogger.i('Running with administrator privileges');
              return true;
            } catch (e) {
              appLogger.w('Not running with administrator privileges');
              if (_context != null) {
                await showDialog<void>(
                  context: _context!,
                  barrierDismissible: false,
                  builder: (BuildContext context) {
                    return AlertDialog(
                      title: const Text('Administrator Privileges Required'),
                      content: const Text(
                        'This step requires administrator privileges to modify Composer Pro configuration. Please run the application as administrator and try again.',
                      ),
                      actions: <Widget>[
                        TextButton(
                          child: const Text('OK'),
                          onPressed: () => Navigator.of(context).pop(),
                        ),
                      ],
                    );
                  },
                );
              }
              return false;
            }
          } catch (e) {
            appLogger.e('Failed to check administrator privileges', error: e);
            return false;
          }
        },
      ),
      JailbreakSubStep(
        title: 'Backup Config',
        description: 'Creating backup of Composer Pro config',
        execute: () async {
          try {
            appLogger.i('\nExecuting Backup Config');
            final configPath = '$_composerPath\\ComposerPro.exe.config';

            if (!File(configPath).existsSync()) {
              throw Exception('Could not find ComposerPro.exe.config');
            }

            appLogger.i('Creating config backup...');
            final backupPath =
                '$configPath.backup-${DateTime.now().toString().replaceAll(':', '-')}';
            await File(configPath).copy(backupPath);
            appLogger.i('Backup created at: $backupPath');
            return true;
          } catch (e) {
            appLogger.e('Failed to backup config', error: e);
            appLogger.e('ails: ${e.toString()}');
            return false;
          }
        },
      ),
      JailbreakSubStep(
        title: 'Modify Config',
        description: 'Updating Composer Pro configuration',
        execute: () async {
          try {
            appLogger.i('\nExecuting Modify Config');
            final configPath = '$_composerPath\\ComposerPro.exe.config';

            appLogger.i('Reading config file...');
            final config = await File(configPath).readAsString();

            final document = XmlDocument.parse(config);
            final systemNet =
                document.findAllElements('system.net').firstOrNull;

            if (systemNet == null) {
              throw Exception(
                  'Could not find system.net section in config file');
            }

            // Check if already patched
            final defaultProxy =
                systemNet.findElements('defaultProxy').firstOrNull;
            if (defaultProxy != null) {
              final proxy = defaultProxy.findElements('proxy').firstOrNull;
              if (proxy != null &&
                  proxy.getAttribute('proxyaddress') ==
                      'http://127.0.0.1:31337/') {
                appLogger.i(
                    'Config file is already patched - continuing with next steps');
                return true;
              }
            }

            // Create the new defaultProxy element
            final defaultProxyElement = XmlElement(
              XmlName('defaultProxy'),
              [],
              [
                XmlElement(
                  XmlName('proxy'),
                  [
                    XmlAttribute(XmlName('usesystemdefault'), 'false'),
                    XmlAttribute(
                        XmlName('proxyaddress'), 'http://127.0.0.1:31337/'),
                    XmlAttribute(XmlName('bypassonlocal'), 'True'),
                  ],
                  [],
                ),
              ],
            );

            // Add the defaultProxy element to system.net
            systemNet.children.add(defaultProxyElement);

            appLogger.i('Writing modified config...');
            await File(configPath)
                .writeAsString(document.toXmlString(pretty: true));
            appLogger.i('Config file modified successfully');
            return true;
          } catch (e) {
            appLogger.e('Failed to modify config', error: e);
            return false;
          }
        },
      ),
      JailbreakSubStep(
        title: 'Generate Composer Key',
        description: 'Creating composer key for certificate',
        execute: () async {
          if (skipCertGeneration == true) {
            appLogger.i('Skipping key generation');
            return true;
          }

          try {
            appLogger.i('\n=== Creating Composer Key ===');

            appLogger.i('Generating Composer key...');
            final result = await _runOpenSSL([
              'genrsa',
              '-out',
              '${localCertDir!.path}/composer.key',
              '1024',
            ]);

            if (result.exitCode != 0) {
              throw Exception(
                  'Failed to generate Composer key: ${result.stderr}');
            }

            appLogger.i('Generated Composer key successfully');
            return true;
          } catch (e) {
            appLogger.e('Failed to create Composer key', error: e);
            return false;
          }
        },
      ),
      JailbreakSubStep(
        title: 'Generate Signing Request',
        description: 'Creating signing request',
        execute: () async {
          if (skipCertGeneration == true) {
            appLogger.i('Skipping signing request generation');
            return true;
          }

          try {
            appLogger.i('\nExecuting Generate Signing Request');

            final result = await _runOpenSSL([
              'req',
              '-new',
              '-nodes',
              '-key',
              '${localCertDir!.path}/composer.key',
              '-subj',
              '/C=US/ST=Utah/L=Draper/CN=${CertificateCN}/',
              '-out',
              '${localCertDir!.path}/composer.csr',
            ]);

            if (result.exitCode != 0) {
              throw Exception(
                  'Failed to generate signing request: ${result.stderr}');
            }

            appLogger.i('Generated signing request successfully');
            return true;
          } catch (e) {
            appLogger.e('Failed to generate signing request', error: e);
            return false;
          }
        },
      ),
      JailbreakSubStep(
        title: 'Sign Request',
        description: 'Signing request',
        execute: () async {
          if (skipCertGeneration == true) {
            appLogger.i('Skipping signing request');
            return true;
          }

          try {
            appLogger.i('\nExecuting Sign Request');

            Directory.current = localCertDir!.path;

            appLogger.i('Running OpenSSL CA command...');
            final result = await _runOpenSSL([
              'x509',
              '-req',
              '-in',
              '${localCertDir!.path}/composer.csr',
              '-CA',
              '${localCertDir!.path}/public.pem',
              '-CAkey',
              '${localCertDir!.path}/private.key',
              '-CAcreateserial',
              '-out',
              '${localCertDir!.path}/composer.pem',
              '-days',
              '365',
              '-sha256'
            ]);

            if (result.exitCode != 0) {
              appLogger.e('OpenSSL error output: ${result.stderr}');
              appLogger.e('OpenSSL stdout: ${result.stdout}');
              throw Exception(
                  'Failed to sign certificate request: ${result.stderr}');
            }

            appLogger.i('Signed certificate request successfully');
            return true;
          } catch (e) {
            appLogger.e('Failed to sign certificate request', error: e);
            return false;
          }
        },
      ),
      JailbreakSubStep(
        title: 'Create Composer P12',
        description: 'Generating composer.p12 file',
        execute: () async {
          if (skipCertGeneration == true) {
            appLogger.i('Skipping p12 creation');
            return true;
          }

          try {
            appLogger.i('\nExecuting Create Composer P12');
            final result = await _runOpenSSL([
              'pkcs12',
              '-export',
              '-out',
              '${localCertDir!.path}/composer.p12',
              '-inkey',
              '${localCertDir!.path}/composer.key',
              '-in',
              '${localCertDir!.path}/composer.pem',
              '-passout',
              'pass:${CertPassword}'
            ]);

            if (result.exitCode != 0) {
              appLogger.e('Failed to create composer.p12: ${result.stderr}');
              appLogger.e('OpenSSL stdout: ${result.stdout}');
              throw Exception(
                  'Failed to create composer.p12: ${result.stderr}');
            }

            appLogger.i('Created composer.p12 successfully');
            return true;
          } catch (e) {
            appLogger.e('Failed to create composer.p12', error: e);
            return false;
          }
        },
      ),
      JailbreakSubStep(
        title: 'Copy Certificates',
        description: 'Installing certificates in Composer directory',
        execute: () async {
          try {
            appLogger.i('\nExecuting Copy Certificates');
            final appData = Platform.environment['APPDATA'] ??
                'C:\\Users\\${Platform.environment['USERNAME']}\\AppData\\Roaming';
            final composerDir = '$appData\\Control4\\Composer';

            appLogger.i('Creating Composer directory if it doesn\'t exist...');
            await Directory(composerDir).create(recursive: true);

            appLogger.i('Copying certificates...');
            await _copyFile('${localCertDir!.path}/${ComposerCertName}',
                '$composerDir\\${ComposerCertName}');
            await _copyFile('${localCertDir!.path}/composer.p12',
                '$composerDir\\composer.p12');

            appLogger.i('Composer certificates updated successfully');
            return true;
          } catch (e) {
            appLogger.e('Failed to copy certificates', error: e);
            return false;
          }
        },
      ),
      JailbreakSubStep(
        title: 'Check Dealer Account',
        description: 'Checking and updating dealer account settings',
        execute: () async {
          try {
            appLogger.i('\nChecking dealer account settings...');
            final appData = Platform.environment['APPDATA'] ??
                'C:\\Users\\${Platform.environment['USERNAME']}\\AppData\\Roaming';
            final dealerAccountPath = '$appData\\Control4\\dealeraccount.xml';

            final dealerAccountFile = File(dealerAccountPath);
            final dealerAccountDir = Directory('$appData\\Control4');

            if (!dealerAccountDir.existsSync()) {
              appLogger.i('Creating Control4 directory...');
              await dealerAccountDir.create(recursive: true);
            }

            // Create or update the dealer account file with default data
            appLogger.i('Creating/updating dealeraccount.xml...');

            const xmlContent = '''<?xml version="1.0" encoding="utf-8"?>
                                  <DealerAccount>
                                    <Username>control4</Username>
                                    <Employee>False</Employee>
                                    <Password>5lX1rOoPaoo1nuxE+NiuRQ==</Password>
                                    <UserHash>62b4f821ef6cb5d3dc1b3d954c7e8423ee85d5e8ad45beb026c5e20944625313</UserHash>
                                  </DealerAccount>''';

            await dealerAccountFile.writeAsString(xmlContent);
            appLogger.i('Successfully created/updated dealeraccount.xml');

            return true;
          } catch (e) {
            appLogger.e('Failed to check/update dealer account', error: e);
            // Not critical, so return true anyway
            return true;
          }
        },
      ),
    ];

    final patchComposerProStep = ComposerStep(
      title: 'Patch Composer Pro',
      subSteps: patchComposerProSubSteps,
      updateStepStatus: updateStepStatus,
    );

    steps.add(patchComposerProStep);

    return steps;
  }

  Future<ProcessResult> _runOpenSSL(List<String> args) async {
    final result = await Process.run(_opensslPath!, args,
        environment: {'OPENSSL_CONF': '${localCertDir!.path}/openssl.cfg'});
    return result;
  }

  Future<void> _createCertDirectory() async {
    try {
      appLogger.i('Attempting to create certificate directory...');
      final appSupportDir = await getApplicationSupportDirectory();
      localCertDir = Directory('${appSupportDir.path}/Certs');
      if (!localCertDir!.existsSync()) {
        appLogger.i('Creating Certs directory at: ${localCertDir!.path}');
        localCertDir!.createSync();
      }

      final configContent =
          await rootBundle.loadString('assets/ssl/openssl.cfg');
      final configFile = File('${localCertDir!.path}/openssl.cfg');
      if (!configFile.existsSync()) {
        await configFile.writeAsString(configContent);
      }
    } catch (e) {
      appLogger.e('Failed to create cert directory',
          error: e, stackTrace: StackTrace.current);
      rethrow;
    }
  }

  Future<void> _copyFile(String source, String destination) async {
    appLogger.d('Copying $source to $destination');
    await File(source).copy(destination);
  }

  Future<String?> _findComposerPro() async {
    appLogger.i('\n=== Searching for Composer Pro ===');

    // Check common installation paths
    final programFiles =
        Platform.environment['ProgramFiles(x86)'] ?? 'C:\\Program Files (x86)';
    final commonPaths = [
      '$programFiles\\Control4\\Composer\\Pro',
      'C:\\Program Files\\Control4\\Composer\\Pro',
      'D:\\Program Files (x86)\\Control4\\Composer\\Pro',
      'D:\\Program Files\\Control4\\Composer\\Pro',
    ];

    for (final path in commonPaths) {
      appLogger.d('Checking path: $path');
      try {
        if (Directory(path).existsSync()) {
          appLogger.i('Found Composer Pro at: $path');
          return path;
        }
      } catch (e) {
        appLogger.w('Error checking path $path: $e');
      }
    }

    appLogger.w('Could not find Composer Pro installation');

    final String? pickedPath = await showDialog<String>(
      context: _context!,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Composer Pro Not Found'),
          content: const Text(
            'Could not find Composer Pro installation. Please select the Composer Pro installation directory.',
          ),
          actions: <Widget>[
            TextButton(
              child: const Text('Cancel'),
              onPressed: () => Navigator.of(context).pop(null),
            ),
            TextButton(
              onPressed: () async {
                try {
                  final String? directoryPath = await FilePicker.platform
                      .getDirectoryPath(
                          dialogTitle: 'Select Composer Pro Directory');
                  Navigator.of(context).pop(directoryPath);
                } catch (e) {
                  appLogger.e('Error opening directory picker', error: e);
                  Navigator.of(context).pop(null);
                }
              },
              child: const Text('Select Directory'),
            ),
          ],
        );
      },
    );

    if (pickedPath == null) {
      throw Exception('Composer Pro installation directory not specified');
    }

    return pickedPath;
  }
}
