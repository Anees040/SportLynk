import 'package:cloudinary_public/cloudinary_public.dart';
import 'package:flutter/foundation.dart';
import '../constants/app_config.dart';

class CloudinaryService {
  static final CloudinaryService _instance = CloudinaryService._internal();
  factory CloudinaryService() => _instance;
  CloudinaryService._internal();

  final CloudinaryPublic cloudinary = CloudinaryPublic(
    AppConfig.cloudinaryCloudName,
    AppConfig.cloudinaryUploadPreset,
    cache: false,
  );

  Future<String?> uploadImage(String filePath, {String folder = 'general'}) async {
    try {
      if (AppConfig.cloudinaryCloudName.isEmpty || AppConfig.cloudinaryUploadPreset.isEmpty) {
        debugPrint('Cloudinary not configured. Skipping upload (no --dart-define provided).');
        return null;
      }

      CloudinaryResponse response = await cloudinary.uploadFile(
        CloudinaryFile.fromFile(
          filePath,
          resourceType: CloudinaryResourceType.Image,
          folder: folder,
        ),
      );

      return response.secureUrl;
    } catch (e) {
      debugPrint('Cloudinary upload error: $e');
      return null;
    }
  }

  /// Upload a voice note. Cloudinary handles audio under its Video resource type,
  /// so the returned URL lives on the same res.cloudinary.com host the backend
  /// already trusts for chat media.
  Future<String?> uploadAudio(String filePath, {String folder = 'chat_audio'}) async {
    try {
      if (AppConfig.cloudinaryCloudName.isEmpty || AppConfig.cloudinaryUploadPreset.isEmpty) {
        debugPrint('Cloudinary not configured. Skipping audio upload.');
        return null;
      }
      final response = await cloudinary.uploadFile(
        CloudinaryFile.fromFile(
          filePath,
          resourceType: CloudinaryResourceType.Video,
          folder: folder,
        ),
      );
      return response.secureUrl;
    } catch (e) {
      debugPrint('Cloudinary audio upload error: $e');
      return null;
    }
  }

  Future<List<String>> uploadMultipleImages(List<String> filePaths, {String folder = 'venues'}) async {
    final futures = filePaths.map((path) => uploadImage(path, folder: folder));
    final results = await Future.wait(futures);
    return results.whereType<String>().toList();
  }
}
