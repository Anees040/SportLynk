package com.example.sportlynk

import android.app.NotificationChannel
import android.app.NotificationManager
import android.os.Build
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity

/**
 * S.7 Wave C — creates the notification channel FCM delivers on.
 *
 * WHY THIS IS NATIVE CODE AND NOT A PLUGIN
 * On Android 8.0+ a notification MUST belong to a channel, and a channel must be
 * created by the app before the first notification arrives — the manifest's
 * `default_notification_channel_id` only names one, it does not create it. If the
 * channel is missing, the Firebase SDK quietly falls back to its own
 * `fcm_fallback_notification_channel` at DEFAULT importance, which means
 * `android.notification.priority = 'max'` on the server has no effect: a booking
 * approval would land silently in the shade instead of as a heads-up banner.
 *
 * The alternative was adding `flutter_local_notifications` purely to call its
 * `createNotificationChannel`. That plugin requires Java-8 core-library desugaring
 * in the Gradle config, which is a build-level change to a release pipeline that
 * currently works — a poor trade for fifteen lines of platform code that the
 * Android framework has exposed since API 26.
 *
 * `sportlynk_default` is the same string as `ANDROID_CHANNEL` in
 * `backend/src/services/pushService.js`. The two must match exactly: the server
 * stamps `channelId` on every message, and a channel id that does not exist here is
 * the fallback case above.
 */
class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        createDefaultChannel()
    }

    private fun createDefaultChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            "Match & booking alerts",
            // HIGH, not DEFAULT: this is the channel that carries booking approvals,
            // challenge invites and no-show warnings — the notifications that are
            // time-critical and that the server marks `priority: 'high'`. A user who
            // disagrees can turn the channel down in Android settings, which is the
            // right place for that decision; the app cannot raise it later.
            NotificationManager.IMPORTANCE_HIGH,
        ).apply {
            description = "Bookings, challenges, tournaments and chat from SportLynk"
            enableVibration(true)
            setShowBadge(true)
        }
        // Creating an existing channel is a documented no-op, so this is safe on
        // every launch and needs no "have I done this?" flag.
        getSystemService(NotificationManager::class.java)
            ?.createNotificationChannel(channel)
    }

    private companion object {
        /** Must equal ANDROID_CHANNEL in backend/src/services/pushService.js. */
        const val CHANNEL_ID = "sportlynk_default"
    }
}
