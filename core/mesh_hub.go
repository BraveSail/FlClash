package core

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	meshident "github.com/metacubex/mihomo/component/mesh"
	"github.com/metacubex/mihomo/component/hubprofile"
	"github.com/metacubex/mihomo/common/yaml"
	"github.com/metacubex/mihomo/config"
	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/hub"
	"github.com/metacubex/mihomo/hub/executor"
	"github.com/metacubex/mihomo/log"
)

var (
	meshHubMu     sync.Mutex
	meshHubCancel context.CancelFunc
	// meshHubKey identifies the channel that is running, so a configuration
	// change that leaves the hub alone does not restart it.
	meshHubKey string
)

// startMeshHub keeps this device's configuration in step with the hub that owns
// it, when the configuration that was just applied asks for one - or when the
// build itself names a hub and the configuration says nothing.
//
// Called from every configuration apply, so it is idempotent: the same hub
// leaves the running channel alone, and a changed one replaces it.
func startMeshHub() {
	block := meshHubBlock()
	if block == nil || !block.Enabled() {
		stopMeshHub()
		return
	}
	key := block.URL + "\x00" + block.ID + "\x00" + block.Token

	meshHubMu.Lock()
	if key == meshHubKey {
		meshHubMu.Unlock()
		return
	}
	if meshHubCancel != nil {
		meshHubCancel()
		meshHubCancel = nil
	}
	meshHubKey = key
	meshHubMu.Unlock()

	if err := block.Validate(); err != nil {
		log.Warnln("[Profile] the hub block is incomplete, staying on the file: %s", err.Error())
		return
	}

	// First contact is a registration, not a pull: the hub only hands a
	// profile to a device whose key it knows, and it only knows a key that was
	// offered. A device that has never been seen registers itself and waits to
	// be let in; the next attempt - the poll, a minute later - is signed and
	// succeeds.
	registerDeviceKey(*block)

	ctx, cancel := context.WithCancel(context.Background())
	client, err := hubprofile.New(*block, applyPushedProfile)
	if err != nil {
		log.Warnln("[Profile] %s", err.Error())
		cancel()
		return
	}

	meshHubMu.Lock()
	meshHubCancel = cancel
	meshHubMu.Unlock()
	log.Infoln("[Profile] this device takes its configuration from %s as %q", block.URL, block.ID)
	client.Start(ctx)
	go publishLoop(ctx, *block)
}

// publishLoop keeps the app's own profile file equal to the configuration this
// device runs.
//
// The pull only calls back when the hub's answer changes, and an unchanged
// answer is a 304 with no callback at all - so a device that started before the
// app wrote its profile would never bring the two together. Watching the file
// the pull keeps is what makes the app's view follow the core's, whatever the
// hub happens to answer.
func publishLoop(ctx context.Context, block hubprofile.Config) {
	id := strings.TrimSpace(block.ID)
	if id == "" {
		return
	}
	path := block.File
	if strings.TrimSpace(path) == "" {
		path = filepath.Join(C.Path.HomeDir(), "profile-"+id+".yaml")
	}
	publish := func() {
		pulled, err := os.ReadFile(path)
		if err != nil || len(pulled) == 0 {
			return
		}
		publishToAppProfile(pulled)
	}
	publish()
	ticker := time.NewTicker(30 * time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			publish()
		}
	}
}

func stopMeshHub() {
	meshHubMu.Lock()
	defer meshHubMu.Unlock()
	if meshHubCancel != nil {
		meshHubCancel()
		meshHubCancel = nil
	}
	meshHubKey = ""
}

// applyPushedProfile installs a whole configuration the hub pushed, through the
// same executor the app's own updates use.
func applyPushedProfile(pulled []byte) error {
	parsed, err := executor.ParseWithBytes(pulled)
	if err != nil {
		return err
	}
	configMu.Lock()
	currentConfig = withPlatformLimits(parsed)
	hub.ApplyConfig(currentConfig)
	// The pushed configuration's groups start at their first member; the picks
	// the device already made are not part of it and would be lost here.
	restoreSelection()
	updateListeners(currentConfig)
	bumpRouteEpoch()
	configMu.Unlock()
	// The app reads a profile from its own file, not from the core: its proxy
	// list, its groups and its rules all come from there. A core that keeps the
	// pulled profile to itself leaves the app showing whatever it was installed
	// with, which is how a device ends up "connected" with an empty proxy page.
	publishToAppProfile(pulled)
	return nil
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
