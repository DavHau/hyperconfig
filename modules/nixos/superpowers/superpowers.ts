/**
 * superpowers — omp port of the Superpowers bootstrap injection
 * (github.com/obra/superpowers, upstream reference: .pi/extensions/superpowers.ts).
 *
 * The skills themselves are registered through config.yml
 * (skills.customDirectories -> the flake input's skills/ directory); this
 * extension supplies the one feature skills alone don't give you: the
 * `using-superpowers` skill content is injected into the LLM context —
 * wrapped in <EXTREMELY_IMPORTANT> — at session start and re-injected after
 * compaction, so the skill-dispatch discipline is active from the first
 * message without any per-session opt-in. Injection targets the LLM payload
 * only (omp `context` event); nothing is persisted into the session.
 *
 * Differences from upstream's pi extension:
 * - no `resources_discover` handler (config.yml already registers the skills;
 *   both would double-register),
 * - the tool mapping speaks omp: native `skill://` reads, the `task` tool for
 *   subagent workflows, the `todo` tool for task lists, and a jj (Jujutsu)
 *   translation of the git-flow skills — this host mandates jj (see
 *   default-rules-superpowers.md),
 * - the skills root comes from $OMP_SUPERPOWERS_DIR (set by the omp-sp
 *   wrapper, modules/nixos/pi-superpowers.nix) instead of import.meta
 *   relative paths, which a Nix-store symlink would break.
 *
 * Loaded from $config_dir/extensions/superpowers.ts (symlinked by
 * modules/nixos/pi-superpowers.nix); tests in superpowers.test.ts run via bun
 * against the ~/projects/oh-my-pi checkout.
 */

import { readFileSync } from "node:fs";
import { join } from "node:path";
import type { AgentMessage } from "@oh-my-pi/pi-agent-core";
import type { ExtensionAPI } from "@oh-my-pi/pi-coding-agent";

export const BOOTSTRAP_MARKER = "superpowers:using-superpowers bootstrap for omp";

/**
 * Structural read surface over an omp AgentMessage: every union member has a
 * `role`; `content` stays `unknown` (custom messages carry arbitrary
 * payloads) and is narrowed at runtime in `messageText`.
 */
export interface SuperpowersMessage {
	role: string;
	content?: unknown;
	summary?: string;
	timestamp?: number;
}

export type SuperpowersHandler = (event: {
	type: string;
	messages?: SuperpowersMessage[];
}) => { messages: SuperpowersMessage[] } | undefined | void;

/** Structural subset of ExtensionAPI, for tests. */
export interface SuperpowersPi {
	on(event: "session_start" | "session_compact" | "agent_end" | "context", handler: SuperpowersHandler): void;
}

export interface SuperpowersDeps {
	/** Root of the Superpowers skills library (contains using-superpowers/SKILL.md). */
	skillsDir: string;
}

function stripFrontmatter(content: string): string {
	const match = content.match(/^---\n[\s\S]*?\n---\n([\s\S]*)$/);
	return (match ? match[1] : content).trim();
}

const OMP_TOOL_MAPPING = `## omp tool mapping

omp has native skills: every available skill is listed in your system prompt with a \`skill://<name>\` URI. When a Superpowers instruction says to invoke a skill or use a "Skill tool", load it with the \`read\` tool (\`read skill://<name>\`) BEFORE acting on the task it applies to. Never read SKILL.md files by filesystem path.

When Superpowers says to dispatch a subagent (implementer, spec reviewer, code-quality reviewer, dispatching-parallel-agents), use the \`task\` tool. When it references a task list or TodoWrite, use the \`todo\` tool.

## Version control mapping (jj, not git)

This machine mandates jj (Jujutsu); your rules and AGENTS.md govern. Translate Superpowers' git vocabulary instead of running raw git workflows:

- using-git-worktrees: create an isolated working copy with \`jj workspace add ../<name>\` (clean up later with \`jj workspace forget\`); for lightweight isolation \`jj new\` on a fresh commit is usually enough.
- test-driven-development "commit after green": \`jj describe -m "<summary>"\` then \`jj new\`.
- finishing-a-development-branch: land work with \`jj squash\` into the target commit or set a bookmark (\`jj bookmark set <name>\`) and \`jj git push\`; there is no local "delete the branch" step.
- Isolated \`task\` subagents run NO version control at all — the harness captures their changes.`;

export function buildBootstrap(skillContent: string): string {
	const body = stripFrontmatter(skillContent);
	return `<EXTREMELY_IMPORTANT>
${BOOTSTRAP_MARKER}

You have superpowers.

The using-superpowers skill content is included below and is already loaded for this omp session. Follow it now. Do not try to load using-superpowers again.

${body}

${OMP_TOOL_MAPPING}
</EXTREMELY_IMPORTANT>`;
}

function messageText(message: SuperpowersMessage): string {
	if (typeof message.content === "string") return message.content;
	if (!Array.isArray(message.content)) return "";
	let text = "";
	for (const part of message.content) {
		if (part.type === "text" && typeof part.text === "string") text += part.text;
	}
	return text;
}

/**
 * Leading compaction/branch summaries must stay first in the payload; the
 * bootstrap slots in right after them.
 */
function insertionIndex(messages: SuperpowersMessage[]): number {
	let index = 0;
	while (index < messages.length && (messages[index].role === "compactionSummary" || messages[index].role === "branchSummary")) {
		index += 1;
	}
	return index;
}

/** Wire bootstrap injection to session_start / session_compact / context. */
export function createSuperpowersExtension(pi: SuperpowersPi, deps: SuperpowersDeps): void {
	let cachedBootstrap: string | null | undefined;
	let injectBootstrap = true;

	const getBootstrap = (): string | null => {
		if (cachedBootstrap === undefined) {
			try {
				const skillPath = join(deps.skillsDir, "using-superpowers", "SKILL.md");
				cachedBootstrap = buildBootstrap(readFileSync(skillPath, "utf8"));
			} catch {
				cachedBootstrap = null;
			}
		}
		return cachedBootstrap;
	};

	pi.on("session_start", () => {
		injectBootstrap = true;
	});

	pi.on("session_compact", () => {
		injectBootstrap = true;
	});

	pi.on("agent_end", () => {
		injectBootstrap = false;
	});

	pi.on("context", event => {
		const messages = event.messages;
		if (!injectBootstrap || !messages) return undefined;
		if (messages.some(message => messageText(message).includes(BOOTSTRAP_MARKER))) return undefined;

		const bootstrap = getBootstrap();
		if (!bootstrap) return undefined;

		const bootstrapMessage: SuperpowersMessage = {
			role: "user",
			content: [{ type: "text", text: bootstrap }],
			timestamp: Date.now(),
		};

		const insertAt = insertionIndex(messages);
		return {
			messages: [...messages.slice(0, insertAt), bootstrapMessage, ...messages.slice(insertAt)],
		};
	});
}

export default function (pi: ExtensionAPI) {
	const skillsDir = process.env.OMP_SUPERPOWERS_DIR;
	if (!skillsDir) return;
	// ExtensionAPI.on is overloaded per event name, so the wiring registers
	// each event explicitly instead of forwarding the union.
	const handlers = new Map<string, SuperpowersHandler>();
	createSuperpowersExtension({ on: (event, handler) => void handlers.set(event, handler) }, { skillsDir });
	pi.on("session_start", () => void handlers.get("session_start")?.({ type: "session_start" }));
	pi.on("session_compact", () => void handlers.get("session_compact")?.({ type: "session_compact" }));
	pi.on("agent_end", () => void handlers.get("agent_end")?.({ type: "agent_end" }));
	pi.on("context", event => {
		const result = handlers.get("context")?.({ type: "context", messages: event.messages });
		if (!result) return undefined;
		// The result reuses the incoming AgentMessages untouched and inserts one
		// plain user text message (a valid UserMessage); the narrow structural
		// SuperpowersMessage surface cannot prove membership in the closed
		// AgentMessage union, and no runtime check is meaningful here.
		const messages = result.messages as AgentMessage[];
		return { messages };
	});
}
