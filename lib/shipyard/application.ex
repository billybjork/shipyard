defmodule Shipyard.Application do
  @moduledoc false
  use Application

  # The worker is significant: when it stops on an empty queue (or keeps
  # crashing) the supervisor shuts down, and stop/1 halts the VM, so no
  # process outlives the worker behind its pid file (bin/shipyard).
  @impl true
  def start(_type, _args) do
    worker =
      if Application.get_env(:shipyard, :worker),
        do: [Supervisor.child_spec({Shipyard.Worker, name: Shipyard.Worker}, significant: true)],
        else: []

    Supervisor.start_link([{Task.Supervisor, name: Shipyard.Tasks} | worker],
      strategy: :one_for_one,
      auto_shutdown: :any_significant
    )
  end

  @impl true
  def stop(_state) do
    if Application.get_env(:shipyard, :worker), do: System.stop(0)
    :ok
  end
end
