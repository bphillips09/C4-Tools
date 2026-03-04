import 'package:c4_tools/models/soap_request.dart';
import 'package:c4_tools/services/app_logger.dart' show appLogger;
import 'package:c4_tools/tools/http_client.dart';
import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';

class Control4UpdatesService {
  static const String defaultEndpoint =
      'https://services.control4.com/Updates2x-experience/v2_0/Updates.asmx';
  static const String namespace = 'http://services.control4.com/updates/v2_0/';

  Future<List<String>> getAllVersions({
    required String endpoint,
    String currentVersion = '3.3.0',
    bool includeEarlierVersions = true,
  }) async {
    final request = GetAllVersionsRequest(
      currentVersion: currentVersion,
      includeEarlierVersions: includeEarlierVersions,
    );
    final response = await _postSoap(endpoint: endpoint, request: request);

    final document = XmlDocument.parse(response.body);
    return document.findAllElements('string').map((e) => e.innerText).toList();
  }

  Future<List<Control4PackageInfo>> getPackagesByVersion({
    required String endpoint,
    required String version,
    String? certificateCommonName,
  }) async {
    final request = GetPackagesByVersionRequest(
      version: version,
      certificateCommonName: certificateCommonName,
    );
    final response = await _postSoap(endpoint: endpoint, request: request);

    final document = XmlDocument.parse(response.body);
    return _parsePackages(document);
  }

  Future<List<Control4PackageInfo>> getPackagesVersionsByName({
    required String endpoint,
    required String packageName,
    required String currentVersion,
    String device = 'x86',
    bool includeEarlierVersions = false,
  }) async {
    final request = GetPackagesVersionsByNameRequest(
      packageName: packageName,
      currentVersion: currentVersion,
      device: device,
      includeEarlierVersions: includeEarlierVersions,
    );
    final response = await _postSoap(endpoint: endpoint, request: request);

    final document = XmlDocument.parse(response.body);
    return _parsePackages(document);
  }

  Future<http.Response> _postSoap({
    required String endpoint,
    required SoapRequest request,
  }) async {
    final envelope = SoapEnvelope(body: SoapBody(request: request)).toXml();
    final soapActionBase = request.namespace.endsWith('/')
        ? request.namespace.substring(0, request.namespace.length - 1)
        : request.namespace;
    final soapAction = '$soapActionBase/${request.methodName}';

    final client = httpIOClient();
    final response = await client.post(
      Uri.parse(endpoint),
      headers: {
        'Content-Type': 'text/xml; charset=utf-8',
        'SOAPAction': soapAction,
      },
      body: envelope,
    );

    appLogger.t('SOAP ${request.methodName} -> $endpoint');
    appLogger.t('SOAP status: ${response.statusCode}');

    if (response.statusCode != 200) {
      throw Exception(
          'SOAP ${request.methodName} failed (Status: ${response.statusCode})');
    }

    return response;
  }

  List<Control4PackageInfo> _parsePackages(XmlDocument document) {
    return document.findAllElements('Package').map((pkg) {
      final name = pkg.findElements('Name').firstOrNull?.innerText ?? '';
      final url = pkg.findElements('Url').firstOrNull?.innerText ?? '';
      final checksum =
          pkg.findElements('Checksum').firstOrNull?.innerText ?? '';
      final sizeText = pkg.findElements('Size').firstOrNull?.innerText ?? '0';
      final size = int.tryParse(sizeText) ?? 0;
      return Control4PackageInfo(
        name: name,
        url: url,
        checksum: checksum,
        size: size,
      );
    }).toList();
  }
}

class Control4PackageInfo {
  final String name;
  final String url;
  final String checksum;
  final int size;

  const Control4PackageInfo({
    required this.name,
    required this.url,
    required this.checksum,
    required this.size,
  });
}
