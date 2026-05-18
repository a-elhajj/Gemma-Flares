import 'package:flutter/material.dart';
import 'package:image_cropper/image_cropper.dart';

class PhotoCropService {
  const PhotoCropService._();

  static Future<String?> cropImageForUpload({
    required BuildContext context,
    required String sourcePath,
  }) async {
    final colorScheme = Theme.of(context).colorScheme;
    final cropped = await ImageCropper().cropImage(
      sourcePath: sourcePath,
      compressFormat: ImageCompressFormat.jpg,
      compressQuality: 92,
      uiSettings: [
        AndroidUiSettings(
          toolbarTitle: 'Crop photo',
          toolbarColor: colorScheme.surface,
          toolbarWidgetColor: colorScheme.onSurface,
          activeControlsWidgetColor: colorScheme.primary,
          initAspectRatio: CropAspectRatioPreset.original,
          lockAspectRatio: false,
          aspectRatioPresets: const [
            CropAspectRatioPreset.original,
            CropAspectRatioPreset.square,
            CropAspectRatioPreset.ratio3x2,
            CropAspectRatioPreset.ratio4x3,
            CropAspectRatioPreset.ratio16x9,
          ],
        ),
        IOSUiSettings(
          title: 'Crop photo',
          doneButtonTitle: 'Use Photo',
          cancelButtonTitle: 'Cancel',
          aspectRatioLockEnabled: false,
          resetAspectRatioEnabled: true,
          aspectRatioPresets: const [
            CropAspectRatioPreset.original,
            CropAspectRatioPreset.square,
            CropAspectRatioPreset.ratio3x2,
            CropAspectRatioPreset.ratio4x3,
            CropAspectRatioPreset.ratio16x9,
          ],
        ),
        WebUiSettings(
          context: context,
          presentStyle: WebPresentStyle.dialog,
          size: const CropperSize(width: 520, height: 520),
        ),
      ],
    );
    return cropped?.path;
  }
}
