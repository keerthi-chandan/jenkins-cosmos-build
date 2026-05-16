#!/bin/bash
# Sanity check after a build.
# Usage: ./verify-build.sh babylond

DAEMON=$1
BIN=$HOME/go/bin/$DAEMON

if [ ! -x "$BIN" ]; then
    echo "Binary not found: $BIN"
    exit 1
fi

$BIN version
