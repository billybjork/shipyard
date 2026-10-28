defmodule Shipyard.Status do
  @moduledoc """
  What the worker is doing, told to the terminal it runs in as Program
  Status reports (OSC 7501), so a Rex tab (`bin/shipyard start`) shows a
  spinner while it works and a mark for each ship's end without anyone
  reading its log. The protocol:
  https://www.superlogical.com/rex/docs/build/program-status.md

  The worker's own state is the root record: `working` while an entry or
  a roll runs, saying which, and `idle` between them. Each PR is a record
  of its own, `pr-<number>`, titled with its number and title: `working`
  with its step while the worker has it, then `done` when it is live and
  `error` for any other end. A `done` or `error` record outlives the
  worker, so the tab keeps each ship's end until it is looked at. The
  gate runs with `SHIPYARD_STATUS_ID` set to its PR's record id, so a
  project's gate can report its parts beneath it (`pr-12/static-1`) to
  `SHIPYARD_STATUS_TTY`.

  Reports go to `ship.status`, never to stdout or the log: the terminal
  device the worker's Rex tab names in `SHIPYARD_STATUS_TTY`, else the
  controlling terminal (`/dev/tty`). The gate gets the same device in
  `SHIPYARD_STATUS_TTY`, since a command the worker runs has no
  controlling terminal of its own. A worker with no terminal
  (the detached start) can't open it and reports nothing; the tests set
  no path. `bin/shipyard wait` reports the same way, in the root record of
  the terminal it waits in (`bin/shipyard watch` opens one).
  """

  @app "shipyard"

  @doc "The root record, the worker's own (or a wait's): `state` and what it is doing."
  def root(ship, state, msg), do: report(ship, state: state, msg: msg)

  @doc "PR `pr`'s record: `:working` with its step, or `:done` or `:error` with its end."
  def pr(ship, pr, state, msg) do
    report(ship, state: state, id: id(pr), title: "##{pr.number} #{pr.title}", msg: msg)
  end

  @doc "The record id of PR `pr`, which its gate reports its parts beneath."
  def id(pr), do: "pr-#{pr.number}"

  @doc "The OSC 7501 report of `fields` (`state`, and optionally `id`, `title`, `msg`)."
  def sequence(fields) do
    pairs =
      [
        state: fields[:state],
        id: fields[:id],
        app: @app,
        title: text(fields[:title], 192),
        msg: text(fields[:msg], 2048)
      ]
      |> Enum.reject(fn {_, v} -> v == nil end)
      |> Enum.map_join(":", fn {k, v} -> "#{k}=#{v}" end)

    "\e]7501;" <> pairs <> "\e\\"
  end

  defp report(%{status: nil}, _fields), do: :ok

  defp report(%{status: path}, fields) do
    # A path that can't be opened (no controlling terminal) is no terminal.
    _ = File.write(path, sequence(fields), [:append])
    :ok
  end

  # One line of at most `max` bytes, base64: the protocol refuses control
  # characters and longer values.
  defp text(nil, _max), do: nil

  defp text(text, max) do
    text
    |> String.replace(~r/[\x00-\x1F\x7F-\x9F]+/u, " ")
    |> String.trim()
    |> truncate(max)
    |> Base.encode64()
  end

  defp truncate(text, max) when byte_size(text) <= max, do: text

  defp truncate(text, max) do
    text
    |> String.graphemes()
    |> Enum.reduce_while("", fn g, acc ->
      if byte_size(acc) + byte_size(g) + 3 <= max, do: {:cont, acc <> g}, else: {:halt, acc}
    end)
    |> Kernel.<>("…")
  end
end
