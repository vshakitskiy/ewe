#!/usr/bin/env bash

rebar3 compile
erl -pa _build/default/lib/*/ebin \
  -eval "application:ensure_all_started(elli_bench)" \
  -noshell
