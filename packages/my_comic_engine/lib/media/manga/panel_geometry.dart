/// 漫画分镜检测的纯几何 / 预处理工具。
///
/// 从已移除的 OCR 检测器里抽出（ticket 21/22）：分镜检测本身保留，但不再需要
/// OCR 的文字检测模型与管线。
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// 分镜检测模型的方形输入边长。
const int kDetInputSize = 640;

/// 原图 -> 模型输入的仿射变换：`dst = src * scale + pad`。
class LetterboxTransform {
  const LetterboxTransform({
    required this.scaleX,
    required this.scaleY,
    required this.padX,
    required this.padY,
    required this.srcWidth,
    required this.srcHeight,
    required this.dstWidth,
    required this.dstHeight,
  });

  final double scaleX;
  final double scaleY;
  final double padX;
  final double padY;
  final int srcWidth;
  final int srcHeight;
  final int dstWidth;
  final int dstHeight;

  double forwardX(double x) => x * scaleX + padX;
  double forwardY(double y) => y * scaleY + padY;
  double inverseX(double x) => (x - padX) / scaleX;
  double inverseY(double y) => (y - padY) / scaleY;
}

/// 计算原图到 [dstWidth]x[dstHeight] 的变换。
LetterboxTransform computeLetterbox(
  int srcWidth,
  int srcHeight, {
  int dstWidth = kDetInputSize,
  int dstHeight = kDetInputSize,
  bool preserveAspect = false,
}) {
  if (srcWidth <= 0 || srcHeight <= 0) {
    throw ArgumentError('invalid source size: ${srcWidth}x$srcHeight');
  }
  if (!preserveAspect) {
    return LetterboxTransform(
      scaleX: dstWidth / srcWidth,
      scaleY: dstHeight / srcHeight,
      padX: 0,
      padY: 0,
      srcWidth: srcWidth,
      srcHeight: srcHeight,
      dstWidth: dstWidth,
      dstHeight: dstHeight,
    );
  }
  final double scale = math.min(dstWidth / srcWidth, dstHeight / srcHeight);
  return LetterboxTransform(
    scaleX: scale,
    scaleY: scale,
    padX: (dstWidth - srcWidth * scale) / 2,
    padY: (dstHeight - srcHeight * scale) / 2,
    srcWidth: srcWidth,
    srcHeight: srcHeight,
    dstWidth: dstWidth,
    dstHeight: dstHeight,
  );
}

/// 按 [transform] 把 [source] 画到目标画布并输出 CHW float32（RGB / 255）。
Float32List rtdetrPreprocess(img.Image source, LetterboxTransform transform) {
  final int dstW = transform.dstWidth;
  final int dstH = transform.dstHeight;
  final int scaledW =
      (transform.srcWidth * transform.scaleX).round().clamp(1, dstW);
  final int scaledH =
      (transform.srcHeight * transform.scaleY).round().clamp(1, dstH);

  img.Image canvas;
  final img.Image resized = img.copyResize(
    source,
    width: scaledW,
    height: scaledH,
    interpolation: img.Interpolation.linear,
  );
  if (scaledW == dstW && scaledH == dstH) {
    canvas = resized;
  } else {
    canvas = img.Image(width: dstW, height: dstH);
    img.fill(canvas, color: img.ColorRgb8(114, 114, 114));
    img.compositeImage(
      canvas,
      resized,
      dstX: transform.padX.round(),
      dstY: transform.padY.round(),
    );
  }

  final Float32List chw = Float32List(3 * dstH * dstW);
  final int planeSize = dstH * dstW;
  int index = 0;
  for (int y = 0; y < dstH; y++) {
    for (int x = 0; x < dstW; x++) {
      final img.Pixel pixel = canvas.getPixel(x, y);
      chw[index] = pixel.r / 255.0;
      chw[planeSize + index] = pixel.g / 255.0;
      chw[2 * planeSize + index] = pixel.b / 255.0;
      index++;
    }
  }
  return chw;
}
