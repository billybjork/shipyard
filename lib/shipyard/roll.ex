defmodule Shipyard.Roll do
  @moduledoc """
  One roll of production: the project's `roll` command from the worker's
  roll checkout (`Shipyard` `:roll`, a clone of its own, so the next
  entry's gate runs beside it), then `/health`. The command rolls
  `origin/main` as it finds it, so one roll covers every merge before that
  commit, and it keeps any lock that stops two rolls overlapping.

  The command's contract: exit 0 when what it rolled is live, anything
  else when it is not, with the reason as its last line. Two kinds of
  stdout line are read: `roll: commit <sha>` names the commit it rolled
  (it may fetch main again, after waiting on a lock; without the line, the
  checkout's HEAD), and `roll: rolled <target>` names each target that
  changed (none means nothing was behind).

  Returns `{outcome, sha, rolled, text, cause}`: `:live` or `:not_live`,
  the commit the roll rolled, one sentence of what rolled (for Billy's
  notification), what it did, to follow the roll's name in the result of
  each PR it covered, and for a roll that is not live, `roll` (the command
  failed) or `health`.
  """

  alias Shipyard.Cmd

  def run(ship) do
    dir = ship.roll
    prepare(ship, dir)
    File.mkdir_p!(Shipyard.logs(ship))
    [cmd | args] = ship.roll_command
    {out, status} = Cmd.run(ship, dir, cmd, args, timeout: ship.roll_timeout_ms)
    sha = rolled(ship, dir, out)
    log = Path.join(Shipyard.logs(ship), "#{System.os_time(:second)}-roll-#{short(sha)}.log")
    File.write!(log, out)

    targets =
      case Regex.scan(~r/^roll: rolled (\S+)/m, out, capture: :all_but_first) do
        [] -> "nothing (no target was behind)"
        names -> names |> List.flatten() |> Enum.join(" and ")
      end

    cond do
      status != 0 ->
        last = out |> String.split("\n", trim: true) |> List.last("")

        {:not_live, sha, "The roll of #{short(sha)} failed.",
         "failed (#{last}); origin/main is not live until a roll succeeds. Log: `#{log}`", "roll"}

      healthy?(ship, 3) ->
        {:live, sha, "Rolled #{targets} at #{short(sha)}.",
         "rolled #{targets}; `/health` reports ok.", nil}

      true ->
        {:not_live, sha, "Rolled #{targets} at #{short(sha)}, but /health is not ok.",
         "rolled #{targets}, but #{ship.health_url} does not report ok.", "health"}
    end
  end

  @doc "Whether merge commit `merged` is in what the roll of `sha` rolled."
  def covers?(ship, sha, merged),
    do: match?({_, 0}, Cmd.git(ship, ship.roll, ["merge-base", "--is-ancestor", merged, sha]))

  # A clone, not a linked worktree of the gating checkout: the roll may
  # fetch main, and two fetches into shared refs at once fail with "cannot
  # lock ref" on one side. A directory that is not a whole clone is cloned
  # again.
  defp prepare(ship, dir) do
    unless File.dir?(Path.join(dir, ".git")) do
      File.rm_rf!(dir)
      origin = Cmd.git!(ship, ship.checkout, ["remote", "get-url", "origin"])
      Cmd.git!(ship, ship.home, ["clone", "-q", origin, dir])
    end

    Cmd.git!(ship, dir, ["fetch", "-q", "origin", "main"])
    Cmd.git!(ship, dir, ["checkout", "-q", "--force", "--detach", "origin/main"])
    Cmd.git!(ship, dir, ["clean", "-fdq"])
  end

  # The commit the roll names, or the checkout's HEAD.
  defp rolled(ship, dir, out) do
    with [_, named] <- Regex.run(~r/^roll: commit ([0-9a-f]{7,40})\b/m, out),
         {sha, 0} <- Cmd.git(ship, dir, ["rev-parse", "-q", "--verify", named <> "^{commit}"]) do
      String.trim(sha)
    else
      _ -> Cmd.git!(ship, dir, ["rev-parse", "HEAD"])
    end
  end

  defp healthy?(ship, tries) do
    case Cmd.run(ship, ship.home, "curl", ["-fsS", "--max-time", "20", ship.health_url]) do
      {body, 0} ->
        body =~ ~s("status":"ok")

      _ when tries > 1 ->
        Process.sleep(ship.merge_wait_ms)
        healthy?(ship, tries - 1)

      _ ->
        false
    end
  end

  defp short(sha), do: String.slice(sha, 0, 8)
end
