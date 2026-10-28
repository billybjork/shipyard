defmodule Shipyard do
  @moduledoc """
  The ship worker: it lands one project's queued pull requests on `main`
  one at a time and rolls what lands, one roll at a time beside the next
  gate (README.md).

  GitHub is its queue and its record. A PR labeled `ship` is queued, in
  the order the labels went on; a ship's end is one comment on its PR,
  marked `#{"<!-- shipyard -->"}`, and the label coming off. A gate that
  passes stamps the `gate` status. The worker keeps no database: a restart
  rereads the labels and loses nothing. What it runs locally is its home,
  `~/.cache/shipyard/<project>/`: the checkout it gates in, the checkout it
  rolls from, `state.json` (the running entry), and `logs/ships.tsv` (each
  entry run, for the numbers).

  This struct is the worker's configuration. `config/1` reads it from the
  project's `.shipyard.json` (`SHIPYARD_CONFIG` names the file) and the
  environment; the tests build their own. `ntfy_topic` comes from the app's
  config, which only `config/runtime.exs` outside the test environment
  fills (`Shipyard.Notify`), and `status`, the terminal the worker reports
  to (`Shipyard.Status`), is the app's config too: none in the tests.

  The project's file names what differs between projects:

    * `name` (the home's directory and the notification's prefix) and
      `repo` (`owner/name` on GitHub);
    * `gate`: the split gate's command, run in the entry's checkout. Exit
      0 is green, 1 red with the digest on stdout, 2 no verdict. It
      appends its row to `gate_log` (`~` expands): at, sha, tier, verdict,
      wall seconds, then each part as `name:seconds:sprite:result[:reran-from-<sprite>]`;
    * `tier` (optional): a command whose stdout names the gate's tier,
      appended to `gate` as its argument. Without it the tier is `check`
      and `gate` runs as written;
    * `history` (optional): commands that must pass on the rebased branch
      before its gate (migration and secret rules);
    * `merge`: `squash` (GitHub squash-merges the PR) or `push` (the gated
      commit itself is pushed to `main`, so the branch's commits land as
      they are);
    * `roll`: the roll's command, run in the roll checkout at
      `origin/main` (`Shipyard.Roll`), and `health_url`, which must
      answer `"status":"ok"` after it.
  """

  @derive {Inspect, except: [:ntfy_topic]}
  defstruct [
    :name,
    :home,
    :repo,
    :checkout,
    :roll,
    :health_url,
    :ntfy_topic,
    :gate,
    :gate_log,
    :tier,
    :roll_command,
    :status,
    history: [],
    merge: "squash",
    ntfy_url: "https://ntfy.sh",
    desktop: false,
    env: [],
    poll_ms: 20_000,
    idle_ms: 60_000,
    merge_tries: 6,
    merge_wait_ms: 5_000,
    gate_timeout_ms: 70 * 60_000,
    roll_timeout_ms: 45 * 60_000,
    tries: 3
  ]

  @marker "<!-- shipyard -->"

  def config(overrides \\ []) do
    project =
      case System.get_env("SHIPYARD_CONFIG") do
        nil -> %{}
        path -> project(path)
      end

    name = Keyword.get(overrides, :name, project[:name])

    home =
      System.get_env("SHIPYARD_HOME") || Path.join(System.user_home!(), ".cache/shipyard/#{name}")

    struct!(
      %Shipyard{
        home: home,
        checkout: Path.join(home, "entry"),
        roll: Path.join(home, "roll"),
        ntfy_topic: Application.get_env(:shipyard, :ntfy_topic),
        status: Application.get_env(:shipyard, :status),
        desktop: :os.type() == {:unix, :darwin}
      },
      Keyword.merge(Map.to_list(project), overrides)
    )
  end

  @doc "A project's `.shipyard.json` as `config/1`'s fields."
  def project(path) do
    json = path |> File.read!() |> JSON.decode!()

    merge = Map.get(json, "merge", "squash")

    unless merge in ["squash", "push"],
      do: raise("#{path}: merge is squash or push, not #{merge}")

    for key <- ~w(name repo gate gate_log roll health_url),
        not Map.has_key?(json, key),
        do: raise("#{path}: #{key} is missing")

    %{
      name: json["name"],
      repo: json["repo"],
      gate: json["gate"],
      gate_log: Path.expand(json["gate_log"]),
      tier: json["tier"],
      history: Map.get(json, "history", []),
      merge: merge,
      roll_command: json["roll"],
      health_url: json["health_url"]
    }
  end

  def logs(%Shipyard{home: home}), do: Path.join(home, "logs")

  @doc "The first line of every result comment the worker posts."
  def marker, do: @marker
end
