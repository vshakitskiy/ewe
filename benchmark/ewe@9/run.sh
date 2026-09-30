#!/usr/bin/env bash
set -euo pipefail

gleam export erlang-shipment
exec build/erlang-shipment/entrypoint.sh run
