package core

import (
	"context"
	"sync"

	meshident "github.com/metacubex/mihomo/component/mesh"
	"github.com/metacubex/mihomo/component/hubprofile"
	"github.com/metacubex/mihomo/config"
	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/hub"
	"github.com/metacubex/mihomo/hub/executor"
	"github.com/metacubex/mihomo/log"
	"github.com/metacubex/mihomo/common/yaml"

	"os"
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
	updateListeners(currentConfig)
	bumpRouteEpoch()
	configMu.Unlock()
	return nil
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
