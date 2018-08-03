defmodule Raft do
  @moduledoc false
  use Application
  use Supervisor

  @impl Application
  def start(_type, _args) do
    case System.argv do
      [node, amount] = args ->
        Node.set_cookie :raft
        for i <- 1..String.to_integer(amount), i != String.to_integer(node), do:
          Node.connect :"#{i}@WERKBEEST"
        Supervisor.start_link([worker(Raft.Node, [args])], strategy: :one_for_one, name: __MODULE__)
      _ ->
        raise "No amount of nodes specified. Use `mix run _ $NODE_NUMBER $AMOUNT` to start."
    end
  end

  @impl Supervisor
  def init(args) do
    {:ok, args}
  end
end
