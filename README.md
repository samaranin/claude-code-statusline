# claude-statusline

A two-line [Claude Code](https://claude.com/claude-code) status line, built on the
official `statusLine` contract — a drop-in replacement for `cship` that needs no
extra binary, just `bash`, `jq`, and `curl`.

![claude-statusline example](img/1.png)

```
~/Projects/claude-statusline on  master  🕐 11:31
🤖 Opus 4.8  🧠 high  💰 $9.57  ██░░░░░░░░ 19%  ⌛ 5h 61% (58m)  📅 7d 18% (6d2h)  🟢 Sonnet 2% (6d2h)  📝 +228/-19
```

**Line 1** — working directory · git branch + dirty flags · language versions · clock
**Line 2** — model · reasoning effort · session cost · context bar · usage limits · lines changed

---

## Features

- **Zero extra binaries** — one bash script reading the Claude Code statusLine JSON on stdin.
- **Reasoning effort** (`🧠 high` / `max` …) straight from the live session.
- **Native context bar** using `context_window.used_percentage` — correct for both 200k and 1M windows.
- **Usage limits** (5h / 7d, plus per-model weekly Opus/Sonnet/Cowork) via the OAuth usage API,
  with a **stdin fallback** for 5h/7d so the numbers survive even when the API is unavailable.
- **Per-profile credentials** via `$CLAUDE_CONFIG_DIR` — one script serves personal and work
  profiles, each showing its own limits, with no `HOME` tricks.
- **Network-safe**: usage API is cached (45 s), refreshed in the background (never blocks a render),
  guarded by a single-flight lock (a burst of renders = one request), with a failure cooldown so a
  rate-limited/erroring API is not retried on every frame. Error responses are never cached.
- Tokyo-Night palette with warn/critical thresholds on cost, context, and limits.

## Requirements

- `bash` ≥ 4.2 (uses `$'\uXXXX'`), `jq`, `curl`
- GNU coreutils `date`/`stat` (Linux). On macOS these differ — see [Portability](#portability).
- Optional: `git`, `python3`, `node`, `rustc` (only used when a matching project is detected).
- A **Nerd Font** in your terminal for the git/language glyphs (e.g. any
  [Nerd Font](https://www.nerdfonts.com/)). Without one, those glyphs show as boxes.

## Install

```sh
# 1. put the script somewhere on disk
install -Dm755 claude-statusline.sh ~/.config/claude-statusline.sh
```

```jsonc
// 2. point Claude Code at it — ~/.claude/settings.json
{
  "statusLine": {
    "type": "command",
    "command": "/home/you/.config/claude-statusline.sh"
  }
}
```

Or run `./install.sh`, which copies the script and prints the snippet to paste.

### Two profiles (personal + work)

If you run a second profile via `CLAUDE_CONFIG_DIR`, prefix the command so the script reads that
profile's credentials (usage limits are per-account):

```jsonc
// ~/.claude-work/settings.json
{
  "statusLine": {
    "type": "command",
    "command": "CLAUDE_CONFIG_DIR=/home/you/.claude-work /home/you/.config/claude-statusline.sh"
  }
}
```

The same script file serves both — only the credential directory differs.

## What each segment means

| Segment | Source | Notes |
|---|---|---|
| `~/Projects/komunalka` | `workspace.current_dir` | truncated to last 3 path components, `~` for `$HOME` |
| `on  branch` | `git` | branch name; falls back to short SHA when detached |
| `[!+?⇡⇣]` | `git status` | `!` unstaged · `+` staged · `?` untracked · `⇡/⇣` ahead/behind |
| `via  v3.12.3` | `python3`/`node`/`rustc` | only shown when project markers exist in the dir |
| `🕐 10:38` | `date` | local `HH:MM` |
| `🤖 Opus 4.8` | `model.display_name` | |
| `🧠 high` | `effort.level` | live; absent on models without reasoning effort |
| `💰 $1.85` | `cost.total_cost_usd` | **cumulative session cost, API-equivalent** (not subscription billing) |
| `█████░░░░░ 57%` | `context_window.used_percentage` | denom-aware (200k vs 1M); falls back to transcript parse |
| `⌛ 5h 35% (1h23m)` | usage API → stdin fallback | percent used and time until reset |
| `📅 7d 15% (6d5h)` | usage API → stdin fallback | rolling 7-day window |
| `🟢 Sonnet 1%` `🔴 Opus` `🟣 Cowork` | usage API only | per-model weekly limits (not in stdin) |
| `📝 +120/-34` | `cost.total_lines_added/removed` | |

## Usage limits & the OAuth API

5h/7d limits are present in the statusLine stdin payload, but **per-model** weekly limits
(Opus/Sonnet/Cowork) are not — those come from `GET https://api.anthropic.com/api/oauth/usage`
(`anthropic-beta: oauth-2025-04-20`), authenticated with the Bearer token in
`${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.credentials.json`. This endpoint is **undocumented**; treat
it as best-effort. The token never leaves your machine except in that request to Anthropic.

Caching lives in `${TMPDIR:-/tmp}/claude-statusline-usage-<hash>.json` (per profile):

- **TTL 45 s**, refreshed in a backgrounded subshell so renders never block on the network.
- **Single-flight lock** (atomic `mkdir`) — concurrent renders trigger at most one request.
- **Failure cooldown** (120 s via a `.fail` marker); error/rate-limit bodies are never cached, so
  the last good values stay on screen.

## Customization

All colors are truecolor escapes near the top of the script (`C_*`). Thresholds for cost, context,
and limits live in the `pick <value> <warn> <crit>` calls. Language/git glyphs are Nerd Font
codepoints (Devicons: python `U+E73C`, node `U+E718`, rust `U+E7A8`).

## Portability

Written for **Linux / GNU coreutils**. The script forces `LC_NUMERIC=C` so comma-decimal locales
don't break `printf`. On **macOS**, replace GNU-isms: `date -d @EPOCH` → `date -r EPOCH`,
`date -d ISO` → `date -j -f`, and `stat -c %Y` → `stat -f %m` (or install `coreutils` and use
`gdate`/`gstat`).

## Troubleshooting

- **Glyphs are boxes/wrong** → install and select a Nerd Font in your terminal.
- **Cost looks high** → it's the cumulative, API-equivalent session cost; subscription users aren't
  billed this. It matches `cost.total_cost_usd` exactly.
- **Limits blank** → token expired/rate-limited; re-auth in Claude Code. 5h/7d still show from stdin.
- **`$X,XX` instead of `$X.XX`** → a locale issue the script already guards against with `LC_NUMERIC=C`.

## License

MIT — see [LICENSE](LICENSE).
