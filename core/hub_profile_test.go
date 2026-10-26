package main

import (
	"testing"

	C "github.com/metacubex/mihomo/constant"
)

// A build linked against a hub answers with that hub even when the
// configuration it was started from names none - that is what makes the app
// able to be stock.
func TestABuildCarriesItsHub(t *testing.T) {
	original := C.HubURL
	t.Cleanup(func() { C.HubURL = original })

	C.HubURL = "http://hub.example"
	block := builtInHub()
	if block == nil {
		t.Fatal("a build that names a hub answered with none")
	}
	if block.URL != "http://hub.example" {
		t.Fatalf("url = %q, want the linked hub", block.URL)
	}
	if block.ID == "" {
		t.Fatal("the block carries no device id, so the hub cannot tell who is asking")
	}
	if block.Token != "" {
		t.Fatalf("the block carries a token (%q): a device proves its id with its key", block.Token)
	}
	if block.Keep["mesh.directory-id"] != block.ID {
		t.Fatalf("keep names %v, the device is %q", block.Keep["mesh.directory-id"], block.ID)
	}
}

// A core built without a hub stays a plain core: it must not invent one.
func TestABuildWithoutAHubStaysPlain(t *testing.T) {
	original := C.HubURL
	t.Cleanup(func() { C.HubURL = original })

	C.HubURL = ""
	if block := builtInHub(); block != nil {
		t.Fatalf("a plain build answered with %q", block.URL)
	}
}
