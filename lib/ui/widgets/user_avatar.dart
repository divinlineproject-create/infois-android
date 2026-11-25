import 'package:flutter/material.dart';

/// Foto profil pengguna (foto akun Google); tanpa foto atau gagal dimuat:
/// inisial nama.
class UserAvatar extends StatelessWidget {
  const UserAvatar({super.key, required this.name, this.url, this.size = 40});

  final String name;
  final String? url;
  final double size;

  /// Inisial nama ("Sri Wahyuni" → "SW").
  static String initialsOf(String name) {
    final parts = name.trim().split(RegExp(r'\s+')).where((part) => part.isNotEmpty).toList();
    if (parts.isEmpty) {
      return '?';
    }
    return (parts.length == 1 ? parts.first.substring(0, 1) : '${parts.first[0]}${parts.last[0]}').toUpperCase();
  }

  static bool isPhotoUrl(String? url) => url != null && (url.startsWith('https://') || url.startsWith('http://'));

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final initials = Center(
      child: Text(initialsOf(name), style: TextStyle(fontSize: size * 0.36, fontWeight: FontWeight.w700, color: scheme.onPrimaryContainer)),
    );
    return Container(
      width: size,
      height: size,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(shape: BoxShape.circle, color: scheme.primaryContainer),
      child: isPhotoUrl(url)
          ? Image.network(
              url!,
              key: const Key('user-avatar-photo'),
              width: size,
              height: size,
              fit: BoxFit.cover,
              gaplessPlayback: true,
              errorBuilder: (_, __, ___) => initials,
              frameBuilder: (_, child, frame, loaded) => loaded || frame != null ? child : initials,
            )
          : initials,
    );
  }
}
