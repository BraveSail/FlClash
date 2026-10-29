package core

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"os"
	"strings"
	"sync"
	"time"

	"github.com/metacubex/mihomo/common/yaml"
	meshident "github.com/metacubex/mihomo/component/mesh"
	"github.com/metacubex/mihomo/component/hubprofile"
	"github.com/metacubex/mihomo/config"
	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/log"
)

var (
	meshHubMu sync.Mutex
	// meshHubOfferedKey identifies the hub this core has already offered its key
	// to, so a configuration change that leaves the hub alone does not register
	// the device again.
	meshHubOfferedKey string
)

// startMeshHub offers this device's key to the hub its configuration names.
//
// That is all the hub is for. It used to hand out a whole configuration, which
// the core then applied over the one the app had just given it: ports moved,
// groups were rebuilt, selections were cleared, and the apply that answers the
// app's setup waited on it - all a few seconds after every start. The profile
// the app applies is the profile this core runs; the hub only needs to know this
// device so its peers accept it.
func startMeshHub() {
	block := meshHubBlock()
	if block == nil || !block.Enabled() {
		return
	}
	key := block.URL + "\x00" + block.ID

	meshHubMu.Lock()
	if key == meshHubOfferedKey {
		meshHubMu.Unlock()
		return
	}
	meshHubOfferedKey = key
	meshHubMu.Unlock()

	if err := block.Validate(); err != nil {
		log.Warnln("[Profile] the hub block is incomplete, staying on the file: %s", err.Error())
		return
	}

	// Never on the caller's goroutine: this runs from the apply that answers the
	// app's setup, and that answer must not wait on a hub whose route was rebuilt
	// milliseconds ago.
	go registerDeviceKey(*block)
}

func stopMeshHub() {
	meshHubMu.Lock()
	defer meshHubMu.Unlock()
	meshHubOfferedKey = ""
}

// registerDeviceKey offers this device's public key to the hub.
//
// It is idempotent and silent: a device already known answers the same way as
// one that just arrived, and the answer is deliberately empty - a device learns
// it was let in by its next request succeeding, not by a message here.
func registerDeviceKey(block hubprofile.Config) {
	identity := meshident.Derive()
	if identity.ID == "" {
		return
	}
	keys, err := meshident.LoadOrCreateKeys("")
	if err != nil {
		log.Debugln("[Profile] cannot read this device's key: %v", err)
		return
	}
	payload, err := json.Marshal(map[string]string{
		"id":        identity.ID,
		"publicKey": meshident.PublicKeyBase64(keys.Signing),
		"name":      identity.Name,
		"os":        identity.OS,
	})
	if err != nil {
		return
	}
	url := strings.TrimSuffix(block.URL, "/") + "/register"
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(payload))
	if err != nil {
		return
	}
	request.Header.Set("content-type", "application/json")
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		log.Debugln("[Profile] could not register this device: %v", err)
		return
	}
	defer func() { _ = response.Body.Close() }()
	if response.StatusCode/100 != 2 {
		log.Debugln("[Profile] the hub answered %d to this device's registration", response.StatusCode)
	}
}

// meshHubBlock answers which hub this device belongs to: the one its
// configuration names, or - when the configuration names none - the one its
// build was linked against.
func meshHubBlock() *hubprofile.Config {
	if raw := runningRawConfig(); raw != nil && raw.Hub != nil && raw.Hub.URL != "" {
		return raw.Hub
	}
	if C.HubURL == "" {
		return nil
	}
	identity := meshident.Derive()
	if identity.ID == "" {
		log.Warnln("[Profile] this build belongs to %s but it has no key to answer with", C.HubURL)
		return nil
	}
	return &hubprofile.Config{
		URL: C.HubURL,
		ID:  identity.ID,
		Keep: map[string]any{
			"mesh.directory-id": identity.ID,
			"mesh.device-name":  identity.Name,
			"mesh.device-os":    identity.OS,
		},
	}
}

func runningRawConfig() *config.RawConfig {
	buf, err := os.ReadFile(runningConfigPath())
	if err != nil {
		return nil
	}
	var raw config.RawConfig
	if err := yaml.Unmarshal(buf, &raw); err != nil {
		return nil
	}
	return &raw
}
