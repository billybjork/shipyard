defmodule Shipyard.Worker do
  @moduledoc """
  Drains the queue one PR at a time, in label order, and rolls what lands
  one roll at a time beside it. It stops once the queue has been empty,
  with no roll running or waiting, for `idle_ms`; its application ends
  with it (`Shipyard.Application`), so the next ship starts a worker on
  fresh code (`bin/shipyard start`).

  Each entry runs as a supervised task (`Shipyard.Entry`) up to its merge.
  One that ends there posts its result and takes the label off
  (`Shipyard.GitHub.finish/3`); one that returns `:retry` (no verdict, main or
  the branch moved) or crashes stays queued and runs again, and after
  `tries` of those in one run it is sent back with the last reason.

  A merged PR keeps its label until a roll covers it, so the next entry's
  gate starts right after a merge. A roll (`Shipyard.Roll`, another task)
  starts whenever one waits and none runs; when it ends, every waiting PR
  whose merge is in the commit it rolled gets its result, naming that
  roll, and the rest wait for the next. A failed roll is not retried: its
  PRs are landed, not live. A merged PR still labeled when the worker
  starts (a worker stopped mid-roll) waits for a roll like any other.

  Every entry run, a retry included, leaves a row (`Shipyard.Record`): how
  long its PR waited for the worker, what the gate took, and why it did
  not land live. What it is doing, and how each ship ended, it also
  reports to its terminal (`Shipyard.Status`).
  """

  use GenServer, restart: :transient
  require Logger
  alias Shipyard.{GitHub, Notify, Record, Roll, Status}

  @outcomes %{live: "live", not_live: "landed, not live", red: "red", back: "sent back"}

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))

  @impl true
  def init(opts) do
    ship = Keyword.get_lazy(opts, :ship, &Shipyard.config/0)
    Record.idle(ship)

    unless ship.ntfy_topic,
      do:
        Logger.warning(
          "ship: NTFY_TOPIC is not set in the project's .env; ships end with no push"
        )

    send(self(), :poll)

    {:ok,
     %{
       ship: ship,
       # {task ref, pr, run} for the entry being gated; a run is what its
       # row records: %{t0, wait, gate, cause}
       running: nil,
       # {task ref, the waiting PR numbers when it started} for the roll
       rolling: nil,
       # PR number => %{pr, merged, text, run}: merged, waiting for a roll
       landed: %{},
       # PR number => the runs since its label went on that ended in a retry
       tries: %{},
       idle_since: now(),
       timer: nil,
       # what the worker's status record last said, so it reports changes only
       said: nil
     }}
  end

  @impl true
  def handle_info(:poll, s) do
    s = s |> take() |> roll() |> say()

    if idle?(s) and now() - s.idle_since >= s.ship.idle_ms do
      Logger.info("ship: the queue is empty and nothing waits for a roll; stopping")
      Status.root(s.ship, :idle, "stopped: the queue is empty")
      {:stop, :normal, s}
    else
      if s.timer, do: Process.cancel_timer(s.timer)
      {:noreply, %{s | timer: Process.send_after(self(), :poll, s.ship.poll_ms)}}
    end
  end

  def handle_info({ref, {result, gate}}, %{running: {ref, pr, run}} = s) do
    Process.demonitor(ref, [:flush])
    {:noreply, s |> entry_ended(pr, result, %{run | gate: gate}) |> poll_now()}
  end

  def handle_info({ref, result}, %{rolling: {ref, _waiting}} = s) do
    Process.demonitor(ref, [:flush])
    {:noreply, s |> rolled(result) |> poll_now()}
  end

  def handle_info({:DOWN, ref, :process, _, reason}, %{running: {ref, pr, run}} = s) do
    result = {:retry, "the entry crashed: #{Exception.format_exit(reason)}", "crash"}
    {:noreply, s |> entry_ended(pr, result, run) |> poll_now()}
  end

  def handle_info({:DOWN, ref, :process, _, reason}, %{rolling: {ref, waiting}} = s) do
    text =
      "The roll crashed (#{Exception.format_exit(reason)}); origin/main is not live until a roll succeeds."

    s =
      Enum.reduce(waiting, s, fn number, s ->
        {landed, s} = pop_in(s.landed[number])

        if landed,
          do:
            ending(
              s,
              landed.pr,
              :not_live,
              "#{landed.text}. #{text}",
              %{landed.run | cause: "roll-crash"},
              "The roll crashed."
            )

        s
      end)

    {:noreply, %{s | rolling: nil, idle_since: now()} |> poll_now()}
  end

  def handle_info(_stale, s), do: {:noreply, s}

  defp poll_now(s) do
    send(self(), :poll)
    s
  end

  defp idle?(s), do: s.running == nil and s.rolling == nil and s.landed == %{}

  # Reads the labels while no entry runs: a merged PR not yet known waits
  # for a roll, and the first open one not merged here starts. A PR this
  # worker merged can still read as open just after; it is never gated
  # twice.
  defp take(%{running: {_, _, _}} = s), do: s

  defp take(s) do
    case queue(s.ship) do
      :unreachable ->
        s

      prs ->
        {merged, open} = Enum.split_with(prs, & &1.merged)

        landed =
          Enum.reduce(merged, s.landed, fn pr, landed ->
            Map.put_new(landed, pr.number, %{
              pr: pr,
              merged: pr.merged,
              text: "Merged as `#{short(pr.merged)}`",
              run: run(nil)
            })
          end)

        s = %{s | landed: landed}

        case Enum.reject(open, &Map.has_key?(landed, &1.number)) do
          [pr | _] -> start(s, pr)
          [] -> s
        end
    end
  end

  defp roll(%{rolling: nil, landed: landed} = s) when landed != %{} do
    Logger.info("ship: rolling for #{numbers(Map.keys(landed))}")
    ship = s.ship
    task = Task.Supervisor.async_nolink(Shipyard.Tasks, fn -> Roll.run(ship) end)
    %{s | rolling: {task.ref, Map.keys(landed)}}
  end

  defp roll(s), do: s

  defp queue(ship) do
    GitHub.queue(ship)
  rescue
    e ->
      Logger.warning("ship: reading the queue failed: #{Exception.message(e)}")
      :unreachable
  end

  defp start(s, pr) do
    Logger.info("ship: ##{pr.number} #{pr.title} (#{pr.branch})")
    ship = s.ship

    step = fn step ->
      Record.running(ship, pr, step)
      Status.pr(ship, pr, :working, step)
    end

    step.("start")

    task =
      Task.Supervisor.async_nolink(Shipyard.Tasks, fn -> Shipyard.Entry.run(ship, pr, step) end)

    # The wait is the label's: a retry's run waited on the run before it.
    wait = if Map.has_key?(s.tries, pr.number), do: nil, else: waited(pr.queued_at)
    %{s | running: {task.ref, pr, run(wait)}}
  end

  defp entry_ended(s, pr, result, run) do
    tries = Map.update(s.tries, pr.number, 1, &(&1 + 1))
    n = tries[pr.number]

    {landed, tries} =
      case result do
        {:merged, merged, text} ->
          Logger.info("ship: ##{pr.number} merged as #{short(merged)}; it waits for a roll")
          cause = if run.gate[:reran], do: "sprite-rerun"
          landed = %{pr: pr, merged: merged, text: text, run: %{run | cause: cause}}
          Status.pr(s.ship, pr, :working, "merged as #{short(merged)}; waiting for a roll")
          {Map.put(s.landed, pr.number, landed), Map.delete(tries, pr.number)}

        {:retry, why, cause} when n >= s.ship.tries ->
          ending(s, pr, :back, "No result after #{n} tries; the last: #{why}.", %{
            run
            | cause: cause
          })

          {s.landed, Map.delete(tries, pr.number)}

        {:retry, why, cause} ->
          Logger.warning("ship: ##{pr.number} stays queued: #{why}")
          Status.pr(s.ship, pr, :working, "queued again (try #{n} of #{s.ship.tries}): #{why}")
          Record.result(s.ship, pr, :retry, row(%{run | cause: cause}))
          {s.landed, tries}

        {outcome, text, cause} ->
          ending(s, pr, outcome, text, %{run | cause: cause})
          {s.landed, Map.delete(tries, pr.number)}
      end

    Record.idle(s.ship)
    %{s | running: nil, tries: tries, landed: landed, idle_since: now()}
  end

  # Each waiting PR whose merge is in what the roll rolled gets its result;
  # one merged after the roll fetched main waits for the next.
  defp rolled(s, {outcome, sha, rolled, text, cause}) do
    {covered, waiting} =
      Enum.split_with(s.landed, fn {_, landed} -> Roll.covers?(s.ship, sha, landed.merged) end)

    covered = Enum.sort_by(covered, fn {_, landed} -> landed.run.t0 end)
    name = "The roll of `#{short(sha)}`, covering #{numbers(Enum.map(covered, &elem(&1, 0)))},"

    for {_, landed} <- covered do
      run = %{landed.run | cause: cause || landed.run.cause}
      ending(s, landed.pr, outcome, "#{landed.text}. #{name} #{text}", run, rolled)
    end

    %{s | rolling: nil, landed: Map.new(waiting), idle_since: now()}
  end

  # A ship's end: its row, its result on the PR, and Billy's notification.
  # A retry is not an end and reaches none but its row.
  defp ending(s, pr, outcome, text, run, rolled \\ nil) do
    row = row(run)
    Logger.info("ship: ##{pr.number} #{@outcomes[outcome]} in #{row.secs} s")
    Record.result(s.ship, pr, outcome, row)

    try do
      GitHub.finish(s.ship, pr.number, "ship: #{@outcomes[outcome]}. " <> text)
    rescue
      e -> Logger.error("ship: posting ##{pr.number}'s result failed: #{Exception.message(e)}")
    end

    Notify.ended(s.ship, pr, outcome, @outcomes[outcome], rolled)
    words = if rolled, do: "#{@outcomes[outcome]}. #{rolled}", else: "#{@outcomes[outcome]}."
    Status.pr(s.ship, pr, if(outcome == :live, do: :done, else: :error), words)
  end

  # The worker's status record, when what it would say has changed: the
  # entry it gates and the PRs a roll is rolling or waits to roll.
  defp say(s) do
    doing =
      Enum.reject(
        [
          with({_, pr, _} <- s.running, do: "gating ##{pr.number}"),
          with({_, waiting} <- s.rolling, do: "rolling #{numbers(waiting)}"),
          case Map.keys(s.landed) -- ((s.rolling && elem(s.rolling, 1)) || []) do
            [] -> nil
            waiting -> "#{numbers(waiting)} waiting for a roll"
          end
        ],
        &is_nil/1
      )

    said =
      if doing == [], do: {:idle, "the queue is empty"}, else: {:working, Enum.join(doing, "; ")}

    if said != s.said, do: Status.root(s.ship, elem(said, 0), elem(said, 1))
    %{s | said: said}
  end

  defp run(wait), do: %{t0: now(), wait: wait, gate: %{}, cause: nil}
  defp row(run), do: run |> Map.delete(:t0) |> Map.put(:secs, secs(run.t0))

  # Seconds since the label went on, or nil when GitHub gave no time.
  defp waited(queued_at) do
    case DateTime.from_iso8601(queued_at) do
      {:ok, at, _} -> max(DateTime.diff(DateTime.utc_now(), at), 0)
      _ -> nil
    end
  end

  defp numbers(numbers), do: Enum.map_join(numbers, ", ", &"##{&1}")
  defp secs(t0), do: div(now() - t0, 1000)
  defp short(sha), do: String.slice(sha, 0, 8)
  defp now, do: System.monotonic_time(:millisecond)
end
