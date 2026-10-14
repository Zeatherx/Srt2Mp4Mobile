import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../models/encoding_progress.dart';
import '../../services/translation_service.dart';

/// Only this subtree listens to frequent progress changes.
class ProcessingCard extends StatelessWidget {
  const ProcessingCard({
    super.key,
    required this.encodingProgress,
    required this.translationProgress,
    required this.translating,
    required this.cancelling,
    required this.onCancel,
  });
  final ValueListenable<EncodingProgress> encodingProgress;
  final ValueListenable<TranslationProgress> translationProgress;
  final bool translating;
  final bool cancelling;
  final VoidCallback onCancel;

  String _time(Duration? value) {
    if (value == null) return '--';
    final minutes = (value.inMinutes % 60).toString().padLeft(2, '0');
    final seconds = (value.inSeconds % 60).toString().padLeft(2, '0');
    return value.inHours > 0
        ? '${value.inHours}:$minutes:$seconds'
        : '$minutes:$seconds';
  }

  @override
  Widget build(
    BuildContext context,
  ) => ValueListenableBuilder<EncodingProgress>(
    valueListenable: encodingProgress,
    builder: (context, progress, _) =>
        ValueListenableBuilder<TranslationProgress>(
          valueListenable: translationProgress,
          builder: (context, translation, _) {
            final theme = Theme.of(context);
            return Card(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      cancelling
                          ? 'Cancelling...'
                          : translating
                          ? 'Translating Subtitles...'
                          : progress.exporting
                          ? 'Saving video...'
                          : 'Encoding ${(progress.fraction * 100).floor()}%',
                      style: theme.textTheme.titleMedium,
                    ),
                    const SizedBox(height: 16),
                    LinearProgressIndicator(
                      value: translating
                          ? translation.fraction
                          : progress.exporting
                          ? null
                          : progress.fraction,
                      minHeight: 8,
                      borderRadius: BorderRadius.circular(8),
                      semanticsLabel: translating
                          ? 'Translation progress'
                          : progress.exporting
                          ? 'Saving video'
                          : 'Encoding progress',
                    ),
                    const SizedBox(height: 12),
                    if (translating) ...[
                      Text(
                        translation.message,
                        style: theme.textTheme.bodySmall,
                      ),
                      if (translation.total > 0)
                        Text(
                          '${translation.completed} / ${translation.total} cues',
                        ),
                    ] else if (progress.exporting)
                      Text(
                        'Saving your finished video to the export folder.',
                        style: theme.textTheme.bodySmall,
                      )
                    else
                      Wrap(
                        spacing: 18,
                        runSpacing: 8,
                        children: [
                          Text('Elapsed ${_time(progress.elapsed)}'),
                          Text('Remaining ~ ${_time(progress.remaining)}'),
                          Text('${progress.fps.toStringAsFixed(1)} FPS'),
                        ],
                      ),
                    const SizedBox(height: 12),
                    Text(
                      'Keep the app open until processing finishes.',
                      style: theme.textTheme.bodySmall,
                    ),
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      onPressed: cancelling ? null : onCancel,
                      icon: const Icon(Icons.stop_circle_outlined),
                      label: const Text('Cancel'),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
  );
}
