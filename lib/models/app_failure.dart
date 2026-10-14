import 'dart:io';

import 'package:flutter/services.dart';

/// Keep diagnostic details out of the user-facing message.
class AppFailure implements Exception {
  const AppFailure(this.message, {this.details});
  final String message;
  final String? details;
  @override
  String toString() => message;
}

String userFacingError(Object error) {
  if (error is AppFailure) return error.message;
  if (error is FormatException) return error.message;
  if (error is FileSystemException) {
    return 'Could not access or save a file. Check available storage and file permissions, then retry.';
  }
  if (error is PlatformException) {
    return 'A device service could not complete the operation. Check connectivity and storage, then retry.';
  }
  return 'The operation could not be completed. Please retry.';
}
