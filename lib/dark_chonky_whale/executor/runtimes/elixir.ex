defmodule DarkChonkyWhale.Executor.Runtimes.Elixir do
  @moduledoc """
  The in-process Elixir runtime: evaluate `code` in the agent's own BEAM,
  where it can see and touch the live system — inspect a running session,
  call a loaded module, hot-swap code.

  That power is the point, and the hazard: unlike the port-based runtimes,
  nothing here is isolated. A side effect cannot be rolled back, and a
  timeout only stops the damage — the evaluation runs in a task that is
  brutally killed when it outlives `timeout_ms`, but whatever it already did
  stays done.

  The output is what the code printed (`IO.puts` and friends are captured
  through a stand-in group leader, so it lands here instead of the agent's
  terminal) followed by the inspected return value, capped at
  `max_output_bytes` like any other runtime's output. A raised exception is
  reported as an error; it never escapes into the pipeline.
  """

  @behaviour DarkChonkyWhale.Executor.Runtime

  alias DarkChonkyWhale.Executor.Runner

  @impl true
  def run(code, ctx) do
    collector = start_collector()

    task =
      Task.async(fn ->
        Process.group_leader(self(), collector)

        try do
          {value, _binding} = Code.eval_string(code, [], file: "execute")
          {:ok, value}
        rescue
          exception -> {:error, Exception.format(:error, exception, __STACKTRACE__)}
        catch
          kind, reason -> {:error, Exception.format(kind, reason, __STACKTRACE__)}
        end
      end)

    result =
      case Task.yield(task, ctx.timeout_ms) do
        {:ok, outcome} ->
          outcome

        nil ->
          # Stop-loss only: the side effects already happened, and no
          # unwinding can take them back. :kill cannot be trapped.
          Task.shutdown(task, :brutal_kill)
          :timeout
      end

    report(result, stop_collector(collector), ctx)
  end

  defp report({:ok, value}, io, ctx) do
    rendered = inspect(value, pretty: true, limit: 50)
    {:ok, Runner.cap_output(join(io, rendered), ctx.max_output_bytes)}
  end

  defp report({:error, formatted}, io, ctx) do
    {:error, Runner.cap_output(join(io, formatted), ctx.max_output_bytes)}
  end

  defp report(:timeout, io, ctx) do
    message = "timed out after #{ctx.timeout_ms}ms; the evaluation was killed"
    body = String.trim_trailing(io, "\n")
    {:error, if(body == "", do: message, else: message <> "\n" <> body)}
  end

  defp join("", rendered), do: rendered
  defp join(io, rendered), do: String.trim_trailing(io, "\n") <> "\n" <> rendered

  ## The output collector

  # A stand-in group leader that does not print but remembers: IO in the
  # evaluated code arrives here as io requests, and the accumulated output is
  # handed back when the evaluation settles. IO waits for each reply, so by
  # the time the task is done every write is already folded into the
  # accumulator — no drain race.
  defp start_collector do
    parent = self()
    spawn_link(fn -> collect(parent, []) end)
  end

  defp stop_collector(pid) do
    send(pid, {:collect, self()})

    receive do
      {:collected, output} -> output
    after
      1_000 -> ""
    end
  end

  defp collect(parent, acc) do
    receive do
      {:collect, ^parent} ->
        send(parent, {:collected, acc |> Enum.reverse() |> IO.iodata_to_binary()})

      {:io_request, from, reply_as, request} ->
        collect(parent, handle_io(from, reply_as, request, acc))
    end
  end

  defp handle_io(from, reply_as, {:put_chars, chars}, acc) do
    send(from, {:io_reply, reply_as, :ok})
    [chars | acc]
  end

  defp handle_io(from, reply_as, {:put_chars, _encoding, chars}, acc) do
    send(from, {:io_reply, reply_as, :ok})
    [chars | acc]
  end

  # A batch carries one reply for the whole list; the first request the
  # collector cannot serve fails the batch.
  defp handle_io(from, reply_as, {:requests, requests}, acc) do
    {reply, acc} =
      Enum.reduce(requests, {:ok, acc}, fn
        _request, {{:error, _reason} = error, acc} ->
          {error, acc}

        {:put_chars, chars}, {:ok, acc} ->
          {:ok, [chars | acc]}

        {:put_chars, _encoding, chars}, {:ok, acc} ->
          {:ok, [chars | acc]}

        _other, {:ok, acc} ->
          {{:error, :unsupported}, acc}
      end)

    send(from, {:io_reply, reply_as, reply})
    acc
  end

  defp handle_io(from, reply_as, _request, acc) do
    send(from, {:io_reply, reply_as, {:error, :unsupported}})
    acc
  end
end
