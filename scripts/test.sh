#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build
swiftc Sources/RemoteFinderCore/*.swift Tests/main.swift -o .build/core-tests
.build/core-tests
swiftc Sources/RemoteFinderCore/RemotePath.swift Sources/RemoteFinder/RemotePathBar.swift Tests/PathBar/main.swift -o .build/pathbar-tests
.build/pathbar-tests
