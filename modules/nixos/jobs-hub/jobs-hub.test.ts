/**
 * Jobs-hub extension tests. Run from the oh-my-pi checkout so the
 * @oh-my-pi/* workspace packages resolve (node_modules symlink next to
 * this file):
 *   cd ~/projects/oh-my-pi && nix-shell -p bun --run \
 *     'bun test ~/projects/hyperconfig/modules/nixos/jobs-hub/jobs-hub.test.ts'
 */
import { describe, expect, it } from "bun:test";
import { mkdirSync, writeFileSync } from "node:fs";
import { loadExtensions } from "@oh-my-pi/pi-coding-agent/extensibility/extensions";
import {
	buildLogMessage,
	createJobsHub,
	findArtifactFile,
	jobLogText,
	type JobsHubCtx,
	type JobsHubDeps,
	JobsHubOverlay,
	type JobsHubPi,
	LOG_MESSAGE_TYPE,
	type LogMessage,
	renderJobsWidget,
	renderLogMessage,
	TailStore,
} from "./jobs-hub";

interface TestJob {
	id: string;
	type: "bash" | "task";
	status: "running" | "completed" | "failed" | "cancelled";
	startTime: number;
	label: string;
	resultText?: string;
}

const NOW = 1_800_000_000_000;

function job(over: Partial<TestJob> = {}): TestJob {
	return {
		id: over.id ?? "job_1",
		type: over.type ?? "bash",
		status: over.status ?? "running",
		startTime: over.startTime ?? NOW - 12_000,
		label: over.label ?? "sleep 60",
		...over,
	};
}

describe("renderJobsWidget", () => {
	it("renders one row per running bash job with label and elapsed", () => {
		const lines = renderJobsWidget([job({ id: "a", label: "make world" })], {
			now: NOW,
			lastLine: () => "compiling...",
		});
		expect(lines).toBeDefined();
		expect(lines).toHaveLength(1);
		const row = Bun.stripANSI(lines![0]);
		expect(row).toContain("make world");
		expect(row).toContain("12s");
		expect(row).toContain("compiling...");
	});

	it("returns undefined when no bash jobs are running", () => {
		expect(renderJobsWidget([], { now: NOW })).toBeUndefined();
		expect(
			renderJobsWidget([job({ type: "task" }), job({ status: "completed" })], { now: NOW }),
		).toBeUndefined();
	});
	it("caps rows and reports the overflow count", () => {
		const jobs = Array.from({ length: 6 }, (_, i) => job({ id: `j${i}`, label: `cmd ${i}` }));
		const lines = renderJobsWidget(jobs, { now: NOW });
		expect(lines).toHaveLength(5);
		expect(Bun.stripANSI(lines![4])).toContain("+2 more");
		expect(Bun.stripANSI(lines!.join("\n"))).toContain("cmd 3");
		expect(Bun.stripANSI(lines!.join("\n"))).not.toContain("cmd 4");
	});
});

function updateEvent(jobId: string, text: string, jobType = "bash") {
	return {
		type: "tool_execution_update" as const,
		toolCallId: "call_1",
		toolName: "bash",
		args: {},
		partialResult: {
			content: [{ type: "text", text }],
			details: { async: { state: "running", jobId, type: jobType } },
		},
	};
}

describe("TailStore", () => {
	it("captures the cumulative tail and exposes the last line", () => {
		const store = new TailStore();
		store.ingest(updateEvent("job_a", "one\ntwo"));
		store.ingest(updateEvent("job_a", "one\ntwo\nthree\n"));
		expect(store.text("job_a")).toBe("one\ntwo\nthree\n");
		expect(store.lastLine("job_a")).toBe("three");
	});

	it("ignores payloads without a bash job correlation", () => {
		const store = new TailStore();
		store.ingest({ type: "tool_execution_update", toolCallId: "c", toolName: "bash", args: {}, partialResult: { content: [{ type: "text", text: "x" }], details: {} } });
		store.ingest(updateEvent("job_t", "hi", "task"));
		expect(store.text("job_t")).toBeUndefined();
		expect(store.lastLine("job_t")).toBeUndefined();
	});

	it("keeps only the trailing window of oversized tails", () => {
		const store = new TailStore(1024);
		const big = `${"x".repeat(2000)}\nEND`;
		store.ingest(updateEvent("job_b", big));
		expect(store.text("job_b")!.length).toBeLessThanOrEqual(1024);
		expect(store.text("job_b")!.endsWith("END")).toBe(true);
	});
});

function makeManager(jobs: TestJob[]) {
	return {
		getRunningJobs: () => jobs.filter(j => j.status === "running"),
		getRecentJobs: (limit = 10) => jobs.filter(j => j.status !== "running").slice(0, limit),
		getJob: (id: string) => jobs.find(j => j.id === id),
		cancel: (id: string) => {
			const j = jobs.find(j => j.id === id);
			if (!j || j.status !== "running") return false;
			j.status = "cancelled";
			return true;
		},
	};
}

function makeOverlay(jobs: TestJob[], over: Partial<JobsHubDeps> = {}) {
	let doneCalls = 0;
	const manager = makeManager(jobs);
	const overlay = new JobsHubOverlay({
		manager,
		tails: new TailStore(),
		done: () => {
			doneCalls++;
		},
		requestRender: () => {},
		openLog: () => {},
		now: () => NOW,
		...over,
	});
	return { overlay, manager, doneCalls: () => doneCalls };
}

function view(overlay: JobsHubOverlay, width = 80): string {
	return Bun.stripANSI(overlay.render(width).join("\n"));
}

describe("JobsHubOverlay list", () => {
	it("lists running then recent bash jobs, ignoring task jobs", () => {
		const jobs = [
			job({ id: "r1", label: "make -j8" }),
			job({ id: "t1", type: "task", label: "subagent stuff" }),
			job({ id: "f1", status: "completed", label: "seq 1 10" }),
		];
		const { overlay } = makeOverlay(jobs);
		const text = view(overlay);
		expect(text).toContain("make -j8");
		expect(text).toContain("seq 1 10");
		expect(text).not.toContain("subagent stuff");
		expect(text.indexOf("make -j8")).toBeLessThan(text.indexOf("seq 1 10"));
	});

	it("moves the selection cursor with j/k and arrow keys", () => {
		const jobs = [job({ id: "a", label: "first cmd" }), job({ id: "b", label: "second cmd" })];
		const { overlay } = makeOverlay(jobs);
		const cursorLine = (s: string) => s.split("\n").find(l => l.includes("›"));
		expect(cursorLine(view(overlay))).toContain("first cmd");
		overlay.handleInput("j");
		expect(cursorLine(view(overlay))).toContain("second cmd");
		overlay.handleInput("k");
		expect(cursorLine(view(overlay))).toContain("first cmd");
		overlay.handleInput("\x1b[B"); // down arrow
		expect(cursorLine(view(overlay))).toContain("second cmd");
	});

	it("escape closes the hub", () => {
		const { overlay, doneCalls } = makeOverlay([job()]);
		overlay.handleInput("\x1b");
		expect(doneCalls()).toBe(1);
	});

	it("x cancels the selected running job", () => {
		const jobs = [job({ id: "a", label: "long build" })];
		const { overlay } = makeOverlay(jobs);
		overlay.handleInput("x");
		expect(jobs[0].status).toBe("cancelled");
	});
});

describe("JobsHubOverlay log dispatch", () => {
	it("enter dispatches openLog with the selected job and closes the hub", () => {
		const opened: string[] = [];
		const jobs = [job({ id: "a", label: "first cmd" }), job({ id: "b", label: "second cmd" })];
		const { overlay, doneCalls } = makeOverlay(jobs, { openLog: id => opened.push(id) });
		overlay.handleInput("j");
		overlay.handleInput("\r");
		expect(opened).toEqual(["b"]);
		expect(doneCalls()).toBe(1);
	});
});

describe("jobLogText", () => {
	function deps(jobs: TestJob[], over: Partial<{ tails: TailStore; artifactFile: (id: string) => string | undefined }> = {}) {
		return { manager: makeManager(jobs), tails: new TailStore(), ...over };
	}

	it("prefers the spill artifact file over the in-memory tail", async () => {
		const file = `${process.env.TMPDIR ?? "/tmp"}/jobs-hub-test-${Date.now()}.log`;
		await Bun.write(file, "full history from artifact\n");
		try {
			const tails = new TailStore();
			tails.ingest(updateEvent("a", "short tail"));
			const text = jobLogText("a", deps([job({ id: "a" })], { tails, artifactFile: id => (id === "a" ? file : undefined) }));
			expect(text).toContain("full history from artifact");
			expect(text).not.toContain("short tail");
		} finally {
			await Bun.file(file).delete();
		}
	});

	it("falls back to the in-memory tail, then to the job result text", () => {
		const tails = new TailStore();
		tails.ingest(updateEvent("a", "tail text"));
		expect(jobLogText("a", deps([job({ id: "a" })], { tails }))).toBe("tail text");
		const finished = job({ id: "b", status: "completed", resultText: "result text" });
		expect(jobLogText("b", deps([finished]))).toBe("result text");
		expect(jobLogText("c", deps([]))).toBe("(no output yet)");
	});
});

describe("log message", () => {
	it("keeps the full log out of the LLM-visible content", () => {
		const msg = buildLogMessage(job({ label: "builder", status: "completed" }), "secret log body\nline two");
		expect(msg.customType).toBe(LOG_MESSAGE_TYPE);
		expect(msg.display).toBe(true);
		expect(msg.content).toContain("builder");
		expect(msg.content).not.toContain("secret log body");
		expect(msg.details.log).toBe("secret log body\nline two");
	});

	it("renders the full log into the transcript component", () => {
		const msg = buildLogMessage(job({ label: "builder" }), "line one\nline two");
		const component = renderLogMessage(msg);
		expect(component).toBeDefined();
		const text = Bun.stripANSI(component!.render(80).join("\n"));
		expect(text).toContain("builder");
		expect(text).toContain("line one");
		expect(text).toContain("line two");
	});

	it("falls back to the default card when details are missing", () => {
		expect(renderLogMessage({})).toBeUndefined();
	});
});

describe("findArtifactFile", () => {
	const tmp = () => {
		const dir = `${process.env.TMPDIR ?? "/tmp"}/jobs-hub-artifacts-${Date.now()}-${Math.random().toString(36).slice(2)}`;
		mkdirSync(dir, { recursive: true });
		return dir;
	};

	it("resolves a finished job's artifact from the resultText footer", () => {
		const dir = tmp();
		writeFileSync(`${dir}/42.bash.log`, "full log\n");
		const finished = {
			...job({ id: "a", status: "completed" }),
			resultText: "tail...\n[raw output: artifact://42]\nWall time: 3s",
		};
		expect(findArtifactFile(finished, { artifactsDir: dir })).toBe(`${dir}/42.bash.log`);
	});

	it("matches a running job's spill file by tail content", () => {
		const dir = tmp();
		const body = Array.from({ length: 3000 }, (_, i) => `logline ${i}`).join("\n");
		writeFileSync(`${dir}/7.bash.log`, body);
		const tailText = body.slice(-8000); // in-memory tail window
		const running = job({ id: "b", startTime: Date.now() - 60_000 });
		expect(findArtifactFile(running, { artifactsDir: dir, tailText })).toBe(`${dir}/7.bash.log`);
	});

	it("returns undefined when nothing matches", () => {
		const dir = tmp();
		writeFileSync(`${dir}/9.bash.log`, "unrelated content\n");
		const running = job({ id: "c" });
		expect(findArtifactFile(running, { artifactsDir: dir, tailText: "z".repeat(8000) })).toBeUndefined();
		expect(findArtifactFile(running, { artifactsDir: dir })).toBeUndefined();
		expect(findArtifactFile(running, {})).toBeUndefined();
	});
});

describe("createJobsHub", () => {
	type CustomFactory = Parameters<JobsHubCtx["ui"]["custom"]>[0];

	function makePi() {
		const shortcuts = new Map<string, (ctx: JobsHubCtx) => void | Promise<void>>();
		const commands = new Map<string, (args: string, ctx: JobsHubCtx) => void | Promise<void>>();
		const events = new Map<string, Array<(event: unknown, ctx: JobsHubCtx) => void>>();
		const sent: LogMessage[] = [];
		const renderers = new Set<string>();
		const pi: JobsHubPi = {
			registerShortcut: (key, opts) => {
				shortcuts.set(key, opts.handler);
			},
			registerCommand: (name, opts) => {
				commands.set(name, opts.handler);
			},
			on: (event, handler) => {
				const list = events.get(event) ?? [];
				list.push(handler);
				events.set(event, list);
			},
			sendMessage: message => {
				sent.push(message);
			},
			registerMessageRenderer: customType => {
				renderers.add(customType);
			},
		};
		return { pi, shortcuts, commands, events, sent, renderers };
	}
	function makeCtx() {
		const widgets: Array<string[] | undefined> = [];
		let customCall: { factory: CustomFactory; options: { overlay?: boolean } | undefined } | undefined;
		const ctx: JobsHubCtx = {
			hasUI: true,
			ui: {
				setWidget: (_key, content) => {
					widgets.push(content);
				},
				custom: (factory, options) => {
					customCall = { factory, options };
					return Promise.resolve(undefined);
				},
			},
			sessionManager: { getArtifactsDir: () => undefined },
		};
		return { ctx, widgets, customCall: () => customCall };
	}

	it("registers the ctrl+j shortcut and /bashjobs command", () => {
		const { pi, shortcuts, commands } = makePi();
		createJobsHub(pi, { manager: () => makeManager([]) });
		expect(shortcuts.has("ctrl+j")).toBe(true);
		expect(commands.has("bashjobs")).toBe(true);
	});

	it("opens the overlay via ctx.ui.custom with overlay: true", async () => {
		const { pi, shortcuts } = makePi();
		createJobsHub(pi, { manager: () => makeManager([job({ label: "npm run build" })]) });
		const { ctx, customCall } = makeCtx();
		await shortcuts.get("ctrl+j")!(ctx);
		const call = customCall();
		expect(call).toBeDefined();
		expect(call!.options?.overlay).toBe(true);
		const fakeTui = { requestRender: () => {}, terminal: { rows: 24 } };
		// factory returns Component (unknown to JobsHubCtx); we constructed it, so it IS a JobsHubOverlay
		const component = call!.factory(fakeTui, {}, {}, () => {}) as JobsHubOverlay;
		expect(Bun.stripANSI(component.render(80).join("\n"))).toContain("npm run build");
	});

	it("updates the widget from tool_execution_update events and clears it when idle", () => {
		const { pi, events } = makePi();
		const jobs = [job({ id: "job_w", label: "cargo build" })];
		createJobsHub(pi, { manager: () => makeManager(jobs), now: () => NOW });
		const { ctx, widgets } = makeCtx();
		for (const handler of events.get("tool_execution_update") ?? []) {
			handler(updateEvent("job_w", "Compiling hyper v1.0\n"), ctx);
		}
		const lastWidget = widgets.at(-1);
		expect(lastWidget).toBeDefined();
		expect(Bun.stripANSI(lastWidget!.join("\n"))).toContain("cargo build");
		expect(Bun.stripANSI(lastWidget!.join("\n"))).toContain("Compiling hyper v1.0");
		jobs[0].status = "completed";
		for (const handler of events.get("tool_execution_end") ?? []) {
			handler({}, ctx);
		}
		expect(widgets.at(-1)).toBeUndefined();
	});

	it("enter in the overlay dumps the log into chat via sendMessage", async () => {
		const { pi, shortcuts, events, sent, renderers } = makePi();
		const jobs = [job({ id: "job_l", label: "npm run build" })];
		createJobsHub(pi, { manager: () => makeManager(jobs) });
		expect(renderers.has(LOG_MESSAGE_TYPE)).toBe(true);
		const { ctx, customCall } = makeCtx();
		for (const handler of events.get("tool_execution_update") ?? []) {
			handler(updateEvent("job_l", "Compiling hyper v1.0\n"), ctx);
		}
		await shortcuts.get("ctrl+j")!(ctx);
		const fakeTui = { requestRender: () => {}, terminal: { rows: 24 } };
		const overlay = customCall()!.factory(fakeTui, {}, {}, () => {}) as JobsHubOverlay;
		overlay.handleInput("\r");
		expect(sent).toHaveLength(1);
		expect(sent[0].customType).toBe(LOG_MESSAGE_TYPE);
		expect(sent[0].display).toBe(true);
		expect(sent[0].content).not.toContain("Compiling hyper v1.0");
		expect(sent[0].details.log).toContain("Compiling hyper v1.0");
	});
});

describe("extension loading", () => {
	it("loads under omp's real extension loader without errors", async () => {
		const result = await loadExtensions([`${import.meta.dir}/jobs-hub.ts`], "/tmp");
		expect(result.errors).toEqual([]);
		expect(result.extensions).toHaveLength(1);
		const extension = result.extensions[0];
		expect(extension.shortcuts.has("ctrl+j")).toBe(true);
		expect(extension.commands.has("bashjobs")).toBe(true);
	});
});
