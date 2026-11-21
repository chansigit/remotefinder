#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build
swiftc Sources/RemoteFinderCore/*.swift Tests/main.swift -o .build/core-tests
.build/core-tests
swiftc Sources/RemoteFinderCore/RemotePath.swift Sources/RemoteFinder/RemotePathBar.swift Tests/PathBar/main.swift -o .build/pathbar-tests
.build/pathbar-tests

swiftc -O Sources/RemoteFinderCore/*.swift Tests/Listing/main.swift -o .build/listing-tests
.build/listing-tests

python3 Tests/Recovery/run.py

python3 Tests/Passwords/run.py

swiftc -O Sources/RemoteFinderCore/*.swift Tests/Transfers/main.swift -o .build/transfer-tests
.build/transfer-tests
