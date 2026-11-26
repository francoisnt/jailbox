package forwarding

import (
	"bufio"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"time"

	"golang.org/x/sys/unix"
)

// Run dispatches private resource operations from the Bash core.
func Run(operation string, args []string) error {
	minimum := map[string]int{
		"capture": 2, "hash": 0, "describe": 2, "publish": 4,
		"storage": 1, "names": 1, "retire": 1, "check": 2,
		"start": 4, "serve": 3, "request": 1,
	}
	count, ok := minimum[operation]
	if !ok || len(args) < count || (operation != "publish" && len(args) != count) {
		return errors.New("invalid host forwarding operation or arguments")
	}
	umask := unix.Umask(0077)
	switch operation {
	case "capture":
		contents, err := capture(args[0], args[1])
		return printResult(base64.StdEncoding.EncodeToString(contents), err)
	case "hash", "describe":
		input, err := readInputLimit(os.Stdin, 45000)
		if err != nil {
			return err
		}
		contents, err := decodePolicy(string(input))
		if err != nil {
			return err
		}
		if operation == "hash" {
			return printResult(hash(contents), nil)
		}
		timer := time.AfterFunc(3*time.Second, func() {
			fmt.Fprintln(os.Stderr, "Error: host command forwarding: policy preparation timed out")
			os.Exit(1)
		})
		defer timer.Stop()
		prepared, err := prepare(args[0], args[1], contents, umask)
		if err != nil {
			return err
		}
		return json.NewEncoder(os.Stdout).Encode(prepared)
	case "publish":
		input := bufio.NewReader(os.Stdin)
		frame, err := input.ReadString('\n')
		if err != nil {
			return err
		}
		contents, err := decodePolicy(frame)
		if err != nil {
			return err
		}
		prepared, err := readInputLimit(input, 1<<20)
		if err != nil {
			return err
		}
		return publish(args[0], args[1], args[2], args[3], args[4:], contents, prepared)
	case "storage":
		var saved manifest
		if err := json.NewDecoder(os.Stdin).Decode(&saved); err != nil {
			return err
		}
		return saved.checkStorage(args[0])
	case "names":
		if err := inspectState(args[0]); err != nil {
			return err
		}
		names, err := names()
		return printResult(names, err)
	case "retire":
		return retire(args[0])
	case "check":
		response, err := check(args[0], args[1])
		return printResult(response, err)
	case "start":
		mounts, err := readInputLimit(os.Stdin, 1<<20)
		if err != nil {
			return err
		}
		return start(args[0], args[1], args[2], args[3], mounts)
	case "serve":
		return serve(args[0], args[1], args[2])
	case "request":
		return request(args[0], time.Second)
	}
	return errors.New("unknown host forwarding operation")
}

func printResult(value string, err error) error {
	if err != nil {
		return err
	}
	_, err = fmt.Fprintln(os.Stdout, value)
	return err
}

func readInputLimit(input io.Reader, limit int64) ([]byte, error) {
	contents, err := io.ReadAll(io.LimitReader(input, limit+1))
	if err == nil && int64(len(contents)) > limit {
		err = errors.New("host forwarding input exceeds its limit")
	}
	return contents, err
}
