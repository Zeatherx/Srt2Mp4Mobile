class EncodingProgress {
  const EncodingProgress({
    this.fraction = 0,
    this.elapsed = Duration.zero,
    this.remaining,
    this.fps = 0,
    this.exporting = false,
  });

  final double fraction;
  final Duration elapsed;
  final Duration? remaining;
  final double fps;
  final bool exporting;
}
