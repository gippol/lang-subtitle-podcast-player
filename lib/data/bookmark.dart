/// 保存した A-B 区間 (苦手なフレーズの復習用)。
class AbBookmark {
  const AbBookmark({
    required this.id,
    required this.trackPath,
    required this.a,
    required this.b,
    this.label = '',
  });

  final String id;
  final String trackPath;
  final Duration a;
  final Duration b;

  /// ユーザーが付けた名前 (空なら区間の時刻を表示する)
  final String label;

  AbBookmark copyWith({String? label}) => AbBookmark(
    id: id,
    trackPath: trackPath,
    a: a,
    b: b,
    label: label ?? this.label,
  );

  Map<String, Object> toJson() => {
    'id': id,
    'track': trackPath,
    'a': a.inMilliseconds,
    'b': b.inMilliseconds,
    'label': label,
  };

  /// 壊れた/不正なデータなら null。
  static AbBookmark? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id'], track = json['track'];
    final a = json['a'], b = json['b'], label = json['label'];
    if (id is! String || track is! String || a is! int || b is! int) {
      return null;
    }
    if (a < 0 || b <= a) return null;
    return AbBookmark(
      id: id,
      trackPath: track,
      a: Duration(milliseconds: a),
      b: Duration(milliseconds: b),
      label: label is String ? label : '',
    );
  }
}

/// 区間リピートの回し方。
class AbRepeatSettings {
  const AbRepeatSettings({this.count = 0, this.gap = Duration.zero});

  /// 区間を再生する回数。0 は無制限。
  final int count;

  /// 1回ごとに入れる無音 (発話練習の時間)。
  final Duration gap;

  static const countOptions = [0, 2, 3, 5, 10];
  static const gapOptions = [
    Duration.zero,
    Duration(seconds: 1),
    Duration(seconds: 2),
    Duration(seconds: 3),
    Duration(seconds: 5),
  ];

  static const maxCount = 99;
  static const maxGap = Duration(seconds: 30);
}
