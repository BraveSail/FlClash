package main

import (
	"strings"
	"testing"
)

func TestNetshFirewallAddRuleArgs(t *testing.T) {
	const exePath = `C:\Program Files\FlClash\FlClashCore.exe`
	args := netshFirewallAddRuleArgs(exePath)
	joined := strings.Join(args, " ")
	for _, want := range []string{
		"firewall add rule",
		"name=" + coreFirewallRuleName,
		"dir=in",
		"action=allow",
		"protocol=udp",
		"program=" + exePath,
		"profile=any",
		"enable=yes",
	} {
		if !strings.Contains(joined, want) {
			t.Errorf("add rule args %q do not contain %q", joined, want)
		}
	}

	removeArgs := strings.Join(netshFirewallDeleteRuleArgs(), " ")
	if !strings.Contains(removeArgs, "firewall delete rule") ||
		!strings.Contains(removeArgs, "name="+coreFirewallRuleName) {
		t.Errorf("delete rule args %q do not target the rule by name", removeArgs)
	}
}
