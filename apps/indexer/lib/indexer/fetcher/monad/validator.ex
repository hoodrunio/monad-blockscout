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

  # Handle Task.async responses from Chain.import -> Notify.async
  # When Task completes, it sends {ref, result} to the caller
  @impl GenServer
  def handle_info({ref, _result}, state) when is_reference(ref) do
    # Demonitor and flush to avoid :DOWN message
    Process.demonitor(ref, [:flush])
    {:noreply, state}
  end

  # Handle DOWN messages if task crashes
  @impl GenServer
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
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
      {:ok, data} when byte_size(data) >= 384 ->
        # getValidator return struct (from Monad docs):
        # Slot 0:  address authAddress        (20 bytes, left-padded to 32)
        # Slot 1:  uint64 flags               (8 bytes, left-padded to 32)
        # Slot 2:  uint256 stake              (execution stake)
        # Slot 3:  uint256 accRewardPerToken  (accumulator)
        # Slot 4:  uint256 commission         (execution commission, 1e18 scale)
        # Slot 5:  uint256 unclaimedRewards
        # Slot 6:  uint256 consensusStake
        # Slot 7:  uint256 consensusCommission
        # Slot 8:  uint256 snapshotStake
        # Slot 9:  uint256 snapshotCommission
        # Slot 10: bytes secpPubkey offset
        # Slot 11: bytes blsPubkey offset
        # ... dynamic data follows
        <<
          # Slot 0: authAddress
          _padding_addr::binary-size(12),
          auth_address::binary-size(20),
          # Slot 1: flags (uint64 padded to 32 bytes)
          _padding_flags::binary-size(24),
          flags::unsigned-big-integer-size(64),
          # Slot 2: stake (execution)
          stake::unsigned-big-integer-size(256),
          # Slot 3: accRewardPerToken (we don't store this)
          _acc_reward_per_token::unsigned-big-integer-size(256),
          # Slot 4: commission (execution)
          commission::unsigned-big-integer-size(256),
          # Slot 5: unclaimedRewards
          unclaimed_rewards::unsigned-big-integer-size(256),
          # Slot 6: consensusStake
          consensus_stake::unsigned-big-integer-size(256),
          # Slot 7: consensusCommission (we use execution commission)
          _consensus_commission::unsigned-big-integer-size(256),
          # Slot 8: snapshotStake (we don't store this)
          _snapshot_stake::unsigned-big-integer-size(256),
          # Slot 9: snapshotCommission (we don't store this)
          _snapshot_commission::unsigned-big-integer-size(256),
          # Slot 10: secpPubkey offset (relative to start of return data)
          secp_offset::unsigned-big-integer-size(256),
          # Slot 11: blsPubkey offset
          bls_offset::unsigned-big-integer-size(256),
          # Rest: dynamic data (pubkeys)
          _rest::binary
        >> = data

        # Parse dynamic bytes fields (secpPubkey and blsPubkey)
        secp_pubkey = parse_dynamic_bytes(data, secp_offset)
        bls_pubkey = parse_dynamic_bytes(data, bls_offset)

        # Only return validator if it has non-zero stake or is registered (flags or any stake)
        if stake > 0 or consensus_stake > 0 or flags > 0 do
          {:ok, auth_hash} = Hash.Address.cast(auth_address)

          %{
            validator_id: validator_id,
            auth_address_hash: auth_hash,
            total_stake: stake,
            consensus_stake: consensus_stake,
            commission: commission,
            unclaimed_rewards: unclaimed_rewards,
            flags: flags,
            secp_pubkey: secp_pubkey,
            bls_pubkey: bls_pubkey,
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

  # Parse dynamic bytes from ABI-encoded data
  # offset is the byte offset from the start of the data where the bytes field is located
  # Layout at offset: [32 bytes length][length bytes data]
  defp parse_dynamic_bytes(data, offset) when is_integer(offset) and offset >= 0 do
    data_size = byte_size(data)

    # Ensure we have enough data to read the length
    if offset + 32 <= data_size do
      <<_skip::binary-size(offset), length::unsigned-big-integer-size(256), rest::binary>> = data

      # Ensure we have enough data to read the actual bytes
      if length > 0 and byte_size(rest) >= length do
        <<bytes_data::binary-size(length), _::binary>> = rest
        bytes_data
      else
        nil
      end
    else
      nil
    end
  end

  defp parse_dynamic_bytes(_data, _offset), do: nil

  defp parse_validator_data(_validator_id, _data), do: nil

  defp get_current_block_number do
    Explorer.Chain.fetch_max_block_number()
  end

  defp import_validators([]), do: :ok

  defp import_validators(validators) do
    # Extract unique addresses from validators to ensure they exist before FK check
    addresses =
      validators
      |> Enum.map(fn v -> %{hash: v.auth_address_hash} end)
      |> Enum.uniq_by(& &1.hash)

    case Chain.import(%{
           addresses: %{params: addresses},
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
