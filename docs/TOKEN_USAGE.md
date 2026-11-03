# Token usage

Yardlet counts the tokens Claude Code and Codex record in their own transcripts on this Mac and shows them
with each account's plan limits: on Home over the projects, in Settings › Usage, and on one line under Usage in
the menu bar menu and the sidebar's account menu. Nothing is sent anywhere and no model is asked anything.

## Where it shows

- **Home:** a band over the projects. Its heading reads today's tokens and their API-equivalent cost ("Usage ·
  5.48B tokens today · $2,124 API equivalent") and opens Settings › Usage. Under it, the last 14 days as bars (today
  in the accent) and the three limit windows closest to running out, each with its account, harness mark, the share
  left and, when the window runs out before it resets at its recent pace, "runs out in 1 hr, 30 min". While the band
  shows, the line over the composer leaves out its nearly spent limits, which the band already says, and keeps the
  Mac's own warnings. With Home shown, the limits are read again every five minutes so the pace has readings a while
  apart.
- **Settings › Usage** (after Accounts), as the Claude and Codex apps put usage in Settings:
  - **Plan limits:** every account with a limit, each window on the bar grid every limit uses, with when it resets or,
    in orange, when it runs out first at this pace.
  - **Token usage** for Today, 7 days or 30 days: tokens, API-equivalent cost, requests and the share of input read
    from the cache; the last 30 days as bars of their cost with the chosen range in the accent; the range's tokens and
    cost by kind (cache reads, new input, cache writes, output: two bars and a table); and where it went, by model,
    project, task or account, six rows and then "Show more".
  - The prices' source and date, and the switch.
- **Menus:** "5.48B tokens today · $2,124 API equivalent" first under Usage. In the sidebar's account menu it opens
  Settings › Usage.

## Turning it on and off

- Settings › Usage › **Count token usage**, on by default. It is also in the settings the agents' settings tools
  list (`token_usage`).
- Turning it off stops reading and watching, and deletes `~/.yardlet/usage/` with every count in it. The transcripts
  stay as they are; they belong to Claude Code and Codex. The limits stay in Settings › Usage and the menus, as they
  come from the account checks Yardlet makes anyway. Turning it on reads the transcripts again.

## What is read

- Claude Code: `projects/**/*.jsonl` of the default config folder (`~/.claude`) and of every saved account folder that
  keeps its own (most link to the default one's, which is read once). Each `assistant` line's `message.usage`: input,
  cache writes (5-minute and 1-hour), cache reads and output, with the model, `speed` and `inference_geo`.
- Codex: `sessions/**/rollout-*.jsonl` of `~/.codex` and of saved account folders. Each `token_count` event's running
  totals, counted as the difference from the one before; the model from `turn_context`, the folder from the first
  `session_meta`.
- Each file is read only past where it last stopped, from a file-system watch (FSEvents, two seconds' latency, so a
  streaming turn's writes come as one read). A line still being written waits for the next read. A file replaced or
  cut short is read again from its start. The first read takes every transcript modified within a year, once, at a low
  priority (about two minutes for 15 GB in a debug build).

## How it counts

- **Once per response.** Claude Code writes one line per content block of a response, each with the response's usage
  and an output that grows to its final count. Each `message.id` counts once, with its largest output; a later line
  adds only the output not counted yet. A forked or branched conversation copies earlier responses into a new file;
  those ids were counted, so the copy adds nothing. The ids of the last 14 days are kept for this.
- **Codex's replayed history.** A subagent's rollout first replays its parent's history up to
  `subagent_history_start_ordinal`; its counts are not counted, and a repeated total (a count that only refreshed
  the limits) adds nothing.
- **Days** are the Mac's calendar days at the time of each request. Counts older than a year are dropped.
- **Accounts:** a session Yardlet runs counts against the account its task is on when the request is read (a task
  moved to another account counts there from then on); any other session against its harness's default login. The
  names are the Usage lines' (the address, with a team's organization). History read when counting is first turned on
  counts against the account each task is on at that time.
- **Projects** are the sidebar's (a worktree counts with its project); a session Yardlet did not start goes to the
  project whose folder holds its folder, else to the folder's name.

## Prices

The API-equivalent cost uses the providers' public prices, copied into Yardlet with the date of the copy
(`TokenUsagePrices`), never fetched:

- Anthropic, <https://platform.claude.com/docs/en/about-claude/pricing>, 2026-11-03: input, 5-minute and 1-hour cache
  writes, cache reads and output per model; Claude Haiku 5.5's prices over 100,000 prompt tokens; fast mode at twice
  the rates on the models that have it; US-only inference at 1.1 times.
- OpenAI, <https://developers.openai.com/api/docs/pricing>, 2026-11-03: the GPT-6 family's Standard tier, with the
  long-context prices over 272K input tokens; a cache write at the 30-minute write price.

A model missing from the table is counted in tokens only and named "No price" by model. A subscription does not pay
these dollars; it pays in plan limits, as the page says under the numbers.

## Pace

When a limit window runs out is worked out from the limit's own readings, never from tokens: the share used in two
readings of the same window at least 15 minutes apart within the last hour, and the latest no older than 30 minutes.
It shows only when that comes before the window resets. The readings are the account checks the Usage lines already
make, kept in memory only.

## What is kept

`~/.yardlet/usage/usage.sqlite3`, one file: counts by day, harness, model, provider session, folder and account (tokens
of each kind, requests and their cost); how far each transcript was read; and the response ids of the last 14 days.
About 13 MB for two months of heavy use. Nothing else is written, and the folder goes when counting is turned off.

## Work on the main thread

The reading, counting and summing run off the main thread. The app gets a summary of the last 30 days after a read that
counted something, and publishes it only when it differs; only the Home band and the usage page read it, so a new count
redraws them and nothing else (`TokenUsageLedgerTests`: 60,000 responses read once, then each new response one read of its
own bytes and one publication).
