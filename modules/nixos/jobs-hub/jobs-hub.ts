/**
 * jobs-hub — background bash-jobs overview for omp.
 *
 * Widget: one row per running bash job (spinner, label, elapsed, last
 * output line) while any run. Overlay (Ctrl+J or /bashjobs): list of
 * running + recent bash jobs; Enter prints the selected job's log into
 * the chat transcript — it rides omp's normal append-only commit path
 * into native terminal scrollback (like pi's own transcript), so the
 * log scrolls with the conversation instead of taking over the screen.
 * x cancels.
 *
 * Loaded from $config_dir/extensions/jobs-hub.ts; the @oh-my-pi/*
 * imports are remapped by omp's legacy-pi specifier shim onto the
 * running agent's live modules (shared AsyncJobManager singleton).
 */


import { existsSync, readdirSync, readFileSync, statSync } from "node:fs";

import { AsyncJobManager } from "@oh-my-pi/pi-coding-agent/async/job-manager";
import { type KeyId, matchesKey, Text } from "@oh-my-pi/pi-tui";
const SPINNER_FRAMES = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"];

/** Structural subset of AsyncJob the hub renders. */
export interface JobLike {
	id: string;
	type: "bash" | "task";
	status: "running" | "completed" | "failed" | "cancelled";
	startTime: number;
	label: string;
	resultText?: string;
}

export interface WidgetOptions {
	now: number;
	/** Spinner animation step (poll tick). */
	tick?: number;
	/** Last visible output line for a job id, if any. */
	lastLine?: (id: string) => string | undefined;
	maxRows?: number;
}

function formatElapsed(ms: number): string {
	const s = Math.max(0, Math.round(ms / 1000));
	if (s < 60) return `${s}s`;
	if (s < 3600) return `${Math.floor(s / 60)}m${s % 60 ? ` ${s % 60}s` : ""}`;
	return `${Math.floor(s / 3600)}h ${Math.floor((s % 3600) / 60)}m`;
}

/** Render the auto-appearing widget: one row per running bash job. */
export function renderJobsWidget(jobs: readonly JobLike[], opts: WidgetOptions): string[] | undefined {
	const running = jobs.filter(j => j.type === "bash" && j.status === "running");
	if (running.length === 0) return undefined;
	const spinner = SPINNER_FRAMES[(opts.tick ?? 0) % SPINNER_FRAMES.length];
	const maxRows = opts.maxRows ?? 4;
	const shown = running.slice(0, maxRows);
	const lines = shown.map(j => {
		const last = opts.lastLine?.(j.id);
		const base = `${spinner} ${formatElapsed(opts.now - j.startTime)} ${j.label}`;
		return last ? `${base} — ${last}` : base;
	});
	if (running.length > maxRows) lines.push(`  +${running.length - maxRows} more`);
	return lines;
}

/** Default in-memory tail window per job (matches OutputSink's 50 KiB). */
const DEFAULT_TAIL_BYTES = 50 * 1024;

function isRecord(value: unknown): value is Record<string, unknown> {
	return typeof value === "object" && value !== null;
}

/** Extract {jobId, text} from a bash tool_execution_update payload. */
function bashJobUpdate(event: unknown): { jobId: string; text: string } | undefined {
	if (!isRecord(event)) return undefined;
	const partial = event.partialResult;
	if (!isRecord(partial)) return undefined;
	const details = partial.details;
	if (!isRecord(details) || !isRecord(details.async)) return undefined;
	const { jobId, type } = details.async;
	if (typeof jobId !== "string" || jobId.length === 0 || type !== "bash") return undefined;
	if (!Array.isArray(partial.content)) return undefined;
	for (const item of partial.content) {
		if (isRecord(item) && item.type === "text" && typeof item.text === "string") {
			return { jobId, text: item.text };
		}
	}
	return undefined;
}

/**
 * Per-job cumulative output tails, fed by `tool_execution_update` events.
 * Bash updates carry the full TailBuffer snapshot (not a delta), so ingest
 * replaces rather than appends.
 */
export class TailStore {
	#tails = new Map<string, string>();
	#maxBytes: number;

	constructor(maxBytes = DEFAULT_TAIL_BYTES) {
		this.#maxBytes = maxBytes;
	}

	ingest(event: unknown): void {
		const update = bashJobUpdate(event);
		if (!update) return;
		let text = update.text;
		if (text.length > this.#maxBytes) text = text.slice(text.length - this.#maxBytes);
		this.#tails.set(update.jobId, text);
	}

	text(jobId: string): string | undefined {
		return this.#tails.get(jobId);
	}

	lastLine(jobId: string): string | undefined {
		const text = this.#tails.get(jobId);
		if (text === undefined) return undefined;
		const lines = text.split("\n").filter(l => l.trim().length > 0);
		return lines.at(-1);
	}

	drop(jobId: string): void {
		this.#tails.delete(jobId);
	}
}

/** Manager surface the hub needs (structural subset of AsyncJobManager). */
export interface JobManagerLike {
	getRunningJobs(): readonly JobLike[];
	getRecentJobs(limit?: number): readonly JobLike[];
	getJob(id: string): JobLike | undefined;
	cancel(id: string): boolean;
}

export interface JobsHubDeps {
	manager: JobManagerLike;
	tails: TailStore;
	done: () => void;
	requestRender: () => void;
	/** Print the job's log into the chat transcript (native scrollback). */
	openLog: (jobId: string) => void;
	/** Chord that toggles the hub closed (besides escape). */
	toggleKey?: KeyId;
	now?: () => number;
}

const RECENT_LIMIT = 10;

const STATUS_GLYPHS: Record<JobLike["status"], string> = {
	running: "●",
	completed: "✓",
	failed: "✗",
	cancelled: "⊘",
};

/**
 * Ctrl+J / `/bashjobs` overlay: bash-job list. Enter dispatches the
 * selected job's log to `openLog` (chat-transcript dump) and closes the
 * hub. Standalone pi-tui Component (render/handleInput/dispose).
 */
export class JobsHubOverlay {
	#deps: JobsHubDeps;
	#selectedId: string | undefined;

	constructor(deps: JobsHubDeps) {
		this.#deps = deps;
	}

	#jobs(): JobLike[] {
		const running = this.#deps.manager.getRunningJobs().filter(j => j.type === "bash");
		const recent = this.#deps.manager.getRecentJobs(RECENT_LIMIT).filter(j => j.type === "bash");
		return [...running, ...recent];
	}

	#selectedIndex(jobs: readonly JobLike[]): number {
		const index = jobs.findIndex(j => j.id === this.#selectedId);
		return index >= 0 ? index : 0;
	}

	render(_width: number): string[] {
		const jobs = this.#jobs();
		const selected = this.#selectedIndex(jobs);
		const now = this.#deps.now?.() ?? Date.now();
		const lines = [" Bash Jobs", ""];
		if (jobs.length === 0) lines.push("  no background bash jobs");
		for (let i = 0; i < jobs.length; i++) {
			const j = jobs[i];
			const cursor = i === selected ? "›" : " ";
			lines.push(` ${cursor} ${STATUS_GLYPHS[j.status]} ${formatElapsed(now - j.startTime)} ${j.label}`);
		}
		lines.push("", " ↑/↓ select · enter log · x cancel · esc close");
		return lines;
	}

	handleInput(data: string): void {
		const jobs = this.#jobs();
		if (matchesKey(data, "escape") || (this.#deps.toggleKey && matchesKey(data, this.#deps.toggleKey))) {
			this.#deps.done();
			return;
		}
		if (jobs.length === 0) return;
		const selected = this.#selectedIndex(jobs);
		if (data === "j" || matchesKey(data, "down")) {
			this.#selectedId = jobs[Math.min(selected + 1, jobs.length - 1)].id;
		} else if (data === "k" || matchesKey(data, "up")) {
			this.#selectedId = jobs[Math.max(selected - 1, 0)].id;
		} else if (data === "x") {
			this.#deps.manager.cancel(jobs[selected].id);
		} else if (matchesKey(data, "enter") || data === "\r" || data === "\n") {
			this.#deps.openLog(jobs[selected].id);
			this.#deps.done();
			return;
		} else {
			return;
		}
		this.#deps.requestRender();
	}

	dispose(): void {}

	invalidate(): void {}
}

const ARTIFACT_FOOTER_RE = /artifact:\/\/([\w.-]+)|Artifact: ([\w.-]+)/;
/** Skip the possibly-unflushed end of the in-memory tail when matching. */
const TAIL_PROBE_END_SKIP = 1024;
const TAIL_PROBE_LEN = 3072;
/** How much of a candidate file's end to search for the probe. */
const FILE_MATCH_WINDOW = 256 * 1024;

/**
 * Locate a bash job's spill artifact file on disk.
 *
 * Finished jobs advertise their artifact id in the result footer
 * (`artifact://<id>` / `Artifact: <id>`). Running jobs never expose the
 * id, so match candidate `*.bash.log` files (modified after the job
 * started) against a probe slice of the in-memory tail — skipping the
 * final bytes that may not have hit the file sink yet. Column-capped
 * tails won't match the raw file; callers fall back to the tail.
 */
export function findArtifactFile(
	job: JobLike,
	opts: { artifactsDir?: string; tailText?: string },
): string | undefined {
	const dir = opts.artifactsDir;
	if (!dir || !existsSync(dir)) return undefined;

	const footer = job.resultText?.match(ARTIFACT_FOOTER_RE);
	const artifactId = footer?.[1] ?? footer?.[2];
	if (artifactId !== undefined) {
		const match = readdirSync(dir).find(f => f.startsWith(`${artifactId}.`));
		return match ? `${dir}/${match}` : undefined;
	}

	const tail = opts.tailText;
	if (job.status !== "running" || tail === undefined) return undefined;
	const probeEnd = tail.length - TAIL_PROBE_END_SKIP;
	if (probeEnd < TAIL_PROBE_LEN) return undefined; // small outputs never spill
	const probe = tail.slice(probeEnd - TAIL_PROBE_LEN, probeEnd);

	for (const name of readdirSync(dir)) {
		if (!name.endsWith(".bash.log")) continue;
		const path = `${dir}/${name}`;
		try {
			if (statSync(path).mtimeMs < job.startTime) continue;
			const content = readFileSync(path, "utf8");
			const window = content.length > FILE_MATCH_WINDOW ? content.slice(-FILE_MATCH_WINDOW) : content;
			if (window.includes(probe)) return path;
		} catch {
			// raced with eviction/rotation — skip candidate
		}
	}
	return undefined;
}

/** customType of the chat message that carries a dumped job log. */
export const LOG_MESSAGE_TYPE = "jobs-hub:log";

export interface LogMessageDetails {
	label: string;
	status: JobLike["status"];
	log: string;
}

/** Payload for `pi.sendMessage` carrying a job log dump. */
export interface LogMessage {
	customType: string;
	content: string;
	display: boolean;
	details: LogMessageDetails;
}

export interface JobLogDeps {
	manager: JobManagerLike;
	tails: TailStore;
	/** Spill artifact file path for a job, when it exists on disk. */
	artifactFile?: (jobId: string) => string | undefined;
}

/** Resolve a job's log: spill artifact file > in-memory tail > result text. */
export function jobLogText(jobId: string, deps: JobLogDeps): string {
	const file = deps.artifactFile?.(jobId);
	if (file !== undefined) {
		try {
			const raw = readFileSync(file, "utf8");
			return raw.length > DEFAULT_TAIL_BYTES ? raw.slice(raw.length - DEFAULT_TAIL_BYTES) : raw;
		} catch {
			// fall through to the in-memory tail
		}
	}
	const tail = deps.tails.text(jobId);
	if (tail !== undefined) return tail;
	return deps.manager.getJob(jobId)?.resultText ?? "(no output yet)";
}

/**
 * Build the chat message for a log dump. The LLM only ever sees the short
 * `content` line (custom messages are forwarded as developer messages);
 * the full log rides `details`, which never reaches the model.
 */
export function buildLogMessage(job: JobLike, log: string): LogMessage {
	return {
		customType: LOG_MESSAGE_TYPE,
		content: `[jobs-hub] Showed the user the log of bash job "${job.label}" (${job.status}). No action needed.`,
		display: true,
		details: { label: job.label, status: job.status, log },
	};
}

/**
 * Transcript renderer for LOG_MESSAGE_TYPE: header + raw log as plain
 * text (no markdown mangling). Returning undefined falls back to omp's
 * default custom-message card (e.g. entries reloaded without details).
 */
export function renderLogMessage(message: { details?: Partial<LogMessageDetails> }): Text | undefined {
	const details = message.details;
	if (details?.log === undefined) return undefined;
	const glyph = details.status !== undefined ? STATUS_GLYPHS[details.status] : undefined;
	const header = [glyph, details.label ?? "bash job"].filter(Boolean).join(" ");
	return new Text(`${header}\n\n${details.log}`, 1, 0);
}

/** Narrow structural view of ExtensionAPI — keeps tests dependency-free. */
export interface JobsHubPi {
	registerShortcut(
		key: string,
		opts: { description?: string; handler: (ctx: JobsHubCtx) => void | Promise<void> },
	): void;
	registerCommand(
		name: string,
		opts: { description?: string; handler: (args: string, ctx: JobsHubCtx) => void | Promise<void> },
	): void;
	on(event: string, handler: (event: unknown, ctx: JobsHubCtx) => void): void;
	sendMessage(
		message: LogMessage,
		options?: { deliverAs?: "steer" | "followUp" | "nextTurn"; triggerTurn?: boolean },
	): void;
	registerMessageRenderer(
		customType: string,
		renderer: (message: { details?: Partial<LogMessageDetails> }, options: unknown, theme: unknown) => unknown,
	): void;
}

/** Narrow structural view of ExtensionContext. */
export interface JobsHubCtx {
	hasUI: boolean;
	ui: {
		setWidget(key: string, content: string[] | undefined, opts?: { placement?: string }): void;
		custom(
			factory: (tui: JobsHubTui, theme: unknown, keybindings: unknown, done: (result?: void) => void) => unknown,
			opts?: { overlay?: boolean },
		): Promise<unknown>;
	};
	sessionManager?: { getArtifactsDir?: () => string | undefined };
}

export interface JobsHubTui {
	requestRender(): void;
}

export interface JobsHubOptions {
	/** Job manager accessor (defaults to AsyncJobManager.instance()). */
	manager: () => JobManagerLike | undefined;
	now?: () => number;
	/** Widget poll period in ms while jobs run. */
	intervalMs?: number;
}

const WIDGET_KEY = "jobs-hub";
const TOGGLE_KEY = "ctrl+j";
const WIDGET_POLL_MS = 1000;

export function createJobsHub(pi: JobsHubPi, opts: JobsHubOptions): void {
	const tails = new TailStore();
	const now = opts.now ?? Date.now;
	const intervalMs = opts.intervalMs ?? WIDGET_POLL_MS;
	let tick = 0;
	let timer: NodeJS.Timeout | undefined;
	let widgetVisible = false;

	const refreshWidget = (ctx: JobsHubCtx): void => {
		if (!ctx.hasUI) return;
		tick++;
		const manager = opts.manager();
		const lines = manager
			? renderJobsWidget(manager.getRunningJobs(), {
					now: now(),
					tick,
					lastLine: id => tails.lastLine(id),
				})
			: undefined;
		if (lines === undefined && !widgetVisible) return; // avoid clearing a widget we never set
		widgetVisible = lines !== undefined;
		ctx.ui.setWidget(WIDGET_KEY, lines);
		// Poll while jobs run so elapsed times and spinner stay live even
		// when no tool events fire (e.g. agent idle with background jobs).
		if (lines !== undefined && timer === undefined) {
			timer = setInterval(() => refreshWidget(ctx), intervalMs);
			timer.unref?.();
		} else if (lines === undefined && timer !== undefined) {
			clearInterval(timer);
			timer = undefined;
		}
	};

	const openLog = (ctx: JobsHubCtx, jobId: string): void => {
		const manager = opts.manager() ?? EMPTY_MANAGER;
		const job = manager.getJob(jobId);
		if (!job) return;
		const log = jobLogText(jobId, {
			manager,
			tails,
			artifactFile: id => {
				const j = manager.getJob(id);
				if (!j) return undefined;
				return findArtifactFile(j, {
					artifactsDir: ctx.sessionManager?.getArtifactsDir?.(),
					tailText: tails.text(id),
				});
			},
		});
		pi.sendMessage(buildLogMessage(job, log));
	};

	const openHub = async (ctx: JobsHubCtx): Promise<void> => {
		if (!ctx.hasUI) return;
		await ctx.ui.custom(
			(tui, _theme, _keybindings, done) =>
				new JobsHubOverlay({
					manager: opts.manager() ?? EMPTY_MANAGER,
					tails,
					done: () => done(),
					requestRender: () => tui.requestRender(),
					now,
					toggleKey: TOGGLE_KEY,
					openLog: id => openLog(ctx, id),
				}),
			{ overlay: true },
		);
	};

	pi.registerShortcut(TOGGLE_KEY, { description: "Bash jobs hub", handler: openHub });
	// "/jobs" is taken by omp's builtin (plain status printout); builtins
	// shadow extension commands, so use a distinct name.
	pi.registerCommand("bashjobs", { description: "Bash jobs hub (logs, cancel)", handler: (_args, ctx) => openHub(ctx) });
	pi.registerMessageRenderer(LOG_MESSAGE_TYPE, message => renderLogMessage(message));
	pi.on("tool_execution_update", (event, ctx) => {
		tails.ingest(event);
		refreshWidget(ctx);
	});
	pi.on("tool_execution_start", (_event, ctx) => refreshWidget(ctx));
	pi.on("tool_execution_end", (_event, ctx) => refreshWidget(ctx));
	pi.on("session_shutdown", () => {
		clearInterval(timer);
		timer = undefined;
	});
}

const EMPTY_MANAGER: JobManagerLike = {
	getRunningJobs: () => [],
	getRecentJobs: () => [],
	getJob: () => undefined,
	cancel: () => false,
};

/** omp extension entry point. */
export default function jobsHub(pi: JobsHubPi): void {
	createJobsHub(pi, {
		manager: () => {
			// Deferred import target: the legacy-pi shim maps this specifier
			// onto the running agent's live module, so instance() is the
			// session's own singleton.
			return AsyncJobManager.instance?.();
		},
	});
}
