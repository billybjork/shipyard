defmodule Shipyard.Record do
  @moduledoc """
  What the worker keeps on its own host, for `bin/shipyard list`: `state.json`
  (its pid and the entry it is running) and `logs/ships.tsv`, one row per
  entry run, written as the run ends, with the fields in `@fields`:

    * `at`, `pr`, `outcome` (live, red, sent back, landed not live, or
      retry), and `secs` from the worker taking the PR to its end;
    * `wait`: seconds from the `ship` label to the worker taking the PR,
      on the first run of each labeling only (a retry's wait is the run
      before it);
    * `gate`, `tier` and `slowest`: the split gate's wall seconds, its
      tier, and its slowest part, when a gate ran;
    * `cause`: why a run did not land live (`Shipyard.Entry`, `Shipyard.Roll`:
      `test`, `timing`, `static`, `sprite`, `main-moved`, ...), or
      `sprite-rerun` for a green gate one of whose parts reran on the
      spare;
    * `title`, last.

  The PR stays the record of each ship; these say what this host is doing
  and has done, and `summary/2` reads the rows for the trial's numbers:
  gate time (p50, p90), queue wait, and the reds and retries by cause.
  """

  @fields ~w(at pr outcome secs wait gate tier slowest cause title)a

  def running(ship, pr, step) do
    write(ship, %{pid: System.pid(), pr: pr.number, title: pr.title, step: step, at: now()})
  end

  def idle(ship), do: write(ship, %{pid: System.pid(), at: now()})

  @doc "The worker's state, or nil when none is running."
  def state(ship) do
    with {:ok, json} <- File.read(state_path(ship)),
         %{"pid" => pid} = state <- JSON.decode!(json),
         {_, 0} <- System.cmd("kill", ["-0", pid], stderr_to_stdout: true) do
      state
    else
      _ -> nil
    end
  end

  @doc """
  Appends one entry run's row. `run` holds `secs` and, when known, `wait`,
  `cause` and the gate's `%{tier, secs, slowest}`.
  """
  def result(ship, pr, outcome, run) do
    File.mkdir_p!(Shipyard.logs(ship))
    gate = run[:gate] || %{}

    row =
      [
        now(),
        pr.number,
        outcome,
        run.secs,
        run[:wait],
        gate[:secs],
        gate[:tier],
        gate[:slowest],
        run[:cause],
        String.replace(pr.title, ~r/[\t\n]/, " ")
      ]
      |> Enum.map_join("\t", &to_string/1)

    File.write!(results_path(ship), row <> "\n", [:append])
  end

  @doc "The last `n` rows (all with `:all`), oldest first, each a map of `@fields` (strings; empty when unknown)."
  def results(ship, n \\ :all) do
    case File.read(results_path(ship)) do
      {:ok, tsv} ->
        rows = String.split(tsv, "\n", trim: true)
        rows = if n == :all, do: rows, else: Enum.take(rows, -n)
        Enum.map(rows, &(@fields |> Enum.zip(String.split(&1, "\t")) |> Map.new()))

      {:error, _} ->
        []
    end
  end

  @doc """
  The trial's numbers over `rows` (`results/2`) from `since` (an ISO date
  or time, or nil for all), as lines: the runs by outcome, gate time p50
  and p90 per tier with the slowest parts, queue wait p50, p90 and max,
  and the causes.
  """
  def summary(rows, since \\ nil) do
    rows = if since, do: Enum.filter(rows, &(&1.at >= since)), else: rows
    by = fn key -> rows |> Enum.map(&Map.get(&1, key, "")) |> Enum.reject(&(&1 == "")) end
    seconds = fn values -> Enum.map(values, &String.to_integer/1) end

    outcomes =
      rows
      |> Enum.frequencies_by(& &1.outcome)
      |> Enum.map_join(", ", fn {o, n} -> "#{n} #{o}" end)

    gates =
      rows
      |> Enum.filter(&(Map.get(&1, :gate, "") != ""))
      |> Enum.group_by(& &1.tier)
      |> Enum.sort()
      |> Enum.map(fn {tier, gated} ->
        secs = seconds.(Enum.map(gated, & &1.gate))

        slowest =
          gated
          |> Enum.frequencies_by(& &1.slowest)
          |> Enum.sort_by(fn {_, n} -> -n end)
          |> Enum.map_join(", ", fn {part, n} -> "#{part} #{n}" end)

        "gate #{tier}: #{length(secs)} run(s), p50 #{pct(secs, 50)} s, p90 #{pct(secs, 90)} s; slowest part: #{slowest}"
      end)

    waits = seconds.(by.(:wait))

    wait =
      if waits == [],
        do: "queue wait: none recorded",
        else:
          "queue wait: #{length(waits)} take(s), p50 #{pct(waits, 50)} s, p90 #{pct(waits, 90)} s, max #{Enum.max(waits)} s"

    causes =
      case by.(:cause) |> Enum.frequencies() |> Enum.sort_by(fn {_, n} -> -n end) do
        [] -> "causes: none"
        counts -> "causes: " <> Enum.map_join(counts, ", ", fn {c, n} -> "#{c} #{n}" end)
      end

    [
      "#{length(rows)} entry run(s)#{if since, do: " since #{since}"}: #{if outcomes == "", do: "none", else: outcomes}"
      | gates
    ] ++ [wait, causes]
  end

  # Nearest rank: the smallest value at or above `p` percent of them.
  defp pct(values, p) do
    sorted = Enum.sort(values)
    Enum.at(sorted, max(ceil(length(sorted) * p / 100) - 1, 0))
  end

  defp write(ship, state) do
    File.mkdir_p!(ship.home)
    path = state_path(ship)
    File.write!(path <> ".tmp", JSON.encode!(state))
    File.rename!(path <> ".tmp", path)
  end

  defp state_path(ship), do: Path.join(ship.home, "state.json")
  defp results_path(ship), do: Path.join(Shipyard.logs(ship), "ships.tsv")
  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
end
