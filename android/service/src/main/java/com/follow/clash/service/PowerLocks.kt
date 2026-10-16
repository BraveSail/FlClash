package com.follow.clash.service

import android.content.Context
import android.net.wifi.WifiManager
import android.os.Build
import android.os.PowerManager

/**
 * The locks a VPN needs to keep working once the screen goes off: two Wi-Fi
 * locks (see below) and one partial wake lock.
 *
 * Without them, Android treats this process as idle the moment the display is
 * off: the Wi-Fi radio drops into 802.11 power save, so frames are held and
 * delivered on a wake-up interval instead of immediately, and the CPU is
 * allowed to suspend between those intervals. Both are invisible while the
 * screen is on and both show up as latency - a tunnel, or a mesh peer, that
 * answers in milliseconds becomes one that answers in seconds, or times out.
 *
 * A `WifiLock` is the only way an app can ask the framework to keep Wi-Fi out
 * of power save. The two modes do not mean what their names suggest, so both
 * are requested:
 *
 * - `WIFI_MODE_FULL_HIGH_PERF` (3) is the one that disables power save outright
 *   and with no screen-on condition: `WifiLockManager.setNewMode` calls
 *   `setPowerSave(..., false)` for it, and `canActivateHighPerfLock` only
 *   requires a connected Wi-Fi. **From Android 14 it is silently remapped to
 *   LOW_LATENCY at acquisition** - `acquireWifiLock` rewrites the mode when
 *   `DeviceConfigFacade.isHighPerfLockDeprecated()`, whose default is true.
 *   The remap is visible on-device: a lock requested as mode 3 is listed as
 *   `type=4` and counted under `... full low latency`, never under high perf.
 * - `WIFI_MODE_FULL_LOW_LATENCY` (4) activates only while Wi-Fi is connected,
 *   **the screen is on**, and the owning uid is foreground. A VpnService behind
 *   a screen-off display never satisfies that, and when a condition stops
 *   holding, `setNewMode` runs `setPowerSave(..., true)` again - it turns power
 *   save back on.
 *
 * Both are therefore held: on Android 13 and below the high-perf one really
 * does suppress power save with the screen off, and on Android 14+ it collapses
 * into the low-latency one, which suppresses it while the screen is on. There is
 * no app-side route to suppress it while the screen is off on 14+ - the only
 * escape is the root-only `cmd wifi force-hi-perf-mode`, which the shell uid is
 * explicitly refused. Measured with the screen off, the station still advertises
 * `flags ... WME PS ...` to the AP in `wl sta_info`, and that PS flag is what
 * the screen-off latency is.
 *
 * A partial `WakeLock` covers the other half: it keeps the CPU running without
 * keeping the screen on, which is what a service that must answer packets
 * needs. No lock is reference counted, so a repeated `acquire` cannot leave a
 * count behind that `release` fails to clear.
 */
class PowerLocks(context: Context) {
    private val applicationContext = context.applicationContext
    private val wifiManager =
        applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
    private val powerManager =
        applicationContext.getSystemService(Context.POWER_SERVICE) as? PowerManager

    private var wifiLocks: List<WifiManager.WifiLock> = emptyList()
    private var wakeLock: PowerManager.WakeLock? = null

    fun acquire() {
        acquireWifiLocks()
        acquireWakeLock()
    }

    fun release() {
        releaseWifiLocks()
        releaseWakeLock()
    }

    private fun acquireWifiLocks() {
        if (wifiLocks.isNotEmpty() || wifiManager == null) {
            return
        }
        // Both modes, deliberately. HIGH_PERF is what turns power save off and
        // works with the screen off; LOW_LATENCY is the modern equivalent but
        // the framework only activates it for a foreground app, so on its own it
        // left the radio in power save (seen from the AP as a `PS` flag on this
        // station). Holding both means the power-save half does not depend on
        // which one the vendor's framework decides to honour.
        val modes = buildList {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                add(WifiManager.WIFI_MODE_FULL_LOW_LATENCY)
            }
            @Suppress("DEPRECATION")
            add(WifiManager.WIFI_MODE_FULL_HIGH_PERF)
        }
        wifiLocks = modes.mapNotNull { mode ->
            try {
                wifiManager.createWifiLock(mode, "$WIFI_LOCK_TAG:$mode")?.apply {
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

    private fun releaseWifiLocks() {
        val locks = wifiLocks
        wifiLocks = emptyList()
        for (lock in locks) {
            try {
                if (lock.isHeld) {
                    lock.release()
                }
            } catch (_: RuntimeException) {
            }
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
