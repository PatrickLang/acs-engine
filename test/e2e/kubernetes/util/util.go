package util

import (
	"fmt"
	"log"
	"os/exec"
	"strings"
	"time"
)

// PrintCommand prints a command string
func PrintCommand(cmd *exec.Cmd) {
	fmt.Printf("\n$ %s\n", strings.Join(cmd.Args, " "))
}

// RunAndLogCommand logs the command with a timestamp when it's run, and duration at and
func RunAndLogCommand(cmd *exec.Cmd) ([]byte, error) {
	cmdLine := fmt.Sprintf("$ %s\n", strings.Join(cmd.Args, " "))
	start := time.Now()
	log.Printf("%s", cmdLine)
	out, err := cmd.CombinedOutput()
	end := time.Now()
	log.Printf("\n#### %s completed in %s", cmdLine, end.Sub(start).String())
	return out, err
}
