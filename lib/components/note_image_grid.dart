import 'dart:math';

import 'package:better_keep/components/universal_image.dart';
import 'package:better_keep/models/attachments/image_attachment.dart';
import 'package:flutter/material.dart';

/// Custom image builder function type for rendering images in the grid.
/// Used for custom rendering like blurred thumbnails for locked notes.
typedef ImageTileBuilder =
    Widget Function(ImageAttachment image, int index, int total, BoxFit fit);

class NoteImageGrid extends StatelessWidget {
  final List<ImageAttachment> images;
  final Function(ImageAttachment) onImageTap;
  final double maxHeight;
  final double gap;
  final int? noteId;

  /// Optional custom image builder. If provided, this is used instead of the
  /// default image rendering. Useful for showing thumbnails in locked notes.
  final ImageTileBuilder? customImageBuilder;

  const NoteImageGrid({
    super.key,
    required this.images,
    required this.onImageTap,
    this.maxHeight = 400,
    this.gap = 2,
    this.noteId,
    this.customImageBuilder,
  });

  @override
  Widget build(BuildContext context) {
    if (images.isEmpty) return const SizedBox.shrink();

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final layout = _calculateLayout(width, images.length);

        // Ensure we don't exceed maxHeight
        final finalHeight = min(layout.height, maxHeight);

        return SizedBox(
          width: width,
          height: finalHeight,
          child: Stack(
            children: layout.items.asMap().entries.map((entry) {
              final index = entry.key;
              final rect = entry.value;

              return Positioned(
                left: rect.left,
                top: rect.top,
                width: rect.width,
                height: rect.height,
                child: GestureDetector(
                  onTap: () => onImageTap(images[index]),
                  child: _buildImageTile(images[index], index, images.length),
                ),
              );
            }).toList(),
          ),
        );
      },
    );
  }

  Widget _buildImageTile(ImageAttachment image, int index, int total) {
    bool showOverlay = index == 3 && total > 4;
    int remaining = total - 4;

    // Use contain for single images to show full image without cropping
    final fit = total == 1 ? BoxFit.contain : BoxFit.cover;

    // Use custom builder if provided (e.g., for thumbnails in locked notes)
    if (customImageBuilder != null) {
      Widget customWidget = customImageBuilder!(image, index, total, fit);

      if (showOverlay) {
        return Stack(
          fit: StackFit.expand,
          children: [
            customWidget,
            Container(
              color: Colors.black54,
              alignment: Alignment.center,
              child: Text(
                '+$remaining',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        );
      }

      return customWidget;
    }

    Widget imageWidget = UniversalImage(
      path: image.path,
      fit: fit,
      loadingBuilder: (context, child, loadingProgress) {
        if (loadingProgress == null) return child;
        return Center(
          child: CircularProgressIndicator(
            value: loadingProgress.expectedTotalBytes != null
                ? loadingProgress.cumulativeBytesLoaded /
                      loadingProgress.expectedTotalBytes!
                : null,
          ),
        );
      },
      errorBuilder: (context, error, stackTrace) {
        return const Center(child: Icon(Icons.error, color: Colors.red));
      },
    );

    // Wrap in Hero for smooth transition to note editor
    if (noteId != null) {
      imageWidget = Hero(tag: image.path, child: imageWidget);
    }

    return Container(
      decoration: const BoxDecoration(color: Colors.black12),
      child: Stack(
        fit: StackFit.expand,
        children: [
          imageWidget,
          if (showOverlay)
            Container(
              color: Colors.black54,
              alignment: Alignment.center,
              child: Text(
                '+$remaining',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
        ],
      ),
    );
  }

  _GridLayout _calculateLayout(double width, int count) {
    final List<Rect> items = [];
    double height = 0;

    if (count == 0) return _GridLayout(0, []);

    // 1 Image
    if (count == 1) {
      final ratio = images[0].aspectRatio;
      height = width / ratio;
      if (height > maxHeight) height = maxHeight;
      items.add(Rect.fromLTWH(0, 0, width, height));
    }
    // 2 Images
    else if (count == 2) {
      final r1 = images[0].aspectRatio;
      final r2 = images[1].aspectRatio;
      // h * r1 + gap + h * r2 = width
      // h * (r1 + r2) = width - gap
      final h = (width - gap) / (r1 + r2);
      height = h;
      final w1 = h * r1;

      items.add(Rect.fromLTWH(0, 0, w1, h));
      items.add(Rect.fromLTWH(w1 + gap, 0, width - w1 - gap, h));
    }
    // 3 Images
    else if (count == 3) {
      final r1 = images[0].aspectRatio;
      final r2 = images[1].aspectRatio;
      final r3 = images[2].aspectRatio;

      final firstIsLandscape = r1 > 1.2;

      if (firstIsLandscape) {
        // 1 Top (Full), 2 Bottom (Side by Side)
        final h1 = width / r1;

        // Bottom row: similar to 2-image case
        final h2 = (width - gap) / (r2 + r3);
        final w2 = h2 * r2;

        items.add(Rect.fromLTWH(0, 0, width, h1));
        items.add(Rect.fromLTWH(0, h1 + gap, w2, h2));
        items.add(Rect.fromLTWH(w2 + gap, h1 + gap, width - w2 - gap, h2));

        height = h1 + gap + h2;
      } else {
        // 1 Left (Tall), 2 Right (Stacked)
        // w1 + w2 + gap = width
        // hLeft = w1 / r1
        // hRight = w2 / r2 + gap + w2 / r3
        // We want hLeft = hRight
        // (width - gap - w2) / r1 = w2 * (1/r2 + 1/r3) + gap

        final wNet = width - gap;
        final invR1 = 1 / r1;
        final invR2 = 1 / r2;
        final invR3 = 1 / r3;

        // (wNet - w2) * invR1 = w2 * (invR2 + invR3) + gap
        // wNet * invR1 - w2 * invR1 = w2 * (invR2 + invR3) + gap
        // wNet * invR1 - gap = w2 * (invR1 + invR2 + invR3)

        final numerator = wNet * invR1 - gap;
        final denominator = invR1 + invR2 + invR3;

        double w2 = numerator / denominator;

        // Safety check
        if (w2 < 20 || w2 > wNet - 20) {
          // Fallback to Top/Bottom layout if calculation is extreme
          final h1 = width / r1;
          final h2 = (width - gap) / (r2 + r3);
          final scaledImageHeight = h2 * r2;

          items.add(Rect.fromLTWH(0, 0, width, h1));
          items.add(Rect.fromLTWH(0, h1 + gap, scaledImageHeight, h2));
          items.add(
            Rect.fromLTWH(
              scaledImageHeight + gap,
              h1 + gap,
              width - scaledImageHeight - gap,
              h2,
            ),
          );
          height = h1 + gap + h2;
        } else {
          final w1 = wNet - w2;
          final h1 = w1 / r1;
          final h2 = w2 / r2;
          // h3 is determined by remaining space to ensure alignment
          // But h1 should be equal to h2 + gap + h3
          // Let's use h1 as the master height

          items.add(Rect.fromLTWH(0, 0, w1, h1));
          items.add(Rect.fromLTWH(w1 + gap, 0, w2, h2));
          items.add(Rect.fromLTWH(w1 + gap, h2 + gap, w2, h1 - h2 - gap));

          height = h1;
        }
      }
    }
    // 4+ Images
    else {
      // 2 Rows of 2 images (Dynamic widths)
      // Row 1
      final r1 = images[0].aspectRatio;
      final r2 = images[1].aspectRatio;
      final h1 = (width - gap) / (r1 + r2);
      final w1 = h1 * r1;

      items.add(Rect.fromLTWH(0, 0, w1, h1));
      items.add(Rect.fromLTWH(w1 + gap, 0, width - w1 - gap, h1));

      // Row 2
      final r3 = images[2].aspectRatio;
      final r4 = images[3].aspectRatio;
      final h2 = (width - gap) / (r3 + r4);
      final w3 = h2 * r3;

      items.add(Rect.fromLTWH(0, h1 + gap, w3, h2));
      items.add(Rect.fromLTWH(w3 + gap, h1 + gap, width - w3 - gap, h2));

      height = h1 + gap + h2;
    }

    // Scale down if total height exceeds maxHeight
    if (height > maxHeight) {
      final scale = maxHeight / height;
      final newWidth = width * scale;
      final xOffset = (width - newWidth) / 2;

      for (int i = 0; i < items.length; i++) {
        final r = items[i];
        items[i] = Rect.fromLTWH(
          r.left * scale + xOffset,
          r.top * scale,
          r.width * scale,
          r.height * scale,
        );
      }
      height = maxHeight;
    }

    return _GridLayout(height, items);
  }
}

class _GridLayout {
  final double height;
  final List<Rect> items;
  _GridLayout(this.height, this.items);
}
