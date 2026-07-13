/**
 * Superpowers bootstrap extension tests. Run from the oh-my-pi checkout so
 * the @oh-my-pi/* workspace packages resolve (node_modules symlink next to
 * this file):
 *   cd ~/projects/oh-my-pi && nix-shell -p bun --run \
 *     'bun test ~/projects/hyperconfig/modules/nixos/superpowers/superpowers.test.ts'
 */
import { afterAll, describe, expect, it } from "bun:test";
import { loadExtensions } from "@oh-my-pi/pi-coding-agent/extensibility/extensions";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
	BOOTSTRAP_MARKER,
	buildBootstrap,
	createSuperpowersExtension,
	type SuperpowersMessage,
	type SuperpowersPi,
} from "./superpowers";

const SKILL_MD = `---
name: using-superpowers
description: Use when starting any conversation
---

<EXTREMELY-IMPORTANT>
If a skill applies, you MUST use it.
</EXTREMELY-IMPORTANT>

## The Rule

Invoke relevant skills BEFORE any response.
`;

const tempRoots: string[] = [];
afterAll(() => {
	for (const dir of tempRoots) rmSync(dir, { recursive: true, force: true });
});

/** Skills dir fixture with a using-superpowers/SKILL.md. */
function skillsDir(content: string | null = SKILL_MD): string {
	const root = mkdtempSync(join(tmpdir(), "superpowers-test-"));
	tempRoots.push(root);
	if (content !== null) {
		mkdirSync(join(root, "using-superpowers"), { recursive: true });
		writeFileSync(join(root, "using-superpowers", "SKILL.md"), content);
	}
	return root;
}

type Handler = (event: { type: string; messages?: SuperpowersMessage[] }) => Promise<unknown> | unknown;

/** Structural ExtensionAPI fake capturing registered handlers. */
function fakePi(): { pi: SuperpowersPi; emit: (type: string, messages?: SuperpowersMessage[]) => Promise<unknown> } {
	const handlers = new Map<string, Handler>();
	const pi: SuperpowersPi = {
		on(event, handler) {
			handlers.set(event, handler as Handler);
		},
	};
	return {
		pi,
		emit: async (type, messages) => {
			const handler = handlers.get(type);
			if (!handler) return undefined;
			return handler(messages === undefined ? { type } : { type, messages });
		},
	};
}

function user(text: string): SuperpowersMessage {
	return { role: "user", content: [{ type: "text", text }], timestamp: 1 };
}

function textOf(message: SuperpowersMessage): string {
	if (typeof message.content === "string") return message.content;
	if (!Array.isArray(message.content)) return "";
	let text = "";
	for (const part of message.content) {
		if (part && typeof part === "object" && "type" in part && part.type === "text" && "text" in part && typeof part.text === "string") {
			text += part.text;
		}
	}
	return text;
}

describe("buildBootstrap", () => {
	it("wraps the skill body with the marker and strips frontmatter", () => {
		const bootstrap = buildBootstrap(SKILL_MD);
		expect(bootstrap).toContain("<EXTREMELY_IMPORTANT>");
		expect(bootstrap).toContain(BOOTSTRAP_MARKER);
		expect(bootstrap).toContain("Invoke relevant skills BEFORE any response.");
		expect(bootstrap).not.toContain("description: Use when starting any conversation");
	});

	it("maps Superpowers vocabulary onto omp tools and jj", () => {
		const bootstrap = buildBootstrap(SKILL_MD);
		// omp native mechanisms
		expect(bootstrap).toContain("skill://");
		expect(bootstrap).toContain("`task` tool");
		expect(bootstrap).toContain("`todo` tool");
		// jj translation of the git-flow skills
		expect(bootstrap).toContain("jj workspace add");
		expect(bootstrap).toContain("jj describe");
	});
});

describe("bootstrap injection", () => {
	it("injects the bootstrap as first message on a fresh session", async () => {
		const { pi, emit } = fakePi();
		createSuperpowersExtension(pi, { skillsDir: skillsDir() });
		await emit("session_start");
		const result = (await emit("context", [user("hello")])) as { messages: SuperpowersMessage[] };
		expect(result.messages).toHaveLength(2);
		expect(result.messages[0].role).toBe("user");
		expect(textOf(result.messages[0])).toContain(BOOTSTRAP_MARKER);
		expect(textOf(result.messages[1])).toBe("hello");
	});

	it("inserts after leading compaction/branch summaries", async () => {
		const { pi, emit } = fakePi();
		createSuperpowersExtension(pi, { skillsDir: skillsDir() });
		await emit("session_start");
		const summaries: SuperpowersMessage[] = [
			{ role: "compactionSummary", summary: "earlier work", timestamp: 1 },
			{ role: "branchSummary", summary: "branched", timestamp: 2 },
		];
		const result = (await emit("context", [...summaries, user("go on")])) as {
			messages: SuperpowersMessage[];
		};
		expect(result.messages).toHaveLength(4);
		expect(result.messages[0].role).toBe("compactionSummary");
		expect(result.messages[1].role).toBe("branchSummary");
		expect(textOf(result.messages[2])).toContain(BOOTSTRAP_MARKER);
	});

	it("does not double-inject when the marker is already in context", async () => {
		const { pi, emit } = fakePi();
		createSuperpowersExtension(pi, { skillsDir: skillsDir() });
		await emit("session_start");
		const withMarker = [user(`quoted ${BOOTSTRAP_MARKER} text`), user("next")];
		expect(await emit("context", withMarker)).toBeUndefined();
	});

	it("stops injecting after agent_end", async () => {
		const { pi, emit } = fakePi();
		createSuperpowersExtension(pi, { skillsDir: skillsDir() });
		await emit("session_start");
		await emit("agent_end");
		expect(await emit("context", [user("second prompt")])).toBeUndefined();
	});

	it("re-injects after compaction", async () => {
		const { pi, emit } = fakePi();
		createSuperpowersExtension(pi, { skillsDir: skillsDir() });
		await emit("session_start");
		await emit("agent_end");
		await emit("session_compact");
		const result = (await emit("context", [
			{ role: "compactionSummary", summary: "compacted", timestamp: 3 },
			user("continue"),
		])) as { messages: SuperpowersMessage[] };
		expect(result.messages).toHaveLength(3);
		expect(textOf(result.messages[1])).toContain(BOOTSTRAP_MARKER);
	});

	it("does nothing when the bootstrap skill file is missing", async () => {
		const { pi, emit } = fakePi();
		createSuperpowersExtension(pi, { skillsDir: skillsDir(null) });
		await emit("session_start");
		expect(await emit("context", [user("hello")])).toBeUndefined();
	});
});

describe("extension loading", () => {
	it("registers its handlers under omp's real extension loader", async () => {
		process.env.OMP_SUPERPOWERS_DIR = skillsDir();
		try {
			const result = await loadExtensions([`${import.meta.dir}/superpowers.ts`], "/tmp");
			expect(result.errors).toEqual([]);
			expect(result.extensions).toHaveLength(1);
			const extension = result.extensions[0];
			for (const event of ["session_start", "session_compact", "agent_end", "context"]) {
				expect(extension.handlers.get(event)?.length ?? 0).toBe(1);
			}
		} finally {
			delete process.env.OMP_SUPERPOWERS_DIR;
		}
	});
});
