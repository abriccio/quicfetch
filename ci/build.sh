#!/bin/bash

set -e

ZIG_VERSION="0.12.0"

[ $(uname -m) == 'arm64' ] && ARCH='aarch64' || ARCH=$(uname -m)

TRIPLE="${RUNNER_OS}-${ARCH}-${ZIG_VERSION}"

echo "Getting Zig ${TRIPLE}"

[ $RUNNER_OS != 'windows' ] && curl "https://ziglang.org/builds/zig-${TRIPLE}.tar.xz" | tar xJ
if [[ $RUNNER_OS == 'windows' ]]; then
  choco install zig --version $ZIG_VERSION
  ZIG="zig.exe"
else
  ZIG="zig-${TRIPLE}/zig"
fi

echo "Zig path: ${ZIG}"

$ZIG build run
