#!/usr/bin/env bash

# A packaged relx release changes its working directory to the release
# root, which would break the ../priv relative file paths, so this runs
# straight from source instead.
rebar3 compile
erl -pa _build/default/lib/*/ebin \
  -eval "application:ensure_all_started(roadrunner_bench)" \
  -noshell
