// Package argv implements the argument frame shared by SSH exec and forwarding.
package argv

import (
	"encoding/base64"
	"errors"
	"fmt"
	"strings"
)

const Limit = 49152

var errFrame = errors.New("invalid argument frame")

func Encode(description string, args []string) (string, error) {
	if len(args) == 0 || args[0] == "" {
		return "", fmt.Errorf("invalid %s argument encoding", description)
	}
	size := 0
	for _, arg := range args {
		if strings.ContainsRune(arg, 0) {
			return "", fmt.Errorf("invalid %s argument encoding", description)
		}
		if len(arg) >= Limit || size+len(arg)+1 > base64.StdEncoding.DecodedLen(Limit) {
			return "", fmt.Errorf("argument list too long for %s", description)
		}
		size += len(arg) + 1
	}
	return base64.StdEncoding.EncodeToString([]byte(strings.Join(args, "\x00") + "\x00")), nil
}

func Decode(frame string) ([]string, error) {
	// The base64 decoder accepts line breaks. The wire grammar does not.
	if frame == "" || len(frame) > Limit || strings.ContainsAny(frame, "\r\n") {
		return nil, errFrame
	}
	raw, err := base64.StdEncoding.DecodeString(frame)
	if err != nil || len(raw) == 0 || raw[0] == 0 || raw[len(raw)-1] != 0 {
		return nil, errFrame
	}
	return strings.Split(string(raw[:len(raw)-1]), "\x00"), nil
}
