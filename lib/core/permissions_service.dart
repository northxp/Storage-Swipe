// lib/core/permissions_service.dart
//
// CORE LAYER
// ----------
// Wraps ALL native permission handshakes behind one simple API:
// `PermissionsService.requestGalleryAccess()`.
//
// Why isolate this instead of calling `PhotoManager.requestPermissionExtend()`
// directly from a widget? Two reasons:
//   1. Testability — a ViewModel/provider can depend on an interface here
//      and be tested with a fake, instead of mocking platform channels.
//   2. Single point of change — if we ever need to layer in
//      `permission_handler` checks (e.g. for Android's granular media
//      permissions on API 33+, or to show a rationale dialog), we only
//      touch this one file.

import 'package:permission_handler/permission_handler.dart' as ph;
import 'package:photo_manager/photo_manager.dart';

/// The three outcomes the rest of the app actually needs to branch on.
///
/// We deliberately collapse `photo_manager`'s more granular
/// `PermissionState` (authorized / limited / denied / restricted) into a
/// smaller enum because the UI only ever needs to know: can we proceed,
/// can we proceed with a reduced set, or do we need to stop and explain?
enum GalleryAccessResult {
  /// Full access to the photo library was granted.
  granted,

  /// iOS "Limited Photos" access — user picked a subset of photos.
  /// The app can still function, just against a smaller library.
  limited,

  /// Access was denied. The caller should show a rationale + a button
  /// that opens app settings via [PermissionsService.openSettings].
  denied,
}

class PermissionsService {
  /// Requests native gallery/photo-library access.
  ///
  /// On iOS this triggers the system Photos permission sheet. On Android
  /// it requests READ_MEDIA_IMAGES (API 33+) or READ_EXTERNAL_STORAGE
  /// (older APIs) — `photo_manager` handles picking the right permission
  /// string for the running OS version internally.
  static Future<GalleryAccessResult> requestGalleryAccess() async {
    final PermissionState state = await PhotoManager.requestPermissionExtend();

    switch (state) {
      case PermissionState.authorized:
        return GalleryAccessResult.granted;
      case PermissionState.limited:
        return GalleryAccessResult.limited;
      case PermissionState.denied:
      case PermissionState.notDetermined:
      case PermissionState.restricted:
        return GalleryAccessResult.denied;
    }
  }

  /// Deletion on Android 11+ (API 30+) requires a *separate* runtime
  /// consent step the OS shows at the moment of deletion (scoped storage).
  /// `photo_manager`'s `PhotoManager.editor.deleteWithIds` triggers that
  /// system dialog automatically, so no extra permission is needed here —
  /// this getter exists mainly as a documented extension point in case a
  /// future OS version requires an explicit pre-check.
  static Future<bool> hasManageStoragePermission() async {
    final status = await ph.Permission.manageExternalStorage.status;
    return status.isGranted;
  }

  /// Opens the OS-level app settings screen so the user can manually grant
  /// permission after a hard denial (where re-requesting won't re-prompt).
  static Future<void> openSettings() async {
    await PhotoManager.openSetting();
  }
}
