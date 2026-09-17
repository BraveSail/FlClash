//go:build !cgo && windows

package main

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/Microsoft/go-winio"
)

// TestCoreLogDeliveryOverIPC drives a built core through the same named-pipe
// IPC the app uses, so the log stream can be inspected without the app:
//
//	FLCLASH_CORE_BIN=FlClashCore.exe go test -run TestCoreLogDeliveryOverIPC -v .
//
// The core only publishes logs while a host is subscribed, which is what the
// app's log switch does, so this also proves that path stays wired.
//
// Point it at a real directory to watch a node report:
//
//	FLCLASH_CORE_BIN=FlClashCore.exe FLCLASH_HARNESS_SECONDS=50 \
//	  FLCLASH_HARNESS_DIRECTORY_URL=https://hub.see.moe \
//	  FLCLASH_HARNESS_DIRECTORY_TOKEN=... FLCLASH_HARNESS_DIRECTORY_ID=pc-debug \
//	  FLCLASH_HARNESS_HEARTBEAT=30 go test -run TestCoreLogDeliveryOverIPC -v .
func TestCoreLogDeliveryOverIPC(t *testing.T) {
	coreBin := os.Getenv("FLCLASH_CORE_BIN")
	if coreBin == "" {
		t.Skip("FLCLASH_CORE_BIN is not set")
	}

	home := t.TempDir()
	directoryURL := envOr("FLCLASH_HARNESS_DIRECTORY_URL", "https://peer-directory.invalid")
	directoryToken := envOr("FLCLASH_HARNESS_DIRECTORY_TOKEN", "debug")
	directoryID := envOr("FLCLASH_HARNESS_DIRECTORY_ID", "pc")
	heartbeat := envOr("FLCLASH_HARNESS_HEARTBEAT", "")
	heartbeatLine := ""
	if heartbeat != "" {
		heartbeatLine = "\n    heartbeat: " + heartbeat
	}
	config := `log-level: debug
mixed-port: 17890
mode: rule
proxies:
  - name: PEER
    type: tailnet-peer
    peer: gt7
    port: 8443
    directory-url: ` + directoryURL + `
    directory-token: ` + directoryToken + `
    directory-id: ` + directoryID + heartbeatLine + `
    proxy:
      type: direct
      name: peer-inner
proxy-groups:
  - name: G
    type: select
    proxies:
      - PEER
      - DIRECT
rules:
  - MATCH,G
`
	if err := os.WriteFile(filepath.Join(home, "config.yaml"), []byte(config), 0o600); err != nil {
		t.Fatal(err)
	}

	pipeName := fmt.Sprintf(`\\.\pipe\FlClashCore_debug_%d`, os.Getpid())
	listener, err := winio.ListenPipe(pipeName, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()

	cmd := exec.Command(coreBin, pipeName)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	defer func() {
		_ = cmd.Process.Kill()
		_, _ = cmd.Process.Wait()
	}()

	type acceptResult struct {
		conn interface {
			Read([]byte) (int, error)
			Write([]byte) (int, error)
			Close() error
			SetWriteDeadline(time.Time) error
		}
		err error
	}
	accepted := make(chan acceptResult, 1)
	go func() {
		raw, err := listener.Accept()
		if err != nil {
			accepted <- acceptResult{err: err}
			return
		}
		conn, ok := raw.(interface {
			Read([]byte) (int, error)
			Write([]byte) (int, error)
			Close() error
			SetWriteDeadline(time.Time) error
		})
		if !ok {
			accepted <- acceptResult{err: fmt.Errorf("unexpected conn type %T", raw)}
			return
		}
		accepted <- acceptResult{conn: conn}
	}()

	var conn interface {
		Read([]byte) (int, error)
		Write([]byte) (int, error)
		Close() error
		SetWriteDeadline(time.Time) error
	}
	select {
	case result := <-accepted:
		if result.err != nil {
			t.Fatal(result.err)
		}
		conn = result.conn
	case <-time.After(15 * time.Second):
		t.Fatal("core never connected to the IPC pipe")
	}
	defer conn.Close()

	send := func(id string, method CoreMethod, args any) {
		var raw json.RawMessage
		if args != nil {
			data, err := json.Marshal(args)
			if err != nil {
				t.Fatal(err)
			}
			raw = data
		}
		data, err := json.Marshal(MethodCall{ID: id, Method: method, Arguments: raw})
		if err != nil {
			t.Fatal(err)
		}
		if _, err := writeFrame(conn, data); err != nil {
			t.Fatal(err)
		}
	}

	logs := make(chan string, 256)
	go func() {
		for {
			data, err := readFrame(conn)
			if err != nil {
				return
			}
			var call struct {
				ID        string          `json:"id"`
				Method    CoreMethod      `json:"method"`
				Arguments json.RawMessage `json:"arguments"`
			}
			if err := json.Unmarshal(data, &call); err != nil {
				fmt.Printf("[harness] unparsed frame: %.200s\n", string(data))
				continue
			}
			if call.Method != messageMethod {
				fmt.Printf("[harness] response id=%s body=%.200s\n", call.ID, string(data))
				continue
			}
			var messages []Message
			if err := json.Unmarshal(call.Arguments, &messages); err != nil {
				fmt.Printf("[harness] unparsed message batch: %.200s\n", string(call.Arguments))
				continue
			}
			for _, message := range messages {
				if message.Type != LogMessage {
					continue
				}
				payload, _ := json.Marshal(message.Data)
				select {
				case logs <- string(payload):
				default:
				}
			}
		}
	}()

	send("1", initClashMethod, InitParams{HomeDir: home, Version: 1})
	send("2", setupConfigMethod, defaultSetupParams())
	time.Sleep(time.Second)
	send("3", startListenerMethod, nil)
	send("4", startLogMethod, nil)
	send("5", forceGcMethod, nil)
	send("6", asyncTestDelayMethod, TestDelayParams{
		ProxyName: "PEER",
		TestUrl:   "https://www.gstatic.com/generate_204",
		Timeout:   5000,
	})

	stop := time.After(time.Duration(envInt("FLCLASH_HARNESS_SECONDS", 12)) * time.Second)
	seen, related := 0, 0
	for {
		select {
		case payload := <-logs:
			seen++
			if strings.Contains(payload, "netmon") || strings.Contains(payload, "PeerDirectory") {
				related++
			}
			switch {
			case strings.Contains(payload, "netmon"):
				fmt.Printf("[netmon] %s\n", payload)
			case strings.Contains(payload, "PeerDirectory"):
				fmt.Printf("[peer-directory] %s\n", payload)
			case seen <= 40:
				fmt.Printf("[core log] %s\n", payload)
			}
		case <-stop:
			fmt.Printf("[harness] core log events: %d (peer-directory/netmon: %d)\n", seen, related)
			if seen == 0 {
				t.Fatal("no core log events arrived over IPC")
			}
			return
		}
	}
}

func envOr(key, fallback string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}
	return fallback
}

func envInt(key string, fallback int) int {
	if value := os.Getenv(key); value != "" {
		if parsed, err := strconv.Atoi(value); err == nil {
			return parsed
		}
	}
	return fallback
}
