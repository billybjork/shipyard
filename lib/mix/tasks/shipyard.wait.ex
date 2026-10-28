defmodule Mix.Tasks.Shipyard.Wait do
  @shortdoc "Blocks until a queued ship ends (`bin/shipyard wait <project> <pr>`)"
  @moduledoc """
  `mix shipyard.wait <pr>`: waits, silently, while the PR carries the `ship`
  label, then prints its newest result comment and exits 0 when the ship
  is live, 1 otherwise (red, sent back, or landed but not live). A red
  result's text is the gate's digest, which is all a session needs to fix
  it. `SHIPYARD_WAIT_MS` sets the poll interval (15 s). It reports to its
  terminal as it goes (`Shipyard.Status`): `working` while it waits, then
  `done` for a live ship and `error` for any other end.
  """
  use Mix.Task

  @impl true
  def run([number]) do
    Mix.Task.run("app.config")
    ship = Shipyard.config()
    interval = String.to_integer(System.get_env("SHIPYARD_WAIT_MS", "15000"))
    wait(ship, String.to_integer(number), interval)
  end

  def run(_), do: Mix.raise("usage: mix shipyard.wait <pr number>")

  defp wait(ship, number, interval) do
    case Shipyard.GitHub.pr(ship, number) do
      %{queued: true} ->
        Shipyard.Status.root(ship, :working, "##{number}: waiting for its ship to end")
        Process.sleep(interval)
        wait(ship, number, interval)

      %{results: []} ->
        Mix.shell().error("##{number} is not queued and has no ship result (a ship queues it)")
        Shipyard.Status.root(ship, :error, "##{number} is not queued and has no ship result")

        exit({:shutdown, 1})

      %{results: results} ->
        text = results |> List.last() |> String.replace_prefix(Shipyard.marker() <> "\n", "")
        Mix.shell().info("##{number} " <> text)
        live = String.starts_with?(text, "ship: live.")
        line = text |> String.split("\n", parts: 2) |> hd()
        Shipyard.Status.root(ship, if(live, do: :done, else: :error), "##{number} #{line}")
        unless live, do: exit({:shutdown, 1})
    end
  end
end
