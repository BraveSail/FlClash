//go:build !windows

package main

func ensureInboundUDPRule(string) error {
	return nil
}
