#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."

test -f third_party/skynet/Makefile
make -C third_party/skynet linux

test -x third_party/skynet/skynet
test -f third_party/skynet/3rd/lua/lua.h
echo "SKYNET_BUILD_OK"