# shipyard

The ship worker: a small Elixir app that lands a project's queued pull
requests on `main` one at a time and rolls production behind them, one
roll at a time. It has no database. GitHub is its queue and its record.
One worker runs per project, each from its own clone of this repository,
so projects never wait on one another.

## A project

A project is a GitHub repository with a `.shipyard.json` at its root. It
names what differs between projects; the code that gates and rolls stays
in the project.

```json
{
  "name": "soco",
  "repo": "billybjork/soco",
  "merge": "push",
  "gate": ["bash", "tooling/check-remote.sh"],
  "gate_log": "~/.cache/soco-ship/logs/check-remote.tsv",
  "tier": ["bash", "tooling/deployable.sh"],
  "history": [["bash", "tooling/check-history.sh"]],
  "roll": ["bash", "tooling/roll.sh"],
  "health_url": "https://app.example.com/health"
}
```

- `gate` is the split gate on the entry's HEAD. Exit 0 is green, 1 red with
  a digest of 30 lines or fewer on stdout, 2 no verdict (a runner failed
  and its spare could not cover it). It appends one row per run to
  `gate_log`: at, sha, tier, verdict, wall seconds, then each part as
  `name:seconds:sprite:result`, with `:reran-from-<sprite>` on a part that
  reran on the spare.
- `tier` (optional) prints the gate's tier, which is passed to `gate` as
  its argument; a change that reaches no deploy target can take a faster
  gate. Without it every gate is `check`, and `gate` runs as written.
- `history` (optional) lists commands that must pass on the rebased branch
  before its gate, such as rules on applied migrations or a secret scan.
- `merge` is `squash` (GitHub squash-merges the PR, and the worker checks
  the landed tree is the gated one) or `push` (the gated commit itself is
  pushed to `main`, with a lease on the base it was gated on, so the
  branch's commits land as they are).
- `roll` rolls `origin/main` from the worker's roll checkout. Exit 0 means
  what it rolled is live; otherwise its last line says why. It prints
  `roll: commit <sha>` for the commit it rolled (when it fetches main
  again, after waiting on a lock) and `roll: rolled <target>` for each
  target that changed. After it, `health_url` must answer `"status":"ok"`.

## A ship

- **The queue** is the open PRs labeled `ship`, oldest label first. A
  project's ship command pushes the branch, opens or updates the PR, adds
  the label, and runs `bin/shipyard start <project>`. Any session that can
  push and label can queue a PR, but only a running worker takes it.
- **Each entry** (`Shipyard.Entry`):
  1. Fetch, then rebase onto `origin/main`. A conflict sends the PR back.
  2. The history rules.
  3. The tier.
  4. The split gate on that exact commit. No verdict leaves the PR queued.
  5. Force-push the branch with lease.
  6. The `gate` status on the commit, naming the Sprites.
  7. The merge, per `merge`: `squash` merges with `--match-head-commit`,
     then checks that the landed tree equals the gated one.

  The next entry starts right after the merge.
- **The roll** (`Shipyard.Roll`) runs beside the next gate, from its own
  checkout. A merged PR keeps its label and waits for a roll; one starts
  whenever a PR waits and none runs. It rolls `origin/main`, so one roll
  covers every merge before that commit. When it ends, each PR it covered
  gets its result, naming the roll (``The roll of `<sha>`, covering #12,
  #11, ...``); a PR merged after it fetched waits for the next. A failed
  roll is not retried: its PRs are landed, not live, until a later roll.
  A merged PR still labeled when a worker starts (one stopped mid-roll)
  waits for a roll like any other.
- **The record** is one comment per ship on its PR, led by
  `<!-- shipyard -->`: `ship: live.`, `ship: red.` (the digest),
  `ship: landed, not live.`, or `ship: sent back.` (the reason). The label
  comes off after the comment. A PR that gets no verdict three times in
  one run is sent back.
- **Billy hears** of every ship's end (`Shipyard.Notify`): live, red,
  landed but not live, or sent back, one message each; a retry is not an
  end and sends nothing. Each is one push to ntfy.sh on the topic
  `NTFY_TOPIC` from the project's `.env`, and a macOS notification, each
  naming the project, the PR's number and title, the outcome, what rolled,
  and the branch, never code, logs or the digest. The topic's secrecy is
  the only access control: it stays in `.env`, out of logs, and the tests
  never read it. A notification never holds a ship: without the topic the
  worker logs a warning at start and sends no push, and a failed push is
  one warning line.
- **Reading it.** `bin/shipyard wait <project> <pr>` waits silently until
  the label is off, prints the newest result, and exits 0 only on `live`.
  `bin/shipyard watch <project> <pr>` runs that wait in a Rex pane, out
  of focus, below the pane it's called from (`$REX_BLOCK`; a tab in the
  session `Shipyard` when there is none), and prints the pane's block: `rex wait -s <session> <block>
  --for 9m` returns the wait's exit status when the ship ends (repeat it
  on a timeout) and `rex capture` reads the result. A wait in a pane
  belongs to no agent's command, so no command timeout or harness ends it,
  and Billy can see it. Without Rex, `watch` is `wait`.
- **Its status.** The worker and `wait` report to the terminal they run in
  with Program Status reports (OSC 7501, `Shipyard.Status`), which Rex
  shows as a spinner on the tab and marks on the session: the worker's own
  record says what it gates and rolls; each PR has a record, `pr-<n>`,
  working with its step, then `done` when live and `error` for any other
  end, which outlive the worker. The gate runs with `SHIPYARD_STATUS_ID`
  set to its PR's record, so a project's gate can report each part beneath
  it (`pr-<n>/<part>`) to `/dev/tty`. Reports go only to the terminal,
  never to stdout or the logs.
  `bin/shipyard list <project>` shows the queue, the running entry and its
  step, the merged PRs waiting for a roll, and the last 20 results.
- **The numbers.** Each entry run, a retry included, is a row in
  `logs/ships.tsv` (`Shipyard.Record`): its outcome and seconds, the wait
  from its label to the worker taking it, the gate's wall seconds, tier
  and slowest part, and the cause of a red, a retry, or a ship that landed
  but is not live: a red gate is `static` (a part other than the suite),
  `timing` (the digest names a timeout) or `test`; others include
  `sprite`, `sprite-rerun`, `main-moved`, `conflict`, `history`, `roll`
  and `health`. `bin/shipyard list <project> --summary [since]` gives
  gate time p50 and p90 per tier, the queue wait, and the causes.

## Where it runs

On the laptop for now. `bin/shipyard start <project>` keeps the worker's
home at `~/.cache/shipyard/<name>/`: `app` (a clone of this repository)
and `repo` (a clone of the project), both reset to `origin/main` at each
start, so a worker runs merged code under the project's merged config;
`entry`, a linked worktree of `repo` it gates in; `roll`, a second clone
it rolls from (a fetch into refs the gating checkout shares would race
the entry's own); `state.json`; and `logs/` (`worker.log`, `ships.tsv`,
each roll's log). It loads the primary checkout's `.env`, runs `mix run`
under `caffeinate -i`, and stops once the queue has been empty, with no
roll running or waiting, for a minute. The next ship starts it on fresh
code.

Where a Rex server runs, the worker runs in a Rex tab: the session
`Shipyard`, a tab named for the project, out of focus, showing its log
and status, which stays once the worker stops and is replaced by the
next start's. A Rex terminal outlives whatever started it, which an
agent's command does not (a harness kills its process group when the
command ends). Without Rex (launchd's poll before login, or
`SHIPYARD_REX=0`) the worker runs detached in its own session instead.

The launchd job `launchd/com.billy.shipyard.plist` runs `bin/shipyard
poll` every 15 minutes, which starts a worker for each project listed in
`~/.config/shipyard/projects` (one checkout path per line) that has a PR
labeled, so a PR a cloud session labeled lands while the laptop is awake.

A change to shipyard takes effect at each worker's next start. Gate it
with `bin/shipyard check` (compile, format, tests) and push it to `main`.
