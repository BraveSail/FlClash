package main

import meshident "github.com/metacubex/mihomo/component/mesh"

// The mesh identity is derived inside the core, from the machine itself, so it
// does not have to be written into a profile that runs on every device of the
// mesh. Platforms whose id is readable from Go are probed by the mesh package
// on first use; Android keeps it behind a Java API, so the JNI bridge reads it
// there and it is handed over here before anything parses a configuration.
func init() {
	meshident.SetHostIdentity(platformMachineID(), platformOSName())
}
