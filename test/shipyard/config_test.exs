defmodule Shipyard.ConfigTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  @project %{
    "name" => "proj",
    "repo" => "owner/proj",
    "gate" => ["bash", "tooling/check-remote.sh"],
    "gate_log" => "~/.cache/proj/check-remote.tsv",
    "roll" => ["bash", "tooling/roll.sh"],
    "health_url" => "https://proj.test/health"
  }

  defp write!(tmp, json) do
    path = Path.join(tmp, ".shipyard.json")
    File.write!(path, JSON.encode!(json))
    path
  end

  test "a project's file gives the worker its repo, commands and home", %{tmp_dir: tmp} do
    fields = Shipyard.project(write!(tmp, Map.put(@project, "merge", "push")))

    ship = Shipyard.config(Map.to_list(fields))

    assert %Shipyard{
             name: "proj",
             repo: "owner/proj",
             gate: ["bash", "tooling/check-remote.sh"],
             roll_command: ["bash", "tooling/roll.sh"],
             tier: nil,
             history: [],
             merge: "push"
           } = ship

    assert ship.gate_log == Path.join(System.user_home!(), ".cache/proj/check-remote.tsv")
    assert ship.home == Path.join(System.user_home!(), ".cache/shipyard/proj")
    assert ship.checkout == Path.join(ship.home, "entry")
  end

  test "a file missing a field, or naming an unknown merge, is refused", %{tmp_dir: tmp} do
    assert_raise RuntimeError, ~r/roll is missing/, fn ->
      Shipyard.project(write!(tmp, Map.delete(@project, "roll")))
    end

    assert_raise RuntimeError, ~r/merge is squash or push, not rebase/, fn ->
      Shipyard.project(write!(tmp, Map.put(@project, "merge", "rebase")))
    end
  end
end
