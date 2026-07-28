#!/usr/bin/env bash
set -uo pipefail

vite_pid=

stop_vite() {
  trap '' INT TERM

  if [[ -n "${vite_pid}" ]] && kill -0 "${vite_pid}" 2>/dev/null; then
    kill -INT "${vite_pid}" 2>/dev/null || true
    wait "${vite_pid}" 2>/dev/null || true
  fi

  exit 0
}

trap stop_vite INT TERM

pnpm exec vite --host 127.0.0.1 --port 3000 --strictPort &
vite_pid=$!

wait "${vite_pid}"
status=$?
if (( status == 130 || status == 143 )); then
  exit 0
fi

exit "${status}"
