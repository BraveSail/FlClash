package core

import (
	"encoding/json"
	"os"
	"path/filepath"
	"regexp"
	"runtime"
	"strconv"
	"strings"

	"github.com/metacubex/mihomo/log"
)

// publishToAppProfile writes the configuration this device pulled where the app
// keeps the profile it shows.
//
// The app and the core read different things. The core is handed a
// configuration and runs it; the app reads a profile file, and everything it
// draws - the proxy list, the groups, the rules - comes from that file. A core
// that pulled a fresh configuration and kept it to itself left the app showing
// whatever it was installed with, so a device could be carrying traffic while
// its proxy page said "no proxies".
//
// The file is named by the app's own currentProfileId, kept in its preferences,
// and is written only when that id is known: guessing a name would mean writing
// a profile the app never reads.
func publishToAppProfile(pulled []byte) {
	dir, profiles, ok := appDataDir()
	if !ok {
		return
	}
	id := currentProfileID(dir)
	if id == "" {
		return
	}
	path := filepath.Join(profiles, id+".yaml")
	if existing, err := os.ReadFile(path); err == nil && string(existing) == string(pulled) {
		return
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		log.Debugln("[Profile] cannot reach the app's profile directory: %v", err)
		return
	}
	// Written beside the target and renamed, so a reader never sees half a
	// profile: the app may open this file while the core is replacing it.
	temporary := path + ".pulling"
	if err := os.WriteFile(temporary, pulled, 0o644); err != nil {
		log.Debugln("[Profile] cannot stage the app's profile: %v", err)
		return
	}
	if err := os.Rename(temporary, path); err != nil {
		_ = os.Remove(temporary)
		log.Debugln("[Profile] cannot replace the app's profile: %v", err)
		return
	}
	log.Infoln("[Profile] the app's profile now carries what the hub publishes (%s)", filepath.Base(path))
}

// appDataDir answers where the app keeps its preferences and its profile files.
//
// The two layouts differ: the desktop app holds profiles directly under its
// support directory, while the android app holds them under the files directory
// the platform hands it.
func appDataDir() (dir string, profiles string, ok bool) {
	if runtime.GOOS == "android" {
		// The core runs as the app's own user, so the app's directory is its own.
		const base = "/data/data/com.follow.clash"
		dir = filepath.Join(base, "files")
		profiles = filepath.Join(dir, "profiles")
		if info, err := os.Stat(profiles); err == nil && info.IsDir() {
			return dir, profiles, true
		}
		return "", "", false
	}
	base, err := os.UserConfigDir()
	if err != nil {
		return "", "", false
	}
	dir = filepath.Join(base, "com.follow", "clash")
	profiles = filepath.Join(dir, "profiles")
	if info, err := os.Stat(profiles); err == nil && info.IsDir() {
		return dir, profiles, true
	}
	return "", "", false
}

// currentProfileID answers which profile the app is showing.
//
// Desktop builds keep preferences in a json file; android keeps them in the
// platform's xml. Both name the id the same way, because it is the same plugin
// underneath.
func currentProfileID(dir string) string {
	if raw, err := os.ReadFile(filepath.Join(dir, "shared_preferences.json")); err == nil {
		if id := profileIDFromJSON(raw); id != "" {
			return id
		}
	}
	if runtime.GOOS == "android" {
		if raw, err := os.ReadFile("/data/data/com.follow.clash/shared_prefs/FlutterSharedPreferences.xml"); err == nil {
			return profileIDFromXML(string(raw))
		}
	}
	return ""
}

func profileIDFromJSON(raw []byte) string {
	var preferences map[string]any
	if err := json.Unmarshal(raw, &preferences); err != nil {
		return ""
	}
	config, ok := preferences["flutter.config"]
	if !ok {
		return ""
	}
	if text, ok := config.(string); ok {
		var parsed map[string]any
		if err := json.Unmarshal([]byte(text), &parsed); err != nil {
			return ""
		}
		return numericID(parsed["currentProfileId"])
	}
	if parsed, ok := config.(map[string]any); ok {
		return numericID(parsed["currentProfileId"])
	}
	return ""
}

var preferenceString = regexp.MustCompile(`name="flutter\.currentProfileId"[^>]*>([0-9]+)<`)

func profileIDFromXML(raw string) string {
	match := preferenceString.FindStringSubmatch(raw)
	if len(match) != 2 {
		return ""
	}
	return strings.TrimSpace(match[1])
}

func numericID(value any) string {
	switch typed := value.(type) {
	case float64:
		return strconv.FormatInt(int64(typed), 10)
	case string:
		if typed != "" && strings.Trim(typed, "0123456789") == "" {
			return typed
		}
	}
	return ""
}
