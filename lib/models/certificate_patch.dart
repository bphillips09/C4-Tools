import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:c4_tools/tools/http_client.dart';
import 'package:c4_tools/services/control4_updates_service.dart';
import 'jailbreak_step.dart';
import 'package:flutter/services.dart';
import 'package:xml/xml.dart';
import 'package:file_picker/file_picker.dart';
import 'package:c4_tools/services/app_logger.dart' show appLogger;

class CertificatePatch {
  final String directorIP;
  final String? directorVersion;
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
  static const int CertSchemaVersion = 1;
  static const String _updatesExperienceUrl =
      'https://services.control4.com/Updates2x-experience/v2_0/Updates.asmx';
  final Control4UpdatesService _updatesService = Control4UpdatesService();

  CertificatePatch({
    required this.directorIP,
    required this.jwtToken,
    required this.directorVersion,
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
            final schemaFile = File('${localCertDir!.path}/.schema-version');
            final storedSchemaVersion = schemaFile.existsSync()
                ? schemaFile.readAsStringSync().trim()
                : null;
            final schemaMatches =
                storedSchemaVersion == CertSchemaVersion.toString();

            bool allCertificatesExist = true;
            for (final file in certFiles) {
              final exists = File(file).existsSync();
              appLogger.d('$file exists: $exists');
              if (!exists) {
                allCertificatesExist = false;
              }
            }

            if (allCertificatesExist && schemaMatches) {
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

            if (allCertificatesExist && !schemaMatches) {
              appLogger.i(
                  'Certificate schema mismatch ($storedSchemaVersion -> $CertSchemaVersion), regenerating.');
            } else {
              appLogger.i('Certificates not found or will be regenerated');
            }
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
              '-sha256',
              '-nodes',
              '-days',
              CertificateExpireDays.toString(),
              '-newkey',
              'rsa:2048',
              '-keyout',
              '${localCertDir!.path}/private.key',
              '-extensions',
              'v3_ca',
              '-subj',
              '/C=US/ST=Utah/L=Draper/O=Control4 Corporation/CN=Control4 Corporation CA/emailAddress=pki@control4.com/',
              '-out',
              '${localCertDir!.path}/public.pem',
            ]);

            if (result.exitCode != 0) {
              throw Exception('Failed to generate keys: ${result.stderr}');
            }

            appLogger.i('Generated private + public keys successfully');
            await File('${localCertDir!.path}/.schema-version')
                .writeAsString(CertSchemaVersion.toString());
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
                XmlElement(
                  XmlName('bypasslist'),
                  [],
                  [
                    XmlElement(XmlName('add'), [
                      XmlAttribute(
                          XmlName('address'), r'services\.control4\.com')
                    ], []),
                    XmlElement(XmlName('add'), [
                      XmlAttribute(
                          XmlName('address'), r'update2\.control4\.com')
                    ], []),
                    XmlElement(XmlName('add'), [
                      XmlAttribute(
                          XmlName('address'), r'c4updates\.control4\.com')
                    ], []),
                  ],
                ),
              ],
            );

            final existingDefaultProxy =
                systemNet.findElements('defaultProxy').firstOrNull;
            existingDefaultProxy?.replace(defaultProxyElement);
            if (existingDefaultProxy == null) {
              systemNet.children.add(defaultProxyElement);
            }

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
        title: 'Write Feature Flags',
        description: 'Creating offline feature flag cache for Composer',
        execute: () async {
          try {
            await _writeFeatureFlagsConfig();
            return true;
          } catch (e) {
            appLogger.e('Failed to write feature flags', error: e);
            return false;
          }
        },
      ),
      JailbreakSubStep(
        title: 'Update Manager URL',
        description: 'Setting default Update Manager experience endpoint',
        execute: () async {
          try {
            await _updateUpdateManagerSettings();
            return true;
          } catch (e) {
            appLogger.e('Failed to update Update Manager URL', error: e);
            return false;
          }
        },
      ),
      JailbreakSubStep(
        title: 'Install Management Pack',
        description: 'Detecting and installing matching Drivers package',
        execute: () async {
          try {
            if (!Platform.isWindows) {
              appLogger
                  .i('Skipping management pack installation: Windows only');
              return true;
            }
            return await _installManagementPackWithRetries();
          } catch (e) {
            appLogger.e('Failed to install management pack', error: e);
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
              '2048',
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

            await File('${localCertDir!.path}/ext.conf').writeAsString(
              '[v3_client]\n'
              'subjectAltName=DNS:$CertificateCN\n'
              'extendedKeyUsage=clientAuth,serverAuth\n'
              'basicConstraints=CA:FALSE\n'
              'keyUsage=digitalSignature,keyEncipherment\n',
            );

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
              '1095',
              '-sha256',
              '-extfile',
              '${localCertDir!.path}/ext.conf',
              '-extensions',
              'v3_client',
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
                                    <Username>no</Username>
                                    <Employee>False</Employee>
                                    <Password>+bJjU5zcsEI=</Password>
                                    <UserHash>9390298f3fb0c5b160498935d79cb139aef28e1c47358b4bbba61862b9c26e59</UserHash>
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

  Future<void> _writeFeatureFlagsConfig() async {
    final appData = Platform.environment['APPDATA'] ??
        'C:\\Users\\${Platform.environment['USERNAME']}\\AppData\\Roaming';
    final composerDir = Directory('$appData\\Control4\\Composer');
    await composerDir.create(recursive: true);

    final featureFlags = <String, Map<String, dynamic>>{
      'composer-x4-updatemanger-restrict-override': {
        'Result': true,
        'Config': null,
      },
      'connection-whitelist': {
        'Result': false,
        'Config': '[]',
      },
      'os-pack-on-connect': {
        'Result': true,
        'Config': null,
      },
    };

    final featurePath = '${composerDir.path}\\FeaturesConfiguration.json';
    await File(featurePath).writeAsString(jsonEncode(featureFlags));
    appLogger.i('Wrote Composer feature flags at: $featurePath');
  }

  Future<void> _updateUpdateManagerSettings() async {
    final appData = Platform.environment['APPDATA'] ??
        'C:\\Users\\${Platform.environment['USERNAME']}\\AppData\\Roaming';
    final composerDir = Directory('$appData\\Control4\\Composer');
    await composerDir.create(recursive: true);
    final settingsPath =
        '${composerDir.path}\\ComposerUpdateManagerSettings.Config';

    final settingsXml = XmlDocument([
      XmlProcessing('xml', 'version="1.0" encoding="utf-8"'),
      XmlElement(
        XmlName('settings'),
        [],
        [
          XmlElement(
            XmlName('UpdateURLList30'),
            [XmlAttribute(XmlName('type'), 'System.Collections.ArrayList')],
            [
              XmlElement(
                XmlName('ArrayOfAnyType'),
                [
                  XmlAttribute(XmlName('xsi', 'xmlns'),
                      'http://www.w3.org/2001/XMLSchema-instance'),
                  XmlAttribute(XmlName('xsd', 'xmlns'),
                      'http://www.w3.org/2001/XMLSchema'),
                ],
                [
                  XmlElement(
                    XmlName('anyType'),
                    [XmlAttribute(XmlName('type', 'xsi'), 'xsd:string')],
                    [XmlText(_updatesExperienceUrl)],
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    ]);

    await File(settingsPath)
        .writeAsString(settingsXml.toXmlString(pretty: true));
    appLogger.i('Wrote Update Manager settings at: $settingsPath');
  }

  Future<bool> _installManagementPackWithRetries() async {
    final version = directorVersion?.trim();
    if (version == null || version.isEmpty) {
      appLogger
          .w('Skipping management pack install: Director version unavailable');
      return true;
    }

    const maxAttempts = 3;
    Object? lastError;

    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        appLogger.i(
            'Installing management pack for Director $version (attempt $attempt/$maxAttempts)');

        final installed = await _getInstalledManagementPackVersions();
        if (_isPackInstalled(version, installed)) {
          appLogger.i('Management pack already installed for $version');
          return true;
        }

        final package = await _resolveDriversPackageInfo(version);
        if (package == null) {
          throw Exception('Could not resolve Drivers package for $version');
        }

        final appSupportDir = await getApplicationSupportDirectory();
        final downloadDir = Directory('${appSupportDir.path}/Downloads');
        if (!downloadDir.existsSync()) {
          await downloadDir.create(recursive: true);
        }

        final installerPath = '${downloadDir.path}\\${package.name}';
        await _downloadFileWithRetry(
          url: package.url,
          destinationPath: installerPath,
          attempts: 3,
        );

        if (package.checksum.isNotEmpty) {
          final actualMd5 = await _computeMd5(installerPath);
          final expected = package.checksum.toLowerCase();
          if (actualMd5 != expected) {
            throw Exception(
                'Management pack checksum mismatch (expected $expected, got $actualMd5)');
          }
          appLogger.i('Management pack checksum verified');
        }

        final installOk = await _runInstallerWithFallback(installerPath);
        if (!installOk) {
          throw Exception('Management pack installer did not complete');
        }

        final installedAfter = await _getInstalledManagementPackVersions();
        if (!_isPackInstalled(version, installedAfter)) {
          throw Exception(
              'Installer completed but package is still not detected as installed');
        }

        appLogger.i('Management pack installation successful for $version');
        return true;
      } catch (e) {
        lastError = e;
        appLogger.w('Management pack attempt $attempt failed: $e');
        if (attempt < maxAttempts) {
          await Future.delayed(Duration(seconds: 2 * attempt));
        }
      }
    }

    appLogger.e('Management pack installation failed after retries',
        error: lastError);
    return false;
  }

  Future<void> _downloadFileWithRetry({
    required String url,
    required String destinationPath,
    int attempts = 3,
  }) async {
    Object? lastError;
    for (var i = 1; i <= attempts; i++) {
      try {
        final client = httpIOClient();
        final response = await client.get(Uri.parse(url));
        if (response.statusCode != 200) {
          throw Exception(
              'Download failed (status ${response.statusCode}) from $url');
        }
        await File(destinationPath).writeAsBytes(response.bodyBytes);
        return;
      } catch (e) {
        lastError = e;
        if (i < attempts) {
          await Future.delayed(Duration(seconds: i));
        }
      }
    }
    throw Exception('Download failed after retries: $lastError');
  }

  Future<bool> _runInstallerWithFallback(String installerPath) async {
    final argumentSets = <List<String>>[
      ['/S'],
      ['/s'],
      ['/quiet', '/norestart'],
      ['/verysilent', '/norestart'],
      const [],
    ];

    for (final args in argumentSets) {
      try {
        appLogger.i(
            'Running management pack installer with args: ${args.join(' ')}');
        final result = await Process.run(installerPath, args, runInShell: true);
        appLogger.d('Installer exit code: ${result.exitCode}');
        if (result.exitCode == 0) {
          return true;
        }
      } catch (e) {
        appLogger.w('Installer run failed with args $args: $e');
      }
    }

    return false;
  }

  Future<String> _computeMd5(String filePath) async {
    final bytes = await File(filePath).readAsBytes();
    return md5.convert(bytes).toString().toLowerCase();
  }

  Future<_DriversPackageInfo?> _resolveDriversPackageInfo(
      String directorVersion) async {
    final candidates = _buildPackageVersionCandidates(directorVersion);

    for (final candidate in candidates) {
      try {
        final packages = await _updatesService.getPackagesByVersion(
          endpoint: _updatesExperienceUrl,
          version: candidate,
        );
        for (final pkg in packages) {
          final name = pkg.name;
          if (!name.toLowerCase().startsWith('drivers-')) {
            continue;
          }
          final url = pkg.url.replaceFirst('http://', 'https://');
          final checksum = pkg.checksum;
          if (name.isEmpty || url.isEmpty) {
            continue;
          }
          appLogger
              .i('Resolved management pack $name using version $candidate');
          return _DriversPackageInfo(
            name: name,
            url: url,
            checksum: checksum,
          );
        }
      } catch (e) {
        appLogger.w('SOAP package lookup failed for $candidate: $e');
      }
    }

    return null;
  }

  List<String> _buildPackageVersionCandidates(String directorVersion) {
    final raw = directorVersion.trim();
    final base = raw.split('+').first;
    final noSuffix = base.split('-').first;
    final parts = noSuffix.split('.');
    final shortVersion =
        parts.length >= 3 ? '${parts[0]}.${parts[1]}.${parts[2]}' : noSuffix;

    final candidates = <String>[
      if (raw.contains('+Composer')) raw,
      if (!raw.contains('+Composer') && raw.endsWith('-res')) '$raw+Composer',
      if (!raw.contains('+Composer')) '$raw-res+Composer',
      if (!raw.contains('+Composer')) '$raw+Composer',
      '$base+Composer',
      '$base-res+Composer',
      '$noSuffix+Composer',
      '$noSuffix-res+Composer',
      '$shortVersion+Composer',
      '$shortVersion-res+Composer',
    ];

    final unique = <String>{};
    return candidates.where((c) => unique.add(c)).toList();
  }

  Future<Set<String>> _getInstalledManagementPackVersions() async {
    final installed = <String>{};
    final queryPaths = <String>[
      r'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
      r'HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
    ];

    for (final path in queryPaths) {
      try {
        final result = await Process.run(
          'reg',
          ['query', path, '/s', '/v', 'DisplayName'],
          runInShell: true,
        );

        if (result.exitCode != 0) {
          continue;
        }

        final lines = result.stdout.toString().split('\n');
        for (final rawLine in lines) {
          final line = rawLine.trim();
          if (!line.contains('REG_SZ')) {
            continue;
          }
          final displayName = line.split(RegExp(r'\s+REG_SZ\s+')).last.trim();

          if (displayName.toLowerCase().startsWith('drivers-')) {
            var ver = displayName.substring(8);
            final dashIdx = ver.indexOf('-');
            if (dashIdx > 0) {
              ver = ver.substring(0, dashIdx);
            }
            if (ver.isNotEmpty) {
              installed.add(ver);
            }
          } else if (displayName
              .toLowerCase()
              .startsWith('composer os management package ')) {
            final ver = displayName
                .substring('Composer OS Management Package '.length)
                .trim();
            if (ver.isNotEmpty) {
              installed.add(ver);
            }
          }
        }
      } catch (e) {
        appLogger.w('Management pack registry query failed for $path: $e');
      }
    }

    return installed;
  }

  bool _isPackInstalled(String soapVersion, Set<String> installedVersions) {
    final normalized = soapVersion.split('-').first;
    if (installedVersions.contains(soapVersion) ||
        installedVersions.contains(normalized)) {
      return true;
    }
    for (final iv in installedVersions) {
      if (normalized == iv || normalized.startsWith('$iv.')) {
        return true;
      }
    }
    return false;
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

class _DriversPackageInfo {
  final String name;
  final String url;
  final String checksum;

  const _DriversPackageInfo({
    required this.name,
    required this.url,
    required this.checksum,
  });
}
