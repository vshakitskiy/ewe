#!/usr/bin/env bash
set -euo pipefail

rebar3 as prod compile
exec erl -noshell -pa _build/prod/lib/*/ebin -eval "application:ensure_all_started(httpd_bench)"
