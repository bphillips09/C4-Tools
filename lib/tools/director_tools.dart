import 'package:c4_tools/screens/composer_express_screen.dart';
import 'package:c4_tools/screens/composer_installer_screen.dart';
import 'package:c4_tools/screens/composer_pro_screen.dart';
import 'package:c4_tools/screens/update_manager_screen.dart';
import 'package:c4_tools/services/app_logger.dart' show appLogger;
import 'package:c4_tools/tools/http_client.dart';
import 'package:flutter/material.dart';
import 'dart:convert';
import 'dart:io';
import 'package:c4_tools/screens/ssh_screen.dart';
import 'package:c4_tools/main.dart' show MainApp;
import 'package:c4_tools/screens/jailbreak_screen.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:version/version.dart';
import 'package:c4_tools/services/app_settings.dart';

class DirectorTools extends StatelessWidget {
  final String? jwtToken;
  final String? macAddress;
  final String? generatedPassword;
  final String? errorMessage;
  final String? successfulPassword;
  final String directorIP;
  final bool isLoading;
  final VoidCallback onConnect;
  final TextEditingController ipController;
  final String? directorVersion;
  final String? directorUUID;

  const DirectorTools({
    Key? key,
    required this.jwtToken,
    required this.macAddress,
    required this.generatedPassword,
    required this.errorMessage,
    required this.successfulPassword,
    required this.directorIP,
    required this.isLoading,
    required this.onConnect,
    required this.ipController,
    required this.directorVersion,
    required this.directorUUID,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        if (errorMessage != null) ...[
          const SizedBox(height: 8),
          Text(
            errorMessage!,
            style: const TextStyle(color: Colors.red),
          ),
        ],
        if (jwtToken != null && directorIP.isNotEmpty) ...[
          DirectorToolsGrid(
            directorIP: directorIP,
            successfulPassword: successfulPassword,
            jwtToken: jwtToken,
            directorVersion: directorVersion,
            directorUUID: directorUUID,
          ),
        ],
      ],
    );
  }
}

class DirectorToolsGrid extends StatelessWidget {
  final String directorIP;
  final String? successfulPassword;
  final String? jwtToken;
  final String? directorVersion;
  final String? directorUUID;

  const DirectorToolsGrid({
    Key? key,
    required this.directorIP,
    required this.successfulPassword,
    required this.jwtToken,
    required this.directorVersion,
    required this.directorUUID,
  }) : super(key: key);

  Future<bool> _refreshNavigators(BuildContext context) async {
    if (jwtToken == null) {
      MainApp.showSnackBar('Authentication token is missing', isError: true);
      return false;
    }

    try {
      final url = 'https://$directorIP:443/api/v1/refresh_navigators';

      final client = httpIOClient();
      final response = await client.post(
        Uri.parse(url),
        headers: {
          'Accept': 'application/json',
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $jwtToken',
        },
      );

      if (response.statusCode == 200) {
        return true;
      } else {
        String errorMessage =
            'Failed to refresh navigators (Status: ${response.statusCode})';
        try {
          final errorJson = jsonDecode(response.body);
          if (errorJson['error'] != null) {
            errorMessage = errorJson['error'];
          }
        } catch (_) {}

        MainApp.showSnackBar(errorMessage, isError: true);
        return false;
      }
    } catch (e) {
      MainApp.showSnackBar('Error: ${e.toString()}', isError: true);
      return false;
    }
  }

  void _showRefreshNavigatorsDialog(BuildContext context) {
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext dialogContext) {
        return AlertDialog(
          title: const Text('Refresh Navigators'),
          content:
              const Text('Are you sure you want to refresh all navigators?'),
          actions: <Widget>[
            TextButton(
              child: const Text('Cancel'),
              onPressed: () {
                Navigator.of(context).pop();
              },
            ),
            TextButton(
              child: const Text('Refresh'),
              onPressed: () async {
                Navigator.of(dialogContext).pop();
                final success = await _refreshNavigators(context);
                if (success) {
                  MainApp.showSnackBar('Navigators refreshed successfully');
                }
              },
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    if (directorIP.isEmpty) {
      return const Center(
        child: Text('Director IP address is required'),
      );
    }

    if (jwtToken == null) {
      return const Center(
        child: Text('Authentication token is required'),
      );
    }

    // Fixed sizes based on default window size
    const double fixedIconSize = 48.0;
    const double fixedTitleSize = 16.0;
    const double fixedDescriptionSize = 14.0;
    const double fixedPadding = 16.0;
    const double cardWidth = 200.0;
    const double cardHeight = 200.0;
    const double gridSpacing = 8.0;

    final screenWidth = MediaQuery.of(context).size.width;
    final columnsCount = (screenWidth / (cardWidth + gridSpacing)).floor();
    final actualColumns = columnsCount.clamp(2, 3);

    bool isCoreOnX4 = false;
    if (directorVersion != null && directorUUID != null) {
      final cleanVersion = directorVersion!.split('-')[0];
      final version = Version.parse(cleanVersion);
      if (version >= Version(4, 0, 0) &&
          directorUUID!.toLowerCase().contains('core')) {
        isCoreOnX4 = true;
      }
    }

    return GridView.count(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      crossAxisCount: actualColumns,
      mainAxisSpacing: gridSpacing,
      crossAxisSpacing: gridSpacing,
      childAspectRatio: cardWidth / cardHeight,
      children: [
        _buildToolCard(
          context,
          icon: Icons.lock_open,
          title: 'Jailbreak',
          description: 'Director',
          iconSize: fixedIconSize,
          titleSize: fixedTitleSize,
          descriptionSize: fixedDescriptionSize,
          padding: fixedPadding,
          onTap: () {
            if (isCoreOnX4) {
              showDialog<void>(
                context: context,
                builder: (BuildContext context) {
                  return AlertDialog(
                    title: const Text('Warning'),
                    content: const Text(
                      'One-click Jailbreaking on Core-series controllers running X4 (>= 4.0.0) is untested and may not work. Do you want to proceed anyway?',
                    ),
                    actions: <Widget>[
                      TextButton(
                        child: const Text('Cancel'),
                        onPressed: () {
                          Navigator.of(context).pop();
                        },
                      ),
                      TextButton(
                        child: const Text('Proceed'),
                        onPressed: () {
                          Navigator.of(context).pop();
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (context) => JailbreakScreen(
                                directorIP: directorIP,
                                jwtToken: jwtToken!,
                                directorVersion: directorVersion,
                              ),
                            ),
                          );
                        },
                      ),
                    ],
                  );
                },
              );
            } else {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => JailbreakScreen(
                    directorIP: directorIP,
                    jwtToken: jwtToken!,
                    directorVersion: directorVersion,
                  ),
                ),
              );
            }
          },
        ),
        _buildToolCard(
          context,
          icon: Icons.terminal,
          title: 'SSH',
          description: 'Terminal',
          iconSize: fixedIconSize,
          titleSize: fixedTitleSize,
          descriptionSize: fixedDescriptionSize,
          padding: fixedPadding,
          onTap: () {
            String sshPassword = AppSettings.instance.getDefaultSshPassword();

            // If we have a successful password, use that instead
            if (successfulPassword != null) {
              sshPassword = successfulPassword!;
            }

            appLogger.d('SSH Password: $sshPassword');

            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => SSHScreen(
                  host: directorIP,
                  username: AppSettings.instance.getDefaultSshUsername(),
                  password: sshPassword,
                ),
              ),
            ).then((_) {
              appLogger.i('SSH session ended, returning to main window');
            });
          },
        ),
        _buildToolCard(
          context,
          icon: Icons.refresh,
          title: 'Refresh',
          description: 'Navigators',
          iconSize: fixedIconSize,
          titleSize: fixedTitleSize,
          descriptionSize: fixedDescriptionSize,
          padding: fixedPadding,
          onTap: () {
            _showRefreshNavigatorsDialog(context);
          },
        ),
        _buildToolCard(
          context,
          icon: Icons.browser_updated,
          title: 'Update',
          description: 'Manager',
          iconSize: fixedIconSize,
          titleSize: fixedTitleSize,
          descriptionSize: fixedDescriptionSize,
          padding: fixedPadding,
          onTap: () {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => UpdateManagerScreen(
                  directorIP: directorIP,
                  jwtToken: jwtToken!,
                ),
              ),
            );
          },
        ),
        _buildToolCard(
          context,
          icon: Icons.view_in_ar_outlined,
          title: 'Composer',
          description: 'Express',
          iconSize: fixedIconSize,
          titleSize: fixedTitleSize,
          descriptionSize: fixedDescriptionSize,
          padding: fixedPadding,
          onTap: () {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => ComposerInstallerScreen(),
              ),
            ).then((_) async {
              try {
                final appDir = await getApplicationSupportDirectory();
                final indexPath = path.join(appDir.path, 'ComposerExpress',
                    'assets', 'www', 'index.html');
                if (File(indexPath).existsSync()) {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => ComposerExpressScreen(
                        directorIP: directorIP,
                        jwtToken: jwtToken!,
                      ),
                    ),
                  );
                }
              } catch (e) {
                appLogger.e('Error checking Composer Express installation: $e');
              }
            });
          },
        ),
        _buildToolCard(
          context,
          icon: Icons.download,
          title: 'Composer Pro',
          description: 'Downloads',
          iconSize: fixedIconSize,
          titleSize: fixedTitleSize,
          descriptionSize: fixedDescriptionSize,
          padding: fixedPadding,
          onTap: () {
            if (jwtToken == null) {
              MainApp.showSnackBar('Please authenticate first', isError: true);
              return;
            }
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => const ComposerProScreen(),
              ),
            );
          },
        ),
      ],
    );
  }

  Widget _buildToolCard(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String description,
    required double iconSize,
    required double titleSize,
    required double descriptionSize,
    required double padding,
    required VoidCallback? onTap,
    String? tooltip,
  }) {
    return Card(
      child: InkWell(
        onTap: onTap,
        child: Tooltip(
          message: tooltip ?? '',
          child: Padding(
            padding: EdgeInsets.all(padding),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: iconSize),
                const SizedBox(height: 8),
                Text(
                  title,
                  style: TextStyle(
                    fontSize: titleSize,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  description,
                  style: TextStyle(
                    fontSize: descriptionSize,
                    color: Theme.of(context).textTheme.bodySmall?.color,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
