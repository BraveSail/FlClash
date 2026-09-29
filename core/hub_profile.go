package main

import (
	"context"
	"os"
	"sync"

	"gopkg.in/yaml.v3"

	"github.com/metacubex/mihomo/component/hubprofile"
	"github.com/metacubex/mihomo/config"
	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/hub"
	"github.com/metacubex/mihomo/hub/executor"
	"github.com/metacubex/mihomo/log"
)

var (
	hubProfileMu     sync.Mutex
	hubProfileCancel context.CancelFunc
	// hubProfileKey identifies the hub channel that is running, so a
	// configuration change that leaves it alone does not restart it - a restart
	// would drop the watch socket and re-pull a profile that has not changed.
	hubProfileKey string
)

// startHubProfile keeps this device's configuration in step with the hub that
// owns it, when the configuration that was just applied asks for one.
//
// A device that runs this core without the app had no way to be given a
// configuration: the core reads its file once and never looks again, so the
// pull and the push both lived in the app, and a box running the kernel alone -
// an ONT, a router - could only ever be configured by hand and by restart.
//
// Called from every configuration apply, so it is idempotent: the same hub
// leaves the running channel alone, and a changed one replaces it.
func startHubProfile() {
	block := hubBlockFromAppliedConfig()
	key := ""
	if block.Enabled() {
		key = block.URL + "\x00" + block.ID + "\x00" + block.Token
	}

	hubProfileMu.Lock()
	if key == hubProfileKey {
		hubProfileMu.Unlock()
		return
	}
	// The old channel, if any, belongs to a configuration that is no longer
	// running: its socket would keep pushing the previous hub's profile.
	if hubProfileCancel != nil {
		hubProfileCancel()
		hubProfileCancel = nil
	}
	hubProfileKey = key
	hubProfileMu.Unlock()

	if key == "" {
		return
	}
	if err := block.Validate(); err != nil {
		log.Warnln("[Profile] the hub block is incomplete, staying on the file: %s", err.Error())
		return
	}

	ctx, cancel := context.WithCancel(context.Background())
	client, err := hubprofile.New(*block, func(pulled []byte) error {
		// ParseWithBytes, not a reload of the file: the pulled YAML is a whole
		// configuration, and re-reading would take the file this one is written
		// beside.
		parsed, err := executor.ParseWithBytes(pulled)
		if err != nil {
			return err
		}
		hub.ApplyConfig(parsed)
		return nil
	})
	if err != nil {
		log.Warnln("[Profile] %s", err.Error())
		cancel()
		return
	}

	hubProfileMu.Lock()
	hubProfileCancel = cancel
	hubProfileMu.Unlock()
	log.Infoln("[Profile] this device takes its configuration from %s as %q", block.URL, block.ID)
	client.Start(ctx)
}

// hubBlockFromAppliedConfig reads the hub block out of the configuration the
// core is running.
//
// From the file rather than the parsed configuration: the parsed one keeps only
// what the core runs, and this block describes how the core is to be kept up to
// date, which is not part of that.
func hubBlockFromAppliedConfig() *hubprofile.Config {
	buf, err := os.ReadFile(C.Path.Config())
	if err != nil {
		// A core started with a configuration string or from stdin has no file
		// to read; it is also a core the app owns and drives, so the channel is
		// the app's to run.
		log.Debugln("[Profile] no configuration file to read a hub block from: %s", err.Error())
		return nil
	}
	var raw config.RawConfig
	if err := yaml.Unmarshal(buf, &raw); err != nil {
		log.Debugln("[Profile] the configuration could not be read for a hub block: %s", err.Error())
		return nil
	}
	return raw.Hub
}
