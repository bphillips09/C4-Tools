import 'package:c4_tools/models/certificate_patch.dart' show CertificatePatch;
import 'package:http/http.dart' as http;
import 'package:dartssh2/dartssh2.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'jailbreak_step.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:io';
import 'package:c4_tools/services/app_logger.dart' show appLogger;
import 'package:c4_tools/services/app_settings.dart';

class SSHJailbreak {
  final String directorIP;
  final String? jwtToken;
  final String? directorVersion;
  final Function(int, StepStatus, [String?]) updateStepStatus;
  SSHSocket? _sshSocket;
  SSHClient? _sshClient;
  Directory? _tempCertDir;
  static const List<String> _rootSshKeyFiles = [
    'ssh_host_rsa_key',
    'ssh_host_rsa_key.pub',
    'ssh_host_ed25519_key',
    'ssh_host_ed25519_key.pub',
  ];
  static const List<String> _remoteCertChainPaths = [
    '/etc/openvpn/clientca-prod.pem',
    '/opt/control4/etc/ssl/certs/clientca-prod.pem',
    '/etc/mosquitto/certs/ca-chain.pem',
  ];

  SSHJailbreak({
    required this.directorIP,
    required this.jwtToken,
    required this.updateStepStatus,
    required this.directorVersion,
  });

  List<JailbreakStep> createSteps() {
    List<JailbreakStep> steps = [];

    final x4Steps = <JailbreakStep>[
      SSHStep(
        title: 'Get Writable Driver',
        subSteps: [
          JailbreakSubStep(
            title: 'Query Drivers',
            description: 'Searching for compatible drivers',
            execute: () async {
              final driverId = await _getWritableDriver();
              if (driverId == null) {
                // TODO: Add a tiny writable driver through the API later
                updateStepStatus(0, StepStatus.failed,
                    "Unable to find a writable driver on the system. If you need to add a driver, open Composer Express and add some common drivers.");
                return false;
              }
              return true;
            },
          ),
        ],
        updateStepStatus: updateStepStatus,
      ),
      SSHStep(
        title: 'Check System Files',
        subSteps: [
          JailbreakSubStep(
            title: 'Read SSH Configuration',
            description: 'Checking SSH configuration',
            execute: () async {
              try {
                await _readFile('/etc/ssh/sshd_config');
                return true;
              } catch (e) {
                appLogger.e('Failed to read /etc/ssh/sshd_config:', error: e);
                return false;
              }
            },
          ),
        ],
        updateStepStatus: updateStepStatus,
      ),
      SSHStep(
        title: 'Apply Patch',
        subSteps: [
          JailbreakSubStep(
            title: 'Sending Patch Commands',
            description: 'Executing Lua commands to modify system files',
            execute: () async {
              try {
                final driverId = await _getWritableDriver();
                if (driverId == null) return false;
                await _applyExploit(driverId);
                return true;
              } catch (e) {
                appLogger.e('Failed to apply jailbreak:', error: e);
                return false;
              }
            },
          ),
        ],
        updateStepStatus: updateStepStatus,
      ),
      SSHStep(
        title: 'Verify Changes',
        subSteps: [
          JailbreakSubStep(
            title: 'Check SSH Config',
            description: 'Verifying SSH configuration changes',
            execute: () async {
              try {
                final sshConfig = await _readFile('/etc/ssh/sshd_config');
                appLogger.t(sshConfig);
                return sshConfig.contains('PasswordAuthentication yes');
              } catch (e) {
                appLogger.e('Failed to verify SSH config:', error: e);
                return false;
              }
            },
          ),
        ],
        updateStepStatus: updateStepStatus,
      ),
      SSHStep(
        title: 'Restart SSH Service',
        subSteps: [
          JailbreakSubStep(
            title: 'Send Hang-Up',
            description: 'Sending Hang-Up signal to restart SSH',
            execute: () async {
              try {
                final killUrl =
                    'https://${directorIP}:443/api/v1/sysman/ssh?command=pkill%20-HUP%20sshd';
                final client = http.Client();

                final killResponse = await client.get(
                  Uri.parse(killUrl),
                  headers: {
                    'Accept': 'application/json',
                    'Content-Type': 'application/json',
                    'Authorization': 'Bearer ${jwtToken}',
                  },
                );

                appLogger.t(killResponse.body);

                if (killResponse.statusCode != 200) {
                  throw Exception(
                      'Failed to restart SSH: ${killResponse.statusCode}');
                }

                return true;
              } catch (e) {
                appLogger.e('Failed to send HUP signal:', error: e);
                throw e;
              }
            },
          ),
        ],
        updateStepStatus: updateStepStatus,
      ),
      SSHStep(
        title: 'Persist SSH Access',
        subSteps: [
          JailbreakSubStep(
            title: 'Cache Device SSH Keys',
            description: 'Saving controller SSH keys locally',
            execute: () async {
              try {
                await _ensureSSHConnection();
                await _downloadRootDeviceSshKeys();
                return true;
              } catch (e) {
                appLogger.e('Failed to cache SSH keys:', error: e);
                return false;
              }
            },
          ),
          JailbreakSubStep(
            title: 'Patch authorized_keys',
            description: 'Adding cached public keys to root authorized_keys',
            execute: () async {
              try {
                await _ensureSSHConnection();
                await _patchAuthorizedKeysFromCachedPublicKeys();
                return true;
              } catch (e) {
                appLogger.e('Failed to patch authorized_keys:', error: e);
                return false;
              }
            },
          ),
        ],
        updateStepStatus: updateStepStatus,
      ),
    ];

    if (directorVersion != null) {
      appLogger.i('Director Version: $directorVersion');
    }
    steps.addAll(x4Steps);

    steps.add(SSHStep(
      title: 'Verify SSH Access',
      subSteps: [
        JailbreakSubStep(
          title: 'Test Connection',
          description: 'Attempting SSH connection',
          execute: () async {
            try {
              await _ensureSSHConnection();
              appLogger.i('Using existing SSH connection for verification');

              final session = await _sshClient!.shell(
                pty: SSHPtyConfig(
                  width: 80,
                  height: 24,
                ),
              );

              Completer<bool> resultCompleter = Completer<bool>();
              String result = '';

              final stdoutSubscription = session.stdout.listen(
                (data) {
                  result += String.fromCharCodes(data);
                  if (result
                      .contains(AppSettings.instance.getDefaultSshUsername())) {
                    resultCompleter.complete(true);
                  }
                },
                onError: (error) {
                  appLogger.e('Error in stdout stream:', error: error);
                  resultCompleter.complete(false);
                },
              );

              session.write(Uint8List.fromList('whoami\n'.codeUnits));

              final success = await resultCompleter.future.timeout(
                const Duration(seconds: 5),
                onTimeout: () {
                  appLogger.w('SSH verification timed out');
                  return false;
                },
              );

              stdoutSubscription.cancel();
              session.close();

              if (success) {
                appLogger.i('Successfully verified SSH access');
              } else {
                appLogger.w('Failed to verify SSH access');
              }

              return success;
            } catch (e) {
              appLogger.e('SSH verification failed:', error: e);
              return false;
            }
          },
        ),
      ],
      updateStepStatus: updateStepStatus,
    ));

    // Only add certificate patching step on Windows
    if (Platform.isWindows) {
      steps.add(DirectorStep(
        title: 'Patch Director Certificate',
        subSteps: [
          JailbreakSubStep(
            title: 'Download Certificate',
            description: 'Downloading existing certificate from Director',
            execute: () async {
              try {
                appLogger.i('\n=== Downloading Director Certificate ===');
                await _downloadDirectorCertificate();
                appLogger.i('Download Certificate completed successfully');
                return true;
              } catch (e) {
                appLogger.e('Failed to download certificate:', error: e);
                return false;
              }
            },
          ),
          JailbreakSubStep(
            title: 'Create Backup',
            description: 'Creating backup of existing certificate',
            execute: () async {
              try {
                appLogger.i('\n=== Creating Certificate Backup ===');
                await _createCertificateBackup();
                appLogger.i('Create Backup completed successfully');
                return true;
              } catch (e) {
                appLogger.e('Failed to create backup:', error: e);
                return false;
              }
            },
          ),
          JailbreakSubStep(
            title: 'Append Certificate',
            description:
                'Appending our certificate to the Director\'s certificate',
            execute: () async {
              try {
                appLogger.i('\n=== Appending Certificate ===');
                await _ensureSSHConnection();

                final appSupportDir = await getApplicationSupportDirectory();
                final localCertDir = Directory('${appSupportDir.path}/Certs');

                final publicCertPath =
                    '${localCertDir.path}/${CertificatePatch.ComposerCertName}';
                final publicCert =
                    (await File(publicCertPath).readAsString()).trim();
                appLogger.t('Read local certificate from: $publicCertPath\n');

                for (final remotePath in _remoteCertChainPaths) {
                  appLogger
                      .t('Reading remote certificate with SSH: $remotePath');
                  final readSession = await _sshClient!
                      .execute('cat $remotePath 2>/dev/null || true');
                  final bytesBuilder = BytesBuilder();
                  await for (final data in readSession.stdout) {
                    bytesBuilder.add(data);
                  }
                  await readSession.done;
                  final directorCert =
                      String.fromCharCodes(bytesBuilder.takeBytes()).trim();

                  if (directorCert.isEmpty) {
                    appLogger
                        .w('Skipping missing certificate chain: $remotePath');
                    continue;
                  }

                  final uniqueRemoteCertChain =
                      await _consolidateX509CertChain(directorCert);

                  if (directorCert == uniqueRemoteCertChain &&
                      directorCert.contains(publicCert)) {
                    appLogger.i('Certificate already patched for $remotePath');
                    continue;
                  }

                  final timestamp =
                      DateTime.now().toString().replaceAll(':', '-');
                  final backupFilename =
                      '${remotePath.split('/').last}.$timestamp.backup';
                  final remoteBackupPath =
                      '${remotePath.substring(0, remotePath.lastIndexOf('/'))}/$backupFilename';

                  appLogger.t('Creating remote backup at: $remoteBackupPath');
                  final backupSession = await _sshClient!
                      .execute('cp $remotePath $remoteBackupPath');
                  await backupSession.done;

                  final localBackupPath =
                      '${localCertDir.path}/$backupFilename';
                  await File(localBackupPath).writeAsString(directorCert);

                  final combinedCert = '$uniqueRemoteCertChain\n$publicCert';
                  final cleanedCertChain =
                      await _consolidateX509CertChain(combinedCert);
                  if (cleanedCertChain.trim().isEmpty) {
                    appLogger.e(
                        'Skipping write for $remotePath: dedupe produced empty chain');
                    continue;
                  }

                  final writeSession =
                      await _sshClient!.execute('cat > $remotePath');
                  writeSession.stdin.add(utf8.encode(cleanedCertChain));
                  await writeSession.stdin.close();
                  await writeSession.done;
                  appLogger
                      .i('Certificate updated successfully for $remotePath');
                }

                return true;
              } catch (e) {
                appLogger.e('Failed to append certificate:', error: e);
                return false;
              }
            },
          ),
          JailbreakSubStep(
            title: 'Verify Changes',
            description: 'Verifying certificate changes',
            execute: () async {
              try {
                appLogger.i('\n=== Verifying Certificate ===');
                await _ensureSSHConnection();

                final appSupportDir = await getApplicationSupportDirectory();
                final localCertDir = Directory('${appSupportDir.path}/Certs');
                final publicCertPath =
                    '${localCertDir.path}/${CertificatePatch.ComposerCertName}';
                final publicCert = await File(publicCertPath).readAsString();
                appLogger.t('\nLocal Certificate Contents:');
                appLogger.t('------------------------');
                appLogger.t(publicCert);
                appLogger.t('------------------------\n');

                final normalizedPublicCert = publicCert
                    .replaceAll('\r\n', '\n')
                    .replaceAll('\r', '\n')
                    .trim();

                bool foundAnyChain = false;
                bool allPatched = true;
                for (final remotePath in _remoteCertChainPaths) {
                  final readSession = await _sshClient!
                      .execute('cat $remotePath 2>/dev/null || true');
                  final bytesBuilder = BytesBuilder();
                  await for (final data in readSession.stdout) {
                    bytesBuilder.add(data);
                  }
                  await readSession.done;

                  final directorCert =
                      String.fromCharCodes(bytesBuilder.takeBytes()).trim();
                  if (directorCert.isEmpty) {
                    continue;
                  }

                  foundAnyChain = true;
                  final normalizedDirectorCert = directorCert
                      .replaceAll('\r\n', '\n')
                      .replaceAll('\r', '\n')
                      .trim();
                  final patched =
                      normalizedDirectorCert.contains(normalizedPublicCert);
                  appLogger.i(
                      'Verification for $remotePath: ${patched ? 'patched' : 'missing cert'}');
                  if (!patched) {
                    allPatched = false;
                  }
                }
                return foundAnyChain && allPatched;
              } catch (e) {
                appLogger.e('Failed to verify certificate:', error: e);
                return false;
              }
            },
          ),
          JailbreakSubStep(
            title: 'Cleanup',
            description: 'Cleaning up temporary files',
            execute: () async {
              try {
                appLogger.i('\n=== Cleaning Up ===');
                await _cleanUp();
                appLogger.i('Cleanup completed successfully');
                return true;
              } catch (e) {
                appLogger.e('Failed to cleanup:', error: e);
                return false;
              }
            },
          ),
        ],
        updateStepStatus: updateStepStatus,
      ));
    }

    appLogger.t('Step Titles: ${steps.map((step) => step.title).join(', ')}');

    return steps;
  }

  Future<String?> _getWritableDriver() async {
    final url = 'https://${directorIP}:443/api/v1/items';
    final client = http.Client();

    final response = await client.get(
      Uri.parse(url),
      headers: {
        'Accept': 'application/json',
        'Content-Type': 'application/json',
        'Authorization': 'Bearer ${jwtToken}',
      },
    );

    if (response.statusCode != 200) {
      appLogger.e(
          'Failed to get items: Error ${response.statusCode} - ${response.body}');
      return null;
    }

    appLogger.t('Response: ${response.body}');

    final items = jsonDecode(response.body) as List;
    for (final item in items) {
      if (item['name'] == 'Data Analytics Agent' ||
          item['name'] == 'Stations') {
        return item['id'].toString();
      }
    }
    return null;
  }

  Future<String> _readFile(String path) async {
    final url =
        'https://${directorIP}:443/api/v1/sysman/ssh?command=cat%20$path';
    final client = http.Client();

    appLogger.t(url);

    final response = await client.get(
      Uri.parse(url),
      headers: {
        'Accept': 'application/json',
        'Content-Type': 'application/json',
        'Authorization': 'Bearer ${jwtToken}',
      },
    );

    if (response.statusCode != 200) {
      throw Exception('Failed to read file: ${response.statusCode}');
    }

    return response.body;
  }

  Future<void> _applyExploit(String driverId) async {
    const luaExploit = r'''
    -- Only patch sshd_config to restore SSH password auth
    local ssh_path = "/etc/ssh/sshd_config"

    -- Read & patch sshd_config
    local ssh_lines = {}
    for line in io.lines(ssh_path) do
      if line:match("^%s*PasswordAuthentication%s+no") then
        ssh_lines[#ssh_lines+1] = "PasswordAuthentication yes"
      else
        ssh_lines[#ssh_lines+1] = line
      end
    end

    -- Write back sshd_config
    local f = assert(io.open(ssh_path, "w"))
    for _, l in ipairs(ssh_lines) do
      f:write(l, "\n")
    end
    f:close()
    ''';

    final url = 'https://${directorIP}:443/api/v1/items/$driverId/commands';
    final client = http.Client();

    final body = {
      'command': 'LUA_COMMANDS',
      'async': false,
      'tParams': {
        'COMMANDS': luaExploit,
      },
    };

    final response = await client.post(
      Uri.parse(url),
      headers: {
        'Accept': 'application/json',
        'Content-Type': 'application/json',
        'Authorization': 'Bearer ${jwtToken}',
      },
      body: jsonEncode(body),
    );

    appLogger.t('POST ${url}');
    appLogger.t('Headers: ${jsonEncode({
          'Accept': 'application/json',
          'Content-Type': 'application/json',
          'Authorization': 'Bearer ${jwtToken}',
        })}');
    appLogger.t('Body: ${jsonEncode(body)}');
    appLogger.t('JWT: ${jwtToken}');

    appLogger.t('Response: ${response.body}');

    if (response.statusCode != 200) {
      throw Exception('Failed to apply jailbreak: ${response.statusCode}');
    }
  }

  Future<void> _ensureSSHConnection() async {
    try {
      // If we have an existing connection, try to verify it's still alive
      if (_sshSocket != null && _sshClient != null) {
        try {
          final session = await _sshClient!.shell(
            pty: SSHPtyConfig(
              width: 80,
              height: 24,
            ),
          );
          session.close();
          return; // Connection is still good
        } catch (e) {
          appLogger.w('Existing SSH connection failed, reconnecting...');
          await _closeSSHConnection();
        }
      }

      int retries = 3;
      while (retries > 0) {
        try {
          _sshSocket = await SSHSocket.connect(directorIP, 22);
          final identities = await _loadCachedSshIdentities();
          _sshClient = SSHClient(
            _sshSocket!,
            username: AppSettings.instance.getDefaultSshUsername(),
            identities: identities.isEmpty ? null : identities,
            onPasswordRequest: () =>
                AppSettings.instance.getDefaultSshPassword(),
          );

          final session = await _sshClient!.shell(
            pty: SSHPtyConfig(
              width: 80,
              height: 24,
            ),
          );
          session.close();
          appLogger.i('SSH connection established successfully');
          return;
        } catch (e) {
          appLogger.e('SSH connection attempt failed:', error: e);
          await _closeSSHConnection();
          retries--;
          if (retries > 0) {
            appLogger
                .t('Retrying SSH connection... ($retries attempts remaining)');
            await Future.delayed(const Duration(seconds: 2));
          }
        }
      }

      throw Exception(
          'Failed to establish SSH connection after multiple attempts');
    } catch (e) {
      appLogger.e('Error in _ensureSSHConnection:', error: e);
      await _closeSSHConnection();
      rethrow;
    }
  }

  Future<Directory> _getLocalKeysFolder() async {
    final appSupportDir = await getApplicationSupportDirectory();
    final safeId = directorIP.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
    final dir = Directory('${appSupportDir.path}/Keys/$safeId');
    if (!dir.existsSync()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  Future<List<SSHKeyPair>> _loadCachedSshIdentities() async {
    try {
      final keysDir = await _getLocalKeysFolder();
      final identities = <SSHKeyPair>[];

      for (final keyName
          in _rootSshKeyFiles.where((f) => !f.endsWith('.pub'))) {
        final file = File('${keysDir.path}/$keyName');
        if (!file.existsSync()) {
          continue;
        }

        try {
          final pem = await file.readAsString();
          identities.addAll(SSHKeyPair.fromPem(pem));
        } catch (e) {
          appLogger.w('Unable to parse cached SSH key $keyName: $e');
        }
      }

      if (identities.isNotEmpty) {
        appLogger.i('Loaded ${identities.length} cached SSH key identity(ies)');
      }
      return identities;
    } catch (e) {
      appLogger.w('Failed loading cached SSH identities: $e');
      return <SSHKeyPair>[];
    }
  }

  Future<void> _downloadRootDeviceSshKeys() async {
    final keysDir = await _getLocalKeysFolder();
    for (final keyName in _rootSshKeyFiles) {
      final remotePath = '/etc/ssh/$keyName';
      try {
        final readSession = await _sshClient!.execute('cat $remotePath');
        final stdoutBytes = BytesBuilder();
        await for (final data in readSession.stdout) {
          stdoutBytes.add(data);
        }
        await readSession.done;

        final contents = utf8.decode(stdoutBytes.takeBytes());
        if (contents.trim().isEmpty || contents.contains('No such file')) {
          continue;
        }

        await File('${keysDir.path}/$keyName').writeAsString(contents);
      } catch (e) {
        appLogger.w('Skipping unavailable key $remotePath: $e');
      }
    }
  }

  Future<void> _patchAuthorizedKeysFromCachedPublicKeys() async {
    final keysDir = await _getLocalKeysFolder();
    final localPubKeys = <String>[];

    for (final keyName in _rootSshKeyFiles.where((f) => f.endsWith('.pub'))) {
      final file = File('${keysDir.path}/$keyName');
      if (!file.existsSync()) {
        continue;
      }
      final key = (await file.readAsString()).trim();
      if (key.isNotEmpty) {
        localPubKeys.add(key);
      }
    }

    if (localPubKeys.isEmpty) {
      appLogger.w('No cached SSH public keys found to patch authorized_keys');
      return;
    }

    final mkdirSession = await _sshClient!
        .execute('mkdir -p /home/root/.ssh && chmod 700 /home/root/.ssh');
    await mkdirSession.done;

    final readSession = await _sshClient!
        .execute('cat /home/root/.ssh/authorized_keys 2>/dev/null || true');
    final stdoutBytes = BytesBuilder();
    await for (final data in readSession.stdout) {
      stdoutBytes.add(data);
    }
    await readSession.done;

    var authorizedKeys = utf8.decode(stdoutBytes.takeBytes()).trim();
    for (final key in localPubKeys) {
      if (!authorizedKeys.contains(key)) {
        authorizedKeys = authorizedKeys.isEmpty ? key : '$authorizedKeys\n$key';
      }
    }

    final writeSession = await _sshClient!.execute(
        'cat > /home/root/.ssh/authorized_keys && chmod 600 /home/root/.ssh/authorized_keys');
    writeSession.stdin.add(utf8.encode('$authorizedKeys\n'));
    await writeSession.stdin.close();
    await writeSession.done;
  }

  Future<void> _closeSSHConnection() async {
    try {
      if (_sshClient != null) {
        _sshClient!.close();
      }
      if (_sshSocket != null) {
        _sshSocket!.close();
      }
    } catch (e) {
      appLogger.e('Error closing SSH connection:', error: e);
    } finally {
      _sshClient = null;
      _sshSocket = null;
    }
  }

  Future<void> _downloadDirectorCertificate() async {
    try {
      appLogger.i('\n=== Downloading Director Certificate ===');
      await _ensureSSHConnection();

      if (_tempCertDir == null) {
        _tempCertDir = await Directory.systemTemp.createTemp('c4_certs');
      }
      final localCertPath = '${_tempCertDir!.path}/clientca-prod.pem';

      // Download the certificate using SSH
      // SCP isn't supported with this version of SSH and
      // SFTP is not supported on OS3 apparently

      Uint8List bytes = Uint8List(0);
      for (final remotePath in _remoteCertChainPaths) {
        final session =
            await _sshClient!.execute('cat $remotePath 2>/dev/null || true');
        final bytesBuilder = BytesBuilder();
        await for (final data in session.stdout) {
          bytesBuilder.add(data);
        }
        await session.done;
        final candidate = bytesBuilder.takeBytes();
        if (candidate.isNotEmpty) {
          bytes = candidate;
          break;
        }
      }
      if (bytes.isEmpty) {
        throw Exception('Could not read any known remote certificate chain');
      }

      await File(localCertPath).writeAsBytes(bytes);
      appLogger.t('Downloaded certificate to: $localCertPath');
      appLogger.t('Got ${bytes.length} bytes\n');

      final timestamp = DateTime.now().toString().replaceAll(':', '-');
      final localBackupPath =
          '${_tempCertDir!.path}/clientca-prod.$timestamp.backup';
      await File(localBackupPath).writeAsBytes(bytes);
      appLogger.t('Created local backup at: $localBackupPath\n');
    } catch (e) {
      appLogger.e('Failed to download certificate:', error: e);
      rethrow;
    }
  }

  Future<void> _createCertificateBackup() async {
    try {
      appLogger.i('\n=== Creating Certificate Backup ===');
      await _ensureSSHConnection();

      bool backedUpAny = false;
      final timestamp = DateTime.now().millisecondsSinceEpoch.toString();
      for (final remotePath in _remoteCertChainPaths) {
        final backupPath = '$remotePath.${timestamp}.backup';
        final session = await _sshClient!.execute(
            "if [ -f '$remotePath' ]; then cp '$remotePath' '$backupPath' && echo 'Success'; fi");
        final outputBytes = BytesBuilder();
        await for (final data in session.stdout) {
          outputBytes.add(data);
        }
        await session.done;
        final result = utf8.decode(outputBytes.takeBytes());
        if (result.contains('Success')) {
          backedUpAny = true;
          appLogger.t('Created backup at: $backupPath');
        }
      }
      if (!backedUpAny) {
        throw Exception('Failed to create any remote certificate backup');
      }
    } catch (e) {
      appLogger.e('Failed to create backup:', error: e);
      rethrow;
    }
  }

  Future<void> _cleanUp() async {
    try {
      if (_tempCertDir != null) {
        await _tempCertDir!.delete(recursive: true);
        _tempCertDir = null;
      }
    } catch (e) {
      appLogger.e('Error cleaning up temporary directory:', error: e);
    }
  }

  Future<String> _consolidateX509CertChain(String certChain) async {
    try {
      appLogger.t('Consolidating certificate chain...');

      final certs = certChain
          .split('-----END CERTIFICATE-----')
          .where((cert) => cert.trim().isNotEmpty)
          .map((cert) => '${cert.trim()}\n-----END CERTIFICATE-----')
          .toList();

      appLogger.t('Found ${certs.length} certificates in chain');

      final Map<String, String> subjectToCertMap = {};

      for (var i = certs.length - 1; i >= 0; i--) {
        final cert = certs[i];
        final remoteCertPath = '/tmp/cert_$i.pem';

        final writeSession = await _sshClient!.execute('cat > $remoteCertPath');
        writeSession.stdin.add(utf8.encode(cert));
        await writeSession.stdin.close();
        await writeSession.done;

        final subjectSession = await _sshClient!.execute(
            'openssl x509 -in $remoteCertPath -noout -subject 2>/dev/null || echo "INVALID_CERT"');

        final stdoutBytes = BytesBuilder();
        await for (final data in subjectSession.stdout) {
          stdoutBytes.add(data);
        }

        final subject = utf8.decode(stdoutBytes.takeBytes()).trim();
        await subjectSession.done;

        if (subject == 'INVALID_CERT' || subject.isEmpty) {
          appLogger.w('Warning: Certificate $i appears invalid, skipping');
          continue;
        }

        appLogger.t('Certificate $i subject: $subject');

        if (!subjectToCertMap.containsKey(subject)) {
          subjectToCertMap[subject] = cert;
        }
      }

      await _sshClient!.execute('rm -f /tmp/cert_*.pem');

      if (subjectToCertMap.isEmpty) {
        appLogger.w(
            'No valid certificates with subjects found! Using original chain.');
        return certChain;
      }

      appLogger.t(
          'Consolidated chain contains ${subjectToCertMap.length} unique certificates');

      return subjectToCertMap.values.join('\n\n').trim();
    } catch (e) {
      appLogger.e('Error consolidating certificate chain:', error: e);
      return certChain;
    }
  }
}
