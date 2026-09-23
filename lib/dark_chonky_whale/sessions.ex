defmodule DarkChonkyWhale.Sessions do
  @moduledoc """
  The `:sessions` seam provider: a component owning the session store.

      %DexterousLoader.Entry{
        id: :sessions,
        component: DarkChonkyWhale.Sessions,
        config: [dir: "~/.dark_chonky_whale/sessions"]
      }

  Config:

    * `:dir` (required) — where the per-session JSONL logs live

  The provision is a `%Sessions{}` handle; consumers `inject: [:sessions]`
  and `open/2` sessions by id. Sessions are plain processes supervised under
  the component; unloading the component stops the supervisor and with it
  every open session (the logs on disk survive, they reopen lazily).
  """

  use Dexterous.Component, provide: [:sessions]

  alias DarkChonkyWhale.Session
  alias Dexterous.Context

  @typedoc "The session store handle, the value bound to the `:sessions` coeffect."
  @type t :: %__MODULE__{sup: pid(), registry: atom(), dir: Path.t(), scope: Context.scope()}

  defstruct [:sup, :registry, :dir, :scope]

  @doc """
  Open the session `id`, starting its log process (replaying the on-disk
  log, if any) or returning the already-open one.
  """
  @spec open(t(), Session.id()) :: {:ok, pid()}
  def open(%__MODULE__{} = sessions, id) do
    # DynamicSupervisor does not dedupe children by spec id; the via-name
    # registration does (a second open returns :already_started).
    spec = %{
      id: {Session, id},
      start:
        {Session, :start_link,
         [
           [
             id: id,
             dir: sessions.dir,
             scope: sessions.scope,
             name: {:via, Registry, {sessions.registry, id}}
           ]
         ]},
      restart: :transient
    }

    case DynamicSupervisor.start_child(sessions.sup, spec) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
    end
  end

  @doc "Stop the session process. The on-disk log is unaffected."
  @spec close(t(), pid()) :: :ok
  def close(%__MODULE__{} = sessions, pid) do
    DynamicSupervisor.terminate_child(sessions.sup, pid)
  end

  @doc "The ids of all sessions that have an on-disk log."
  @spec list(t()) :: [String.t()]
  def list(%__MODULE__{} = sessions) do
    sessions.dir
    |> Path.join("session-*.jsonl")
    |> Path.wildcard()
    |> Enum.map(fn path ->
      path |> Path.basename(".jsonl") |> String.trim_leading("session-")
    end)
  end

  ## Component

  @impl true
  def apply(ctx, config) do
    dir = config |> Keyword.fetch!(:dir) |> Path.expand()
    File.mkdir_p!(dir)

    {:ok, sup} = DynamicSupervisor.start_link(strategy: :one_for_one)
    registry = :"dcw_sessions_registry_#{System.unique_integer([:positive])}"
    {:ok, registry_pid} = Registry.start_link(keys: :unique, name: registry)

    # Both trap exits, and a trapping process dies when its parent (here:
    # the fiber's transient apply process) exits. Component-owned processes
    # are owned through Context.track/2 disposers, not links.
    Process.unlink(sup)
    Process.unlink(registry_pid)
    Context.track(ctx, sup)
    Context.track(ctx, registry_pid)

    Context.set(ctx, :sessions, %__MODULE__{
      sup: sup,
      registry: registry,
      dir: dir,
      scope: ctx.scope
    })
  end
end
