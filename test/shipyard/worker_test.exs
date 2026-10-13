defmodule Shipyard.WorkerTest do
  @moduledoc """
  The worker drains a real queue end to end: a bare origin, the worker's
  own clone of it, PR branches, and stubs for what leaves the machine
  (`gh`, which keeps the queue as files and squash-merges into the
  origin; the project's split gate, tier, history rule, and roll; the
  ntfy push and the macOS notification). The scenes assert what reached GitHub, the origin
  and Billy, in order, and that the worker stops on an empty queue.
  """
  use ExUnit.Case, async: true

  @moduletag :tmp_dir
  @moduletag :capture_log

  # The queue is $QUEUE/pr-<n> ("branch<TAB>labeled at<TAB>title"); a
  # comment is appended to $QUEUE/comments-<n>; every call is a line in
  # $STUB_LOG.
  @gh ~S"""
  #!/bin/bash
  case "$1 $2" in
    "api graphql")
      nodes=""
      for f in "$QUEUE"/pr-*; do
        [ -f "$f" ] || continue
        n=${f##*/pr-}
        IFS=$'\t' read -r branch at title <"$f"
        merged=null
        [ -f "$QUEUE/merged-$n" ] && merged="{\"oid\":\"$(cat "$QUEUE/merged-$n")\"}"
        nodes+="${nodes:+,}{\"number\":$n,\"title\":\"$title\",\"url\":\"u/$n\",\"headRefName\":\"$branch\",\"mergeCommit\":$merged,\"timelineItems\":{\"nodes\":[{\"createdAt\":\"$at\",\"label\":{\"name\":\"ship\"}}]}}"
      done
      echo "{\"data\":{\"repository\":{\"pullRequests\":{\"nodes\":[$nodes]}}}}" ;;
    "api -X")
      echo "stamp ${4##*/} ${10#description=}" >>"$STUB_LOG" ;;
    "pr comment")
      echo "comment $3" >>"$STUB_LOG"
      printf '%s\n' "${@: -1}" >>"$QUEUE/comments-$3" ;;
    "pr edit")
      echo "unlabel $3" >>"$STUB_LOG"
      rm -f "$QUEUE/pr-$3" ;;
    "pr merge")
      sha=${@: -1}
      echo "merge $3 $sha" >>"$STUB_LOG"
      git --git-dir="$ORIGIN" update-ref refs/heads/main \
        "$(git --git-dir="$ORIGIN" commit-tree "$sha^{tree}" -p main -m "squash #$3")"
      git --git-dir="$ORIGIN" rev-parse main >"$QUEUE/.merged-$3"
      mv "$QUEUE/.merged-$3" "$QUEUE/merged-$3" ;;
    "pr view")
      cat "$QUEUE/merged-$3" ;;
  esac
  """

  # GATE_AFTER_ROLL holds each gate after the first merge until a roll
  # has run.
  @check_remote ~S"""
  #!/bin/bash
  if [ -n "${GATE_AFTER_ROLL:-}" ] && grep -qs '^merge ' "$STUB_LOG"; then
    until grep -q '^deploy ' "$STUB_LOG"; do sleep 0.05; done
  fi
  sha=$(git rev-parse HEAD)
  echo "gate $1 $sha" >>"$STUB_LOG"
  mkdir -p "$HOME/gate-logs"
  [ "${GATE_EXIT:-0}" = 1 ] && result=red || result=green
  printf 'at\t%s\t%s\tv\t14\tstatic:9:proj-gate-1:green\ttest-1:12:proj-gate-5:%s:reran-from-proj-gate-2\n' \
    "$sha" "$1" "$result" >>"$HOME/gate-logs/check-remote.tsv"
  echo "check-remote: progress, on stderr" >&2
  [ "${GATE_EXIT:-0}" = 1 ] && echo "  1) test a clip keeps its name (Heaters.NamesTest)"
  exit "${GATE_EXIT:-0}"
  """

  # ROLL_AFTER=<n> holds the roll until PR n has merged, as a roll waiting
  # on a deploy lock does; then it fetches main again and names what it
  # rolled.
  @roll ~S"""
  #!/bin/bash
  if [ -n "${ROLL_AFTER:-}" ]; then
    until [ -f "$QUEUE/merged-$ROLL_AFTER" ]; do sleep 0.05; done
  fi
  git fetch -q origin main
  head=$(git rev-parse origin/main)
  echo "deploy $head" >>"$STUB_LOG"
  echo "roll: commit ${head:0:8}"
  echo "roll: rolled web"
  [ "${DEPLOY_EXIT:-0}" = 0 ] || echo "deploy: origin/main is NOT live everywhere"
  exit "${DEPLOY_EXIT:-0}"
  """

  # Every change but one under docs/ reaches a target.
  @tier ~S"""
  #!/bin/bash
  if git diff --name-only origin/main HEAD | grep -qv '^docs/'; then echo check; else echo check-fast; fi
  """

  # The push to ntfy is logged with its JSON body; any other URL (the
  # health check's file://) goes to the real curl.
  @curl ~S"""
  #!/bin/bash
  if [ "${@: -1}" = https://ntfy.test ]; then
    echo "push ${@: -2:1}" >>"$STUB_LOG"
    exit "${PUSH_EXIT:-0}"
  fi
  exec /usr/bin/curl "$@"
  """

  @osascript ~S"""
  #!/bin/bash
  echo "notify ${@: -2:1} | $(printf %s "${@: -1}" | tr '\n' '~')" >>"$STUB_LOG"
  """

  defp write_exec!(path, body) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, body)
    File.chmod!(path, 0o755)
  end

  defp sh!(dir, command, env) do
    {out, status} = System.cmd("bash", ["-c", command], cd: dir, env: env, stderr_to_stdout: true)
    assert status == 0, out
    String.trim(out)
  end

  # An origin whose main carries the scripts the worker runs (stubs), the
  # worker's clone of it, and its config.
  defp setup_origin(tmp, scene_env, config \\ []) do
    origin = Path.join(tmp, "origin.git")
    queue = Path.join(tmp, "queue")
    bin = Path.join(tmp, "bin")
    File.mkdir_p!(queue)
    write_exec!(Path.join(bin, "gh"), @gh)
    write_exec!(Path.join(bin, "curl"), @curl)
    write_exec!(Path.join(bin, "osascript"), @osascript)

    env =
      [
        {"PATH", bin <> ":" <> System.get_env("PATH")},
        {"HOME", tmp},
        {"STUB_LOG", Path.join(tmp, "stub.log")},
        {"QUEUE", queue},
        {"ORIGIN", origin},
        {"GIT_AUTHOR_NAME", "t"},
        {"GIT_AUTHOR_EMAIL", "t@example.test"},
        {"GIT_COMMITTER_NAME", "t"},
        {"GIT_COMMITTER_EMAIL", "t@example.test"}
      ] ++ scene_env

    sh!(tmp, "git init -q --bare -b main origin.git && git clone -q origin.git seed", env)
    seed = Path.join(tmp, "seed")
    write_exec!(Path.join(seed, "scripts/check-remote.sh"), @check_remote)
    write_exec!(Path.join(seed, "scripts/roll.sh"), @roll)
    write_exec!(Path.join(seed, "scripts/tier.sh"), @tier)

    write_exec!(
      Path.join(seed, "scripts/history.sh"),
      ~S"""
      #!/bin/bash
      echo "history $(git rev-parse HEAD)" >>"$STUB_LOG"
      exit "${HISTORY_EXIT:-0}"
      """
    )

    File.mkdir_p!(Path.join(seed, "lib"))
    File.write!(Path.join(seed, "lib/app.ex"), "1\n")
    File.write!(Path.join(tmp, "health"), ~s({"status":"ok"}))
    sh!(seed, "git add -A && git commit -qm base && git push -q origin main", env)
    sh!(tmp, "git clone -q origin.git entry", env)

    ship =
      Shipyard.config(
        [
          name: "proj",
          home: Path.join(tmp, ".cache/shipyard/proj"),
          repo: "owner/repo",
          gate: ["bash", "scripts/check-remote.sh"],
          gate_log: Path.join(tmp, "gate-logs/check-remote.tsv"),
          tier: ["bash", "scripts/tier.sh"],
          history: [["bash", "scripts/history.sh"]],
          roll_command: ["bash", "scripts/roll.sh"],
          checkout: Path.join(tmp, "entry"),
          roll: Path.join(tmp, "roll"),
          health_url: "file://" <> Path.join(tmp, "health"),
          ntfy_topic: "test-topic",
          ntfy_url: "https://ntfy.test",
          desktop: true,
          env: env,
          poll_ms: 10,
          idle_ms: 0,
          merge_wait_ms: 10,
          tries: 2
        ] ++ config
      )

    %{tmp: tmp, seed: seed, queue: queue, env: env, ship: ship, log: Path.join(tmp, "stub.log")}
  end

  # A branch on origin that changes `path`, labeled `ship` at `at`.
  defp queue!(o, number, branch, path, at) do
    sh!(
      o.seed,
      "git checkout -q -B #{branch} origin/main && mkdir -p $(dirname #{path}) && echo #{branch} >> #{path} && " <>
        "git add -A && git commit -qm '#{branch}' && git push -q origin #{branch}",
      o.env
    )

    File.write!(Path.join(o.queue, "pr-#{number}"), "#{branch}\t#{at}\tchange #{branch}\n")
    sh!(o.seed, "git rev-parse HEAD", o.env)
  end

  # Main moves on after the branches were cut, so each ship really rebases.
  defp advance_main!(o, path) do
    sh!(
      o.seed,
      "git checkout -q -B main origin/main && echo main >> #{path} && git add -A && git commit -qm main && git push -q origin main",
      o.env
    )
  end

  defp drain!(o) do
    pid = start_supervised!({Shipyard.Worker, ship: o.ship})
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 60_000
  end

  defp events(o), do: o.log |> File.read!() |> String.split("\n", trim: true)
  defp comments(o, n), do: File.read!(Path.join(o.queue, "comments-#{n}"))
  defp pushes(o), do: for("push " <> json <- events(o), do: JSON.decode!(json))
  defp origin(o, ref), do: sh!(o.tmp, "git --git-dir=origin.git rev-parse #{ref}", o.env)

  # The rows the worker kept (`Shipyard.Record`), each the fields a scene
  # asserts, a wait as whether one was recorded.
  defp rows(o) do
    for row <- Shipyard.Record.results(o.ship) do
      row
      |> Map.take([:pr, :outcome, :gate, :tier, :slowest, :cause])
      |> Map.put(:waited, row.wait != "")
    end
  end

  test "queued PRs land in label order: rebased, gated on that commit, pushed, stamped, merged; the next gate runs while a roll waits, the roll covers both merges, and the worker stops",
       %{tmp_dir: tmp} do
    o = setup_origin(tmp, [{"ROLL_AFTER", "11"}])
    queue!(o, 11, "claude/later", "lib/later.ex", "2026-10-09T10:05:00Z")
    queue!(o, 12, "claude/first", "lib/first.ex", "2026-10-09T10:00:00Z")
    advance_main!(o, "lib/main.ex")
    moved_main = origin(o, "main")

    drain!(o)

    [first_gate, second_gate] =
      for "gate check " <> sha <- events(o), do: sha

    assert [
             "history " <> ^first_gate,
             "gate check " <> ^first_gate,
             "stamp " <> stamp_one,
             "merge 12 " <> ^first_gate,
             "history " <> ^second_gate,
             "gate check " <> ^second_gate,
             "stamp " <> _,
             "merge 11 " <> ^second_gate,
             "deploy " <> rolled,
             "comment 12",
             "unlabel 12",
             "push " <> _,
             "notify proj #12 change claude/first | live. Rolled web at " <> _,
             "comment 11",
             "unlabel 11",
             "push " <> _,
             "notify proj #11 change claude/later | " <> _
           ] = events(o)

    assert rolled == origin(o, "main")

    # One push per ship to the topic, with the title, outcome, what
    # rolled and the branch, and nothing else.
    assert [first_push, _] = pushes(o)

    assert first_push == %{
             "topic" => "test-topic",
             "title" => "proj #12 change claude/first",
             "message" => "live. Rolled web at #{String.slice(rolled, 0, 8)}.\nclaude/first",
             "tags" => ["white_check_mark"]
           }

    # Each gate saw the branch on top of the main it lands on, and that
    # is what reached the branch on origin.
    sh!(
      tmp,
      "git --git-dir=origin.git merge-base --is-ancestor #{moved_main} #{first_gate}",
      o.env
    )

    sh!(tmp, "git --git-dir=origin.git merge-base --is-ancestor main~1 #{second_gate}", o.env)
    assert origin(o, "claude/first") == first_gate
    assert origin(o, "main^{tree}") == origin(o, "#{second_gate}^{tree}")

    assert stamp_one =~
             ~r/^#{first_gate} bash scripts\/check-remote.sh check passed on proj-gate-1,5 at /

    roll = "The roll of `#{String.slice(rolled, 0, 8)}`, covering #12, #11, rolled web;"

    assert comments(o, 12) =~
             ~r/^#{Regex.escape(Shipyard.marker())}\nship: live\. Merged as `\w{8}` after bash scripts\/check-remote.sh check passed .*\. #{Regex.escape(roll)}/

    assert comments(o, 11) =~ "ship: live. Merged as `#{String.slice(rolled, 0, 8)}`"
    assert comments(o, 11) =~ roll
    assert Path.wildcard(Path.join(o.queue, "pr-*")) == []

    # Each row has its label's wait and its gate; a part that reran on the
    # spare marks the green gate.
    gated = %{gate: "14", tier: "check", slowest: "test-1", cause: "sprite-rerun", waited: true}

    assert rows(o) == [
             Map.merge(gated, %{pr: "12", outcome: "live"}),
             Map.merge(gated, %{pr: "11", outcome: "live"})
           ]
  end

  test "a merge after the roll fetched main waits for the next roll", %{tmp_dir: tmp} do
    o = setup_origin(tmp, [{"GATE_AFTER_ROLL", "1"}])
    queue!(o, 12, "claude/first", "lib/first.ex", "2026-10-09T10:00:00Z")
    queue!(o, 11, "claude/later", "lib/later.ex", "2026-10-09T10:05:00Z")

    drain!(o)

    assert [first_roll, second_roll] = for("deploy " <> sha <- events(o), do: sha)
    assert second_roll == origin(o, "main")
    assert first_roll == origin(o, "main~1")

    at = fn event -> Enum.find_index(events(o), &(&1 == event)) end
    assert at.("comment 12") < at.("deploy " <> second_roll)
    assert at.("deploy " <> second_roll) < at.("comment 11")
    assert comments(o, 12) =~ "The roll of `#{String.slice(first_roll, 0, 8)}`, covering #12,"
    assert comments(o, 11) =~ "The roll of `#{String.slice(second_roll, 0, 8)}`, covering #11,"
  end

  test "a merged PR still labeled when the worker starts is rolled and gets its result",
       %{tmp_dir: tmp} do
    o = setup_origin(tmp, [])
    main = origin(o, "main")
    File.write!(Path.join(o.queue, "pr-5"), "claude/old\t2026-10-09T09:00:00Z\tchange old\n")
    File.write!(Path.join(o.queue, "merged-5"), main)

    drain!(o)

    assert ["deploy " <> ^main, "comment 5", "unlabel 5", "push " <> _, "notify " <> _] =
             events(o)

    assert comments(o, 5) =~
             "ship: live. Merged as `#{String.slice(main, 0, 8)}`. The roll of `#{String.slice(main, 0, 8)}`, covering #5, rolled web;"
  end

  test "a red gate posts its digest and ends the ship with nothing pushed, stamped, merged or rolled",
       %{tmp_dir: tmp} do
    o = setup_origin(tmp, [{"GATE_EXIT", "1"}])
    head = queue!(o, 7, "claude/red", "lib/red.ex", "2026-10-09T10:00:00Z")
    advance_main!(o, "lib/main.ex")

    drain!(o)

    assert [
             "history " <> _,
             "gate check " <> _,
             "comment 7",
             "unlabel 7",
             "push " <> _,
             "notify proj #7 change claude/red | red.~claude/red"
           ] = events(o)

    assert comments(o, 7) =~ "ship: red. Red on `"
    assert comments(o, 7) =~ "1) test a clip keeps its name (Heaters.NamesTest)"
    refute comments(o, 7) =~ "progress, on stderr"

    # The digest stays on the PR; the push says only that it is red.
    assert [%{"message" => "red.\nclaude/red", "tags" => ["x"]}] = pushes(o)
    assert origin(o, "claude/red") == head

    assert [%{outcome: "red", cause: "test", gate: "14", tier: "check", waited: true}] =
             rows(o)
  end

  test "no verdict leaves the PR queued to run again with no push, and sends it back after `tries`",
       %{tmp_dir: tmp} do
    o = setup_origin(tmp, [{"GATE_EXIT", "2"}])
    head = queue!(o, 7, "claude/flaky-pool", "lib/a.ex", "2026-10-09T10:00:00Z")

    drain!(o)

    assert [
             "history " <> _,
             "gate check " <> _,
             "history " <> _,
             "gate check " <> _,
             "comment 7",
             "unlabel 7",
             "push " <> _,
             "notify " <> _
           ] = events(o)

    assert [%{"message" => "sent back.\nclaude/flaky-pool"}] = pushes(o)

    assert comments(o, 7) =~
             "ship: sent back. No result after 2 tries; the last: no verdict: a Sprite failed"

    assert origin(o, "claude/flaky-pool") == head

    # Both runs are rows with their cause; only the first waited on the
    # label.
    assert [
             %{outcome: "retry", cause: "sprite", waited: true},
             %{outcome: "back", cause: "sprite", waited: false}
           ] = rows(o)
  end

  test "a branch that conflicts with main is sent back before any gate; a failed push holds nothing",
       %{tmp_dir: tmp} do
    o = setup_origin(tmp, [{"PUSH_EXIT", "22"}])
    queue!(o, 7, "claude/conflict", "lib/app.ex", "2026-10-09T10:00:00Z")
    advance_main!(o, "lib/app.ex")

    drain!(o)

    assert ["comment 7", "unlabel 7", "push " <> _, "notify " <> _] = events(o)
    assert comments(o, 7) =~ "ship: sent back. The rebase onto origin/main"
    assert comments(o, 7) =~ "conflicts"
    assert [%{outcome: "back", cause: "conflict", gate: ""}] = rows(o)
  end

  test "a failed roll ends the ship landed but not live", %{tmp_dir: tmp} do
    o = setup_origin(tmp, [{"DEPLOY_EXIT", "1"}])
    queue!(o, 7, "claude/roll", "lib/a.ex", "2026-10-09T10:00:00Z")

    drain!(o)

    assert comments(o, 7) =~ "ship: landed, not live. Merged as `"

    assert comments(o, 7) =~
             ~r/The roll of `\w{8}`, covering #7, failed \(deploy: origin\/main is NOT live everywhere\); .* Log: `/

    assert [
             "history " <> _,
             "gate check " <> _,
             "stamp " <> _,
             "merge 7 " <> _,
             "deploy " <> _ | _
           ] =
             events(o)

    assert length(for "deploy " <> _ <- events(o), do: 1) == 1

    assert [%{"message" => message, "tags" => ["warning"]}] = pushes(o)
    assert message =~ ~r/^landed, not live\. The roll of \w{8} failed\.\nclaude\/roll$/
    assert origin(o, "main^{tree}") != origin(o, "main~1^{tree}")
    assert [%{outcome: "not_live", cause: "roll"}] = rows(o)
  end

  test "with merge: push the gated commit itself becomes main, its commits as they are, and a docs-only change gates on the tier its project names",
       %{tmp_dir: tmp} do
    o = setup_origin(tmp, [], merge: "push")
    queue!(o, 9, "claude/docs", "docs/guide.md", "2026-10-09T10:00:00Z")
    advance_main!(o, "lib/main.ex")

    drain!(o)

    assert [
             "history " <> gated,
             "gate check-fast " <> gated,
             "stamp " <> _,
             "deploy " <> rolled | _
           ] =
             events(o)

    refute Enum.any?(events(o), &String.starts_with?(&1, "merge "))
    assert origin(o, "main") == gated
    assert rolled == gated
    assert origin(o, "claude/docs") == gated
    assert sh!(tmp, "git --git-dir=origin.git log -1 --format=%s main", o.env) == "claude/docs"

    assert comments(o, 9) =~
             "ship: live. Merged as `#{String.slice(gated, 0, 8)}` after bash scripts/check-remote.sh check-fast passed"
  end

  test "a red history rule ends the ship before any gate", %{tmp_dir: tmp} do
    o = setup_origin(tmp, [{"HISTORY_EXIT", "1"}])
    head = queue!(o, 7, "claude/history", "lib/a.ex", "2026-10-09T10:00:00Z")

    drain!(o)

    assert ["history " <> _, "comment 7", "unlabel 7", "push " <> _, "notify " <> _] = events(o)
    assert comments(o, 7) =~ "ship: red. The history rule `bash scripts/history.sh` failed"
    assert origin(o, "claude/history") == head
    assert [%{outcome: "red", cause: "history", gate: ""}] = rows(o)
  end
end
