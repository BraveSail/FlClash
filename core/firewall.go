package main

import (
	"os"
	"sync"

	"github.com/metacubex/mihomo/config"
	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/log"
)

const coreFirewallRuleName = "FlClashCore UDP"

var firewallRuleState = struct {
	sync.Mutex
	exePath string
	failure string
	applied bool
}{}

// The embedded tailscale advertises local UDP endpoints, and Windows drops
// unsolicited inbound UDP from a program without a matching rule. sing-tun
// writes a TCP-only rule for the Core, so the UDP rule is added here on demand.
func ensureTailscaleInboundRule(cfg *config.Config) {
	if !hasTailscaleProxy(cfg) {
		return
	}
	exePath, err := os.Executable()
	if err != nil {
		return
	}

	firewallRuleState.Lock()
	if firewallRuleState.exePath == exePath && firewallRuleState.applied {
		firewallRuleState.Unlock()
		return
	}
	firewallRuleState.exePath = exePath
	firewallRuleState.Unlock()

	err = ensureInboundUDPRule(exePath)

	firewallRuleState.Lock()
	previousFailure := firewallRuleState.failure
	firewallRuleState.applied = err == nil
	if err != nil {
		firewallRuleState.failure = err.Error()
	}
	firewallRuleState.Unlock()

	if err != nil {
		if previousFailure != err.Error() {
			log.Warnln("[Firewall] no inbound UDP rule for %s: %v", exePath, err)
		}
		return
	}
	if previousFailure != "" {
		log.Infoln("[Firewall] %q now allows inbound UDP for %s", coreFirewallRuleName, exePath)
	}
}

func hasTailscaleProxy(cfg *config.Config) bool {
	if cfg == nil {
		return false
	}
	for _, proxy := range cfg.Proxies {
		if proxy.Type() == C.Tailscale {
			return true
		}
	}
	return false
}

func netshFirewallAddRuleArgs(exePath string) []string {
	return []string{
		"advfirewall", "firewall", "add", "rule",
		"name=" + coreFirewallRuleName,
		"dir=in",
		"action=allow",
		"protocol=udp",
		"program=" + exePath,
		"profile=any",
		"enable=yes",
	}
}

func netshFirewallDeleteRuleArgs() []string {
	return []string{
		"advfirewall", "firewall", "delete", "rule",
		"name=" + coreFirewallRuleName,
	}
}
