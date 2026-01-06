#!/bin/sh
set -euo pipefail
swift test --filter UpdateSupportTests
swift test --filter UpdateServiceTests
swift test --filter UpdateViewModelTests
