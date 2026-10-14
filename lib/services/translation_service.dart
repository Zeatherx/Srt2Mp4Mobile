import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:google_mlkit_translation/google_mlkit_translation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/app_failure.dart';
import 'srt_processing.dart';

class TranslationCancelled implements Exception {
  const TranslationCancelled();
  @override
  String toString() => 'Translation cancelled.';
}

/// One token per translation + encoding pipeline, never reused for retries.
class TranslationCancellationToken {
  bool _cancelled = false;
  final _signal = Completer<void>();
  bool get isCancelled => _cancelled;
  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    _signal.complete();
  }

  void throwIfCancelled() {
    if (_cancelled) throw const TranslationCancelled();
  }

  // Model downloads are owned by ML Kit rather than a translator. Stop waiting
  // immediately on cancel; ML Kit may finish caching the model in background.
  Future<T> waitForModel<T>(Future<T> Function() request) {
    throwIfCancelled();
    return Future.any([
      request(),
      _signal.future.then<T>((_) => throw const TranslationCancelled()),
    ]);
  }
}

class TranslationProgress {
  const TranslationProgress(this.message, {this.completed = 0, this.total = 0});
  final String message;
  final int completed;
  final int total;
  double? get fraction => total == 0 ? null : completed / total;
}

class TranslationService {
  final _models = OnDeviceTranslatorModelManager();
  final _temporaryFiles = <String>{};
  bool _running = false;

  /// Native requests already in flight cannot be interrupted by this plugin;
  /// cancellation stops the next operation. Models are reused across jobs.
  Future<File> translateSrtFile({
    required File inputFile,
    required TranslateLanguage sourceLanguage,
    required TranslateLanguage targetLanguage,
    required TranslationCancellationToken cancellationToken,
    ValueChanged<TranslationProgress>? onProgress,
    bool wifiOnly = true,
  }) async {
    if (_running) throw StateError('A translation is already running.');
    _running = true;
    OnDeviceTranslator? translator;
    Directory? workspace;
    var succeeded = false;
    try {
      cancellationToken.throwIfCancelled();
      onProgress?.call(const TranslationProgress('Reading subtitles...'));
      final document = await compute(loadSrtDocument, inputFile.path);
      cancellationToken.throwIfCancelled();
      if (sourceLanguage != targetLanguage) {
        for (final language in {sourceLanguage, targetLanguage}) {
          // English is built in. An English remote model is unsupported.
          if (language == TranslateLanguage.english) continue;
          cancellationToken.throwIfCancelled();
          onProgress?.call(
            TranslationProgress('Checking ${language.name} model...'),
          );
          final downloaded = await cancellationToken.waitForModel(
            () => _models
                .isModelDownloaded(language.bcpCode)
                .timeout(const Duration(seconds: 15)),
          );
          cancellationToken.throwIfCancelled();
          if (!downloaded) {
            onProgress?.call(
              TranslationProgress(
                'Downloading ${language.name} model${wifiOnly ? ' over Wi-Fi' : ''}...',
              ),
            );
            final success = await cancellationToken.waitForModel(
              () => _models
                  .downloadModel(language.bcpCode, isWifiRequired: wifiOnly)
                  .timeout(const Duration(minutes: 5)),
            );
            cancellationToken.throwIfCancelled();
            if (!success) {
              throw AppFailure(
                'Could not download the ${language.name} model. Check your connection and retry.',
              );
            }
          }
        }
        translator = OnDeviceTranslator(
          sourceLanguage: sourceLanguage,
          targetLanguage: targetLanguage,
        );
      }

      final translatedLines = <int, String>{};
      final cache = <String, String>{};
      final total = document.blocks.length;
      onProgress?.call(
        TranslationProgress('Translating Subtitles...', total: total),
      );
      // ML Kit has a single-text API. Sequential cue batches bound native work
      // without joining unrelated cues into one translation request.
      const batchSize = 8;
      final progressClock = Stopwatch()..start();
      for (var batch = 0; batch < total; batch += batchSize) {
        final end = (batch + batchSize).clamp(0, total);
        for (var cue = batch; cue < end; cue++) {
          cancellationToken.throwIfCancelled();
          final block = document.blocks[cue];
          for (var line = 0; line < block.textLines.length; line++) {
            cancellationToken.throwIfCancelled();
            translatedLines[block.firstTextLine + line] = translator == null
                ? block.textLines[line]
                : await _translateLine(
                    block.textLines[line],
                    translator,
                    cache,
                    cancellationToken,
                  );
          }
          if (cue + 1 == total || progressClock.elapsedMilliseconds >= 100) {
            onProgress?.call(
              TranslationProgress(
                'Translating Subtitles...',
                completed: cue + 1,
                total: total,
              ),
            );
            progressClock.reset();
          }
        }
        await Future<void>.delayed(Duration.zero);
      }
      cancellationToken.throwIfCancelled();
      final temporary = await getTemporaryDirectory();
      workspace = await temporary.createTemp('translated_srt_');
      final output = File(p.join(workspace.path, 'subtitles.srt'));
      await compute(writeTranslatedSrt, (
        document,
        translatedLines,
        output.path,
      ));
      cancellationToken.throwIfCancelled();
      _temporaryFiles.add(output.path);
      succeeded = true;
      return output;
    } on TimeoutException catch (error) {
      throw AppFailure(
        'Translation timed out. Check model-download connectivity and retry.',
        details: error.toString(),
      );
    } finally {
      try {
        if (translator != null) {
          await translator.close().timeout(const Duration(seconds: 5));
        }
      } catch (error, stack) {
        // Closing must not hide an original failure or leak a completed file.
        debugPrint('Could not close ML Kit translator: $error\n$stack');
      }
      if (!succeeded && workspace != null) await _removeWorkspace(workspace);
      _running = false;
    }
  }

  static final _formatting = RegExp(r'<[^>\r\n]+>|\{\\[^}\r\n]*\}');
  static final _letter = RegExp(r'\p{L}', unicode: true);

  Future<String> _translateLine(
    String line,
    OnDeviceTranslator translator,
    Map<String, String> cache,
    TranslationCancellationToken token,
  ) async {
    final result = StringBuffer();
    var position = 0;
    for (final tag in _formatting.allMatches(line)) {
      result.write(
        await _translateText(
          line.substring(position, tag.start),
          translator,
          cache,
          token,
        ),
      );
      result.write(tag.group(0));
      position = tag.end;
    }
    result.write(
      await _translateText(line.substring(position), translator, cache, token),
    );
    return result.toString();
  }

  Future<String> _translateText(
    String original,
    OnDeviceTranslator translator,
    Map<String, String> cache,
    TranslationCancellationToken token,
  ) async {
    final text = original.trim();
    if (text.isEmpty || !_letter.hasMatch(text)) return original;
    token.throwIfCancelled();
    var translated = cache[text];
    if (translated == null) {
      translated = (await token.waitForModel(
        () =>
            translator.translateText(text).timeout(const Duration(seconds: 45)),
      )).trim();
      token.throwIfCancelled();
      translated = translated.replaceAll(RegExp(r'[\r\n]+'), ' ');
      if (translated.isEmpty ||
          translated.contains('\u0000') ||
          _formatting.hasMatch(translated)) {
        throw const FormatException(
          'The translator returned invalid subtitle text.',
        );
      }
      if (cache.length < 2048) cache[text] = translated;
    }
    final start = original.indexOf(text);
    return '${original.substring(0, start)}$translated${original.substring(start + text.length)}';
  }

  /// Only accepts files created in a dedicated translateSrtFile job folder.
  Future<void> release(File? translatedFile) async {
    if (translatedFile == null) return;
    if (!_temporaryFiles.contains(translatedFile.path)) {
      throw ArgumentError('Not a translation temporary file.');
    }
    await _removeWorkspace(translatedFile.parent);
    _temporaryFiles.remove(translatedFile.path);
  }

  Future<void> _removeWorkspace(Directory directory) async {
    try {
      if (await directory.exists()) await directory.delete(recursive: true);
    } on FileSystemException catch (error) {
      debugPrint('Could not remove translation temporary files: $error');
    }
  }
}
