class PlatformStatus {
  final String? directorIP;
  final String? directorMAC;
  final String? directorUUID;
  final String? directorName;
  final int? directorDeviceId;
  final String? directorVersion;

  PlatformStatus({
    this.directorIP,
    this.directorMAC,
    this.directorUUID,
    this.directorName,
    this.directorDeviceId,
    this.directorVersion,
  });

  factory PlatformStatus.fromJson(Map<String, dynamic> json) {
    String? directorVersion;
    if (json['versions'] != null) {
      for (var version in json['versions']) {
        if (version['name'] == 'Director') {
          directorVersion = version['version'];
          break;
        }
      }
    }

    return PlatformStatus(
      directorIP: json['directorIP'],
      directorMAC: json['directorMAC'],
      directorUUID: json['directorUUID'],
      directorName: json['directorName'],
      directorDeviceId: json['directorDeviceId'],
      directorVersion: directorVersion,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'directorIP': directorIP,
      'directorMAC': directorMAC,
      'directorUUID': directorUUID,
      'directorName': directorName,
      'directorDeviceId': directorDeviceId,
      'directorVersion': directorVersion,
    };
  }
}

class JwtResponse {
  final String? token;
  final ErrorResponse? error;

  JwtResponse({this.token, this.error});

  factory JwtResponse.fromJson(Map<String, dynamic> json) {
    final token = json['token'];

    ErrorResponse? error;

    // Handling the weird response format from the API...
    // Case 1: Error in C4ErrorResponse object
    if (json['C4ErrorResponse'] != null) {
      error = ErrorResponse.fromJson(json['C4ErrorResponse']);
    }
    // Case 2: Error fields directly in the response
    else if (json['code'] != null &&
        json['code'] != 200 &&
        json['message'] != null) {
      error = ErrorResponse(
        code: json['code'],
        details: json['details'],
        message: json['message'],
        subCode: json['subCode'],
      );
    }

    return JwtResponse(
      token: token,
      error: error,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'token': token,
      'error': error,
    };
  }

  @override
  String toString() {
    return 'JwtResponse(token: $token, error: $error)';
  }
}

class ErrorResponse {
  final int? code;
  final String? details;
  final String? message;
  final int? subCode;

  ErrorResponse({this.code, this.details, this.message, this.subCode});

  factory ErrorResponse.fromJson(Map<String, dynamic> json) {
    return ErrorResponse(
        code: json['code'],
        details: json['details'],
        message: json['message'],
        subCode: json['subCode']);
  }

  Map<String, dynamic> toJson() {
    return {
      'code': code,
      'details': details,
      'message': message,
      'subCode': subCode
    };
  }

  @override
  String toString() {
    return 'ErrorResponse(code: $code, details: $details, message: $message, subCode: $subCode)';
  }
}

class ApiEndpoint {
  final String path;
  final String method;
  final String? description;

  ApiEndpoint({
    required this.path,
    required this.method,
    this.description,
  });

  factory ApiEndpoint.fromJson(Map<String, dynamic> json) {
    return ApiEndpoint(
      path: json['path'] ?? '',
      method: json['method'] ?? '',
      description: json['description'],
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'path': path,
      'method': method,
      'description': description,
    };
  }
}

class CreateAccountRequest {
  final String accountName;
  final String projectScale;
  final String installType;
  final String dateInstalled;
  final bool allowRemoteSupport;
  final bool receivePromotions;
  final String firstName;
  final String lastName;
  final String email;
  final String phone;
  final String password;
  final Address address;
  final String languageCode;
  final String recaptchaResponse;

  CreateAccountRequest({
    required this.accountName,
    required this.projectScale,
    required this.installType,
    required this.dateInstalled,
    required this.allowRemoteSupport,
    required this.receivePromotions,
    required this.firstName,
    required this.lastName,
    required this.email,
    required this.phone,
    required this.password,
    required this.address,
    required this.languageCode,
    required this.recaptchaResponse,
  });

  Map<String, dynamic> toJson() => {
        'AccountName': accountName,
        'ProjectScale': projectScale,
        'InstallType': installType,
        'DateInstalled': dateInstalled,
        'AllowRemoteSupport': allowRemoteSupport,
        'ReceivePromotions': receivePromotions,
        'FirstName': firstName,
        'LastName': lastName,
        'Email': email,
        'Phone': phone,
        'Password': password,
        'Address': address.toJson(),
        'LanguageCode': languageCode,
        'RecaptchaResponse': recaptchaResponse,
      };
}

class Address {
  final String addressLine1;
  final String city;
  final String state;
  final String zip;
  final String country;

  Address({
    required this.addressLine1,
    required this.city,
    required this.state,
    required this.zip,
    required this.country,
  });

  Map<String, dynamic> toJson() => {
        'AddressLine1': addressLine1,
        'City': city,
        'State': state,
        'Zip': zip,
        'Country': country,
      };
}
