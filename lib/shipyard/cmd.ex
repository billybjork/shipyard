defmodule Shipyard.Cmd do
  @moduledoc """
  Runs a command to its end in a directory and returns its output and exit
  status. With `:timeout` (ms) it runs under `alarm`, so a command past it
  is killed (exit 142) rather than holding the worker.
  """

  def run(%Shipyard{env: env}, dir, cmd, args, opts \\ []) do
    {timeout, opts} = Keyword.pop(opts, :timeout)

    # Found on the PATH the command runs with, not only the VM's own.
    cmd =
      with {_, path} <- List.keyfind(env, "PATH", 0),
           exe when exe != false <- :os.find_executable(~c"#{cmd}", ~c"#{path}"),
           do: List.to_string(exe),
           else: (_ -> cmd)

    {cmd, args} =
      if timeout,
        do:
          {"perl", ["-e", "alarm shift; exec @ARGV", to_string(div(timeout, 1000)), cmd | args]},
        else: {cmd, args}

    System.cmd(cmd, args, [cd: dir, env: env, stderr_to_stdout: true] |> Keyword.merge(opts))
  end

  def git(ship, dir, args), do: run(ship, dir, "git", args)

  # The output of a git command that must succeed, trimmed.
  def git!(ship, dir, args) do
    case git(ship, dir, args) do
      {out, 0} -> String.trim(out)
      {out, status} -> raise "git #{Enum.join(args, " ")} exited #{status}: #{out}"
    end
  end
end
