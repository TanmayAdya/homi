import 'dart:async';
import 'package:flutter/services.dart';

const localModelId = 'Qwen3-0.6B-Q8_0';
const localModelBytes = 639446688;
const localModelSha256 =
    '9465e63a22add5354d9bb4b99e90117043c7124007664907259bd16d043bb031';
const localRuntimeId =
    'llama.cpp:b11889:d854d98bae598388ecea1ed84396587e5edc326d';

class LocalModelStatus {
  const LocalModelStatus({
    required this.compiled,
    required this.installed,
    required this.busy,
  });
  final bool compiled, installed, busy;
  String get modelId => localModelId;
  String get runtimeId => localRuntimeId;
  int get bytes => localModelBytes;
  String get sha256 => localModelSha256;
  factory LocalModelStatus.parse(Object? raw) {
    if (raw is! Map ||
        raw['compiled'] is! bool ||
        raw['installed'] is! bool ||
        raw['busy'] is! bool ||
        raw['modelId'] != localModelId ||
        raw['runtimeId'] != localRuntimeId ||
        raw['bytes'] != localModelBytes ||
        raw['sha256'] != localModelSha256) {
      throw PlatformException(code: 'INVALID_RESPONSE');
    }
    return LocalModelStatus(
      compiled: raw['compiled'] as bool,
      installed: raw['installed'] as bool,
      busy: raw['busy'] as bool,
    );
  }
}

class LocalGeneration {
  const LocalGeneration({
    required this.text,
    required this.firstTokenMs,
    required this.totalMs,
    required this.promptTokens,
    required this.outputTokens,
  });
  final String text;
  final double firstTokenMs, totalMs;
  final int promptTokens, outputTokens;
  factory LocalGeneration.parse(Object? raw) {
    if (raw is! Map ||
        raw['text'] is! String ||
        (raw['text'] as String).trim().isEmpty ||
        (raw['text'] as String).runes.length > 2400 ||
        raw['firstTokenMs'] is! num ||
        raw['totalMs'] is! num ||
        !(raw['firstTokenMs'] as num).isFinite ||
        !(raw['totalMs'] as num).isFinite ||
        (raw['firstTokenMs'] as num) < 0 ||
        (raw['totalMs'] as num) < 0 ||
        raw['promptTokens'] is! int ||
        raw['outputTokens'] is! int ||
        (raw['promptTokens'] as int) < 1 ||
        (raw['promptTokens'] as int) > 1664 ||
        (raw['outputTokens'] as int) < 1 ||
        (raw['outputTokens'] as int) > 384) {
      throw PlatformException(code: 'INVALID_RESPONSE');
    }
    return LocalGeneration(
      text: (raw['text'] as String).trim(),
      firstTokenMs: (raw['firstTokenMs'] as num).toDouble(),
      totalMs: (raw['totalMs'] as num).toDouble(),
      promptTokens: raw['promptTokens'] as int,
      outputTokens: raw['outputTokens'] as int,
    );
  }
}

class HomiLocalLlm {
  const HomiLocalLlm({this.channel = const MethodChannel('homi_local_llm')});
  final MethodChannel channel;
  Future<LocalModelStatus> status() async =>
      LocalModelStatus.parse(await channel.invokeMethod<Object?>('status'));
  Future<LocalModelStatus> importModel(String requestId) async =>
      LocalModelStatus.parse(
        await channel.invokeMethod<Object?>('importModel', {
          'requestId': requestId,
        }),
      );
  Future<LocalModelStatus> deleteModel() async => LocalModelStatus.parse(
    await channel.invokeMethod<Object?>('deleteModel'),
  );
  Future<void> unload() => channel.invokeMethod<void>('unload');
  Future<void> cancel(String requestId) =>
      channel.invokeMethod<void>('cancel', {'requestId': requestId});
  Future<LocalGeneration> generate({
    required String requestId,
    required String systemPrompt,
    required String prompt,
  }) async {
    try {
      return LocalGeneration.parse(
        await channel
            .invokeMethod<Object?>('generate', {
              'requestId': requestId,
              'systemPrompt': systemPrompt,
              'prompt': prompt,
            })
            .timeout(const Duration(seconds: 65)),
      );
    } on TimeoutException {
      await cancel(requestId);
      throw PlatformException(code: 'TIMEOUT');
    }
  }
}
