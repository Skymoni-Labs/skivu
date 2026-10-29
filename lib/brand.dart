import 'package:flutter/material.dart';

const appName = 'Skivu';
// Keep this fallback aligned with pubspec; Android update info uses PackageManager.
const appVersion = '0.2.48';
const brandArtwork = 'assets/branding/skivu-approved.png';

class BrandMark extends StatelessWidget {
  const BrandMark({super.key, this.size = 48});
  final double size;

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(size * .25),
    child: Image.asset(
      brandArtwork,
      width: size,
      height: size,
      fit: BoxFit.cover,
      semanticLabel: appName,
    ),
  );
}
