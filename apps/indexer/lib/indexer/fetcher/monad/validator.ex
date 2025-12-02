defmodule Indexer.Fetcher.Monad.Validator do
  @moduledoc """
  GenServer responsible for periodically fetching Monad validator data from the staking precompile.

  Fetches validator state snapshots by calling getValidator(uint64) on the staking precompile
  at address 0x1000. Validator data is stored in the monad_validators table.
  """

  use GenServer

  require Logger

  alias EthereumJSONRPC
  alias EthereumJSONRPC.Monad.Constants.Contracts
  alias Explorer.Chain
  alias Explorer.Chain.Hash

  @fetch_interval :timer.minutes(5)
  @max_validator_id_to_check 1000
  @batch_size 10

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent
    }
  end

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl GenServer
  def init(opts) do
    json_rpc_named_arguments = Keyword.fetch!(opts, :json_rpc_named_arguments)

    state = %{
      json_rpc_named_arguments: json_rpc_named_arguments
    }

    # Schedule first fetch after a short delay
    Process.send_after(self(), :fetch_validators, :timer.seconds(30))

    {:ok, state}
  end

  @impl GenServer
  def handle_info(:fetch_validators, state) do
    fetch_all_validators(state.json_rpc_named_arguments)
    Process.send_after(self(), :fetch_validators, @fetch_interval)
    {:noreply, state}
  end

  @doc """
  Manually trigger a validator fetch.
  """
  @spec trigger_fetch() :: :ok
  def trigger_fetch do
    GenServer.cast(__MODULE__, :fetch_validators)
  end

  @impl GenServer
  def handle_cast(:fetch_validators, state) do
    fetch_all_validators(state.json_rpc_named_arguments)
    {:noreply, state}
  end

  defp fetch_all_validators(json_rpc_named_arguments) do
    Logger.info("Starting Monad validator fetch")

    validators =
      1..@max_validator_id_to_check
      |> Enum.chunk_every(@batch_size)
      |> Enum.reduce_while([], fn batch, acc ->
        results = fetch_validator_batch(batch, json_rpc_named_arguments)

        # Check if all results in the batch are nil (no more validators)
        valid_results = Enum.reject(results, &is_nil/1)

        if Enum.empty?(valid_results) do
          {:halt, acc}
        else
          {:cont, acc ++ valid_results}
        end
      end)

    if Enum.empty?(validators) do
      Logger.info("No Monad validators found")
    else
      Logger.info("Found #{length(validators)} Monad validators")
      import_validators(validators)
    end
  end

  defp fetch_validator_batch(validator_ids, json_rpc_named_arguments) do
    validator_ids
    |> Enum.map(&build_get_validator_request/1)
    |> EthereumJSONRPC.json_rpc(json_rpc_named_arguments)
    |> case do
      {:ok, responses} ->
        Enum.zip(validator_ids, responses)
        |> Enum.map(fn {validator_id, response} ->
          parse_validator_response(validator_id, response)
        end)

      {:error, reason} ->
        Logger.warning("Failed to fetch Monad validators batch: #{inspect(reason)}")
        Enum.map(validator_ids, fn _ -> nil end)
    end
  end

  defp build_get_validator_request(validator_id) do
    staking_address = Contracts.staking_precompile()
    selector = Contracts.get_validator_selector()

    # Encode validator_id as uint64 (padded to 32 bytes)
    encoded_id = validator_id |> Integer.to_string(16) |> String.pad_leading(64, "0")

    %{
      id: validator_id,
      jsonrpc: "2.0",
      method: "eth_call",
      params: [
        %{
          to: staking_address,
          data: selector <> encoded_id
        },
        "latest"
      ]
    }
  end

  defp parse_validator_response(validator_id, %{result: "0x" <> _ = result}) when byte_size(result) > 2 do
    parse_validator_data(validator_id, result)
  end

  defp parse_validator_response(_validator_id, %{result: "0x"}) do
    # Empty result means validator doesn't exist
    nil
  end

  defp parse_validator_response(_validator_id, %{error: error}) do
    Logger.debug("Error fetching validator: #{inspect(error)}")
    nil
  end

  defp parse_validator_response(_validator_id, _response) do
    nil
  end

  defp parse_validator_data(validator_id, "0x" <> hex_data) do
    case Base.decode16(hex_data, case: :mixed) do
      {:ok, data} when byte_size(data) >= 256 ->
        # ValidatorMetadata struct layout:
        # - authAddress: address (20 bytes, padded to 32)
        # - totalStake: uint256
        # - consensusStake: uint256
        # - commission: uint256
        # - unclaimedRewards: uint256
        # - flags: uint64 (padded to 32)
        # - secpPubkey: bytes (offset pointer)
        # - blsPubkey: bytes (offset pointer)
        <<
          _padding1::binary-size(12),
          auth_address::binary-size(20),
          total_stake::unsigned-big-integer-size(256),
          consensus_stake::unsigned-big-integer-size(256),
          commission::unsigned-big-integer-size(256),
          unclaimed_rewards::unsigned-big-integer-size(256),
          flags::unsigned-big-integer-size(256),
          _rest::binary
        >> = data

        # Only return validator if it has non-zero stake or is active
        if total_stake > 0 or flags > 0 do
          {:ok, auth_hash} = Hash.Address.cast(auth_address)

          %{
            validator_id: validator_id,
            auth_address_hash: auth_hash,
            total_stake: total_stake,
            consensus_stake: consensus_stake,
            commission: commission,
            unclaimed_rewards: unclaimed_rewards,
            flags: flags,
            updated_at_block: get_current_block_number()
          }
        else
          nil
        end

      _ ->
        Logger.warning("Failed to parse validator data for ID #{validator_id}")
        nil
    end
  end

  defp parse_validator_data(_validator_id, _data), do: nil

  defp get_current_block_number do
    case Explorer.Chain.Block.get_max_block_number() do
      {:ok, number} -> number
      _ -> 0
    end
  end

  defp import_validators([]), do: :ok

  defp import_validators(validators) do
    case Chain.import(%{
           monad_validators: %{params: validators},
           timeout: :infinity
         }) do
      {:ok, _} ->
        Logger.info("Successfully imported #{length(validators)} Monad validators")
        :ok

      {:error, reason} ->
        Logger.error("Failed to import Monad validators: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
