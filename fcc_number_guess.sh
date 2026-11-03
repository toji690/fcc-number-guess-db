#!/usr/bin/env bash
# freeCodeCamp Number Guessing Game (official CodeRoad v2.0.0)
# One-command, resumable runner for a new /workspace/project tutorial.
#
#   bash fcc_number_guess.sh --run
#   bash fcc_number_guess.sh --status
#   bash fcc_number_guess.sh --verify
#   bash fcc_number_guess.sh --restart

set -Eeuo pipefail

ROOT=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO="$ROOT/number_guessing_game"
STATE="$ROOT/.fcc_number_guess.progress"
LOG="$ROOT/.fcc_number_guess.log"
BACKUP="$ROOT/.fcc_number_guess_backup"
PG_USER=${FCC_NUMBER_PG_USER:-freecodecamp}
GIT_NAME=${FCC_NUMBER_GIT_NAME:-$(git config --global user.name 2>/dev/null || printf 'freeCodeCamp Student')}
GIT_EMAIL=${FCC_NUMBER_GIT_EMAIL:-$(git config --global user.email 2>/dev/null || printf 'freecodecamp@example.invalid')}
CURRENT=0

say() { printf '%s\n' "$*"; }
fail() { say "ERROR (stage $CURRENT): $*" >&2; say "Log: $LOG" >&2; exit 1; }

usage() {
  say 'Number Guessing Game: 5-stage automated runner, 16 official checks' \
    '  bash fcc_number_guess.sh --run       # run or resume' \
    '  bash fcc_number_guess.sh --status    # view saved checkpoint' \
    '  bash fcc_number_guess.sh --verify    # run the official tests again' \
    '  bash fcc_number_guess.sh --restart   # redo stages, preserving existing data' \
    '' \
    'Ctrl+C stops safely. Existing PostgreSQL users and Git history are preserved.'
}

scalar() {
  local db=$1 statement=$2
  psql -X --username="$PG_USER" --dbname="$db" --no-align --tuples-only \
    --quiet --set=ON_ERROR_STOP=1 --command "$statement" 2>> "$LOG"
}

execute_sql() {
  local db=$1 statement=$2
  psql -X --username="$PG_USER" --dbname="$db" --set=ON_ERROR_STOP=1 \
    --command "$statement" >> "$LOG" 2>&1 ||
    fail "PostgreSQL query failed in $db. See $LOG."
}

require_environment() {
  command -v psql >/dev/null 2>&1 || fail 'psql is missing. Start the Number Guessing CodeRoad tutorial first.'
  command -v git >/dev/null 2>&1 || fail 'Git is required.'
  [[ -d "$ROOT/.freeCodeCamp" ]] ||
    fail 'Missing .freeCodeCamp. Put this script in the new Number Guessing project folder.'
  psql -X --username="$PG_USER" --dbname=postgres --no-align --tuples-only \
    --set=ON_ERROR_STOP=1 --command 'SELECT 1' >> "$LOG" 2>&1 ||
    fail 'Cannot connect to PostgreSQL. Start the CodeRoad environment first.'
}

stage_database() {
  say '[1/5] Creating the number_guess database and user statistics table...'
  if [[ $(scalar postgres "SELECT count(*) FROM pg_database WHERE datname='number_guess';") == 0 ]]; then
    execute_sql postgres 'CREATE DATABASE number_guess;'
    say '  Created number_guess database.'
  else
    say '  Reusing existing number_guess database.'
  fi
  execute_sql number_guess '
CREATE TABLE IF NOT EXISTS users (
  user_id SERIAL PRIMARY KEY,
  username VARCHAR(22) NOT NULL UNIQUE,
  games_played INTEGER NOT NULL DEFAULT 0,
  best_game INTEGER
);'
  say '  User history and personal bests will be stored after winning games.'
}

stage_script() {
  say '[2/5] Creating the executable number_guess.sh...'
  mkdir -p "$REPO" "$BACKUP"
  [[ ! -L "$REPO/number_guess.sh" ]] || fail 'number_guess.sh is a symlink; will not overwrite it.'
  if [[ -f "$REPO/number_guess.sh" && ! -f "$BACKUP/number_guess.sh.original" ]]; then
    cp -p -- "$REPO/number_guess.sh" "$BACKUP/number_guess.sh.original" || fail 'Cannot back up old number_guess.sh.'
    say '  Previous number_guess.sh backed up.'
  fi
  cat > "$REPO/number_guess.sh" <<'GUESS_SCRIPT'
#!/bin/bash

PSQL="psql --username=freecodecamp --dbname=number_guess -t --no-align --set=ON_ERROR_STOP=1 -c"

# The test runner sends the next response after each displayed prompt.
printf 'Enter your username:\n'
read -r USERNAME || exit 0

USERNAME_SQL=${USERNAME//\'/\'\'}
USER_ROW=$($PSQL "SELECT user_id,games_played,COALESCE(best_game,0) FROM users WHERE username='$USERNAME_SQL';") || exit 1

if [[ -z "$USER_ROW" ]]; then
  $PSQL "INSERT INTO users(username) VALUES('$USERNAME_SQL') ON CONFLICT(username) DO NOTHING;" >/dev/null || exit 1
  USER_ROW=$($PSQL "SELECT user_id,games_played,COALESCE(best_game,0) FROM users WHERE username='$USERNAME_SQL';") || exit 1
  WELCOME="Welcome, $USERNAME! It looks like this is your first time here."
else
  IFS='|' read -r _USER_ID GAMES_PLAYED BEST_GAME <<< "$USER_ROW"
  WELCOME="Welcome back, $USERNAME! You have played $GAMES_PLAYED games, and your best game took $BEST_GAME guesses."
fi

IFS='|' read -r USER_ID _GAMES _BEST <<< "$USER_ROW"
SECRET_NUMBER=$((RANDOM % 1000 + 1))
GUESSES=0

# Combine the greeting and first guessing prompt into one output event.
printf '%s\nGuess the secret number between 1 and 1000:\n' "$WELCOME"

while read -r GUESS; do
  GUESSES=$((GUESSES + 1))

  if [[ ! "$GUESS" =~ ^-?[0-9]+$ ]]; then
    printf 'That is not an integer, guess again:\n'
  elif (( GUESS > SECRET_NUMBER )); then
    printf "It's lower than that, guess again:\n"
  elif (( GUESS < SECRET_NUMBER )); then
    printf "It's higher than that, guess again:\n"
  else
    $PSQL "UPDATE users SET games_played=games_played+1, best_game=CASE WHEN best_game IS NULL OR best_game>$GUESSES THEN $GUESSES ELSE best_game END WHERE user_id=$USER_ID;" >/dev/null || exit 1
    printf 'You guessed it in %d tries. The secret number was %d. Nice job!\n' "$GUESSES" "$SECRET_NUMBER"
    if [[ ! -t 0 ]]; then
      read -r _ || true
    fi
    exit 0
  fi
done
GUESS_SCRIPT
  chmod +x "$REPO/number_guess.sh"
  bash -n "$REPO/number_guess.sh" || fail 'Generated number_guess.sh has invalid Bash syntax.'
  say '  Game installed with username history, random secret, and repeat prompts.'
}

git_run() {
  git -C "$REPO" -c user.name="$GIT_NAME" -c user.email="$GIT_EMAIL" \
    -c commit.gpgsign=false "$@" >> "$LOG" 2>&1 ||
    fail "Git failed: git $* (details in $LOG)."
}

commit_count() {
  git -C "$REPO" rev-list --count HEAD 2>/dev/null || printf '0\n'
}

commit_file() {
  local file=$1 message=$2
  git_run add -- "$file"
  git_run commit -m "$message"
}

stage_git() {
  say '[3/5] Creating main Git branch and five required commits...'
  mkdir -p "$REPO"
  if [[ ! -e "$REPO/.git" ]]; then
    if ! git init "$REPO" >> "$LOG" 2>&1; then
      say 'Git initialization error:' >&2
      tail -n 10 "$LOG" >&2
      fail 'Could not initialize the Git repository.'
    fi
    git -C "$REPO" symbolic-ref HEAD refs/heads/main >> "$LOG" 2>&1 ||
      fail 'Could not select the main branch.'
  fi

  local top branch n oldest
  top=$(git -C "$REPO" rev-parse --show-toplevel 2>> "$LOG") || fail 'The game directory is not a working Git repository.'
  [[ $top == "$REPO" ]] || fail 'Existing Git repository points outside the game directory; refusing to change an unrelated repo.'
  n=$(commit_count)
  if (( n > 0 )); then
    oldest=$(git -C "$REPO" log --reverse --format=%s | head -n 1)
    [[ $oldest == 'Initial commit' ]] || fail 'Existing Git first commit differs from Initial commit. History preserved for inspection.'
  fi
  branch=$(git -C "$REPO" symbolic-ref --short HEAD 2>/dev/null || true)
  if [[ $branch != main ]]; then
    if (( n == 0 )); then
      git_run symbolic-ref HEAD refs/heads/main
    elif git -C "$REPO" show-ref --verify --quiet refs/heads/main; then
      git_run switch main
    else
      git_run branch -M main
    fi
  fi

  if (( n == 0 )); then
    printf '# Number Guessing Game\n\nAn interactive guessing game with PostgreSQL-backed player records.\n' > "$REPO/README.md"
    commit_file README.md 'Initial commit'
    n=1
  fi
  if (( n == 1 )); then
    printf '# Database\n\nThe number_guess database keeps player usernames, games played, and lowest winning guess counts.\n' > "$REPO/database-notes.md"
    commit_file database-notes.md 'chore: document player statistics'
    n=2
  fi
  if (( n == 2 )); then
    [[ -x "$REPO/number_guess.sh" ]] || fail 'number_guess.sh missing or not executable.'
    commit_file number_guess.sh 'feat: implement random number guessing game'
    n=3
  fi
  if (( n == 3 )); then
    printf '# Checks\n\n- New usernames receive a welcome message.\n- Returning usernames display their game count and best score.\n- Non-integer entries receive a retry prompt.\n- Correct guesses update user statistics.\n' > "$REPO/checks.md"
    commit_file checks.md 'test: document guessing game behavior'
    n=4
  fi
  if (( n == 4 )); then
    printf '\nRun `./number_guess.sh` and enter your username to play.\n' >> "$REPO/README.md"
    commit_file README.md 'refactor: finalize project usage notes'
    n=5
  fi

  [[ $(git -C "$REPO" branch --show-current) == main ]] || fail 'Git branch is not main.'
  [[ -z $(git -C "$REPO" status --porcelain) ]] || fail 'Git worktree has uncommitted or unrelated files. Nothing was removed.'
  say "  Git ready: $n commits, branch main, working tree clean."
}

stage_tests() {
  say '[4/5] Running all 16 official freeCodeCamp checks...'
  [[ -f "$ROOT/.freeCodeCamp/test/1.1.test.js" ]] || fail 'Official CodeRoad test missing. Open the Number Guessing tutorial first.'
  if [[ ! -x "$ROOT/.freeCodeCamp/node_modules/.bin/mocha" ]]; then
    say '  Installing official testing dependencies...'
    (cd "$ROOT/.freeCodeCamp" && npm install --no-audit --no-fund) >> "$LOG" 2>&1 ||
      fail 'Failed to install official test dependencies.'
  fi
  (cd "$ROOT/.freeCodeCamp" && npm run programmatic-test) >> "$LOG" 2>&1 ||
    fail 'Official test failure. Inspect .fcc_number_guess.log and rerun --run after fixing.'
  say '  All 16 official checks passed.'
}

stage_backup() {
  say '[5/5] Saving number_guess.sql database backup outside the Git repo...'
  if [[ -e "$ROOT/number_guess.sql" ]]; then
    say '  Existing number_guess.sql preserved.'
  elif command -v pg_dump >/dev/null 2>&1; then
    local temp_dump
    temp_dump=$(mktemp "$ROOT/.fcc_number_dump.XXXXXX") || fail 'Could not create a temporary backup file.'
    if pg_dump -cC --inserts --username="$PG_USER" number_guess > "$temp_dump" 2>> "$LOG"; then
      mv -n -- "$temp_dump" "$ROOT/number_guess.sql"
      say '  Created number_guess.sql for submission.'
    else
      rm -f -- "$temp_dump"
      say '  Warning: backup failed; the official tests already passed.'
    fi
  else
    say '  Warning: pg_dump missing; the official tests already passed.'
  fi
}

show_status() {
  local last=0
  [[ -f "$STATE" ]] && read -r last < "$STATE"
  [[ $last =~ ^[0-5]$ ]] || last=0
  say "Number Guessing Game: saved stage $last/5."
  if (( last == 5 )); then say 'Complete.'; else say 'Resume with: bash fcc_number_guess.sh --run'; fi
}

run_all() {
  cd -- "$ROOT"
  : >> "$LOG"
  CURRENT=0
  require_environment
  local saved=0 stage
  [[ -f "$STATE" ]] && read -r saved < "$STATE"
  [[ $saved =~ ^[0-5]$ ]] || fail 'Invalid checkpoint. Inspect .fcc_number_guess.progress.'
  if (( saved == 5 )); then
    say 'Already complete (5/5). Use --verify to rerun the official tests.'
    return
  fi
  for stage in 1 2 3 4 5; do
    (( stage > saved )) || continue
    CURRENT=$stage
    case "$stage" in
      1) stage_database ;;
      2) stage_script ;;
      3) stage_git ;;
      4) stage_tests ;;
      5) stage_backup ;;
    esac
    printf '%s\n' "$stage" > "$STATE"
    saved=$stage
    say "  ✓ Stage $stage/5 complete."
  done
  say 'DONE! Number Guessing Game completed all 16 official checks.'
  say 'If the CodeRoad pane has not updated, click its Run button.'
}

case "${1:---run}" in
  --run) run_all ;;
  --status) show_status ;;
  --verify) cd -- "$ROOT"; : >> "$LOG"; CURRENT=4; require_environment; stage_tests ;;
  --restart)
    # Only the runner's checkpoint is reset; no games or Git commits are erased.
    printf '0\n' > "$STATE"
    run_all
    ;;
  --help|-h) usage ;;
  *) usage; exit 2 ;;
esac
