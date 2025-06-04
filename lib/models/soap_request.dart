class SoapEnvelope {
  final SoapBody body;

  SoapEnvelope({required this.body});

  String toXml() {
    return '''<?xml version="1.0" encoding="utf-8"?>
          <soap:Envelope xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" 
          xmlns:xsd="http://www.w3.org/2001/XMLSchema" 
          xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/">
            ${body.toXml()}
          </soap:Envelope>''';
  }
}

class SoapBody {
  final SoapRequest request;

  SoapBody({required this.request});

  String toXml() {
    return '''<soap:Body>
  ${request.toXml()}
</soap:Body>''';
  }
}

abstract class SoapRequest {
  String get namespace;
  String get methodName;
  Map<String, dynamic> get parameters;

  String toXml() {
    final params = parameters.entries
        .map((e) => '<${e.key}>${e.value}</${e.key}>')
        .join('\n      ');

    return '''<${methodName} xmlns="${namespace}">
      $params
    </${methodName}>''';
  }
}

class GetAllVersionsRequest extends SoapRequest {
  final String currentVersion;
  final bool includeEarlierVersions;

  GetAllVersionsRequest({
    required this.currentVersion,
    required this.includeEarlierVersions,
  });

  @override
  String get namespace => 'http://services.control4.com/updates/v2_0/';

  @override
  String get methodName => 'GetAllVersions';

  @override
  Map<String, dynamic> get parameters => {
        'currentVersion': currentVersion,
        'includeEarlierVersions': includeEarlierVersions.toString(),
      };
}

class GetPackagesByVersionRequest extends SoapRequest {
  final String version;
  final String certificateCommonName;

  GetPackagesByVersionRequest({
    required this.version,
    required this.certificateCommonName,
  });

  @override
  String get namespace => 'http://services.control4.com/updates/v2_0/';

  @override
  String get methodName => 'GetPackagesByVersion';

  @override
  Map<String, dynamic> get parameters => {
        'version': version,
        'certificateCommonName': certificateCommonName,
      };
}

class GetPackagesVersionsByNameRequest extends SoapRequest {
  final String packageName;
  final String currentVersion;
  final String device;
  final bool includeEarlierVersions;

  GetPackagesVersionsByNameRequest({
    required this.packageName,
    required this.currentVersion,
    required this.device,
    required this.includeEarlierVersions,
  });

  @override
  String get namespace => 'http://services.control4.com/updates/v2_0/';

  @override
  String get methodName => 'GetPackagesVersionsByName';

  @override
  Map<String, dynamic> get parameters => {
        'packageName': packageName,
        'currentVersion': currentVersion,
        'device': device,
        'includeEarlierVersions': includeEarlierVersions.toString(),
      };
}
