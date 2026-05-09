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
      if (AppConfig.cloudinaryCloudName == 'YOUR_CLOUD_NAME') {
        debugPrint('Cloudinary not configured. Skipping upload.');
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

  Future<List<String>> uploadMultipleImages(List<String> filePaths, {String folder = 'venues'}) async {
    List<String> urls = [];
    for (var path in filePaths) {
      final url = await uploadImage(path, folder: folder);
      if (url != null) {
        urls.add(url);
      }
    }
    return urls;
  }
}
