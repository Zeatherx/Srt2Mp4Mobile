import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_mlkit_translation/google_mlkit_translation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:srt2mp4_mobile/models/srt_document.dart';
import 'package:srt2mp4_mobile/models/app_failure.dart';
import 'package:srt2mp4_mobile/services/translation_service.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.path);
  final String path;
  @override
  Future<String?> getTemporaryPath() async => path;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('google_mlkit_on_device_translator');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory temporary;
  late File input;
  late TranslationService service;
  late List<MethodCall> calls;
  late Set<String> models;
  late FutureOr<String> Function(String) translate;
  late FutureOr<Object?> Function(MethodCall) handleModel;
  late PathProviderPlatform previousPaths;

  const original =
      '\uFEFF007\r\n00:00:01,100 --> 00:00:03,200\r\n'
      '<i>Hello</i>\r\n{\\an8}World\r\n\r\n'
      '011\r\n00:00:04,000 --> 00:00:05,000\r\nHello\r\n';

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('srt_translation_test_');
    input = await File(
      p.join(temporary.path, 'original.srt'),
    ).writeAsBytes(utf8.encode(original));
    previousPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(temporary.path);
    service = TranslationService();
    calls = [];
    models = {'en'};
    translate = (text) => {'Hello': 'Hola', 'World': 'Mundo'}[text]!;
    handleModel = (call) {
      final arguments = call.arguments as Map;
      expect(
        arguments['model'],
        isNot('en'),
        reason: 'English has no remote model',
      );
      if (arguments['task'] == 'check') {
        return models.contains(arguments['model']);
      }
      models.add(arguments['model'] as String);
      return 'success';
    };
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      switch (call.method) {
        case 'nlp#manageLanguageModelModels':
          return await handleModel(call);
        case 'nlp#startLanguageTranslator':
          return await translate((call.arguments as Map)['text'] as String);
        case 'nlp#closeLanguageTranslator':
          return null;
        default:
          throw MissingPluginException(call.method);
      }
    });
  });

  tearDown(() async {
    messenger.setMockMethodCallHandler(channel, null);
    PathProviderPlatform.instance = previousPaths;
    await temporary.delete(recursive: true);
  });

  Future<File> run({
    TranslationCancellationToken? token,
    void Function(TranslationProgress)? progress,
    bool wifiOnly = true,
  }) => service.translateSrtFile(
    inputFile: input,
    sourceLanguage: TranslateLanguage.english,
    targetLanguage: TranslateLanguage.spanish,
    cancellationToken: token ?? TranslationCancellationToken(),
    onProgress: progress,
    wifiOnly: wifiOnly,
  );

  test(
    'translates text only, preserves formatting/metadata/BOM and caches repeats',
    () async {
      final progress = <TranslationProgress>[];
      final output = await run(progress: progress.add);
      final bytes = await output.readAsBytes();
      expect(bytes.take(3), [0xEF, 0xBB, 0xBF]);
      final translated = utf8.decode(bytes);
      expect(
        translated,
        original
            .substring(1)
            .replaceAll('Hello', 'Hola')
            .replaceAll('World', 'Mundo'),
      );
      expect(await input.readAsBytes(), utf8.encode(original));
      final requests = calls
          .where((call) => call.method == 'nlp#startLanguageTranslator')
          .toList();
      expect(requests.map((call) => (call.arguments as Map)['text']), [
        'Hello',
        'World',
      ]);
      expect(
        requests.every(
          (call) =>
              (call.arguments as Map)['source'] == 'en' &&
              (call.arguments as Map)['target'] == 'es',
        ),
        isTrue,
      );
      expect(
        calls.where((call) => call.method == 'nlp#closeLanguageTranslator'),
        hasLength(1),
      );
      expect(progress.last.fraction, 1);
      expect(SrtDocument.parse(translated).blocks.map((cue) => cue.index), [
        '007',
        '011',
      ]);
      expect(
        calls
            .where((call) => (call.arguments as Map)['task'] == 'download')
            .map((call) => call.arguments),
        [
          {'task': 'download', 'model': 'es', 'wifi': true},
        ],
      );
      await service.release(output);
      expect(await output.parent.exists(), isFalse);
    },
  );

  test(
    'download failure stops translation and leaves original intact; retry works',
    () async {
      handleModel = (call) =>
          (call.arguments as Map)['task'] == 'check' ? false : 'failed';
      await expectLater(run(), throwsA(isA<AppFailure>()));
      expect(
        calls.any((call) => call.method == 'nlp#startLanguageTranslator'),
        isFalse,
      );
      expect(await temporary.list().length, 1);
      models.add('es');
      handleModel = (_) => true;
      final output = await run();
      expect(await output.exists(), isTrue);
      await service.release(output);
    },
  );

  test(
    'cancellation during a cue closes translator and produces no temporary SRT',
    () async {
      final token = TranslationCancellationToken();
      translate = (text) {
        token.cancel();
        return 'Hola';
      };
      await expectLater(
        run(token: token),
        throwsA(isA<TranslationCancelled>()),
      );
      expect(
        calls.where((call) => call.method == 'nlp#closeLanguageTranslator'),
        hasLength(1),
      );
      expect(await temporary.list().length, 1);
    },
  );

  test(
    'cancelling a pending model download stops waiting immediately',
    () async {
      final token = TranslationCancellationToken();
      final pending = Completer<Object?>();
      final started = Completer<void>();
      handleModel = (call) {
        if ((call.arguments as Map)['task'] == 'check') return false;
        started.complete();
        return pending.future;
      };
      final result = run(token: token);
      final expectation = expectLater(
        result,
        throwsA(isA<TranslationCancelled>()),
      );
      await started.future;
      token.cancel();
      await expectation;
      pending.complete('success');
      expect(
        calls.any((call) => call.method == 'nlp#startLanguageTranslator'),
        isFalse,
      );
      expect(await temporary.list().length, 1);
    },
  );

  test(
    'empty model output fails safely and still releases native translator',
    () async {
      translate = (_) => '';
      await expectLater(run(), throwsFormatException);
      expect(
        calls.where((call) => call.method == 'nlp#closeLanguageTranslator'),
        hasLength(1),
      );
      expect(await temporary.list().length, 1);
    },
  );

  test(
    'reuses downloaded models and honors opt-in mobile data downloads',
    () async {
      var output = await run(wifiOnly: false);
      await service.release(output);
      final downloads = calls.where(
        (call) => (call.arguments as Map)['task'] == 'download',
      );
      expect(downloads.single.arguments, {
        'task': 'download',
        'model': 'es',
        'wifi': false,
      });
      calls.clear();
      output = await run();
      expect(
        calls.where((call) => (call.arguments as Map)['task'] == 'download'),
        isEmpty,
      );
      await service.release(output);
    },
  );

  test('downloads both non-English models before translating', () async {
    final output = await service.translateSrtFile(
      inputFile: input,
      sourceLanguage: TranslateLanguage.french,
      targetLanguage: TranslateLanguage.german,
      cancellationToken: TranslationCancellationToken(),
    );
    final downloadPositions = <int>[];
    final downloadedModels = <String>[];
    for (var i = 0; i < calls.length; i++) {
      final arguments = calls[i].arguments as Map;
      if (arguments['task'] == 'download') {
        downloadPositions.add(i);
        downloadedModels.add(arguments['model'] as String);
      }
    }
    expect(downloadedModels, ['fr', 'de']);
    final firstTranslation = calls.indexWhere(
      (call) => call.method == 'nlp#startLanguageTranslator',
    );
    expect(
      downloadPositions.every((position) => position < firstTranslation),
      isTrue,
    );
    await service.release(output);
  });

  test(
    'same-language requests copy the SRT without contacting ML Kit',
    () async {
      final output = await service.translateSrtFile(
        inputFile: input,
        sourceLanguage: TranslateLanguage.english,
        targetLanguage: TranslateLanguage.english,
        cancellationToken: TranslationCancellationToken(),
      );
      expect(await output.readAsBytes(), utf8.encode(original));
      expect(calls, isEmpty);
      await service.release(output);
    },
  );

  test(
    'cancels a stuck native text request and still closes the translator',
    () async {
      final token = TranslationCancellationToken();
      final started = Completer<void>();
      final pending = Completer<String>();
      translate = (_) {
        started.complete();
        return pending.future;
      };
      final result = run(token: token);
      final expectation = expectLater(
        result,
        throwsA(isA<TranslationCancelled>()),
      );
      await started.future;
      token.cancel();
      await expectation;
      expect(
        calls.where((call) => call.method == 'nlp#closeLanguageTranslator'),
        hasLength(1),
      );
      pending.completeError(PlatformException(code: 'CLOSED'));
      await Future<void>.delayed(Duration.zero);
    },
  );

  test(
    'cancellation from progress never starts an unobserved model request',
    () async {
      final token = TranslationCancellationToken();
      await expectLater(
        run(
          token: token,
          progress: (progress) {
            if (progress.message.startsWith('Checking')) token.cancel();
          },
        ),
        throwsA(isA<TranslationCancelled>()),
      );
      expect(
        calls.where((call) => call.method == 'nlp#manageLanguageModelModels'),
        isEmpty,
      );
    },
  );
}
