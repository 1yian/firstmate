#!/usr/bin/env bash
printf '%s' "$2" > "$FM_TEST_CAPTURE"
printf 'delivered to %s (%s bytes)\n' "$1" "$(wc -c < "$FM_TEST_CAPTURE" | tr -d ' ')"
