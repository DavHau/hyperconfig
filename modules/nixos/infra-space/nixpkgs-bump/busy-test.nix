# ./busy.sh against a scratch state.db with hermes' two tables (only the
# columns it reads): busy only for a bump session's queued or started
# turn active in the last 12 h; a subagent's, another cwd's, a finished
# or a stale one is not; an unreadable db is not busy.
{ pkgs }:
let
  busy = import ./busy.nix {
    inherit pkgs;
    stateDb = "/build/state.db";
    cwd = "/home/infra/nixpkgs-bump";
  };
in
pkgs.runCommand "nixpkgs-bump-busy-test" { nativeBuildInputs = [ busy pkgs.sqlite ]; } ''
  set -euo pipefail
  if nixpkgs-bump-busy; then echo "FAILED: busy without a db"; exit 1; fi
  sqlite3 /build/state.db "
    create table sessions (id text primary key, source text not null, cwd text,
      started_at real not null, last_activity_at real);
    create table session_admissions (seq integer primary key, target_session_id text not null,
      status text not null);"
  now=$(date +%s)
  add() { # id source cwd age status
    sqlite3 /build/state.db "insert into sessions values ('$1', '$2', '$3', $now - $4, $now - $4);
      insert into session_admissions (target_session_id, status) values ('$1', '$5');"
  }
  expect() { # busy|idle what
    if res=$(nixpkgs-bump-busy); then got=busy; else got=idle; fi
    [ "$got" = "$1" ] || { echo "FAILED: $2: expected $1, got $got ($res)"; exit 1; }
    echo "ok: $2 ($got)"
  }
  b=/home/infra/nixpkgs-bump
  add done oneshot $b 60 terminal
  expect idle "a finished bump turn"
  add sub subagent $b 60 started
  expect idle "a subagent's running turn"
  add other oneshot /home/infra 60 started
  expect idle "another job's running turn"
  add stale oneshot $b 50000 started
  expect idle "a bump turn stuck for 14 h"
  add live oneshot $b 60 started
  expect busy "a running bump turn"
  res=$(nixpkgs-bump-busy)
  [ "$res" = "bump session live still has a turn in the gateway" ] || { echo "FAILED: $res"; exit 1; }
  sqlite3 /build/state.db "update session_admissions set status = 'queued' where target_session_id = 'live'"
  expect busy "a queued bump turn"
  echo ok >$out
''
