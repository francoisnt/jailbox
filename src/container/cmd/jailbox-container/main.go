package main

import (
	"fmt"
	"io"
	"os"
	"syscall"

	"github.com/francoisnt/jailbox/container/internal/forwardclient"
	"github.com/francoisnt/jailbox/internal/argv"
	"github.com/francoisnt/jailbox/internal/buildversion"
)

func main() {
	args := os.Args[1:]
	if len(args) < 2 {
		os.Exit(2)
	}
	if err := buildversion.Check(args[0]); err != nil {
		fmt.Fprintln(os.Stderr, "Error:", err)
		os.Exit(1)
	}
	switch args[1] {
	case "version":
		return
	case "exec":
		if len(args) == 4 {
			command, err := argv.Decode(args[3])
			if err == nil {
				// Retain Bash's executable lookup and text-file fallback.
				code := `cd "$1" || exit 1
shift
exec -- "$@"`
				bash := []string{"/bin/bash", "-pc", code, "jailbox-exec", args[2]}
				fmt.Fprintln(os.Stderr, "Error:", syscall.Exec(bash[0], append(bash, command...), os.Environ()))
				os.Exit(1)
			}
		}
		fmt.Fprintln(os.Stderr, "Error: invalid jailbox exec frame")
		os.Exit(2)
	case "hold":
		if _, err := io.Copy(io.Discard, os.Stdin); err != nil {
			fmt.Fprintln(os.Stderr, "Error:", err)
			os.Exit(1)
		}
	case "probe", "forward":
		os.Exit(forwardclient.Run(args[1], args[2:]))
	default:
		os.Exit(2)
	}
}
