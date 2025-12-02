defmodule Indexer.Fetcher.Monad.Supervisor do
  @moduledoc """
  Supervisor for Monad-specific fetchers.

  Currently manages:
  - Validator fetcher: Periodically fetches validator data from the staking precompile
  """

  use Supervisor

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor
    }
  end

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl Supervisor
  def init(opts) do
    json_rpc_named_arguments = Keyword.fetch!(opts, :json_rpc_named_arguments)

    children = [
      {Indexer.Fetcher.Monad.Validator, [json_rpc_named_arguments: json_rpc_named_arguments]}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
