#!/usr/bin/env bash
# Interactive picker for running Claude sessions.
#
#   picker.sh           fzf picker; on enter, switches the parent client to the
#                       chosen session's origin window and resumes it in the popup.
#   picker.sh --list    print the rows only (used by fzf's ctrl-x reload).
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=helpers.sh
. "$DIR/helpers.sh"

prefix="$(get_tmux_option @claude_session_prefix 'claude-')"

emit_rows() {
  local now s state at path icon rank ago
  now=$(date +%s)
  # A session belongs in the picker if EITHER it carries the launcher's prefix
  # (sessions this plugin created) OR the hooks have stamped it with a Claude
  # state. The latter catches Claude running in your own manually-named sessions
  # (dotfiles, hyper-ai, …), which never match the prefix. Prefix-only sessions
  # with no hook yet still list as "?" — preserving the no-hooks behavior.
  tmux list-sessions -F '#{session_name}' 2>/dev/null | while IFS= read -r s; do
    state=$(tmux show-options -qv -t "$s" @claude_state 2>/dev/null)
    case "$s" in "$prefix"*) ;; *) [ -z "$state" ] && continue ;; esac
    at=$(tmux show-options -qv -t "$s" @claude_state_at 2>/dev/null)
    path=$(tmux display-message -p -t "$s" '#{pane_current_path}' 2>/dev/null)
    case "$state" in
    waiting) icon=$'\033[33m●\033[0m waiting' rank=0 ;; # yellow - needs input
    idle) icon=$'\033[32m●\033[0m idle   ' rank=1 ;;    # green  - done, your turn
    working) icon=$'\033[31m●\033[0m working' rank=3 ;; # red    - busy, leave it
    *) icon=$'\033[90m●\033[0m   ?    ' rank=2 ;;       # grey   - unknown (no hook yet)
    esac
    if [ -n "$at" ]; then ago="$(((now - at) / 60))m"; else ago='-'; fi
    # rank \t session \t icon \t age \t path   (rank/session hidden via --with-nth)
    printf '%s\t%s\t%s\t%5s\t%s\n' "$rank" "$s" "$icon" "$ago" "${path/#$HOME/~}"
    # rank asc (attention-needed floats up), then age asc so the session that
    # finished just now sits at the top of its group. -k4,4n reads the leading
    # number of the age field ("5m" -> 5; "-" -> 0).
  done | sort -t$'\t' -k1,1n -k4,4n
}

[ "${1:-}" = '--list' ] && {
  emit_rows
  exit 0
}

if ! command -v fzf >/dev/null 2>&1; then
  tmux display-message "tmux-claude-session-manager: fzf is required for the picker"
  exit 0
fi

self="${BASH_SOURCE[0]}"
export FZF_DEFAULT_OPTS=''
sel=$(emit_rows | fzf --ansi --delimiter='\t' --with-nth=3,4,5 \
  --reverse --cycle --header='Claude sessions · enter: jump · ctrl-x: kill' \
  --preview="tmux capture-pane -ept {2}" --preview-window='right,62%,wrap' \
  --bind="ctrl-x:execute-silent(tmux kill-session -t {2})+reload($self --list)")

[ -z "$sel" ] && exit 0
target=$(printf '%s' "$sel" | cut -f2)

# Jump to the selected session by switching the OUTER client — the one hosting
# this popup, recorded in @claude_parent by list.sh — directly to it, then exit.
# The -E popup closes on exit, so you land in the chosen session full-screen
# instead of having it attached inside the (now closed) popup. Falls back to the
# popup's own client when the parent is unknown.
parent=$(tmux show-options -gqv @claude_parent 2>/dev/null)
if [ -n "$parent" ]; then
  tmux switch-client -c "$parent" -t "$target" 2>/dev/null
else
  tmux switch-client -t "$target" 2>/dev/null
fi
