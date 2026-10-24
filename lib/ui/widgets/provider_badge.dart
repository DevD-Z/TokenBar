import 'package:flutter/material.dart';
import 'package:tokenbar_core/tokenbar_core.dart';

/// App-icon style badge: rounded square with a soft brand-color gradient.
class ProviderBadge extends StatelessWidget {
  const ProviderBadge({super.key, required this.providerId, this.size = 32});

  final String providerId;
  final double size;

  @override
  Widget build(BuildContext context) {
    final provider = ProviderRegistry.instance.byId(providerId);
    final color = Color(provider?.brandColor ?? 0xFF64748B);
    final name = provider?.displayName ?? providerId;
    final hsl = HSLColor.fromColor(color);
    final top = hsl.withLightness((hsl.lightness + 0.08).clamp(0, 1)).toColor();
    final bottom = hsl.withLightness((hsl.lightness - 0.08).clamp(0, 1)).toColor();
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [top, bottom],
        ),
        borderRadius: BorderRadius.circular(size * 0.28),
        boxShadow: [
          BoxShadow(
            color: color.withValues(alpha: 0.28),
            blurRadius: size * 0.2,
            offset: Offset(0, size * 0.06),
          ),
        ],
      ),
      child: Text(
        name.isEmpty ? '?' : name.characters.first.toUpperCase(),
        style: TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w700,
          fontSize: size * 0.46,
          height: 1.1,
        ),
      ),
    );
  }
}
