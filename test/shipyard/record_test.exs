defmodule Shipyard.RecordTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  test "the summary gives gate time p50 and p90 per tier, the queue wait, and the causes, from a date",
       %{tmp_dir: tmp} do
    ship = Shipyard.config(home: tmp)
    pr = fn n -> %{number: n, title: "change\t#{n}"} end
    gate = fn secs, slowest -> %{tier: "check", secs: secs, slowest: slowest} end

    for {n, outcome, run} <- [
          {1, :live, %{secs: 400, wait: 5, gate: gate.(300, "test-3")}},
          {2, :red, %{secs: 250, wait: 30, gate: gate.(240, "test-2"), cause: "timing"}},
          {3, :retry, %{secs: 260, wait: 10, gate: gate.(250, "test-2"), cause: "main-moved"}},
          {3, :live, %{secs: 270, gate: gate.(260, "test-2"), cause: "sprite-rerun"}},
          {4, :back, %{secs: 3, wait: 2, cause: "conflict"}},
          {5, :live,
           %{secs: 200, wait: 1, gate: %{tier: "check-fast", secs: 190, slowest: "test-3"}}}
        ],
        do: Shipyard.Record.result(ship, pr.(n), outcome, run)

    rows = Shipyard.Record.results(ship)
    assert length(rows) == 6
    assert List.last(rows).title == "change 5"

    assert Shipyard.Record.summary(rows) == [
             "6 entry run(s): 1 back, 3 live, 1 red, 1 retry",
             "gate check: 4 run(s), p50 250 s, p90 300 s; slowest part: test-2 3, test-3 1",
             "gate check-fast: 1 run(s), p50 190 s, p90 190 s; slowest part: test-3 1",
             "queue wait: 5 take(s), p50 5 s, p90 30 s, max 30 s",
             "causes: conflict 1, main-moved 1, sprite-rerun 1, timing 1"
           ]

    future = Date.utc_today() |> Date.add(1) |> Date.to_iso8601()

    assert Shipyard.Record.summary(rows, future) == [
             "0 entry run(s) since #{future}: none",
             "queue wait: none recorded",
             "causes: none"
           ]
  end
end
