#!/usr/bin/env bash
printf '%s' "$2" > "$FM_TEST_CAPTURE"
printf 'captured worker message for %s -> %s\n' "$1" "$FM_TEST_CAPTURE"
