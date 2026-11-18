import 'package:flutter/material.dart';

/// mm:ss (1時間以上は h:mm:ss)
String formatDuration(Duration? d) {
  if (d == null) return '--:--';
  final h = d.inHours;
  final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return h > 0 ? '$h:$m:$s' : '$m:$s';
}

/// 丸型ボタン。[filled] で塗りつぶし (再生ボタンや ON 状態に使う)。
class RoundButton extends StatelessWidget {
  const RoundButton({
    super.key,
    this.icon,
    this.text,
    this.label,
    required this.onPressed,
    this.size = 56,
    this.filled = false,
    this.tooltip,
  }) : assert(icon != null || text != null);

  final IconData? icon;

  /// アイコンの代わりに円の中に表示する短い文字 (例: "1.0x")
  final String? text;

  /// 円の下に表示する小さいラベル
  final String? label;
  final VoidCallback? onPressed;
  final double size;
  final bool filled;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final enabled = onPressed != null;
    final fg = filled ? scheme.onPrimary : scheme.primary;
    final border = enabled ? scheme.primary : scheme.outlineVariant;

    final Widget content = icon != null
        ? Icon(icon, size: size * 0.5, color: enabled ? fg : border)
        : Text(
            text!,
            style: TextStyle(
              fontSize: size * 0.24,
              fontWeight: FontWeight.bold,
              color: enabled ? fg : border,
            ),
          );

    final button = Material(
      color: filled ? scheme.primary : Colors.transparent,
      shape: CircleBorder(side: BorderSide(color: border, width: 1.5)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onPressed,
        child: SizedBox.square(
          dimension: size,
          child: Center(child: content),
        ),
      ),
    );

    final body = label == null
        ? button
        : Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              button,
              const SizedBox(height: 6),
              Text(
                label!,
                style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
              ),
            ],
          );

    return Semantics(
      button: true,
      label: tooltip ?? label ?? text,
      child: tooltip == null ? body : Tooltip(message: tooltip!, child: body),
    );
  }
}
