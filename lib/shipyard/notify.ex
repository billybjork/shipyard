defmodule Shipyard.Notify do
  @moduledoc """
  Tells Billy a ship has ended: one push through ntfy.sh to his private
  topic, and a macOS notification on the laptop. Each carries the PR's
  number and title, the outcome, what rolled, and the branch, never code,
  logs or the digest; those stay on the PR and in `bin/shipyard list`.

  The topic (`NTFY_TOPIC`, from the project's deploy secrets on the laptop) is the push's only access
  control, so it never reaches a log or an inspected struct. A notification
  never holds a ship: without a topic there is no push, and a push or
  notification that fails is one warning in the worker's log.
  """

  require Logger
  alias Shipyard.Cmd

  @tags %{
    live: "white_check_mark",
    not_live: "warning",
    red: "x",
    back: "leftwards_arrow_with_hook"
  }

  @doc "`outcome` in words; `rolled` is what the roll did, or nil when nothing was merged."
  def ended(ship, pr, outcome, words, rolled) do
    title = "#{ship.name} ##{pr.number} #{pr.title}"

    message = if(rolled, do: "#{words}. #{rolled}", else: "#{words}.") <> "\n" <> pr.branch

    push(ship, pr, outcome, title, message)
    desktop(ship, pr, title, message)
  rescue
    e -> Logger.warning("ship: notifying ##{pr.number}'s end failed: #{Exception.message(e)}")
  end

  defp push(%Shipyard{ntfy_topic: nil}, _pr, _outcome, _title, _message), do: :ok

  defp push(ship, pr, outcome, title, message) do
    json =
      JSON.encode!(%{
        topic: ship.ntfy_topic,
        title: title,
        message: message,
        tags: [@tags[outcome]]
      })

    args = ["-fsS", "-o", "/dev/null", "--max-time", "15", "-H", "Content-Type: application/json"]

    case Cmd.run(ship, ship.home, "curl", args ++ ["--data-binary", json, ship.ntfy_url]) do
      {_, 0} ->
        :ok

      {_, status} ->
        Logger.warning("ship: the push for ##{pr.number} failed (curl exit #{status})")
    end
  end

  defp desktop(%Shipyard{desktop: false}, _pr, _title, _message), do: :ok

  defp desktop(ship, pr, title, message) do
    script = [
      "on run argv",
      "display notification (item 2 of argv) with title (item 1 of argv)",
      "end run"
    ]

    args = Enum.flat_map(script, &["-e", &1]) ++ [title, message]

    case Cmd.run(ship, ship.home, "osascript", args) do
      {_, 0} -> :ok
      {out, _} -> Logger.warning("ship: the notification for ##{pr.number} failed: #{out}")
    end
  end
end
