package main

import (
	"fmt"
	"os"

	"github.com/francoisnt/jailbox/host/core/internal/forwarding"
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
	var err error
	switch args[1] {
	case "version":
		return
	case "encode":
		if len(args) < 3 {
			os.Exit(2)
		}
		var frame string
		frame, err = argv.Encode(args[2], args[3:])
		if err == nil {
			_, err = fmt.Fprint(os.Stdout, frame)
		}
	default:
		if err = forwarding.Run(args[1], args[2:]); err != nil {
			err = fmt.Errorf("host command forwarding: %w", err)
		}
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "Error:", err)
		os.Exit(1)
	}
}
