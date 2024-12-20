#!/bin/bash

set -e

[ $RUNNER_OS == 'macOS' ] && OS="macos"
[ $RUNNER_OS == 'Windows' ] && OS="windows"
[ $RUNNER_OS == 'Linux' ] && OS="linux"

ZIG_VERSION="0.13.0"

[ $(uname -m) == 'arm64' ] && ARCH='aarch64' || ARCH=$(uname -m)

TRIPLE="${OS}-${ARCH}-${ZIG_VERSION}"

echo "Getting Zig ${TRIPLE}"

[ $RUNNER_OS != 'Windows' ] && curl "https://ziglang.org/download/${ZIG_VERSION}/zig-${TRIPLE}.tar.xz" | tar xJ
if [[ $RUNNER_OS == 'Windows' ]]; then
  curl "https://ziglang.org/download/${ZIG_VERSION}/zig-${TRIPLE}.zip" -o zig-${TRIPLE}.zip
  7z x zig-${TRIPLE}.zip
  ZIG="zig-${TRIPLE}/zig.exe"
else
  ZIG="zig-${TRIPLE}/zig"
fi

echo "Zig path: ${ZIG}"

echo "Adding API key"

touch .env
echo "${{ secrets.AWS_API_KEY }}" >> .env

$ZIG build run -Dbuild-example
