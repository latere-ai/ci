#!/usr/bin/env bash
#
# The architecture of the machine a step runs on, spelled the way the tool
# release archives spell it. Sourced, it sets TOOL_ARCH to amd64 for an
# x86_64 or amd64 machine and arm64 for an aarch64 or arm64 one, and exits
# non-zero with a message naming the value for anything else, so a step never
# fetches an archive built for another CPU.
#
# CI_UNAME_M replaces `uname -m` when it is set. The tests use it to run both
# mappings on one machine; a runner never sets it.

arch_machine=${CI_UNAME_M:-$(uname -m)}
# TOOL_ARCH is read by the scripts that source this file.
# shellcheck disable=SC2034
case "$arch_machine" in
    x86_64 | amd64) TOOL_ARCH=amd64 ;;
    aarch64 | arm64) TOOL_ARCH=arm64 ;;
    *)
        echo "::error::unsupported machine architecture '$arch_machine': the tool downloads exist for x86_64 (amd64) and aarch64 (arm64)" >&2
        exit 1
        ;;
esac
unset arch_machine
