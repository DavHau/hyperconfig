/**
 * direnv — auto-loads direnv environment into the omp agent process.
 *
 * Port of Mic92's pi direnv extension (Mic92/dotfiles,
 * home/.pi/agent/extensions/direnv.ts): runs `direnv export json` on
 * session start and after every bash command, applying the env diff to
 * `process.env`. Commands then run inside the devshell with no
 * `nix develop -c` prefix and no per-command flake re-eval — pair with
 * nix-direnv so the export is a cache read (milliseconds).
 *
 * omp caveat vs pi: omp caches a persistent native shell per session,
 * spawned lazily on the FIRST bash call — it inherits the env applied at
 * session_start, but a mid-session .envrc change only reaches newly
 * spawned processes (eval kernels, subagents, replacement shells), not
 * the already-running cached shell. Accepted; matches the original's
 * process.env-mutation design.
 *
 * Requirements: direnv on PATH, `.envrc` allowed (`direnv allow`).
 * Status bar: "direnv …" (running), "direnv ✓" (loaded), "direnv ✗" (error).
 *
 * Loaded from $config_dir/extensions/direnv.ts (symlinked by
 * modules/nixos/pi.nix); tests in direnv.test.ts run via bun against the
 * ~/projects/oh-my-pi checkout.
 */

import { spawn } from "node:child_process";
import type { ExtensionAPI } from "@oh-my-pi/pi-coding-agent";

export type DirenvState = "loading" | "ok" | "error";

export interface DirenvRunResult {
	code: number | null;
	stdout: string;
}

export interface DirenvLoaderDeps {
	/** Runs `direnv export json` in `cwd` and resolves with exit code + stdout. */
	run: (cwd: string) => Promise<DirenvRunResult>;
	/** Target env object the export diff is applied to (process.env in production). */
	env: Record<string, string | undefined>;
	/** Inline wait budget; a run outlasting it finishes in the background. */
	timeoutMs?: number;
}

/** Structural subset of ExtensionContext the extension touches. */
export interface DirenvCtx {
	cwd: string;
	hasUI: boolean;
	ui: {
		setStatus(key: string, text: string): void;
		theme: { fg(color: string, text: string): string };
	};
}

/** Structural subset of ExtensionAPI, for tests. */
export interface DirenvPi {
	on(event: "session_start", handler: (event: unknown, ctx: DirenvCtx) => void | Promise<void>): void;
	on(
		event: "tool_result",
		handler: (event: { toolName?: string }, ctx: DirenvCtx) => void | Promise<void>,
	): void;
}

/**
 * Apply `direnv export json` output to `env`: string values are set,
 * nulls unset. Empty output means the environment is already in sync.
 */
export function applyDirenvExport(
	output: string,
	env: Record<string, string | undefined>,
): { ok: boolean; loaded: number; unset: number } {
	if (!output.trim()) return { ok: true, loaded: 0, unset: 0 };

	let parsed: unknown;
	try {
		parsed = JSON.parse(output);
	} catch {
		return { ok: false, loaded: 0, unset: 0 };
	}
	if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) {
		return { ok: false, loaded: 0, unset: 0 };
	}

	let loaded = 0;
	let unset = 0;
	for (const [key, value] of Object.entries(parsed)) {
		if (value === null) {
			delete env[key];
			unset++;
		} else if (typeof value === "string") {
			env[key] = value;
			loaded++;
		}
	}
	return { ok: true, loaded, unset };
}

const DEFAULT_TIMEOUT_MS = 10_000;

/**
 * Serialized direnv loader: one run in flight at a time (later loads
 * queue behind it), each load blocks callers for at most `timeoutMs` —
 * a slower run completes in the background and still applies its result.
 */
export function createDirenvLoader(deps: DirenvLoaderDeps) {
	const timeoutMs = deps.timeoutMs ?? DEFAULT_TIMEOUT_MS;
	// Tail of the run queue; every load chains onto it so runs never overlap,
	// even when a previous load already returned on budget expiry.
	let tail: Promise<void> = Promise.resolve();

	async function runAndApply(cwd: string, onStatus?: (state: DirenvState) => void): Promise<void> {
		let result: DirenvRunResult;
		try {
			result = await deps.run(cwd);
		} catch {
			onStatus?.("error");
			return;
		}
		if (result.code !== 0) {
			onStatus?.("error");
			return;
		}
		const applied = applyDirenvExport(result.stdout, deps.env);
		onStatus?.(applied.ok ? "ok" : "error");
	}

	function load(cwd: string, onStatus?: (state: DirenvState) => void): Promise<void> {
		onStatus?.("loading");
		const work = tail.then(() => runAndApply(cwd, onStatus));
		tail = work;

		const { promise: budget, resolve: expire } = Promise.withResolvers<void>();
		const timer = setTimeout(expire, timeoutMs);
		return Promise.race([work, budget]).finally(() => clearTimeout(timer));
	}

	return { load };
}

function themedStatus(ctx: DirenvCtx, state: DirenvState): string {
	switch (state) {
		case "loading":
			return ctx.ui.theme.fg("warning", "direnv …");
		case "ok":
			return ctx.ui.theme.fg("success", "direnv ✓");
		case "error":
			return ctx.ui.theme.fg("error", "direnv ✗");
	}
}

/** Wire the loader to session_start and bash tool_result events. */
export function createDirenvExtension(pi: DirenvPi, deps: DirenvLoaderDeps): void {
	const loader = createDirenvLoader(deps);

	const statusFor = (ctx: DirenvCtx) =>
		ctx.hasUI
			? (state: DirenvState) => ctx.ui.setStatus("direnv", themedStatus(ctx, state))
			: undefined;

	pi.on("session_start", (_event, ctx) => loader.load(ctx.cwd, statusFor(ctx)));

	// Re-run after every bash command to pick up .envrc changes
	// (cd to a new dir, git checkout, direnv allow, ...).
	pi.on("tool_result", (event, ctx) => {
		if (event.toolName !== "bash") return;
		return loader.load(ctx.cwd, statusFor(ctx));
	});
}

function spawnDirenv(cwd: string): Promise<DirenvRunResult> {
	const { promise, resolve } = Promise.withResolvers<DirenvRunResult>();
	const proc = spawn("direnv", ["export", "json"], {
		cwd,
		stdio: ["ignore", "pipe", "ignore"],
	});
	let stdout = "";
	proc.stdout.on("data", (chunk: Buffer) => {
		stdout += chunk.toString();
	});
	proc.on("close", code => resolve({ code, stdout }));
	proc.on("error", () => resolve({ code: null, stdout: "" }));
	return promise;
}

export default function (pi: ExtensionAPI) {
	// Cast: DirenvPi narrows ExtensionAPI's ThemeColor-typed theme.fg to plain
	// strings for testability; the runtime object satisfies both shapes.
	const direnvPi = pi as unknown as DirenvPi;
	createDirenvExtension(direnvPi, { env: process.env, run: spawnDirenv });
}
