import 'package:flutter/material.dart';
import 'package:c4_tools/tools/http_client.dart';
import 'package:xml/xml.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:c4_tools/main.dart';
import 'package:c4_tools/models/soap_request.dart';
import 'package:c4_tools/services/app_logger.dart' show appLogger;

class ComposerProScreen extends StatefulWidget {
  const ComposerProScreen({Key? key}) : super(key: key);

  @override
  State<ComposerProScreen> createState() => _ComposerProScreenState();
}

class _ComposerProScreenState extends State<ComposerProScreen> {
  List<String> _versions = [];
  bool _isLoading = false;
  String? _errorMessage;
  final TextEditingController _urlController = TextEditingController(
    text: 'https://services.control4.com/Updates2x/v2_0/Updates.asmx',
  );

  @override
  void initState() {
    super.initState();
    _loadVersions();
  }

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  Future<void> _loadVersions() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final versions = await _getComposerProVersions();
      setState(() {
        _versions = versions;
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _errorMessage = e.toString();
        _isLoading = false;
      });
    }
  }

  Future<List<String>> _getComposerProVersions() async {
    try {
      final url = _urlController.text;
      appLogger.i('Fetching Composer Pro versions from: $url');

      final request = GetAllVersionsRequest(
        currentVersion: '3.3.0',
        includeEarlierVersions: true,
      );

      final envelope = SoapEnvelope(
        body: SoapBody(request: request),
      );

      final soapEnvelope = envelope.toXml();
      appLogger.t('SOAP Request:\n$soapEnvelope');

      final client = httpIOClient();
      final response = await client.post(
        Uri.parse(url),
        headers: {
          'Content-Type': 'text/xml; charset=utf-8',
          'SOAPAction':
              'http://services.control4.com/updates/v2_0/GetAllVersions',
        },
        body: soapEnvelope,
      );

      appLogger.t('Response Status Code: ${response.statusCode}');
      appLogger.t('Response Headers: ${response.headers}');
      appLogger.t('Response Body: ${response.body}');

      if (response.statusCode == 200) {
        final document = XmlDocument.parse(response.body);
        final versions = document
            .findAllElements('string')
            .map((e) => e.innerText)
            .where((version) =>
                version.contains('Composer') && !version.contains('ComposerHE'))
            .toList();
        appLogger
            .i('Found ${versions.length} Composer Pro versions: $versions');
        return versions;
      } else {
        appLogger
            .w('Failed to get versions. Status code: ${response.statusCode}');
        throw Exception(
            'Failed to get versions (Status: ${response.statusCode})');
      }
    } catch (e, stackTrace) {
      appLogger.e('Error getting versions:', error: e, stackTrace: stackTrace);
      throw Exception('Error getting versions: ${e.toString()}');
    }
  }

  Future<void> _downloadComposerPro(String version) async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final url = _urlController.text;
      appLogger.i('Getting download URL for Composer Pro version: $version');

      final request = GetPackagesByVersionRequest(
        version: version,
        certificateCommonName: 'ComposerPro',
      );

      final envelope = SoapEnvelope(
        body: SoapBody(request: request),
      );

      final soapEnvelope = envelope.toXml();
      appLogger.t('SOAP Request for packages:\n$soapEnvelope');

      final client = httpIOClient();
      final packageResponse = await client.post(
        Uri.parse(url),
        headers: {
          'Content-Type': 'text/xml; charset=utf-8',
          'SOAPAction':
              'http://services.control4.com/updates/v2_0/GetPackagesByVersion',
        },
        body: soapEnvelope,
      );

      appLogger
          .t('Package Response Status Code: ${packageResponse.statusCode}');
      appLogger.t('Package Response Headers: ${packageResponse.headers}');
      appLogger.t('Package Response Body: ${packageResponse.body}');

      if (packageResponse.statusCode == 200) {
        final packageDocument = XmlDocument.parse(packageResponse.body);
        final packages = packageDocument.findAllElements('Package');
        if (packages.isEmpty) {
          // Try GetPackagesVersionsByName for older versions
          final nameRequest = GetPackagesVersionsByNameRequest(
            packageName: 'ComposerPro',
            currentVersion: version,
            device: 'x86',
            includeEarlierVersions: false,
          );

          final nameEnvelope = SoapEnvelope(
            body: SoapBody(request: nameRequest),
          );

          final nameSoapEnvelope = nameEnvelope.toXml();
          appLogger.t('Trying GetPackagesVersionsByName:\n$nameSoapEnvelope');

          final nameResponse = await client.post(
            Uri.parse(url),
            headers: {
              'Content-Type': 'text/xml; charset=utf-8',
              'SOAPAction':
                  'http://services.control4.com/updates/v2_0/GetPackagesVersionsByName',
            },
            body: nameSoapEnvelope,
          );

          appLogger.t('Name Response Status Code: ${nameResponse.statusCode}');
          appLogger.t('Name Response Headers: ${nameResponse.headers}');
          appLogger.t('Name Response Body: ${nameResponse.body}');

          if (nameResponse.statusCode == 200) {
            final nameDocument = XmlDocument.parse(nameResponse.body);
            final namePackages = nameDocument.findAllElements('Package');
            if (namePackages.isEmpty) {
              throw Exception('No packages found for version $version');
            }

            final composerProPackage = namePackages.firstWhere(
              (package) => package
                  .findElements('Name')
                  .first
                  .innerText
                  .contains('ComposerPro'),
              orElse: () => throw Exception('Composer Pro package not found'),
            );

            final downloadUrl =
                composerProPackage.findElements('Url').first.innerText;
            appLogger.i('Download URL: $downloadUrl');

            if (await canLaunchUrl(Uri.parse(downloadUrl))) {
              await launchUrl(Uri.parse(downloadUrl));
              if (mounted) {
                MainApp.showSnackBar('Download started for version $version');
              }
            } else {
              throw Exception('Could not launch $downloadUrl');
            }
          } else {
            throw Exception(
                'Failed to get packages by name (Status: ${nameResponse.statusCode})');
          }
        } else {
          final composerProPackage = packages.firstWhere(
            (package) => package
                .findElements('Name')
                .first
                .innerText
                .contains('ComposerPro'),
            orElse: () => throw Exception('Composer Pro package not found'),
          );

          final downloadUrl =
              composerProPackage.findElements('Url').first.innerText;
          appLogger.i('Download URL: $downloadUrl');

          if (await canLaunchUrl(Uri.parse(downloadUrl))) {
            await launchUrl(Uri.parse(downloadUrl));
            if (mounted) {
              MainApp.showSnackBar('Download started for version $version');
            }
          } else {
            throw Exception('Could not launch $downloadUrl');
          }
        }
      } else {
        throw Exception(
            'Failed to get packages (Status: ${packageResponse.statusCode})');
      }
    } catch (e) {
      setState(() {
        _errorMessage = e.toString();
      });
      if (mounted) {
        MainApp.showSnackBar('Error: ${e.toString()}', isError: true);
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  void _showDownloadConfirmationDialog(String version) {
    showDialog<void>(
      context: context,
      builder: (BuildContext dialogContext) {
        return AlertDialog(
          title: const Text('Confirm Download'),
          content: Text('Do you want to download $version?'),
          actions: <Widget>[
            TextButton(
              child: const Text('Cancel'),
              onPressed: () {
                Navigator.of(dialogContext).pop();
              },
            ),
            TextButton(
              child: const Text('Download'),
              onPressed: () async {
                Navigator.of(dialogContext).pop();
                await _downloadComposerPro(version);
              },
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        centerTitle: true,
        title: const Text('Composer Pro Downloads'),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _urlController,
                    decoration: const InputDecoration(
                      labelText: 'Update Service URL',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                ElevatedButton.icon(
                  onPressed: _loadVersions,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Refresh'),
                ),
              ],
            ),
          ),
          Expanded(
            child: _isLoading
                ? const Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        CircularProgressIndicator(),
                        SizedBox(height: 16),
                        Text('Getting available versions...'),
                      ],
                    ),
                  )
                : _errorMessage != null
                    ? Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              _errorMessage!,
                              style: const TextStyle(color: Colors.red),
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: 16),
                            ElevatedButton(
                              onPressed: _loadVersions,
                              child: const Text('Retry'),
                            ),
                          ],
                        ),
                      )
                    : _versions.isEmpty
                        ? const Center(child: Text('No versions found'))
                        : ListView(
                            children: _versions.map((version) {
                              return Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 8.0,
                                  horizontal: 16.0,
                                ),
                                child: SizedBox(
                                  width: double.infinity,
                                  child: ElevatedButton(
                                    onPressed: () =>
                                        _showDownloadConfirmationDialog(
                                            version),
                                    child: Text(version),
                                  ),
                                ),
                              );
                            }).toList(),
                          ),
          ),
        ],
      ),
    );
  }
}
