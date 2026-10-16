package com.follow.clash.service

import android.content.Context
import android.net.wifi.WifiManager
import android.os.Build
import android.os.PowerManager

/**
 * The two locks a VPN needs to keep working once the screen goes off.
 *
 * Without them, Android treats this process as idle the moment the display is
 * off: the Wi-Fi radio drops into 802.11 power save, so frames are held and
 * delivered on a wake-up interval instead of immediately, and the CPU is
 * allowed to suspend between those intervals. Both are invisible while the
 * screen is on and both show up as latency - a tunnel, or a mesh peer, that
 * answers in milliseconds becomes one that answers in seconds, or times out.
 *
 * A `WifiLock` is the only way an app can ask the framework to keep Wi-Fi out
 * of power save: `dumpsys wifi` reports `mPowerSaveDisableRequests` as the
 * number of held locks, and it reads 0 when nobody holds one. `WIFI_MODE_FULL_LOW_LATENCY`
 * exists precisely for this - it is what a voice call or a game uses - and it
 * supersedes `WIFI_MODE_FULL_HIGH_PERF`, which is deprecated from API 29.
 *
 * A partial `WakeLock` covers the other half: it keeps the CPU running without
 * keeping the screen on, which is what a service that must answer packets
 * needs. Neither lock is reference counted, so a repeated `acquire` cannot
 * leave a count behind that `release` fails to clear.
 */
class PowerLocks(context: Context) {
    private val applicationContext = context.applicationContext
    private val wifiManager =
        applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
    private val powerManager =
        applicationContext.getSystemService(Context.POWER_SERVICE) as? PowerManager

    private var wifiLock: WifiManager.WifiLock? = null
    private var wakeLock: PowerManager.WakeLock? = null

    fun acquire() {
        acquireWifiLock()
        acquireWakeLock()
    }

    fun release() {
        releaseWifiLock()
        releaseWakeLock()
    }

    private fun acquireWifiLock() {
        if (wifiLock != null || wifiManager == null) {
            return
        }
        val mode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            WifiManager.WIFI_MODE_FULL_LOW_LATENCY
        } else {
            @Suppress("DEPRECATION")
            WifiManager.WIFI_MODE_FULL_HIGH_PERF
        }
        wifiLock = try {
            wifiManager.createWifiLock(mode, WIFI_LOCK_TAG)?.apply {
                setReferenceCounted(false)
                acquire()
            }
        } catch (_: SecurityException) {
            // No CHANGE_WIFI_STATE, or the vendor refuses the mode: the VPN
            // still works, it just pays the power-save latency again.
            null
        } catch (_: RuntimeException) {
            null
        }
    }

    private fun acquireWakeLock() {
        if (wakeLock != null || powerManager == null) {
            return
        }
        wakeLock = try {
            powerManager.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, WAKE_LOCK_TAG)?.apply {
                setReferenceCounted(false)
                acquire()
            }
        } catch (_: SecurityException) {
            // No WAKE_LOCK permission: same trade as above, not fatal.
            null
        } catch (_: RuntimeException) {
            null
        }
    }

    private fun releaseWifiLock() {
        val lock = wifiLock ?: return
        wifiLock = null
        try {
            if (lock.isHeld) {
                lock.release()
            }
        } catch (_: RuntimeException) {
        }
    }

    private fun releaseWakeLock() {
        val lock = wakeLock ?: return
        wakeLock = null
        try {
            if (lock.isHeld) {
                lock.release()
            }
        } catch (_: RuntimeException) {
        }
    }

    private companion object {
        const val WIFI_LOCK_TAG = "flclash:vpn:wifi"
        const val WAKE_LOCK_TAG = "flclash:vpn:cpu"
    }
}
