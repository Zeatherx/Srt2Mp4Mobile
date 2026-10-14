import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:google_mlkit_translation/google_mlkit_translation.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../models/encoding_progress.dart';
import '../../models/app_failure.dart';
import '../../models/exported_video.dart';
import '../../models/selected_media.dart';
import '../../services/ffmpeg_service.dart';
import '../../services/file_picker_service.dart';
import '../../services/translation_service.dart';
import '../widgets/video_preview.dart';
import '../widgets/processing_card.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, this.encoder, this.filePicker, this.translator});
  final FFmpegService? encoder;
  final FilePickerService? filePicker;
  final TranslationService? translator;
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late final FilePickerService _picker;
  late final FFmpegService _encoder;
  late final TranslationService _translator;
  late final StreamSubscription<EncodingProgress> _subscription;
  SelectedMedia? _video;
  SelectedMedia? _subtitles;
  ExportedVideo? _output;
  int? _outputSize;
  final _progress = ValueNotifier(const EncodingProgress());
  bool _picking = false;
  bool _encoding = false;
  bool _cancelling = false;
  bool _showOutput = false;
  bool _translationEnabled = false;
  bool _translating = false;
  bool _wifiOnly = true;
  bool _outputTranslated = false;
  TranslateLanguage _sourceLanguage = TranslateLanguage.english;
  TranslateLanguage _targetLanguage = TranslateLanguage.spanish;
  final _translationProgress = ValueNotifier(
    const TranslationProgress('Translating Subtitles...'),
  );
  TranslationCancellationToken? _cancellation;
  Completer<void>? _pipelineDone;
  String? _error;
  String? _notice;

  bool get _busy => _picking || _encoding;
  bool get _sameLanguage =>
      _translationEnabled && _sourceLanguage == _targetLanguage;

  static const _languages = <TranslateLanguage, String>{
    TranslateLanguage.english: 'English',
    TranslateLanguage.spanish: 'Spanish',
    TranslateLanguage.indonesian: 'Indonesian',
    TranslateLanguage.french: 'French',
    TranslateLanguage.german: 'German',
    TranslateLanguage.chinese: 'Chinese',
    TranslateLanguage.japanese: 'Japanese',
    TranslateLanguage.korean: 'Korean',
    TranslateLanguage.portuguese: 'Portuguese',
    TranslateLanguage.italian: 'Italian',
    TranslateLanguage.dutch: 'Dutch',
    TranslateLanguage.russian: 'Russian',
    TranslateLanguage.turkish: 'Turkish',
    TranslateLanguage.vietnamese: 'Vietnamese',
  };

  @override
  void initState() {
    super.initState();
    _picker = widget.filePicker ?? FilePickerService();
    _encoder = widget.encoder ?? FFmpegService();
    _translator = widget.translator ?? TranslationService();
    _subscription = _encoder.progress.listen((value) {
      if (mounted) _progress.value = value;
    });
  }

  Future<void> _select(bool video) async {
    if (_busy) return;
    setState(() {
      _picking = true;
      _error = null;
      _notice = null;
    });
    try {
      final selected = await (video
          ? _picker.pickVideo()
          : _picker.pickSubtitles());
      if (!mounted) {
        await _picker.release(selected?.file);
        return;
      }
      if (selected == null) return;
      final old = video ? _video : _subtitles;
      setState(() {
        if (video) {
          _video = selected;
        } else {
          _subtitles = selected;
        }
        _showOutput = false;
        _output = null;
        _outputSize = null;
        _outputTranslated = false;
        _progress.value = const EncodingProgress();
      });
      await WidgetsBinding.instance.endOfFrame;
      await _picker.release(old?.file);
    } catch (error) {
      if (mounted) setState(() => _error = userFacingError(error));
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  Future<void> _burn() async {
    final video = _video;
    final subtitles = _subtitles;
    if (_busy || video == null || subtitles == null || _sameLanguage) return;
    final token = TranslationCancellationToken();
    final done = Completer<void>();
    _cancellation = token;
    _pipelineDone = done;
    File? translatedFile;
    setState(() {
      _encoding = true;
      _translating = _translationEnabled;
      _translationProgress.value = const TranslationProgress(
        'Translating Subtitles...',
      );
      _cancelling = false;
      _error = null;
      _notice = null;
      _output = null;
      _outputSize = null;
      _outputTranslated = false;
      _showOutput = false;
      _progress.value = const EncodingProgress();
    });
    try {
      if (_translationEnabled) {
        translatedFile = await _translator.translateSrtFile(
          inputFile: subtitles.file,
          sourceLanguage: _sourceLanguage,
          targetLanguage: _targetLanguage,
          cancellationToken: token,
          wifiOnly: _wifiOnly,
          onProgress: (progress) {
            if (mounted) _translationProgress.value = progress;
          },
        );
      }
      token.throwIfCancelled();
      if (!mounted) return;
      setState(() => _translating = false);
      final result = await _encoder.burn(
        video: video.file,
        subtitles: translatedFile ?? subtitles.file,
        duration: video.duration!,
      );
      final size = result.size;
      if (mounted) {
        setState(() {
          _output = result;
          _outputSize = size;
          _outputTranslated = translatedFile != null;
          _showOutput = true;
          _notice = result.storageNotice ?? 'Video exported successfully.';
        });
      }
    } on EncodingCancelled {
      if (mounted) {
        setState(() => _notice = 'Encoding cancelled. You can try again.');
      }
    } on TranslationCancelled {
      if (mounted) {
        setState(() => _notice = 'Translation cancelled. You can try again.');
      }
    } catch (error) {
      if (mounted) setState(() => _error = userFacingError(error));
    } finally {
      try {
        // FFmpeg must have stopped before deleting its translated input.
        await _translator.release(translatedFile);
      } catch (error, stack) {
        debugPrint('Translation cleanup failed: $error\n$stack');
      } finally {
        _cancellation = null;
        done.complete();
        if (mounted) {
          setState(() {
            _encoding = false;
            _translating = false;
            _cancelling = false;
          });
        }
      }
    }
  }

  Future<void> _cancel() async {
    setState(() => _cancelling = true);
    _cancellation?.cancel();
    try {
      await _encoder.cancel();
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = userFacingError(error);
          _cancelling = false;
        });
      }
    }
  }

  @override
  void dispose() {
    _subscription.cancel();
    _progress.dispose();
    _translationProgress.dispose();
    unawaited(_cleanup());
    super.dispose();
  }

  Future<void> _cleanup() async {
    _cancellation?.cancel();
    Future<void> safely(Future<void> Function() operation) async {
      try {
        await operation();
      } catch (error, stack) {
        debugPrint('Screen cleanup failed: $error\n$stack');
      }
    }

    await safely(_encoder.cancel);
    if (_encoding) {
      await safely(() async {
        await _pipelineDone?.future;
      });
    }
    await safely(_encoder.dispose);
    await safely(() => _picker.release(_video?.file));
    await safely(() => _picker.release(_subtitles?.file));
  }

  String _time(Duration? value) {
    if (value == null) return '--';
    final hours = value.inHours;
    final minutes = (value.inMinutes % 60).toString().padLeft(2, '0');
    final seconds = (value.inSeconds % 60).toString().padLeft(2, '0');
    return hours > 0 ? '$hours:$minutes:$seconds' : '$minutes:$seconds';
  }

  String _size(int size) => size >= 1024 * 1024
      ? '${(size / (1024 * 1024)).toStringAsFixed(1)} MB'
      : '${(size / 1024).toStringAsFixed(1)} KB';

  Widget _fileTile({
    required String title,
    required String prompt,
    required IconData icon,
    required SelectedMedia? media,
    required VoidCallback onTap,
    required bool video,
  }) {
    final colors = Theme.of(context).colorScheme;
    return Card(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: media == null ? colors.outline : colors.primary,
        ),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        leading: Icon(icon, size: 30),
        title: Text(
          media?.name ?? title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(
          media == null
              ? prompt
              : '${_size(media.size)} | ${video ? 'Duration' : 'Last cue'} ${_time(media.duration)}',
        ),
        trailing: const Icon(Icons.folder_open_outlined),
        enabled: !_busy,
        onTap: _busy ? null : onTap,
      ),
    );
  }

  Widget _languagePicker(
    String label,
    TranslateLanguage value,
    ValueChanged<TranslateLanguage> onChanged,
  ) {
    final theme = Theme.of(context);
    return DropdownButtonFormField<TranslateLanguage>(
      key: ValueKey(label),
      initialValue: value,
      isExpanded: true,
      dropdownColor: theme.colorScheme.surface,
      style: theme.textTheme.bodyLarge,
      iconEnabledColor: theme.colorScheme.primary,
      decoration: InputDecoration(labelText: label),
      items: [
        for (final entry in _languages.entries)
          DropdownMenuItem(value: entry.key, child: Text(entry.value)),
      ],
      onChanged: _busy
          ? null
          : (language) {
              if (language != null) setState(() => onChanged(language));
            },
    );
  }

  Widget _translationOptions() {
    final theme = Theme.of(context);
    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SwitchListTile.adaptive(
            title: const Text('Translate Subtitles (SRT)'),
            secondary: Icon(Icons.translate, color: theme.colorScheme.primary),
            value: _translationEnabled,
            onChanged: _busy
                ? null
                : (enabled) => setState(() => _translationEnabled = enabled),
          ),
          if (_translationEnabled)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  LayoutBuilder(
                    builder: (context, constraints) {
                      final source = _languagePicker(
                        'Source Language',
                        _sourceLanguage,
                        (language) => _sourceLanguage = language,
                      );
                      final target = _languagePicker(
                        'Target Language',
                        _targetLanguage,
                        (language) => _targetLanguage = language,
                      );
                      return constraints.maxWidth < 440
                          ? Column(
                              children: [
                                source,
                                const SizedBox(height: 16),
                                target,
                              ],
                            )
                          : Row(
                              children: [
                                Expanded(child: source),
                                const SizedBox(width: 16),
                                Expanded(child: target),
                              ],
                            );
                    },
                  ),
                  if (_sameLanguage)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Text(
                        'Choose different source and target languages.',
                        style: TextStyle(color: theme.colorScheme.error),
                      ),
                    ),
                  const SizedBox(height: 12),
                  Text(
                    'Models download once, then translation works offline. Your subtitles stay on your device.',
                    style: theme.textTheme.bodySmall,
                  ),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    activeColor: theme.colorScheme.primary,
                    checkColor: theme.colorScheme.onPrimary,
                    title: const Text('Download models over Wi-Fi only'),
                    value: _wifiOnly,
                    onChanged: _busy
                        ? null
                        : (value) => setState(() => _wifiOnly = value ?? true),
                  ),
                  Text(
                    'Translation by Google ML Kit',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final preview = _showOutput ? _output?.playbackUri : _video?.file.uri;
    return PopScope(
      canPop: !_busy,
      child: Scaffold(
        appBar: AppBar(title: const Text('Srt2Mp4 Mobile')),
        body: SafeArea(
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: ListView(
                padding: const EdgeInsets.all(20),
                children: [
                  Text(
                    'Choose an MP4 and a UTF-8 SRT file to create a permanently subtitled video.',
                    style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: 24),
                  _fileTile(
                    title: 'Select video',
                    prompt: 'MP4 video',
                    icon: Icons.movie_outlined,
                    media: _video,
                    video: true,
                    onTap: () => _select(true),
                  ),
                  const SizedBox(height: 12),
                  _fileTile(
                    title: 'Select subtitles',
                    prompt: 'SRT subtitle file',
                    icon: Icons.subtitles_outlined,
                    media: _subtitles,
                    video: false,
                    onTap: () => _select(false),
                  ),
                  if (_picking)
                    const Padding(
                      padding: EdgeInsets.all(12),
                      child: LinearProgressIndicator(),
                    ),
                  const SizedBox(height: 20),
                  _translationOptions(),
                  if (preview != null && !_encoding) ...[
                    const SizedBox(height: 20),
                    Text(
                      _showOutput ? 'Finished video' : 'Source preview',
                      style: theme.textTheme.titleMedium,
                    ),
                    const SizedBox(height: 10),
                    VideoPreview(key: ValueKey(preview), uri: preview),
                    if (_showOutput && _outputTranslated)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          'Translated by Google',
                          style: theme.textTheme.bodySmall,
                        ),
                      ),
                    if (_output != null)
                      TextButton.icon(
                        onPressed: _busy
                            ? null
                            : () => setState(() => _showOutput = !_showOutput),
                        icon: const Icon(Icons.swap_horiz),
                        label: Text(
                          _showOutput
                              ? 'Preview source'
                              : 'Preview finished video',
                        ),
                      ),
                  ],
                  const SizedBox(height: 24),
                  FilledButton.icon(
                    onPressed:
                        !_busy &&
                            _video != null &&
                            _subtitles != null &&
                            !_sameLanguage
                        ? _burn
                        : null,
                    icon: Icon(
                      _translationEnabled
                          ? Icons.translate
                          : Icons.closed_caption,
                    ),
                    label: const Text('Burn Subtitles'),
                  ),
                  if (_encoding) ...[
                    const SizedBox(height: 20),
                    ProcessingCard(
                      encodingProgress: _progress,
                      translationProgress: _translationProgress,
                      translating: _translating,
                      cancelling: _cancelling,
                      onCancel: _cancel,
                    ),
                  ],
                  if (_notice != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 16),
                      child: Text(
                        _notice!,
                        style: TextStyle(color: theme.colorScheme.primary),
                      ),
                    ),
                  if (_output != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: SelectableText(
                        '${_size(_outputSize ?? 0)}\n${_output!.path}',
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                  if (_error != null) ...[
                    const SizedBox(height: 16),
                    Text(
                      _error!,
                      style: TextStyle(color: theme.colorScheme.error),
                    ),
                    TextButton(
                      onPressed: () async {
                        await openAppSettings();
                      },
                      child: const Text('Open app settings'),
                    ),
                  ],
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 16),
                    child: Text(
                      'Made by Yohanes Harto Sampurno',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Color(0xFFA0AEC0),
                        fontSize: 12,
                        fontWeight: FontWeight.w400,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
