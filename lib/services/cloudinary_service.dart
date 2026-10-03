import 'package:cloudinary_public/cloudinary_public.dart';
import 'package:flutter/foundation.dart';
import '../constants/app_config.dart';

/// The result of one upload: the hosted URL, or the reason it failed.
///
/// Both halves matter. A caller that only learns "null" can tell the user
/// nothing beyond "not sent", and an upload rejected by Cloudinary (a preset
/// that does not allow this resource type, an exhausted quota, a bad key)
/// reports a precise reason that the user — or whoever configured the account —
/// needs to see in order to fix it.
typedef UploadOutcome = ({String? url, String? error});

class CloudinaryService {
  static final CloudinaryService _instance = CloudinaryService._internal();
  factory CloudinaryService() => _instance;
  CloudinaryService._internal();

  final CloudinaryPublic cloudinary = CloudinaryPublic(
    AppConfig.cloudinaryCloudName,
    AppConfig.cloudinaryUploadPreset,
    cache: false,
  );

  /// Upload one file and report either its URL or why it failed.
  ///
  /// This is the single place an upload happens; [uploadImage] and [uploadAudio]
  /// are thin wrappers that discard the reason for callers that have nowhere to
  /// show it. `onProgress` is the uploader's byte-progress callback —
  /// `(sent, total)`, with `total <= 0` until the body is measured.
  Future<UploadOutcome> upload(
    String filePath, {
    required CloudinaryResourceType resourceType,
    String folder = 'general',
    void Function(int sent, int total)? onProgress,
  }) async {
    if (AppConfig.cloudinaryCloudName.isEmpty ||
        AppConfig.cloudinaryUploadPreset.isEmpty) {
      const reason = 'Uploads are not configured in this build';
      debugPrint('[cloudinary] $reason (no --dart-define provided)');
      return (url: null, error: reason);
    }

    try {
      final response = await cloudinary.uploadFile(
        CloudinaryFile.fromFile(
          filePath,
          resourceType: resourceType,
          folder: folder,
        ),
        onProgress: onProgress,
      );
      return (url: response.secureUrl, error: null);
    } on CloudinaryException catch (e) {
      // Cloudinary's own refusal. `message` is the sentence from its JSON error
      // body — "Upload preset not found", "Video uploads are not allowed" — and
      // is the one piece of information that identifies an account-side cause.
      final reason = e.message ?? 'Upload rejected (${e.statusCode})';
      debugPrint('[cloudinary] ${resourceType.name} upload refused: $e');
      return (url: null, error: reason);
    } catch (e) {
      // Transport-level: no network, DNS, a timeout.
      debugPrint('[cloudinary] ${resourceType.name} upload failed: $e');
      return (url: null, error: 'Upload failed — check your connection');
    }
  }

  /// Uploads an image, reporting byte progress when a callback is given. Returns
  /// null on failure; use [upload] where the reason can be shown.
  Future<String?> uploadImage(
    String filePath, {
    String folder = 'general',
    void Function(int sent, int total)? onProgress,
  }) async =>
      (await upload(
        filePath,
        resourceType: CloudinaryResourceType.Image,
        folder: folder,
        onProgress: onProgress,
      ))
          .url;

  /// Upload a voice note. Cloudinary handles audio under its Video resource
  /// type, so the returned URL lives under `/video/upload/` on the same
  /// res.cloudinary.com host the backend already trusts for chat media. An
  /// unsigned preset restricted to images refuses this, which is why [upload]'s
  /// reason is surfaced rather than swallowed.
  Future<String?> uploadAudio(String filePath,
          {String folder = 'chat_audio'}) async =>
      (await upload(
        filePath,
        resourceType: CloudinaryResourceType.Video,
        folder: folder,
      ))
          .url;

  Future<List<String>> uploadMultipleImages(List<String> filePaths,
      {String folder = 'venues'}) async {
    final futures = filePaths.map((path) => uploadImage(path, folder: folder));
    final results = await Future.wait(futures);
    return results.whereType<String>().toList();
  }
}
