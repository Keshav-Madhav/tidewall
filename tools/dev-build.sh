#!/bin/bash
# The development binary, ./tidewall (the test harness and its flags included; it never updates itself).
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -O $(find Sources -name '*.swift' | sort) -o tidewall -framework Cocoa -framework WebKit -framework IOKit -framework CoreLocation -D TIDEWALL_DEV "$@"
