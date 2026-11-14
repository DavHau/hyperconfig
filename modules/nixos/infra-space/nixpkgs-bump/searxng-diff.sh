# nixpkgs-bump-searxng-diff OLD NEW OUT [LABEL]: the review's diff of two
# SearXNG source trees (./searxng.sh's pick, on the two prefetched store
# paths). Writes OUT (the whole review file) and OUT.part-01, -02, ...:
# OUT cut at line ends into parts of at most @partBytes@ bytes (the file
# tool's line-number prefixes counted) and @partLines@ lines, each one
# read of the reviewer's file tool; a line longer than @lineChars@ bytes
# is folded there into pieces of at most @lineChars@ bytes (so as many
# characters at most), cut between UTF-8 characters (continuations start
# `\~ `), as that tool cuts a line over ~2000 characters and would hide
# its end, and refuses a part whose first 1000 bytes are not UTF-8.
#
# The characters each section may hold, and how OUT shows the rest, are
# ./searxng-text.py's (its header has the rules): in the counted code
# diff anything outside printable ASCII and TAB holds the update back,
# but for visible letters, marks, digits, punctuation and symbols that
# are not default-ignorable, not right-to-left and, if they can be part
# of a name, unchanged by NFKC (written `\u{XXXX}` after the character);
# a word mixing scripts holds too; .md/.rst files there have the data
# rules. Elsewhere only control bytes, invalid UTF-8 and the file tool's
# fence marker hold; invisible characters are written `\u{XXXX}`, bytes
# `\xNN`.
#
# searx/data's JSON (URL templates and engine hosts live there): its
# raw diff is the review's view whenever it fits in @genBytes@ bytes
# (shown whole, character-scanned and read-checked like the rest, with
# the summary's registrable domains and holds before it). Only above
# that the structural summary (./searxng-text.py summary) stands in for
# it: every changed or added scalar by JSON path, old -> new, in every
# searx/data file whatever its size or name (removed ones counted),
# except the two display-only files engine_descriptions.json and
# wikidata_properties.json (counts only; any URL, `<`/`>` or structure
# change in them holds; ./searxng-text.py DISPLAY_ONLY has why);
# whole or HOLD when over @genBytes@ bytes. The raw diff then follows,
# cut after @genBytes@ bytes. In both modes every new or changed string
# that starts (after leading blanks or controls, which hold themselves)
# with a scheme or two slashes must be exactly http(s):// + a plain
# host[:port] (only external_bangs.json's `//host`, \x02 and \x01<rank>
# tail, and the few non-URL forms upstream's data has, excepted;
# ./searxng-text.py NOT_URL): else HOLD.
#
# In the other uncounted diff, and only in a package-lock.json hunk, a
# line that is exactly an npm `"integrity": "sha512-..."` entry is
# masked; OUT's header gives their number. After the code diff (the
# summary and the uncounted diffs) every span hermes' secret redactor
# would rewrite is written escaped, losslessly (`*` as `\x2a`,
# ./searxng-readcheck.py escape); their number is in OUT's last lines.
# In the code diff a line the redactor would change holds.
#
# Last, every part goes through the reviewer's own read_file
# (./searxng-readcheck.py, the hermes infra-space runs): anything it
# would show differently from the part's bytes (its secret redactor, a
# cut, a strip, a spill, whatever a hermes update adds) is held back.
# stdout: a first line `<code lines> <code bytes>`
# (the counted diff), then one line `HOLD <reason>` per thing the review
# cannot see; exit 3 if there is any (OUT is written all the same, for
# Dave), 0 otherwise.
#
# Nothing in the trees may hide a file from the review or from the size
# cap: no git repository is made of them, so their own .gitignore,
# .gitattributes and .git* files are content like any other (shown, not
# obeyed). `git diff --no-index` runs outside any repository (ceiling at
# the scratch directory), with no user or system config, no attributes
# file, no external diff or textconv, --text for every file; symlinks are
# compared as links (their target is the content), never followed.
#
# Generated or vendored artefacts are diffed apart, uncounted, matched by
# path/extension only (never a whole directory), regular files only:
# searx/data/**.json (data the engines read), *.min.js, *.map,
# package-lock.json, translations (*.po, *.mo). Everything else, under
# any directory, and every symlink, is code. After the code in OUT:
# searx/data's raw diff (whole) or its summary (whole, or HOLD) and the
# raw diff cut, then the rest's diff, cut after @genBytes@ bytes.
#
# A symlink in NEW whose target lies outside the tree, or is one of those
# uncounted files, or a directory holding one, would run code the counted
# diff never shows (searx/engines/b.py -> ../data/payload.json): HOLD.
[ $# -ge 3 ] && [ $# -le 4 ] || {
  echo "usage: nixpkgs-bump-searxng-diff OLD NEW OUT [LABEL]" >&2
  exit 2
}
old=$1 new=$2 out=$3 label=${4:-"$1 -> $2"}
[ -d "$old" ] && [ -d "$new" ] || {
  echo "nixpkgs-bump-searxng-diff: OLD and NEW must be directories" >&2
  exit 2
}
partBytes=@partBytes@
genBytes=@genBytes@
lineChars=@lineChars@

# ./<path>: one of the uncounted files' paths? (`*` matches `/` here)
is_gen() {
  case "$1" in
    ./searx/data/*.json | *.min.js | *.map | */package-lock.json | *.po | *.mo) return 0 ;;
  esac
  return 1
}
# the uncounted files the review must see whole (engine data)
is_data() {
  case "$1" in
    ./searx/data/*.json) return 0 ;;
  esac
  return 1
}

# ./searxng-text.py: esc code|data (stdin -> stdout, as OUT shows it),
# scan code|data FILE (its first line the review cannot see as it is),
# mask COUNT (package-lock.json integrity lines)
text() { @python@ -I @text@ "$@"; }

tmp=$(mktemp -d)
trap 'chmod -R u+w "$tmp" 2>/dev/null; rm -rf "$tmp"' EXIT
mkdir "$tmp/code" "$tmp/data" "$tmp/gen"
for side in old new; do
  if [ "$side" = old ]; then src=$old; else src=$new; fi
  # -a: symlinks stay symlinks (-P), modes kept for the diff's mode lines
  cp -a --no-preserve=ownership -- "$src" "$tmp/code/$side"
  chmod -R u+w "$tmp/code/$side"
done

# The new tree's symlinks, before anything moves, resolved inside the
# copy: a target outside the copy is outside the tree.
root=$(cd "$tmp/code/new" && pwd -P)
: >"$tmp/holds"
hold() { printf 'HOLD %s\n' "$*" >>"$tmp/holds"; }
while IFS= read -r -d '' l; do
  t=$(readlink -- "$root/$l") || t='?'
  t=${t//$'\n'/?}
  n=${l#./}
  n=${n//$'\n'/?}
  if ! r=$(realpath -m -- "$root/$l" 2>/dev/null); then
    hold "symlink $n -> $t: cannot be resolved"
    continue
  fi
  case "$r" in
    "$root") hold "symlink $n -> $t: points at the whole tree" ;;
    "$root"/*)
      rel=./${r#"$root"/}
      if [ -d "$r" ]; then
        g=
        while IFS= read -r -d '' f; do
          if is_gen "$f"; then
            g=${f#./}
            break
          fi
        done < <(cd "$root" && find "$rel" -type f -print0)
        [ -z "$g" ] || hold "symlink $n -> $t: a directory holding uncounted files (${g//$'\n'/?})"
      elif is_gen "$rel"; then
        hold "symlink $n -> $t: points into the uncounted ${rel#./}"
      fi
      ;;
    *) hold "symlink $n -> $t: points outside the tree" ;;
  esac
done < <(cd "$root" && find . -type l -print0)

for side in old new; do
  mkdir "$tmp/data/$side" "$tmp/gen/$side"
  (cd "$tmp/code/$side" && find . -type f -print0) |
    while IFS= read -r -d '' f; do
      is_gen "$f" || continue
      if is_data "$f"; then to=data; else to=gen; fi
      mkdir -p "$tmp/$to/$side/$(dirname "$f")"
      mv -- "$tmp/code/$side/$f" "$tmp/$to/$side/$f"
    done
done

gd() { # code|gen git-diff-args...: exit 0 or 1 (differences) is success
  local where=$1 rc=0
  shift
  (
    cd "$tmp/$where" &&
      env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE -u GIT_ATTR_SOURCE \
        GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_COUNT=0 \
        GIT_CEILING_DIRECTORIES="$tmp" \
        git -c core.quotePath=false -c core.attributesFile=/dev/null -c diff.external= \
        diff --no-index --no-ext-diff --no-textconv --text --no-renames --no-color \
        --src-prefix=a/ --dst-prefix=b/ "$@" old new
  ) || rc=$?
  [ "$rc" -le 1 ] || {
    echo "nixpkgs-bump-searxng-diff: git diff failed ($rc)" >&2
    exit 1
  }
}

gd code >"$tmp/code.diff"
gd data >"$tmp/data.diff"
gd gen >"$tmp/gen.diff"
lines=$(wc -l <"$tmp/code.diff")
bytes=$(wc -c <"$tmp/code.diff")
data_total=$(wc -c <"$tmp/data.diff")
gen_total=$(wc -c <"$tmp/gen.diff")
# raw: the searx/data diff itself is the review's view (it fits);
# summary: it does not, the full summary stands in for it
if [ "$data_total" -le "$genBytes" ]; then data_mode=raw smode=hosts; else data_mode=summary smode=full; fi
text summary "$tmp/data/old" "$tmp/data/new" "$smode" >"$tmp/summary.all" || hold "the searx/data summary failed"
grep -v '^HOLD ' "$tmp/summary.all" >"$tmp/summary" || true
grep '^HOLD ' "$tmp/summary.all" >>"$tmp/holds" || true
sum_total=$(wc -c <"$tmp/summary")
[ "$sum_total" -le "$genBytes" ] ||
  hold "the searx/data summary is $sum_total bytes, over the review file's $genBytes: its end (URL templates, hosts) would be cut from the review"
w=$(text scan code "$tmp/code.diff") || hold "the code diff's character scan failed"
[ -z "$w" ] ||
  hold "the code diff's $w: code must be ASCII or a visible character the review reads as itself (shown as \\xNN or \\u{XXXX} in the review file)"
# (the other uncounted diff is shown escaped, not scanned: binary .mo
# files are all control bytes; the read check still sees every part)
w=$(text scan data "$tmp/summary") || hold "the searx/data summary's character scan failed"
[ -z "$w" ] ||
  hold "the searx/data summary's $w: the review's file tool strips or refuses that (shown as \\xNN in the review file)"
if [ "$data_mode" = raw ]; then
  w=$(text scan data "$tmp/data.diff") || hold "the searx/data diff's character scan failed"
  [ -z "$w" ] ||
    hold "the searx/data diff's $w: the review's file tool strips or refuses that (shown as \\xNN in the review file)"
fi
text mask "$tmp/masked" <"$tmp/gen.diff" >"$tmp/gen.masked" || hold "the package-lock.json integrity mask failed"
masked=$(cat "$tmp/masked" 2>/dev/null || echo '?')
{
  {
    echo "# searxng $label: diff of the two prefetched sources (no repository: nothing in them hides a file)"
    echo "# package-lock.json integrity lines masked (npm hashes, nothing else): $masked"
    if [ -s "$tmp/holds" ]; then
      echo "# HELD BACK, the review cannot see what these run:"
      sed 's/^HOLD /#   /' "$tmp/holds"
    fi
    echo "# counted as code (the review's subject):"
    gd code --stat=200
    echo "# not counted (generated data, minified assets, translations):"
    gd data --stat=200
    gd gen --stat=200
    echo "# --- the code diff ($lines lines, $bytes bytes)"
  } | text esc data
  text esc code <"$tmp/code.diff"
  {
    echo "# --- end of the code diff"
    if [ "$data_mode" = raw ]; then
      echo "# --- the searx/data hosts ($sum_total bytes: registrable domains per changed file; the raw diff below is what counts)"
      cat "$tmp/summary"
      echo "# --- end of the searx/data hosts"
      echo "# --- the searx/data diff ($data_total bytes, raw, whole: the review's view of it): not code, but read it, URL templates and engine hosts live here"
      cat "$tmp/data.diff"
      echo "# --- end of the searx/data diff"
    else
      echo "# --- the searx/data summary ($sum_total bytes; the raw diff, $data_total bytes, is over $genBytes): what counts, read it, URL templates and engine hosts live here"
      if [ "$sum_total" -gt "$genBytes" ]; then
        head -c "$genBytes" "$tmp/summary"
        echo
        echo "# --- TRUNCATED: the searx/data summary's first $genBytes bytes only, $((sum_total - genBytes)) more not shown (HELD BACK)"
      else
        cat "$tmp/summary"
        echo "# --- end of the searx/data summary"
      fi
      echo "# --- the searx/data diff ($data_total bytes, raw; the summary above is what counts)"
      head -c "$genBytes" "$tmp/data.diff"
      echo
      echo "# --- TRUNCATED: the searx/data diff's first $genBytes bytes only, $((data_total - genBytes)) more not shown"
    fi
    echo "# --- the other uncounted diff ($gen_total bytes: minified assets, source maps, package-lock.json, translations)"
    if [ "$gen_total" -gt "$genBytes" ]; then
      head -c "$genBytes" "$tmp/gen.masked"
      echo
      echo "# --- TRUNCATED: the other uncounted diff's first $genBytes bytes only, $((gen_total - genBytes)) more not shown"
    else
      cat "$tmp/gen.masked"
      echo "# --- end of the other uncounted diff"
    fi
  } | text esc data
} >"$tmp/out0"
# After the code diff, spans hermes' redactor would rewrite are written
# escaped (lossless, ./searxng-readcheck.py escape); the code diff itself
# is left as it is (a redaction there holds, by the read check below).
from=$(grep -n -m1 -x -F '# --- end of the code diff' "$tmp/out0" | cut -d: -f1)
[[ $from =~ ^[0-9]+$ ]] || {
  echo "nixpkgs-bump-searxng-diff: no end of the code diff in the review file" >&2
  exit 1
}
esc_n='?'
if env -u PYTHONPATH -u PYTHONHOME -u PYTHONSTARTUP \
  @hermesPython@ -I @readcheck@ escape "$from" <"$tmp/out0" >"$out" 2>"$tmp/escape.err"; then
  esc_n=$(sed -n 's/^escaped //p' "$tmp/escape.err" | tail -n 1)
  echo "# spans hermes' secret redactor would rewrite after the code diff, written escaped (\\xNN per character): ${esc_n:-?}" >>"$out"
else
  hold "the redactor escape after the code diff failed ($(tail -n 1 "$tmp/escape.err" | cut -c1-200))"
  cp "$tmp/out0" "$out"
fi
rm -f -- "$out".part-*
# at line ends; a line costs its bytes plus ~9 for the file tool's
# `<number>|` prefix; at most @partLines@ lines (that tool's page). A
# line over $lineChars bytes (>= its characters) is folded there (in OUT
# it stays whole): the first piece as is, the others on lines starting
# `\~ `, each piece at most $lineChars - 3 bytes and ending between two
# UTF-8 characters (backed off past continuation bytes 0x80-0xbf; OUT is
# valid UTF-8 after esc), so every part decodes, its first 1000 bytes
# included.
LC_ALL=C awk -v base="$out.part-" -v max="$partBytes" -v maxl="@partLines@" -v lc="$lineChars" '
  function open_next() { n++; f = sprintf("%s%02d", base, n); b = 0; c = 0 }
  function emit(t,  s) {
    s = length(t) + 9
    if (c > 0 && (b + s > max || c >= maxl)) { close(f); open_next() }
    print t > f; b += s; c++
  }
  BEGIN { open_next(); w = lc - 3 }
  { if (length($0) <= lc) { emit($0); next }
    L = length($0); p = ""
    for (i = 1; i <= L; i = e + 1) {
      e = i + w - 1
      if (e >= L) e = L
      else while (e > i && substr($0, e + 1, 1) ~ /^[\x80-\xbf]$/) e--
      emit(p substr($0, i, e - i + 1)); p = "\\~ "
    } }
' "$out"

# Last: each part through the reviewer's own read_file (the hermes the
# agent runs, ./searxng-readcheck.py), whatever it would change. The
# rules above make the parts plain text for the read_file they were
# written against; this check closes the class: anything that read_file
# shows differently from the part's bytes (a redacted secret, a cut
# line, a stripped sequence, a rule a hermes update adds) holds it back.
# Its reasons name the part and line, never the text.
rc=0
env -u PYTHONPATH -u PYTHONHOME -u PYTHONSTARTUP \
  @hermesPython@ -I @readcheck@ "$out".part-* >"$tmp/readcheck" 2>"$tmp/readcheck.err" || rc=$?
case $rc in
  0) ;;
  3) grep '^HOLD ' "$tmp/readcheck" >"$tmp/readholds" || hold "the review parts' read check held them back without a reason" ;;
  *) hold "the review parts' read check through hermes' read_file failed (exit $rc: $(tail -n 1 "$tmp/readcheck.err" | cut -c1-200))" ;;
esac
if [ -s "$tmp/readholds" ]; then
  cat "$tmp/readholds" >>"$tmp/holds"
  # for Dave, at the end of OUT (held: no review reads these parts)
  {
    echo "# HELD BACK after the parts were cut, the review cannot see what these hold:"
    sed 's/^HOLD /#   /' "$tmp/readholds"
  } | text esc data >>"$out"
fi

echo "$lines $bytes"
text esc data <"$tmp/holds"
[ ! -s "$tmp/holds" ] || exit 3
