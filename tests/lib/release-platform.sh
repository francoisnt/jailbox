#!/bin/bash
# Expected asset suffix on the host running a distribution test.
test_release_platform() {
    case "$(uname -s)/$(uname -m)" in
        Linux/x86_64) echo linux-amd64 ;;
        Linux/aarch64|Linux/arm64) echo linux-arm64 ;;
        Darwin/x86_64) echo darwin-amd64 ;;
        Darwin/arm64) echo darwin-arm64 ;;
        *) return 1 ;;
    esac
}
