import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

enum AssistantAvailability {
  ready,
  requiresIos26,
  requiresAndroid26,
  modelDownloadable,
  modelDownloading,
  unsupportedDevice,
  disabled,
  modelNotReady,
  unsupportedLanguage,
  unsupportedPlatform,
  unavailable,
}

class AssistantFailure implements Exception {
  const AssistantFailure(this.code);
  final String code;
}

abstract interface class AssistantModel {
  Future<AssistantAvailability> availability(String locale);
  Future<String> respond({
    required String requestId,
    required String locale,
    required String question,
    required String history,
    required String findings,
  });
  Future<void> cancel(String requestId);
}

abstract interface class DownloadableAssistantModel {
  Future<void> download(String requestId);
}

abstract interface class ReleasableAssistantModel {
  Future<void> unload();
}

abstract interface class ContextualAssistantModel {
  Future<String> respondWithContext({
    required String requestId,
    required String locale,
    required String question,
    required String history,
    required String findings,
    required String appContext,
    required String guide,
  });
}

class OnDeviceAssistantModel
    implements
        AssistantModel,
        DownloadableAssistantModel,
        ContextualAssistantModel {
  const OnDeviceAssistantModel({
    this.channel = const MethodChannel('safe_at_home/assistant'),
    this.platform,
  });
  final MethodChannel channel;
  final TargetPlatform? platform;
  bool get _supported =>
      !kIsWeb &&
      {
        TargetPlatform.iOS,
        TargetPlatform.android,
      }.contains(platform ?? defaultTargetPlatform);

  @override
  Future<void> download(String requestId) async {
    if (!_supported ||
        (platform ?? defaultTargetPlatform) != TargetPlatform.android) {
      throw const AssistantFailure('UNAVAILABLE');
    }
    try {
      await channel
          .invokeMethod<void>('download', {'requestId': requestId})
          .timeout(const Duration(seconds: 190));
    } on TimeoutException {
      unawaited(cancel(requestId));
      throw const AssistantFailure('TIMEOUT');
    } on PlatformException catch (error) {
      throw AssistantFailure(error.code);
    } on MissingPluginException {
      throw const AssistantFailure('UNAVAILABLE');
    }
  }

  @override
  Future<AssistantAvailability> availability(String locale) async {
    if (!_supported) return AssistantAvailability.unsupportedPlatform;
    try {
      final value = await channel
          .invokeMethod<String>('availability', {'locale': locale})
          .timeout(const Duration(seconds: 8));
      return AssistantAvailability.values.firstWhere(
        (item) => item.name == value,
        orElse: () => AssistantAvailability.unavailable,
      );
    } catch (_) {
      return AssistantAvailability.unavailable;
    }
  }

  @override
  Future<String> respond({
    required String requestId,
    required String locale,
    required String question,
    required String history,
    required String findings,
  }) => _respond({
    'requestId': requestId,
    'locale': locale,
    'question': question,
    'history': history,
    'findings': findings,
  });

  @override
  Future<String> respondWithContext({
    required String requestId,
    required String locale,
    required String question,
    required String history,
    required String findings,
    required String appContext,
    required String guide,
  }) => _respond({
    'requestId': requestId,
    'locale': locale,
    'question': question,
    'history': history,
    'findings': findings,
    'appContext': appContext,
    'guide': guide,
  });

  Future<String> _respond(Map<String, String> request) async {
    if (!_supported) throw const AssistantFailure('UNAVAILABLE');
    try {
      final text = await channel
          .invokeMethod<String>('respond', request)
          .timeout(const Duration(seconds: 60));
      if (text == null ||
          text.trim().isEmpty ||
          text.runes.length >
              (request.containsKey('appContext') ? 8192 : 2400)) {
        throw const AssistantFailure('INVALID_RESPONSE');
      }
      return text.trim();
    } on TimeoutException {
      unawaited(cancel(request['requestId']!));
      throw const AssistantFailure('TIMEOUT');
    } on PlatformException catch (error) {
      throw AssistantFailure(error.code);
    } on MissingPluginException {
      throw const AssistantFailure('UNAVAILABLE');
    }
  }

  @override
  Future<void> cancel(String requestId) async {
    if (!_supported) return;
    try {
      await channel
          .invokeMethod<void>('cancel', {'requestId': requestId})
          .timeout(const Duration(seconds: 3));
    } catch (_) {
      // ignore: empty_catches
    }
  }
}
