package core

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	C "github.com/metacubex/mihomo/constant"
)

// shortStack is the first frames of a call chain: enough to name the caller,
// short enough to read in a log tail.
func shortStack() string {
	full := string(stackTrace())
	lines := strings.Split(full, "\n")
	if len(lines) > 14 {
		lines = lines[:14]
	}
	return strings.Join(lines, "\n")
}

// noteCoreEvent writes a line beside the profile.
//
// The app reports a setup it never saw answered, and the core meanwhile applies
// the configuration and serves traffic: from the panel that is "not running",
// from here it is "which stage took longer than the app waits".
func noteCoreEvent(format string, args ...any) {
	home := strings.TrimSpace(C.Path.HomeDir())
	if home == "" {
		return
	}
	line := time.Now().Format(time.RFC3339) + "  " + fmt.Sprintf(format, args...) + "\n"
	file, err := os.OpenFile(filepath.Join(home, "core-events.log"), os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		return
	}
	_, _ = file.WriteString(line)
	_ = file.Close()
}
