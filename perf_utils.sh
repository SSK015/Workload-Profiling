#!/bin/bash
# perf_utils.sh - Common utilities for perf profiling

# Detect CPU and Perf version to set optimal profiling arguments.
# Input: $1 = target PID
# Sets:
#   PERF_EVENT_STR: The event string (e.g., cpu/mem-loads/pp)
#   PERF_TARGET_FLAGS: Target flags (e.g., -a or -p $PID)
detect_perf_params() {
    local target_pid=$1
    local perf_bin="${PERF_BIN:-perf}"
    
    # 1. Detect CPU Architecture for PEBS event name
    local cpu_model
    cpu_model=$(lscpu | grep "Model:" | awk '{print $2}' | head -n 1)
    
    # 2. Detect Perf version
    local perf_ver
    perf_ver=$("$perf_bin" --version 2>/dev/null || echo "unknown")

    # Special case: Ice Lake (106) / Sapphire Rapids (143) on 5.15 custom kernel
    if [[ "$cpu_model" == "106" || "$cpu_model" == "143" ]]; then
        # For these CPUs, the multi-event group {aux,pp} sometimes fails on newer perf tools
        # or specific kernel backports. Using the direct pp event is more reliable.
        PERF_EVENT_STR="cpu/mem-loads/pp"
    else
        # Standard default
        PERF_EVENT_STR="{cpu/mem-loads-aux/,cpu/mem-loads/pp}"
        # Add modifier if not already present
        if [[ -n "${PERF_EVENT_MOD:-}" ]]; then
            PERF_EVENT_STR="${PERF_EVENT_STR}:${PERF_EVENT_MOD}"
        fi
    fi

    # Special case: The custom "nothrottle" perf build has a bug with '-p PID -- command'
    if [[ "$perf_ver" == *"nothrottle"* ]]; then
        PERF_TARGET_FLAGS="-a"
        echo "Note: Using system-wide sampling (-a) due to known bug in custom perf version."
    else
        PERF_TARGET_FLAGS="-p $target_pid"
    fi

    # Final check: see if the chosen event is supported.
    # Note: perf list often prints the *base* PMU event (e.g., cpu/mem-loads/)
    # but not a specific config suffix (e.g., cpu/mem-loads/pp).
    local check_event="${PERF_EVENT_STR%%:*}"
    local list_pat="$check_event"
    if [[ "$check_event" == cpu/mem-loads/* ]]; then
        list_pat="cpu/mem-loads/"
    elif [[ "$check_event" == cpu/mem-stores/* ]]; then
        list_pat="cpu/mem-stores/"
    fi
    # Important: callers often enable `set -o pipefail`. Using `perf list | grep -q`
    # can falsely fail because grep -q exits early, causing `perf list` to see SIGPIPE.
    # Avoid pipelines here to keep detection robust.
    local perf_list_out=""
    perf_list_out=$("$perf_bin" list 2>/dev/null || true)
    if ! grep -q "$list_pat" <<<"$perf_list_out"; then
        echo "Warning: Chosen event $PERF_EVENT_STR might not be supported (perf list miss: $list_pat). Falling back to 'mem-loads'."
        PERF_EVENT_STR="mem-loads"
    fi

    echo "Perf Params: EVENT=$PERF_EVENT_STR TARGET=$PERF_TARGET_FLAGS"
}




