#!/usr/bin/env bash
set -euo pipefail

export MIX_ENV=prod
mix deps.get
mix release --overwrite
exec _build/prod/rel/bandit_bench/bin/bandit_bench start
