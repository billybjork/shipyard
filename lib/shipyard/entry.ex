defmodule Shipyard.Entry do
  @moduledoc """
  One queued PR from its branch to `main`, in order: rebase onto
  `origin/main`, the project's history rules, its tier, the split gate on
  that exact commit, force-push with lease, the `gate` stamp, and the
  merge: a squash-merge whose landed tree is checked against the gated
  one, or (`merge: push`) the gated commit pushed to `main` with a lease
  on the base it was gated on. Each step runs the branch's own scripts in
  the worker's checkout, as the project's laptop ship runs them. The roll
  is the worker's, after the merge (`Shipyard.Roll`).

  Returns `{result, gate}`. `result` is `{:merged, merge_commit, text}`
  for a PR that landed, where `text` begins its result. Otherwise it is
  `{outcome, text, cause}`: `:not_live` (landed, not to be rolled), `:red`
  and `:back` (sent back to its session) end the ship, and `text` is the
  body of its PR comment; `:retry` leaves it queued, and `text` says why.
  `cause` is one word for the trial's record (`Shipyard.Record`): `test`,
  `timing` or `static` for a red gate, `sprite` for a gate with no
  verdict, and the step's own word otherwise. `gate` is what the split
  gate's run reported (`%{tier, secs, slowest, reran}`), or `%{}` when no
  gate ran.
  """

  alias Shipyard.{Cmd, GitHub, Status}

  def run(ship, pr, report \\ fn _step -> :ok end) do
    dir = ship.checkout
    _ = report.("rebase")

    with {:ok, lease} <- checkout(ship, dir, pr.branch),
         {:ok, base} <- rebase(ship, dir),
         sha = Cmd.git!(ship, dir, ["rev-parse", "HEAD"]),
         :ok <- history(ship, dir) do
      {tier, command} = tier(ship, dir)
      _ = report.("gate: #{Enum.join(command, " ")} on #{short(sha)}")
      {verdict, gate} = gate(ship, dir, tier, command, sha, pr)

      result =
        with {:ok, passed} <- verdict,
             :ok <- unmoved(ship, dir, base),
             :ok <- push(ship, dir, pr.branch, lease),
             :ok <- GitHub.stamp(ship, sha, passed),
             _ = report.("merge"),
             {:ok, merged} <- merge(ship, dir, pr.number, sha, base) do
          {:merged, merged, "Merged as `#{short(merged)}` after #{passed}"}
        end

      {result, gate}
    else
      ended -> {ended, %{}}
    end
  end

  defp checkout(ship, dir, branch) do
    # A rebase a stopped worker left half done.
    _ = Cmd.git(ship, dir, ["rebase", "--abort"])
    Cmd.git!(ship, dir, ["fetch", "-q", "--prune", "origin"])

    case Cmd.git(ship, dir, ["rev-parse", "-q", "--verify", "origin/#{branch}^{commit}"]) do
      {lease, 0} ->
        Cmd.git!(ship, dir, ["checkout", "-q", "--force", "--detach", "origin/#{branch}"])
        Cmd.git!(ship, dir, ["clean", "-fdq"])
        {:ok, String.trim(lease)}

      _ ->
        {:back, "The branch `#{branch}` is not on origin.", "no-branch"}
    end
  end

  defp rebase(ship, dir) do
    base = Cmd.git!(ship, dir, ["rev-parse", "origin/main"])

    case Cmd.git(ship, dir, ["rebase", "-q", "origin/main"]) do
      {_, 0} ->
        if Cmd.git!(ship, dir, ["rev-parse", "HEAD"]) == base,
          do: {:back, "Nothing to ship: the branch holds nothing beyond origin/main.", "empty"},
          else: {:ok, base}

      {out, _} ->
        _ = Cmd.git(ship, dir, ["rebase", "--abort"])

        {:back,
         "The rebase onto origin/main (`#{short(base)}`) conflicts:\n#{block(out)}\n" <>
           "Rebase the branch by hand (`git rebase origin/main`), push it, and ship again.",
         "conflict"}
    end
  end

  defp history(ship, dir) do
    Enum.reduce_while(ship.history, :ok, fn [cmd | args] = command, :ok ->
      case Cmd.run(ship, dir, cmd, args) do
        {_, 0} ->
          {:cont, :ok}

        {out, _} ->
          {:halt,
           {:red, "The history rule `#{Enum.join(command, " ")}` failed:\n#{block(out)}",
            "history"}}
      end
    end)
  end

  # The tier the project's `tier` command names (a change that reaches no
  # deploy target can take a faster gate), and the gate's command for it.
  # Without a `tier` command every gate is `check`, run as written.
  defp tier(%{tier: nil} = ship, _dir), do: {"check", ship.gate}

  defp tier(ship, dir) do
    [cmd | args] = ship.tier

    tier =
      case Cmd.run(ship, dir, cmd, args, stderr_to_stdout: false) do
        {out, 0} when out != "" -> String.trim(out)
        _ -> "check"
      end

    {tier, ship.gate ++ [tier]}
  end

  defp gate(ship, dir, tier, [cmd | args] = command, sha, pr) do
    command = Enum.join(command, " ")

    # The gate may report its parts beneath the PR's status record.
    {out, status} =
      Cmd.run(ship, dir, cmd, args,
        stderr_to_stdout: false,
        timeout: ship.gate_timeout_ms,
        env: [{"SHIPYARD_STATUS_ID", Status.id(pr)} | ship.env]
      )

    run = gate_run(ship, sha)
    gate = run && %{tier: tier, secs: run.secs, slowest: run.slowest, reran: run.reran}

    verdict =
      case status do
        0 ->
          {:ok, "#{command} passed#{on_sprites(run)} at #{now()}"}

        1 ->
          {:red,
           "Red on `#{short(sha)}` (`#{command}`):\n#{block(out)}\nFix it on the branch and ship again.",
           red_cause(out, run)}

        2 ->
          {:retry, "no verdict: a Sprite failed and the spare could not cover it", "sprite"}

        status ->
          {:retry, "check-remote exited #{status}", "gate-exit-#{status}"}
      end

    {verdict, gate || %{tier: tier}}
  end

  # A red gate's cause: a red part that is not the suite is `static`
  # (compile, format, credo, dialyzer and the rest); a digest that names a
  # timeout (the test timeout, the query timeout's 57014, an
  # assert_receive past its wait) is `timing`; any other is `test`.
  defp red_cause(digest, run) do
    cond do
      run &&
          Enum.any?(run.parts, &(&1.result == "red" and not String.starts_with?(&1.name, "test"))) ->
        "static"

      digest =~ ~r/TimeoutError|timed out|57014|statement timeout|no matching message after/i ->
        "timing"

      true ->
        "test"
    end
  end

  # check-remote's row for this commit (the newest, if it ran twice): its
  # wall seconds, its slowest part, whether a part reran on the spare, and
  # each part's name, seconds, Sprite and result.
  defp gate_run(ship, sha) do
    rows =
      case File.read(ship.gate_log) do
        {:ok, tsv} -> String.split(tsv, "\n", trim: true)
        {:error, _} -> []
      end

    case rows |> Enum.map(&String.split(&1, "\t")) |> Enum.filter(&(Enum.at(&1, 1) == sha)) do
      [] ->
        nil

      matching ->
        [_at, _sha, _tier, _verdict, wall | parts] = List.last(matching)

        parts =
          Enum.map(parts, fn part ->
            [name, secs, sprite, result | rest] = String.split(part, ":")

            %{
              name: name,
              secs: String.to_integer(secs),
              sprite: sprite,
              result: result,
              reran: rest != []
            }
          end)

        %{
          secs: String.to_integer(wall),
          slowest: parts |> Enum.max_by(& &1.secs, fn -> %{name: nil} end) |> Map.get(:name),
          reran: Enum.any?(parts, & &1.reran),
          parts: parts
        }
    end
  end

  # Where the gate ran: " on soco-gate-1,2,3,5", each Sprite's name
  # after its pool's prefix (the name up to its last dash).
  defp on_sprites(nil), do: ""

  defp on_sprites(run) do
    run.parts
    |> Enum.map(&String.split(&1.sprite, ~r/-(?=[^-]*$)/))
    |> Enum.chunk_by(&hd/1)
    |> Enum.map_join(" and ", fn [[prefix | _] | _] = same ->
      prefix <> "-" <> Enum.map_join(same, ",", &List.last/1)
    end)
    |> then(&(" on " <> &1))
  end

  defp unmoved(ship, dir, base) do
    Cmd.git!(ship, dir, ["fetch", "-q", "origin", "main"])

    if Cmd.git!(ship, dir, ["rev-parse", "origin/main"]) == base,
      do: :ok,
      else: {:retry, "main moved during the gate", "main-moved"}
  end

  defp push(ship, dir, branch, lease) do
    lease = "--force-with-lease=refs/heads/#{branch}:#{lease}"

    case Cmd.git(ship, dir, ["push", "-q", lease, "origin", "HEAD:refs/heads/#{branch}"]) do
      {_, 0} -> :ok
      {_, _} -> {:retry, "the branch moved during the gate", "branch-moved"}
    end
  end

  # The gated commit itself becomes main, with a lease on the base it was
  # gated on; GitHub marks the PR merged when its head reaches main.
  defp merge(%{merge: "push"} = ship, dir, _number, sha, base) do
    lease = "--force-with-lease=refs/heads/main:#{base}"

    case Cmd.git(ship, dir, ["push", "-q", lease, "origin", "#{sha}:refs/heads/main"]) do
      {_, 0} -> {:ok, sha}
      {_, _} -> {:retry, "main moved before the push", "main-moved"}
    end
  end

  defp merge(ship, dir, number, sha, _base) do
    case GitHub.merge(ship, number, sha) do
      {:ok, merged} ->
        Cmd.git!(ship, dir, ["fetch", "-q", "origin", "main"])

        if tree(ship, dir, merged) == tree(ship, dir, sha),
          do: {:ok, merged},
          else:
            {:not_live,
             "Merged as `#{short(merged)}`, but its tree is not the gated commit's (`#{short(sha)}`); not rolled. " <>
               "Compare them before rolling by hand.", "tree"}

      {:error, why} ->
        {:back, "GitHub refused the merge (the gate stamp is on `#{short(sha)}`):\n#{block(why)}",
         "merge"}
    end
  end

  defp tree(ship, dir, commit), do: Cmd.git!(ship, dir, ["rev-parse", "#{commit}^{tree}"])

  defp block(text), do: "```\n" <> String.trim(text) <> "\n```"
  defp short(sha), do: String.slice(sha, 0, 8)
  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
end
