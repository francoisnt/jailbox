#!/bin/bash
set -euo pipefail
relative=$1
cli=$2
mkdir -p "/home/jailbox/${relative%/*}"
tar -xzf /seed/server.tar.gz -C "/home/jailbox/${relative%/*}"
test -x "/home/jailbox/$relative/bin/$cli"
