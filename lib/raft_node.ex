defmodule Raft.Node do
  @moduledoc """
  This GenServer node implements (or at least tries to) a raft consensus
  algorithm using global registering.

  This version of Node will never get a timeout when it's not supposed to.
  However, the timeout is reset too often, leading to a bit slower elections in
  certain cases where elections don't come to a conclusion. This shouldn't be
  a problem however, as this tends not to happen that often (and elections
  themselves shouldn't happen too often either), and the added security is
  certainly worth it. In theory the absolute worst case time of an unconcluded
  election would be around 7 seconds (2 maximum timeouts + some message
  processing). Which is double than the absolute worst case should be. Also, it
  might use a little bit more resources because of the extra calculations.
  """
  use GenServer
  require Logger

  defmodule State do
    @moduledoc """
    A module to define a state struct.
    """

    @doc """
    This struct defines the state of RaftNode. It holds all vital information
    and it's defaults. These fields are:
      * Mode (:follower or :leader), which will always start as :follower so
        the first term is actually a race to start an election, and a leader
        will be arbitrarily chosen by all nodes.
      * Term, which is incremented by 1 every time a new election is held.
      * Votes, which holds how much votes it has when it holds an election.
      * Amount, which holds the amount of nodes for this raft cluster.
    """
    defstruct mode: :follower,
              term: 1,
              votes: 0,
              amount: 0
  end

  @doc """
  Starts the GenServer.
  """
  def start_link state \\ [], opts \\ [] do
    GenServer.start_link __MODULE__, state, opts
  end


  ## GENSERVER CALLBACKS ##


  @doc """
  Initializes the GenServer, seeds random, define all nodenames of this raft
  cluster, globally registers itself under the name of this node and starts the
  first timeout.

  gateway_spec is a map freeswitch_gateway as defined in config/config.exs
  """
  @impl GenServer
  def init [node, amount] do
    :rand.seed :exsplus

    :global.register_name String.to_integer(node), self()
    Logger.debug "#{inspect __MODULE__} started raft_node #{node}"
    {:ok, %State{amount: String.to_integer(amount)}, generate_timeout()}
  end

  # Handles incoming timeouts by starting a new election. It first checks the
  # mode stored in the state, because leaders shouldn't receive timeouts. After
  # that, the function starts an election by broadcasting an :election message
  # for the next term. It will also start a new timeout, so when the election
  # doesn't come to a conclusion it can try again. It will also vote for itself.
  @impl GenServer
  def handle_info :timeout, %{mode: :follower} = state do
    #IO.inspect state
    #Logger.debug "in handle_info (:timeout)"

    # Log an error if there are not enough nodes connected.
    # This is done in a different process so it doesn't influence the raft_node
    # itself.
    spawn fn ->
      if length(Node.list) + 1 <= (state.amount / 2),
        do: Logger.error "Not enough nodes connected to choose a raft leader!"
    end

    term = state.term + 1
    for i <- 1..state.amount, do:
      GenServer.cast({:global, i},
        {:election, term: term, candidate: node()})
    GenServer.cast self(), {:vote, term}
    {:noreply, %{state | votes: 0, term: term}, generate_timeout()}
  end

  # This function is just to catch all unhandled info messages. In theory this
  # should only catch :timeout messages received by a leader node, which should
  # never happen.
  def handle_info(msg, state) do
    Logger.error "A raft node received an unhadled message!"
    Apex.ap msg
    Apex.ap state
    {:noreply, state}
  end

  # Handles incoming heartbeats. it first checks if the current node is the
  # leader or a follower. When it's the leader it will check whether the
  # broadcasted term is higher that the term in it's state, this should only
  # happen when a seperation of the cluster has taken place and both parts join
  # again. If this is the case, the leader with the lowest term will kill itself,
  # otherwise it will send another heartbeat. When the node is a follower it will
  # reset the timeout. It will also set the term to the term broadcasted by the
  # leader (used after an election or when a new node joins).
  @impl GenServer
  def handle_cast({:heartbeat, term}, %{mode: :follower} = state), do:
    {:noreply, %{state | term: term}, generate_timeout()}
  def handle_cast {:heartbeat, term}, %{mode: :leader} = state do
    #IO.inspect state
    #Logger.debug "in handle_cast ({:heartbeat, term})"
    if term > state.term do
      # TODO
      # This should probably be made into a graceful shutdown of the
      # process this leader node is running, instead of a hard shutdown.
      Process.exit self(), :kill
    else
      for i <- 1..state.amount, do:
        Kernel.spawn(fn ->
          :timer.sleep 2000
          GenServer.cast {:global, i}, {:heartbeat, term}
        end)
      {:noreply, state}
    end
  end

  # Handles incomming :election messages. These messages contain the term this
  # election is about and the candidate which sent the message. The receiving
  # node checks whether the term is higher than the term in it's state. If that
  # is not the case, it means that it already voted, otherwise it votes for the
  # candidate and updates it's term.
  def handle_cast {:election, term: term, candidate: candidate}, state do
    #IO.inspect state
    #Logger.debug "in handle_cast (:election)"
    if term > state.term do
      GenServer.cast {:global, candidate}, {:vote, term}
      {:noreply, %{state | term: term}, generate_timeout()}
    else
      {:noreply, state, generate_timeout()}
    end
  end

  # Handles incomming :vote messages. It first checks if the mode is :follower,
  # because it declares itself leader when it receives more than half of the
  # votes. After that it can still receive leftover votes, which have to be
  # ignored. Then it checks if the vote is for the current election, and not some
  # leftover vote from a previous election that didn't come to a conclusion.
  # After those checks, the function increases the amount of votes by 1 and
  # checks whether a majority of votes is reached. If that is the case, it will
  # declare itself the leader and broadcast a :hearbeat. After that it starts the
  # GenServer for the gateway.
  def handle_cast {:vote, term}, %{mode: :follower, term: term} = state do
    #IO.inspect state
    #Logger.debug "in handle_cast (:vote)"
    votes = state.votes + 1
    if votes > (state.amount / 2) do
      for i <- 1..state.amount, do:
        GenServer.cast({:global, i}, {:heartbeat, term})
      Logger.debug "#{node()} is the raft leader for gateway " <>
                   Atom.to_string(state.spec[:nodename])
      # Perform action that only the leader should do
      spawn_link fn ->
        Logger.info "Some action"
        :timer.sleep(10000)
      end
      {:noreply, %{state | mode: :leader}}
    else
      {:noreply, %{state | votes: votes}, generate_timeout()}
    end
  end
  def handle_cast({:vote, _}, %{mode: :follower} = state), do:
    {:noreply, state, generate_timeout()}

  # This function catches all messages that aren't important. In theory this
  # should only catch :vote messages when the node's mode is :leader.
  def handle_cast(msg, state) do
    Logger.error "A raft node received an unhandled message!"
    Apex.ap msg
    Apex.ap state
    {:noreply, state}
  end


  ## PRIVATE FUNCTIONS ##


  # Generate a random timeout. The minimum is 2000, so a :hearbeat has to be
  # received between two timeouts, but the extra 100 leaves a little buffer to
  # be extra certain.
  defp generate_timeout, do: 2100 + :rand.uniform 1500

end
