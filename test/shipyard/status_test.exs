defmodule Shipyard.StatusTest do
  use ExUnit.Case, async: true
  alias Shipyard.Status

  @moduletag :tmp_dir

  # The reports in `path`, each a map of its pairs with `title` and `msg`
  # decoded.
  def reports(path) do
    path
    |> File.read!()
    |> String.split("\e\\", trim: true)
    |> Enum.map(fn "\e]7501;" <> pairs ->
      for pair <- String.split(pairs, ":"), into: %{} do
        [k, v] = String.split(pair, "=", parts: 2)
        if k in ~w(title msg), do: {k, Base.decode64!(v)}, else: {k, v}
      end
    end)
  end

  test "a report is one OSC 7501 sequence: the state, its id, the app, and a title and message as one base64 line each" do
    assert Status.sequence(state: :working, id: "pr-12", title: "#12 fix", msg: "gate\non  x") ==
             "\e]7501;state=working:id=pr-12:app=shipyard:title=" <>
               Base.encode64("#12 fix") <> ":msg=" <> Base.encode64("gate on  x") <> "\e\\"

    assert Status.sequence(state: :idle) == "\e]7501;state=idle:app=shipyard\e\\"
  end

  test "a title past the protocol's 192 bytes is cut short on a character" do
    "\e]7501;state=done:app=shipyard:title=" <> rest =
      Status.sequence(state: :done, title: String.duplicate("é", 200))

    title = rest |> String.trim_trailing("\e\\") |> Base.decode64!()
    assert byte_size(title) <= 192
    assert String.valid?(title) and String.ends_with?(title, "…")
  end

  test "reports go to the status path, and none without one, or with one that can't be opened", %{
    tmp_dir: tmp
  } do
    tty = Path.join(tmp, "tty")
    pr = %{number: 7, title: "a change"}
    Status.root(%Shipyard{status: tty}, :working, "gating #7")
    Status.pr(%Shipyard{status: tty}, pr, :done, "live.")
    Status.root(%Shipyard{status: nil}, :idle, "nothing")
    assert :ok = Status.root(%Shipyard{status: Path.join(tmp, "no/such/tty")}, :idle, "x")

    assert reports(tty) == [
             %{"state" => "working", "app" => "shipyard", "msg" => "gating #7"},
             %{
               "state" => "done",
               "id" => "pr-7",
               "app" => "shipyard",
               "title" => "#7 a change",
               "msg" => "live."
             }
           ]
  end
end
