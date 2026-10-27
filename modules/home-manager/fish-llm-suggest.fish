# Live LLM autosuggestions (modules/nixos/fish-llm-suggest.nix).
#
# An interactive shell on a terminal re-execs itself under the
# fish-llm-suggest pty proxy, which records recent commands and their output
# and asks the LLM for a completion once the command line has been idle for a
# moment. The patched fish notifies the proxy from its autosuggestion thread
# (fish_autosuggestion_socket) and renders whatever lands in
# fish_autosuggestion_extra as normal ghost text: accept with right arrow /
# ctrl-f (whole line) or alt-right / alt-f (one word), like any autosuggestion.
status is-interactive; or return

if not set -q FISH_LLM_SOCKET
    if isatty stdin; and isatty stdout; and test "$TERM" != dumb
        set -l args
        status is-login; and set args --login
        exec @proxy@ wrap -- (status fish-path) $args
    end
    return
end

# Handler first: the proxy only signals once it has heard from fish via the socket.
set -g __fish_llm_result $FISH_LLM_RESULT
function __fish_llm_suggest_result --on-signal SIGUSR1
    set -l parts (string split0 <$__fish_llm_result 2>/dev/null)
    or return
    test (count $parts) -eq 2; or return
    # Newest first, no duplicates, at most 8 candidates.
    set -l keep $parts[2]
    for c in $fish_autosuggestion_extra
        test "$c" = "$parts[2]"; or set -a keep $c
    end
    set -g fish_autosuggestion_extra $keep[1..8]
end

function __fish_llm_suggest_cd --on-variable PWD
    set -q fish_autosuggestion_extra; and set -e fish_autosuggestion_extra
end

set -g fish_autosuggestion_socket $FISH_LLM_SOCKET
# Not for child shells: a nested fish gets its own proxy.
set -e FISH_LLM_SOCKET FISH_LLM_RESULT
