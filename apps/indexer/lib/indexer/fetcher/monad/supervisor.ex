defmodule Indexer.Fetcher.Monad.Supervisor do
  @moduledoc """
  Supervisor for Monad-specific fetchers.

  Manages:
  - Validator fetcher: Periodically fetches validator data from the staking precompile
  - StakingEventsCatchup: Backfills historical staking events and monitors for new ones
  """

  use Supervisor

  alias Indexer.Fetcher.Monad.{StakingEventsCatchup, Validator}

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

    children =
      [
        {Validator, [json_rpc_named_arguments: json_rpc_named_arguments]},
        catchup_child_spec(json_rpc_named_arguments)
      ]
      |> List.flatten()
      |> Enum.reject(&is_nil/1)

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp catchup_child_spec(json_rpc_named_arguments) do
    if Application.get_env(:indexer, StakingEventsCatchup)[:enabled] do
      {StakingEventsCatchup, [[json_rpc_named_arguments: json_rpc_named_arguments]]}
    else
      nil
    end
  end
end
