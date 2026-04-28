class Detection {
  final String partId;
  final List<double> bbox; // [x, y, w, h] normalized 0..1
  final double confidence;
  final String? name; // optional descriptive name (from inventory or Brickognize)
  final bool matched; // true when partId belongs to the requested inventory

  const Detection({
    required this.partId,
    required this.bbox,
    required this.confidence,
    this.name,
    this.matched = true,
  });

  double get x => bbox[0];
  double get y => bbox[1];
  double get w => bbox[2];
  double get h => bbox[3];

  /// Accepts either:
  ///   - `box_2d`: [ymin, xmin, ymax, xmax] integers 0..1000 (Gemini native)
  ///   - `bbox`:   [x, y, w, h] floats 0..1 (legacy)
  factory Detection.fromJson(Map<String, dynamic> j) {
    List<double> xywh;
    if (j['box_2d'] is List) {
      final raw = j['box_2d'] as List;
      final nums = raw
          .map((e) => (e is num) ? e.toDouble() : 0.0)
          .toList(growable: false);
      if (nums.length == 4) {
        final ymin = nums[0] / 1000.0;
        final xmin = nums[1] / 1000.0;
        final ymax = nums[2] / 1000.0;
        final xmax = nums[3] / 1000.0;
        final x = xmin.clamp(0.0, 1.0);
        final y = ymin.clamp(0.0, 1.0);
        final w = (xmax - xmin).clamp(0.0, 1.0);
        final h = (ymax - ymin).clamp(0.0, 1.0);
        xywh = [x, y, w, h];
      } else {
        xywh = const [0, 0, 0, 0];
      }
    } else {
      final raw = (j['bbox'] as List?) ?? const [];
      final nums = raw
          .map((e) => (e is num) ? e.toDouble() : 0.0)
          .toList(growable: false);
      xywh = nums.length == 4 ? nums : const [0, 0, 0, 0];
    }

    return Detection(
      partId: (j['part_id'] ?? '').toString(),
      bbox: xywh,
      confidence:
          (j['confidence'] is num) ? (j['confidence'] as num).toDouble() : 0.0,
      name: j['name']?.toString(),
      matched: j['matched'] != false, // default true for backward-compat
    );
  }

  Map<String, dynamic> toJson() => {
        'part_id': partId,
        'bbox': bbox,
        'confidence': confidence,
        if (name != null) 'name': name,
        'matched': matched,
      };
}
