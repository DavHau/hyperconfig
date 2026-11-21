"""Export the skills afk gives nmm's sessions into a hermes skill root.

Run by nmm-remote-skills.service on som (../dave-hermes-nmm.nix) as root
with CAP_DAC_READ_SEARCH only, read-only everywhere but the output dir.
It never executes anything from the container: it reads files, and git
plumbing (ls-tree, cat-file: no hooks, filters or fsmonitor) on nmm's
repo. Everything it reads is written by nmm's agents, so it is data:
size-capped, names validated, no symlinks followed out of their tree.

Output (OUT, root:nmm-remote 0750, files 0640):
  nmm/                      the entry skill: how to drive nmm from hermes
    SKILL.md                head (hyperconfig) + nmm's AGENTS.md (trunk)
    references/AGENTS.md
    references/afk-rules/   afk's always-applied omp rules
  nmm-<name>/               every <name>/SKILL.md afk's sessions see:
                            trunk's .agents/skills and afk's distro skills
                            (as the swarm runs it: --no-superpowers),
                            renamed so no hermes skill shadows them.
And KNOWN_HOSTS: the guest's own ed25519 host key, for the ssh client.
"""

import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(sys.argv[1])  # the container's root on the host
OUT = Path(sys.argv[2])  # the skill root hermes reads
KNOWN_HOSTS = Path(sys.argv[3])
HEAD = Path(sys.argv[4])  # the entry skill's head (hyperconfig)
HOST_ALIAS = sys.argv[5]
GROUP_GID = __import__("grp").getgrnam(sys.argv[6]).gr_gid

REPO_GIT = ROOT / "home/agent/nmm/.git"
AFK = "/etc/profiles/per-user/agent/bin/afk"
NAME_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,62}$")
MAX_FILE = 1 << 20
MAX_TOTAL = 16 << 20
total = 0


def git(*args: str) -> bytes:
    env = {
        "PATH": os.environ["PATH"],
        "HOME": "/var/empty",
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_CONFIG_GLOBAL": "/dev/null",
        "GIT_NO_REPLACE_OBJECTS": "1",
        "GIT_TERMINAL_PROMPT": "0",
    }
    return subprocess.run(
        ["git", "-c", "safe.directory=*", "-c", "core.fsmonitor=false", f"--git-dir={REPO_GIT}", *args],
        check=True,
        capture_output=True,
        env=env,
    ).stdout


def put(dest: Path, data: bytes) -> None:
    global total
    if len(data) > MAX_FILE:
        raise SystemExit(f"{dest}: {len(data)} bytes, over the per-file cap")
    total += len(data)
    if total > MAX_TOTAL:
        raise SystemExit("export over the total size cap")
    dest.parent.mkdir(parents=True, exist_ok=True)
    dest.write_bytes(data)


def safe_rel(rel: str) -> bool:
    parts = rel.split("/")
    return all(p not in ("", ".", "..") for p in parts)


SCOPE = "Only for nmm work in the asof-agents container (afk's copy; load the nmm skill first). "


def rename_skill(text: str, new: str) -> str:
    """The frontmatter `name:` becomes `new`, and the description is scoped to
    nmm: every profile of the agent indexes these skills, and an afk skill
    that says "use when starting any conversation" must not take over the
    agent's other work. Refuses a SKILL.md without both fields."""
    m = re.match(r"^---\n(.*?)\n---\n", text, re.S)
    if not m or not re.search(r"^name:", m.group(1), re.M):
        raise ValueError("no frontmatter name")
    d = re.search(r"^description:[ \t]*(.*)$", m.group(1), re.M)
    if not d or not d.group(1).strip() or d.group(1).strip() in ("|", ">", "|-", ">-"):
        raise ValueError("no one-line frontmatter description")
    desc = d.group(1).strip()
    if len(desc) >= 2 and desc[0] == desc[-1] and desc[0] in "\"'":
        desc = desc[1:-1]
    # Agent-written text that lands in every dave-hermes session's skill
    # index: one line, capped.
    desc = " ".join(desc.split())[:400]
    front = re.sub(r"^name:.*$", f"name: {new}", m.group(1), count=1, flags=re.M)
    front = re.sub(
        r"^description:.*$", lambda _: "description: " + json.dumps(SCOPE + desc), front, count=1, flags=re.M
    )
    return f"---\n{front}\n---\n" + text[m.end():]


def in_root(path: str) -> Path:
    """`path` as the guest resolves it: absolute links re-rooted at ROOT,
    except the store, which the guest shares with this host."""
    hops = 0
    todo = [p for p in path.split("/") if p]
    cur = "/"
    while todo:
        part = todo.pop(0)
        nxt = os.path.join(cur, part)
        host = Path(nxt) if nxt.startswith("/nix/store/") else ROOT / nxt.lstrip("/")
        if host.is_symlink():
            hops += 1
            if hops > 40:
                raise SystemExit(f"{path}: too many links")
            target = os.readlink(host)
            if target.startswith("/"):
                cur = "/"
            todo = [p for p in target.split("/") if p] + todo
            continue
        cur = os.path.normpath(nxt)
    return Path(cur) if cur.startswith("/nix/store/") else ROOT / cur.lstrip("/")


def store_path(p: str) -> Path:
    q = Path(os.path.realpath(p))
    if not str(q).startswith("/nix/store/") or not q.exists():
        raise SystemExit(f"{p}: not a store path")
    return q


def copy_tree(src: Path, dest: Path, new_name: str) -> None:
    for dirpath, dirs, files in os.walk(src, followlinks=False):
        for f in files:
            s = Path(dirpath) / f
            if s.is_symlink() or not s.is_file():
                continue
            rel = s.relative_to(src)
            data = s.read_bytes()
            if str(rel) == "SKILL.md":
                data = rename_skill(data.decode(), new_name).encode()
            put(dest / rel, data)


def main() -> None:
    # The unit sees only ROOT, the store and OUT's parent (dave-hermes-nmm.nix),
    # so a .git or link the agent points elsewhere finds nothing; this catches
    # the plain case with a clear message.
    if os.path.realpath(REPO_GIT) != str(REPO_GIT):
        raise SystemExit(f"{REPO_GIT} is or passes through a symlink; refusing")
    stage = Path(tempfile.mkdtemp(dir=OUT.parent, prefix=".stage-"))
    try:
        build(stage)
        for dirpath, dirs, files in os.walk(stage):
            os.chown(dirpath, 0, GROUP_GID)
            os.chmod(dirpath, 0o750)
            for f in files:
                os.chown(os.path.join(dirpath, f), 0, GROUP_GID)
                os.chmod(os.path.join(dirpath, f), 0o640)
        # -a keeps the modes and owners set above; --delay-updates renames the
        # changed files in at the end, so a reader never sees a half file.
        subprocess.run(
            ["rsync", "-a", "--delete", "--delay-updates", "--checksum", f"{stage}/", f"{OUT}/"],
            check=True,
        )
    finally:
        shutil.rmtree(stage, ignore_errors=True)
    write_known_hosts()


def build(stage: Path) -> None:
    trunk = git("rev-parse", "--verify", "refs/heads/trunk^{commit}").decode().strip()
    skills: dict[str, str] = {}

    # trunk's project skills (omp finds them in .agents/skills, walking up).
    listing = git("ls-tree", "-r", "-z", "--full-tree", trunk, "--", ".agents/skills").split(b"\0")
    for entry in filter(None, listing):
        meta, path = entry.decode().split("\t", 1)
        mode, kind, sha = meta.split()
        rel = path.removeprefix(".agents/skills/")
        if kind != "blob" or mode not in ("100644", "100755") or not safe_rel(rel):
            continue
        name, _, inner = rel.partition("/")
        if not NAME_RE.match(name) or not inner:
            continue
        data = git("cat-file", "blob", sha)
        if inner == "SKILL.md":
            try:
                data = rename_skill(data.decode(), f"nmm-{name}").encode()
            except ValueError:
                print(f"skipping .agents/skills/{name}: SKILL.md has no frontmatter name", file=sys.stderr)
                continue
            skills[f"nmm-{name}"] = f".agents/skills/{name} (trunk)"
        put(stage / f"nmm-{name}" / inner, data)
    for d in list(stage.iterdir()):
        if d.name not in skills:
            shutil.rmtree(d)

    # afk's distribution skills and rules, from the afk the guest runs.
    wrapper = in_root(AFK).read_text()
    # Plain `afk` (Dave's own sessions) reads the first OMP_DISTRO_CONFIG,
    # the swarm's and `swarm open`'s `afk --no-superpowers` the second; the
    # union is exported, each skill labelled with who sees it.
    def distro_dirs(pattern: str) -> list[str]:
        m = re.search(pattern, wrapper)
        if not m:
            return []
        text = store_path(m.group(1)).read_text()
        block = re.search(r"^skills:\n((?:[ #].*\n|\n)*)", text, re.M)
        return re.findall(r"^\s+-\s+(/nix/store/\S+)\s*$", block.group(1), re.M) if block else []

    plain = distro_dirs(r'export OMP_DISTRO_CONFIG="(/nix/store/[^"]+-distro-config\.yml)"')
    swarm = distro_dirs(r'OMP_DISTRO_CONFIG="(/nix/store/[^"]+-distro-config-no-superpowers\.yml)"')
    if not plain and not swarm:
        raise SystemExit(f"{AFK}: no distro config found; afk's wrapper changed")
    for d in dict.fromkeys(plain + swarm):
        root = store_path(d)
        seen_by = "every afk session" if d in swarm else "plain `afk` only (swarm sessions run --no-superpowers)"
        for sk in sorted(root.iterdir()):
            if not NAME_RE.match(sk.name) or not (sk / "SKILL.md").is_file() or f"nmm-{sk.name}" in skills:
                continue
            try:
                copy_tree(sk, stage / f"nmm-{sk.name}", f"nmm-{sk.name}")
            except ValueError as e:
                shutil.rmtree(stage / f"nmm-{sk.name}", ignore_errors=True)
                print(f"skipping afk skill {sk.name}: {e}", file=sys.stderr)
                continue
            skills[f"nmm-{sk.name}"] = f"afk distribution, {seen_by}"
    rules = []
    for src, name in re.findall(r'ln -sf (/nix/store/\S+\.md) "\$config_dir/rules/([A-Za-z0-9._-]+\.md)"', wrapper):
        put(stage / "nmm/references/afk-rules" / name, store_path(src).read_bytes())
        rules.append(name)

    # nmm's AGENTS.md at trunk, and the entry skill around it.
    try:
        # cat-file, never `git show`: no textconv drivers from the repo's config.
        agents = git("cat-file", "blob", f"{trunk}:AGENTS.md").decode()
    except subprocess.CalledProcessError:
        agents = "(trunk has no AGENTS.md)\n"
    put(stage / "nmm/references/AGENTS.md", agents.encode())
    listing = "\n".join(f"- `{n}` ({src})" for n, src in sorted(skills.items())) or "- (none)"
    rule_list = "\n".join(f"- `references/afk-rules/{r}`" for r in sorted(rules)) or "- (none)"
    body = (
        HEAD.read_text()
        .replace("@TRUNK@", trunk[:12])
        .replace("@SKILLS@", listing)
        .replace("@RULES@", rule_list)
        .replace("@AGENTS_MD@", agents.strip())
    )
    put(stage / "nmm/SKILL.md", body.encode())
    put(stage / "nmm/references/export.json", json.dumps({"trunk": trunk, "skills": skills, "rules": rules}, indent=1).encode())


def write_known_hosts() -> None:
    pub = (ROOT / "etc/ssh/ssh_host_ed25519_key.pub").read_text().split()
    if len(pub) < 2 or pub[0] != "ssh-ed25519" or not re.fullmatch(r"AAAAC3NzaC1lZDI1NTE5[A-Za-z0-9+/]{48}", pub[1]):
        raise SystemExit("the guest's ed25519 host key is malformed")
    line = f"{HOST_ALIAS} ssh-ed25519 {pub[1]}\n"
    tmp = KNOWN_HOSTS.with_suffix(".tmp")
    tmp.write_text(line)
    os.chmod(tmp, 0o644)
    os.replace(tmp, KNOWN_HOSTS)


main()
