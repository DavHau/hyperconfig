/**
 * Direnv extension tests. Run from the oh-my-pi checkout so the
 * @oh-my-pi/* workspace packages resolve (node_modules symlink next to
 * this file):
 *   cd ~/projects/oh-my-pi && nix-shell -p bun --run \
 *     'bun test ~/synced/projects/hyperconfig/modules/nixos/direnv/direnv.test.ts'
 */
import { describe, expect, it } from "bun:test";
import { loadExtensions } from "@oh-my-pi/pi-coding-agent/extensibility/extensions";
import {
	applyDirenvExport,
	createDirenvExtension,
	createDirenvLoader,
	type DirenvPi,
	type DirenvRunResult,
	type DirenvState,
} from "./direnv";

describe("applyDirenvExport", () => {
	it("treats empty or whitespace-only output as in-sync and leaves env untouched", () => {
		const env: Record<string, string | undefined> = { KEEP: "1" };
		expect(applyDirenvExport("", env)).toEqual({ ok: true, loaded: 0, unset: 0 });
		expect(applyDirenvExport("  \n\t ", env)).toEqual({ ok: true, loaded: 0, unset: 0 });
		expect(env).toEqual({ KEEP: "1" });
	});

	it("assigns string values and deletes null values, counting each", () => {
		const env: Record<string, string | undefined> = { OLD: "x", KEEP: "1" };
		const result = applyDirenvExport(JSON.stringify({ FOO: "bar", BAZ: "qux", OLD: null }), env);
		expect(result).toEqual({ ok: true, loaded: 2, unset: 1 });
		expect(env.FOO).toBe("bar");
		expect(env.BAZ).toBe("qux");
		expect("OLD" in env).toBe(false);
		expect(env.KEEP).toBe("1");
	});

	it("rejects malformed JSON without touching env", () => {
		const env: Record<string, string | undefined> = { KEEP: "1" };
		expect(applyDirenvExport("{not json", env)).toEqual({ ok: false, loaded: 0, unset: 0 });
		expect(env).toEqual({ KEEP: "1" });
	});
});

/** Runner fake that gates each invocation on a caller-controlled promise. */
function makeGatedRunner() {
	const calls: string[] = [];
	const gates: Array<PromiseWithResolvers<DirenvRunResult>> = [];
	const run = (cwd: string): Promise<DirenvRunResult> => {
		calls.push(cwd);
		const gate = Promise.withResolvers<DirenvRunResult>();
		gates.push(gate);
		return gate.promise;
	};
	return { run, calls, gates };
}

describe("createDirenvLoader", () => {
	it("emits loading before the run starts, applies the export, then emits ok", async () => {
		const statuses: DirenvState[] = [];
		const cwds: string[] = [];
		let loadingSeenBeforeRun = false;
		const env: Record<string, string | undefined> = {};
		const loader = createDirenvLoader({
			env,
			run: async cwd => {
				cwds.push(cwd);
				loadingSeenBeforeRun = statuses.includes("loading");
				return { code: 0, stdout: JSON.stringify({ FOO: "bar" }) };
			},
		});
		await loader.load("/proj", state => statuses.push(state));
		expect(loadingSeenBeforeRun).toBe(true);
		expect(cwds).toEqual(["/proj"]);
		expect(statuses).toEqual(["loading", "ok"]);
		expect(env.FOO).toBe("bar");
	});

	it("emits error on malformed stdout and leaves env untouched", async () => {
		const env: Record<string, string | undefined> = { KEEP: "1" };
		const statuses: DirenvState[] = [];
		const loader = createDirenvLoader({
			env,
			run: async () => ({ code: 0, stdout: "{oops" }),
		});
		await loader.load("/proj", state => statuses.push(state));
		expect(statuses).toEqual(["loading", "error"]);
		expect(env).toEqual({ KEEP: "1" });
	});

	it("emits error on nonzero or null exit codes and leaves env untouched", async () => {
		for (const code of [2, null]) {
			const env: Record<string, string | undefined> = { KEEP: "1" };
			const statuses: DirenvState[] = [];
			const loader = createDirenvLoader({
				env,
				run: async () => ({ code, stdout: JSON.stringify({ FOO: "x" }) }),
			});
			await loader.load("/proj", state => statuses.push(state));
			expect(statuses).toEqual(["loading", "error"]);
			expect(env).toEqual({ KEEP: "1" });
		}
	});

	it("resolves with error status when the runner rejects", async () => {
		const statuses: DirenvState[] = [];
		const loader = createDirenvLoader({
			env: {},
			run: () => Promise.reject(new Error("spawn failed")),
		});
		await loader.load("/proj", state => statuses.push(state));
		expect(statuses).toEqual(["loading", "error"]);
	});

	it("serializes loads: a second load waits for the in-flight run to settle", async () => {
		const { run, calls, gates } = makeGatedRunner();
		const loader = createDirenvLoader({ env: {}, run });
		const first = loader.load("/a");
		const second = loader.load("/b");
		await Bun.sleep(0);
		expect(calls).toEqual(["/a"]);
		gates[0].resolve({ code: 0, stdout: "{}" });
		await first;
		await Bun.sleep(0);
		expect(calls).toEqual(["/a", "/b"]);
		gates[1].resolve({ code: 0, stdout: "{}" });
		await second;
	});

	it("resolves after the timeout budget yet still applies the late result in the background", async () => {
		const env: Record<string, string | undefined> = {};
		const statuses: DirenvState[] = [];
		const gate = Promise.withResolvers<DirenvRunResult>();
		const loader = createDirenvLoader({ env, run: () => gate.promise, timeoutMs: 10 });
		await loader.load("/proj", state => statuses.push(state));
		// load() returned on budget expiry; the run never settled.
		expect(statuses).toEqual(["loading"]);
		expect(env.FOO).toBeUndefined();
		gate.resolve({ code: 0, stdout: JSON.stringify({ FOO: "bar" }) });
		await Bun.sleep(0);
		expect(env.FOO).toBe("bar");
		expect(statuses).toEqual(["loading", "ok"]);
	});

	it("after an early-timeout return, the next load still waits for the stale run", async () => {
		const { run, calls, gates } = makeGatedRunner();
		const loader = createDirenvLoader({ env: {}, run, timeoutMs: 10 });
		await loader.load("/one"); // budget expires, run stays in flight
		const second = loader.load("/two");
		await Bun.sleep(20);
		expect(calls).toEqual(["/one"]);
		gates[0].resolve({ code: 0, stdout: "{}" });
		await Bun.sleep(0);
		expect(calls).toEqual(["/one", "/two"]);
		gates[1].resolve({ code: 0, stdout: "{}" });
		await second;
	});
});

interface FakeCtx {
	cwd: string;
	hasUI: boolean;
	ui: {
		setStatus: (key: string, text: string) => void;
		theme: { fg: (color: string, text: string) => string };
	};
}

function makeCtx(over: Partial<FakeCtx> = {}) {
	const statusLog: Array<[string, string]> = [];
	const ctx: FakeCtx = {
		cwd: "/proj",
		hasUI: true,
		ui: {
			setStatus: (key, text) => {
				statusLog.push([key, text]);
			},
			theme: { fg: (color, text) => `[${color}]${text}` },
		},
		...over,
	};
	return { ctx, statusLog };
}

function makePi() {
	const events = new Map<string, Array<(event: unknown, ctx: FakeCtx) => void | Promise<void>>>();
	const pi = {
		on: (event: string, handler: (event: unknown, ctx: FakeCtx) => void | Promise<void>) => {
			const list = events.get(event) ?? [];
			list.push(handler);
			events.set(event, list);
		},
	} as DirenvPi;
	return { pi, events };
}

async function emit(
	events: Map<string, Array<(event: unknown, ctx: FakeCtx) => void | Promise<void>>>,
	name: string,
	event: unknown,
	ctx: FakeCtx,
) {
	for (const handler of events.get(name) ?? []) {
		await handler(event, ctx);
	}
}

describe("createDirenvExtension", () => {
	it("session_start triggers a load in ctx.cwd and applies the export to deps.env", async () => {
		const { pi, events } = makePi();
		const calls: string[] = [];
		const env: Record<string, string | undefined> = {};
		createDirenvExtension(pi, {
			env,
			run: async cwd => {
				calls.push(cwd);
				return { code: 0, stdout: JSON.stringify({ FOO: "bar" }) };
			},
		});
		const { ctx } = makeCtx();
		await emit(events, "session_start", {}, ctx);
		await Bun.sleep(0);
		expect(calls).toEqual(["/proj"]);
		expect(env.FOO).toBe("bar");
	});

	it("ignores tool_result events for non-bash tools", async () => {
		const { pi, events } = makePi();
		const calls: string[] = [];
		createDirenvExtension(pi, {
			env: {},
			run: async cwd => {
				calls.push(cwd);
				return { code: 0, stdout: "{}" };
			},
		});
		const { ctx } = makeCtx();
		await emit(events, "tool_result", { toolName: "read" }, ctx);
		await Bun.sleep(0);
		expect(calls).toEqual([]);
	});

	it("reloads direnv after a bash tool_result", async () => {
		const { pi, events } = makePi();
		const calls: string[] = [];
		createDirenvExtension(pi, {
			env: {},
			run: async cwd => {
				calls.push(cwd);
				return { code: 0, stdout: "{}" };
			},
		});
		const { ctx } = makeCtx();
		await emit(events, "tool_result", { toolName: "bash" }, ctx);
		await Bun.sleep(0);
		expect(calls).toEqual(["/proj"]);
	});

	it("renders themed status: loading while running, then ok on success", async () => {
		const { pi, events } = makePi();
		const gate = Promise.withResolvers<DirenvRunResult>();
		createDirenvExtension(pi, { env: {}, run: () => gate.promise });
		const { ctx, statusLog } = makeCtx();
		const emitting = emit(events, "session_start", {}, ctx);
		await Bun.sleep(0);
		expect(statusLog).toContainEqual(["direnv", "[warning]direnv …"]);
		gate.resolve({ code: 0, stdout: "{}" });
		await emitting;
		await Bun.sleep(0);
		expect(statusLog.at(-1)).toEqual(["direnv", "[success]direnv ✓"]);
	});

	it("renders themed error status when direnv fails", async () => {
		const { pi, events } = makePi();
		createDirenvExtension(pi, { env: {}, run: async () => ({ code: 1, stdout: "" }) });
		const { ctx, statusLog } = makeCtx();
		await emit(events, "session_start", {}, ctx);
		await Bun.sleep(0);
		expect(statusLog.at(-1)).toEqual(["direnv", "[error]direnv ✗"]);
	});

	it("makes zero ui calls when ctx.hasUI is false", async () => {
		const { pi, events } = makePi();
		createDirenvExtension(pi, { env: {}, run: async () => ({ code: 0, stdout: "{}" }) });
		const { ctx, statusLog } = makeCtx({ hasUI: false });
		await emit(events, "session_start", {}, ctx);
		await Bun.sleep(0);
		expect(statusLog).toEqual([]);
	});
});

describe("extension loading", () => {
	it("loads under omp's real extension loader without errors", async () => {
		const result = await loadExtensions([`${import.meta.dir}/direnv.ts`], "/tmp");
		expect(result.errors).toEqual([]);
		expect(result.extensions).toHaveLength(1);
	});
});
