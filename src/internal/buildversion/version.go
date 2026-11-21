// Package buildversion checks the private contract between runtime files and helpers.
package buildversion

import (
	"fmt"
	"strings"
)

const stampPrefix = "jailbox-build-version:"

// Stamp is set at link time to "jailbox-build-version:VERSION:". Build info
// omits linker flags in trimmed builds, so release validation finds this
// delimited marker in each binary instead, including binaries it cannot run.
var Stamp = stampPrefix + "dev:"

var Version = strings.TrimSuffix(strings.TrimPrefix(Stamp, stampPrefix), ":")

func Check(expected string) error {
	if expected != Version {
		return fmt.Errorf("jailbox helper version mismatch (expected %s, found %s); rebuild the checkout or reinstall jailbox", expected, Version)
	}
	return nil
}
