//go:build windows

package main

import (
	"fmt"
	"os/exec"
	"strings"
	"syscall"
)

func ensureInboundUDPRule(exePath string) error {
	if exePath == "" {
		return fmt.Errorf("empty core path")
	}
	// netsh appends a second rule for a repeated name, so replace the previous
	// one instead: that also follows the Core to a new path after an update.
	_ = runFirewallCommand(netshFirewallDeleteRuleArgs()...)
	return runFirewallCommand(netshFirewallAddRuleArgs(exePath)...)
}

func runFirewallCommand(args ...string) error {
	cmd := exec.Command("netsh", args...)
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true}
	output, err := cmd.CombinedOutput()
	if err == nil {
		return nil
	}
	text := strings.TrimSpace(string(output))
	if text == "" {
		return err
	}
	return fmt.Errorf("%w: %s", err, text)
}
