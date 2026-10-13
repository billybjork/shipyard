defmodule Mix.Tasks.Shipyard.List do
  @shortdoc "The ship queue, the running entry, what waits for a roll, and the last 20 results (`bin/shipyard list <project>`)"
  @moduledoc """
  `mix shipyard.list`: the queue from GitHub in order, which entry this host's
  worker is running and at which step, the merged PRs waiting for a roll,
  then its last 20 results (`Shipyard.Record`).

  `mix shipyard.list --summary [since]`: the trial's numbers over this host's
  rows from `since` (an ISO date, such as 2026-10-09; all rows without
  it): gate time p50 and p90 per tier, queue wait, and the causes of reds
  and retries (`Shipyard.Record.summary/2`).
  """
  use Mix.Task

  @impl true
  def run(["--summary" | since]) do
    Mix.Task.run("app.config")

    Shipyard.config()
    |> Shipyard.Record.results()
    |> Shipyard.Record.summary(List.first(since))
    |> Enum.each(&Mix.shell().info(&1))
  end

  def run([]) do
    Mix.Task.run("app.config")
    ship = Shipyard.config()
    state = Shipyard.Record.state(ship)

    {landed, queue} = ship |> Shipyard.GitHub.queue() |> Enum.split_with(& &1.merged)

    case queue do
      [] ->
        Mix.shell().info("queue: empty")

      queue ->
        Mix.shell().info("queue:")

        for pr <- queue do
          running =
            if state && state["pr"] == pr.number, do: "  <- #{state["step"]} since #{state["at"]}"

          Mix.shell().info("  ##{pr.number} #{pr.title} (#{pr.branch})#{running}")
        end
    end

    for pr <- landed,
        do:
          Mix.shell().info(
            "landed: ##{pr.number} #{pr.title} as #{String.slice(pr.merged, 0, 8)}, waiting for its roll"
          )

    Mix.shell().info(
      if state,
        do: "worker: running here (pid #{state["pid"]})",
        else: "worker: not running here (the next ship starts it)"
    )

    case Shipyard.Record.results(ship, 20) do
      [] ->
        :ok

      rows ->
        Mix.shell().info("last #{length(rows)}:")
        for row <- rows, do: Mix.shell().info("  " <> line(row))
    end
  end

  def run(_), do: Mix.raise("usage: mix shipyard.list [--summary [since]]")

  # "<at>  #12 red in 300 s (gate check 280 s, test-2; waited 9 s; test)  <title>"
  defp line(row) do
    get = &Map.get(row, &1, "")

    facts =
      [
        get.(:gate) != "" && "gate #{get.(:tier)} #{get.(:gate)} s, #{get.(:slowest)}",
        get.(:wait) != "" && "waited #{get.(:wait)} s",
        get.(:cause) != "" && get.(:cause)
      ]
      |> Enum.filter(& &1)

    facts = if facts == [], do: "", else: " (#{Enum.join(facts, "; ")})"
    "#{row.at}  ##{row.pr} #{row.outcome} in #{row.secs} s#{facts}  #{get.(:title)}"
  end
end
