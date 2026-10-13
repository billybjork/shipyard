defmodule Shipyard.GitHub do
  @moduledoc """
  The queue and the record, through the `gh` CLI and its own login.

  The queue is the open PRs labeled `ship`, oldest label first. A merged
  PR that still carries the label has landed and waits for the roll that
  covers it. A ship's end is one comment on its PR led by
  `Shipyard.marker/0`, then the label coming off; a passed gate is the `gate`
  commit status, which this module and a project's laptop ship post.
  """

  alias Shipyard.Cmd

  @label "ship"

  @queue """
  query($owner: String!, $name: String!) {
    repository(owner: $owner, name: $name) {
      pullRequests(states: [OPEN, MERGED], labels: ["ship"], first: 50) {
        nodes {
          number title url headRefName mergeCommit { oid }
          timelineItems(itemTypes: [LABELED_EVENT], last: 20) {
            nodes { ... on LabeledEvent { createdAt label { name } } }
          }
        }
      }
    }
  }
  """

  @doc """
  The labeled PRs, each `%{number, title, url, branch, queued_at, merged}`,
  in order; `merged` is the merge commit of one that has landed, else nil.
  """
  def queue(ship) do
    [owner, name] = String.split(ship.repo, "/")

    ship
    |> gh!([
      "api",
      "graphql",
      "-f",
      "query=#{@queue}",
      "-F",
      "owner=#{owner}",
      "-F",
      "name=#{name}"
    ])
    |> JSON.decode!()
    |> get_in(["data", "repository", "pullRequests", "nodes"])
    |> Enum.map(fn pr ->
      queued_at =
        pr["timelineItems"]["nodes"]
        |> Enum.filter(&(&1["label"]["name"] == @label))
        |> Enum.map(& &1["createdAt"])
        |> Enum.max(fn -> "" end)

      %{
        number: pr["number"],
        title: pr["title"],
        url: pr["url"],
        branch: pr["headRefName"],
        queued_at: queued_at,
        merged: get_in(pr, ["mergeCommit", "oid"])
      }
    end)
    |> Enum.sort_by(&{&1.queued_at, &1.number})
  end

  @doc "Whether PR `number` is still queued, and the result comments on it, oldest first."
  def pr(ship, number) do
    pr =
      ship
      |> gh!([
        "pr",
        "view",
        to_string(number),
        "--repo",
        ship.repo,
        "--json",
        "labels,comments,title,url"
      ])
      |> JSON.decode!()

    %{
      queued: Enum.any?(pr["labels"], &(&1["name"] == @label)),
      title: pr["title"],
      url: pr["url"],
      results:
        for(
          %{"body" => body} <- pr["comments"],
          String.starts_with?(body, Shipyard.marker()),
          do: body
        )
    }
  end

  @doc "Ends a ship: the result comment, then the label off, so the label never comes off without a result to read."
  def finish(ship, number, text) do
    gh!(ship, [
      "pr",
      "comment",
      to_string(number),
      "--repo",
      ship.repo,
      "--body",
      Shipyard.marker() <> "\n" <> text
    ])

    gh!(ship, ["pr", "edit", to_string(number), "--repo", ship.repo, "--remove-label", @label])
    :ok
  end

  @doc "The `gate` status on `sha`: the record that the gate passed on that exact commit."
  def stamp(ship, sha, description) do
    gh!(ship, [
      "api",
      "-X",
      "POST",
      "repos/#{ship.repo}/statuses/#{sha}",
      "-f",
      "state=success",
      "-f",
      "context=gate",
      "-f",
      "description=#{String.slice(description, 0, 140)}"
    ])

    :ok
  end

  @doc """
  Squash-merges PR `number` if its head is still `sha`, retrying over
  GitHub's lag behind a fresh push; then the merge commit's id.
  """
  def merge(ship, number, sha), do: merge(ship, number, sha, ship.merge_tries)

  defp merge(ship, number, sha, tries) do
    args = [
      "pr",
      "merge",
      to_string(number),
      "--repo",
      ship.repo,
      "--squash",
      "--match-head-commit",
      sha
    ]

    case gh(ship, args, stderr_to_stdout: true) do
      {_, 0} ->
        view = ["pr", "view", to_string(number), "--repo", ship.repo, "--json", "mergeCommit"]
        {:ok, ship |> gh!(view ++ ["--jq", ".mergeCommit.oid"]) |> String.trim()}

      {_, _} when tries > 1 ->
        Process.sleep(ship.merge_wait_ms)
        merge(ship, number, sha, tries - 1)

      {out, _} ->
        {:error, String.trim(out)}
    end
  end

  defp gh(ship, args, opts \\ [stderr_to_stdout: false]),
    do: Cmd.run(ship, File.cwd!(), "gh", args, opts)

  defp gh!(ship, args) do
    case gh(ship, args) do
      {out, 0} -> out
      {out, status} -> raise "gh #{hd(args)} exited #{status}: #{out}"
    end
  end
end
