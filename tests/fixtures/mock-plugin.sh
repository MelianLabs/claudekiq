#!/usr/bin/env bash
# mock-plugin.sh — A mock plugin for testing scan discovery and plugin execution
# JSON protocol: reads step JSON from stdin, outputs result JSON to stdout

input=$(cat)
echo '{"status":"pass","output":{"message":"mock plugin executed"}}'
exit 0
