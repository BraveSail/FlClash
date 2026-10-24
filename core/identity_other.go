//go:build !(android && cgo)

package main

// No platform answer on this build: the mesh package probes the machine itself
// (the registry on Windows, /etc/machine-id on Linux, IOPlatformUUID on macOS),
// so nothing is handed over here.
func platformMachineID() string {
	return ""
}

func platformOSName() string {
	return ""
}
