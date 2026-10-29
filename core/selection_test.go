package core

import (
	"testing"

	"github.com/metacubex/mihomo/config"
	"github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/tunnel"
)

// A configuration the hub pushes rebuilds every group, so a selector comes back
// on its first member. What the device picked must survive that rebuild.
func TestARebuiltGroupKeepsTheDevicePick(t *testing.T) {
	resetSelectionForTest()
	t.Cleanup(resetSelectionForTest)

	first := selectorGroup(t, "group", "node-a", "node-b")
	tunnel.UpdateProxies(map[string]constant.Proxy{"group": first}, nil)
	t.Cleanup(func() { tunnel.UpdateProxies(nil, nil) })

	rememberSelection(map[string]string{"group": "node-b"})
	patchSelectGroup(map[string]string{"group": "node-b"})
	if got := groupNow(t, first); got != "node-b" {
		t.Fatalf("group resolved to %q, want the pick", got)
	}

	rebuilt := selectorGroup(t, "group", "node-a", "node-b")
	tunnel.UpdateProxies(map[string]constant.Proxy{"group": rebuilt}, nil)
	if got := groupNow(t, rebuilt); got != "node-a" {
		t.Fatalf("a rebuilt group starts on %q, want its first member", got)
	}

	restoreSelection()
	if got := groupNow(t, rebuilt); got != "node-b" {
		t.Fatalf("group resolved to %q after the rebuild, want the pick put back", got)
	}
}

// A pick for a group the pushed configuration no longer has is not an error and
// must not take the rest of the picks with it.
func TestRestoreSelectionIgnoresGroupsThatAreGone(t *testing.T) {
	resetSelectionForTest()
	t.Cleanup(resetSelectionForTest)

	group := selectorGroup(t, "group", "node-a", "node-b")
	tunnel.UpdateProxies(map[string]constant.Proxy{"group": group}, nil)
	t.Cleanup(func() { tunnel.UpdateProxies(nil, nil) })

	rememberSelection(map[string]string{"group": "node-b", "gone": "node-z"})
	restoreSelection()
	if got := groupNow(t, group); got != "node-b" {
		t.Fatalf("group resolved to %q, want the pick despite a group that is gone", got)
	}
}

func resetSelectionForTest() {
	selectionMu.Lock()
	lastSelectedMap = map[string]string{}
	hasSelection = false
	selectionMu.Unlock()
}

// The app's profile never says store-selected, and the zero value turns the
// cache off - which is what made every rebuild of the groups start at the top
// of the list. Every configuration the core runs keeps the picks; this pins the
// decision on a config parsed from a profile like the app's, where the field is
// present and false.
func TestPlatformLimitsKeepThePicks(t *testing.T) {
	// A profile that says nothing about it, which is what the app hands over.
	var raw config.RawConfig
	cfg := &config.Config{
		NTP:     &config.NTP{},
		Profile: &config.Profile{StoreSelected: raw.Profile.StoreSelected},
	}
	if cfg.Profile.StoreSelected {
		t.Fatal("a profile that says nothing must start with the cache off")
	}
	if !withPlatformLimits(cfg).Profile.StoreSelected {
		t.Fatal("a configuration handed to the core must keep the selected cache on")
	}
}
