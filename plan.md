# Brainstorming: Investigating llama.cpp KV/Context/Slot Logic

## Objectives
1.  **Server Defaults:**
    - `-np` default value.
    - `kv_unified` default for `llama-server`.
    - Locate argument parsing locations.

2.  **KV Allocation Logic:**
    - Distinguish `kv_unified=true` vs `kv_unified=false` behavior.
    - Determine if `-c` is total shared or per-slot.
    - Check variable definitions for context sizes (`n_ctx`, `n_ctx_seq`).

3.  **Impact of `-np`:**
    - Simulation/logic check: Does `-np` scale or slice the context?

4.  **Metadata:**
    - Checkpoints vs KV VRAM.
    - `--cache-ram` vs VRAM.

## Plan
1.  **Locate Code:**
    - Search for `n_parallel` and `kv_unified` in `examples/server/`, `common/`, and `src/`.
    - Find the `main()` function in `server.cpp` and how it initializes context/params.

2.  **Investigate Allocation:**
    - Read CLI parsing in `common/arg.cpp` and `examples/server/main.cpp` (or equivalent).
    - Read `server.cpp` to see how slots are initialized.
    - Look into `llama.cpp` core code for `llama_context_params` setting `n_ctx_seq` and KV allocation.

3.  **Analyze & Synthesize:**
    - Answer questions based on code found.
    - Confirm the behavior with source snippets.

## Tooling
- `glob` to find files.
- `grep` to find definitions.
- `read` to read relevant logic.
