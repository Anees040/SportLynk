/// Cloudinary delivery-time transforms for chat media.
///
/// The uploader hands back the original asset URL. Rendering that
/// full-resolution file inside a small bubble is the "blank box with a long
/// spinner" seen in the thread: a multi-megabyte photo fetched and decoded only
/// to fill a thumbnail. Cloudinary resizes at the edge when the transform sits in
/// the URL path, so a bubble fetches a width-capped, auto-format, auto-quality
/// derivative while the full-screen viewer keeps the untouched original.
///
/// A non-Cloudinary URL, or one that already carries a transform, is returned
/// unchanged, so this is safe to call on any media URL.
library;

const String _cloudinaryHost = 'res.cloudinary.com';
const String _uploadMarker = '/upload/';

/// A bubble-sized derivative: capped width, no upscaling, automatic format and
/// quality. [width] is the Cloudinary pixel cap, not a layout size.
String chatThumbUrl(String url, {int width = 800}) =>
    _withTransform(url, 'c_limit,w_$width,q_auto,f_auto');

/// The full-screen viewer's copy. Still a derivative, not the original: a phone
/// screen is ~1200px on its longest edge even at a high pixel ratio, so fetching
/// a multi-megabyte original to display it is the long black-screen wait the
/// viewer used to show. Capped generously so pinch-zoom still has detail to
/// reveal.
String chatFullUrl(String url, {int width = 1600}) =>
    _withTransform(url, 'c_limit,w_$width,q_auto,f_auto');

String _withTransform(String url, String transform) {
  if (!url.contains(_cloudinaryHost)) return url;
  final i = url.indexOf(_uploadMarker);
  if (i < 0) return url;
  final after = i + _uploadMarker.length;
  final rest = url.substring(after);
  // Already carries a transform segment (begins with a known transform key):
  // leave it rather than stack a second one, which Cloudinary would reject.
  if (rest.startsWith('c_') ||
      rest.startsWith('w_') ||
      rest.startsWith('q_') ||
      rest.startsWith('f_')) {
    return url;
  }
  return '${url.substring(0, after)}$transform/$rest';
}
