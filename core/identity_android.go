//go:build android && cgo

package main

// platformMachineID is ANDROID_ID, read by the JNI bridge: it lives behind
// Settings.Secure, and the app sandbox offers no file that holds it.
func platformMachineID() string {
	return machineID()
}

// platformOSName is "Android 14" and the like, from android.os.Build.
func platformOSName() string {
	return osName()
}
