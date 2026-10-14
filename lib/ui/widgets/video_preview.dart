import 'dart:io';
import 'dart:async';

import 'package:chewie/chewie.dart';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

/// Key by URI so each source owns one pair of controllers.
class VideoPreview extends StatefulWidget {
  const VideoPreview({super.key, required this.uri});
  final Uri uri;

  @override
  State<VideoPreview> createState() => _VideoPreviewState();
}

class _VideoPreviewState extends State<VideoPreview>
    with WidgetsBindingObserver {
  late final VideoPlayerController _video;
  ChewieController? _chewie;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _video = widget.uri.scheme == 'content'
        ? VideoPlayerController.contentUri(widget.uri)
        : VideoPlayerController.file(File.fromUri(widget.uri));
    _initialize();
  }

  Future<void> _initialize() async {
    try {
      await _video.initialize();
      if (!mounted) return;
      setState(
        () => _chewie = ChewieController(
          videoPlayerController: _video,
          autoPlay: false,
          looping: false,
          aspectRatio: _video.value.aspectRatio,
          allowFullScreen: true,
          errorBuilder: (_, message) => Center(child: Text(message)),
        ),
      );
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) unawaited(_pauseSafely());
  }

  Future<void> _pauseSafely() async {
    try {
      await _video.pause();
    } catch (error) {
      debugPrint('Preview pause failed: $error');
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _chewie?.dispose();
    unawaited(_disposeVideo());
    super.dispose();
  }

  Future<void> _disposeVideo() async {
    try {
      await _video.dispose();
    } catch (error) {
      debugPrint('Preview disposal failed: $error');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Text('This device cannot preview the video.\n$_error'),
      );
    }
    final player = _chewie;
    return AspectRatio(
      aspectRatio: player == null ? 16 / 9 : _video.value.aspectRatio,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: ColoredBox(
          color: Colors.black,
          child: player == null
              ? const Center(child: CircularProgressIndicator())
              : Chewie(controller: player),
        ),
      ),
    );
  }
}
