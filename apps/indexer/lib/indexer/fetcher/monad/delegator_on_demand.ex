defmodule Indexer.Fetcher.Monad.DelegatorOnDemand do
  @moduledoc """
  On-demand fetcher for delegator positions from the Monad staking precompile.

  This module is called by the API controller when cached delegator position data
  is stale or missing. It fetches data via RPC and caches it in the database.

  Uses:
  - getDelegations(address, startIndex) to get list of validators an address delegated to
  - getDelegator(validatorId, address) to get stake and unclaimed rewards for each position
  """

  require Logger

  alias EthereumJSONRPC
  alias EthereumJSONRPC.Monad.Constants.Contracts
  alias Explorer.Chain
  alias Explorer.Chain.Hash

  @batch_size 10

  @doc """
  Fetches delegator positions for an address and caches them in the database.
  Returns the list of positions after caching.
  """
  @spec fetch_and_cache(Hash.Address.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def fetch_and_cache(address_hash, options \\ []) do
    json_rpc_named_arguments =
      Keyword.get(options, :json_rpc_named_arguments, Application.get_env(:indexer, :json_rpc_named_arguments))

    with {:ok, validator_ids} <- fetch_delegations(address_hash, json_rpc_named_arguments),
         {:ok, positions} <- fetch_positions(address_hash, validator_ids, json_rpc_named_arguments) do
      if Enum.empty?(positions) do
        {:ok, []}
      else
        # Cache positions in the database
        addresses = [%{hash: address_hash}]

        case Chain.import(%{
               addresses: %{params: addresses},
               monad_delegator_positions: %{params: positions},
               timeout: :infinity
             }) do
          {:ok, _} ->
            Logger.debug("Cached #{length(positions)} delegator positions for #{address_hash}")
            {:ok, positions}

          {:error, reason} ->
            Logger.warning("Failed to cache delegator positions: #{inspect(reason)}")
            # Still return the positions even if caching failed
            {:ok, positions}
        end
      end
    end
  end

  @doc """
  Fetches delegator positions without caching.
  Useful for quick lookups where caching isn't needed.
  """
  @spec fetch(Hash.Address.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def fetch(address_hash, options \\ []) do
    json_rpc_named_arguments =
      Keyword.get(options, :json_rpc_named_arguments, Application.get_env(:indexer, :json_rpc_named_arguments))

    with {:ok, validator_ids} <- fetch_delegations(address_hash, json_rpc_named_arguments),
         {:ok, positions} <- fetch_positions(address_hash, validator_ids, json_rpc_named_arguments) do
      {:ok, positions}
    end
  end

  # Fetch validator IDs that the address has delegated to using getDelegations(address, startValId)
  defp fetch_delegations(address_hash, json_rpc_named_arguments) do
    fetch_delegations_recursive(address_hash, 0, [], json_rpc_named_arguments)
  end

  defp fetch_delegations_recursive(address_hash, start_val_id, acc, json_rpc_named_arguments) do
    request = build_get_delegations_request(address_hash, start_val_id)

    case EthereumJSONRPC.json_rpc([request], json_rpc_named_arguments) do
      {:ok, [%{result: result}]} ->
        case parse_delegations_response(result) do
          {:ok, is_done, next_val_id, validator_ids} ->
            all_ids = acc ++ validator_ids

            if is_done or Enum.empty?(validator_ids) do
              {:ok, all_ids}
            else
              fetch_delegations_recursive(address_hash, next_val_id, all_ids, json_rpc_named_arguments)
            end

          {:error, reason} ->
            {:error, reason}
        end

      {:ok, [%{error: error}]} ->
        Logger.warning("Error fetching delegations: #{inspect(error)}")
        {:error, error}

      {:error, reason} ->
        Logger.warning("Failed to fetch delegations: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp build_get_delegations_request(address_hash, start_val_id) do
    staking_address = Contracts.staking_precompile()
    selector = Contracts.get_delegations_selector()

    # Encode address (20 bytes padded to 32 bytes)
    encoded_address =
      address_hash
      |> Hash.Address.to_string()
      |> String.trim_leading("0x")
      |> String.downcase()
      |> String.pad_leading(64, "0")

    # Encode start_val_id as uint64 (padded to 32 bytes)
    encoded_val_id = start_val_id |> Integer.to_string(16) |> String.pad_leading(64, "0")

    %{
      id: 1,
      jsonrpc: "2.0",
      method: "eth_call",
      params: [
        %{
          to: staking_address,
          data: selector <> encoded_address <> encoded_val_id
        },
        "latest"
      ]
    }
  end

  defp parse_delegations_response("0x" <> hex_data) do
    case Base.decode16(hex_data, case: :mixed) do
      {:ok, data} when byte_size(data) >= 96 ->
        # getDelegations returns (bool isDone, uint64 nextValId, uint64[] valIds)
        # First 32 bytes: isDone (bool, right-aligned / left-padded with zeros)
        # Next 32 bytes: nextValId (uint64, right-aligned / left-padded)
        # Next 32 bytes: offset to dynamic array
        # At offset: array length (32 bytes), then elements (each uint64 padded to 32 bytes)
        <<
          _padding1::binary-size(31),
          is_done_byte::unsigned-integer-size(8),
          _padding2::binary-size(24),
          next_val_id::unsigned-big-integer-size(64),
          array_offset::unsigned-big-integer-size(256),
          _rest::binary
        >> = data

        is_done = is_done_byte == 1

        # Parse the dynamic array at the specified offset
        # The offset is relative to the start of the return data
        validator_ids =
          if array_offset > 0 and byte_size(data) > array_offset do
            parse_uint64_array(data, array_offset)
          else
            []
          end

        {:ok, is_done, next_val_id, validator_ids}

      _ ->
        {:error, :invalid_response}
    end
  end

  defp parse_delegations_response(_), do: {:error, :empty_response}

  defp parse_uint64_array(data, offset) when offset < byte_size(data) do
    <<_skip::binary-size(offset), length::unsigned-big-integer-size(256), rest::binary>> = data

    if length > 0 and byte_size(rest) >= length * 32 do
      0..(length - 1)
      |> Enum.map(fn i ->
        # Each uint64 is padded to 32 bytes
        start = i * 32
        <<_skip::binary-size(start), _padding::binary-size(24), value::unsigned-big-integer-size(64), _::binary>> = rest
        value
      end)
      |> Enum.filter(&(&1 > 0))
    else
      []
    end
  end

  defp parse_uint64_array(_data, _offset), do: []

  # Fetch position data for each validator using getDelegator(validatorId, address)
  defp fetch_positions(_address_hash, [], _json_rpc_named_arguments), do: {:ok, []}

  defp fetch_positions(address_hash, validator_ids, json_rpc_named_arguments) do
    current_block = Explorer.Chain.fetch_max_block_number()

    positions =
      validator_ids
      |> Enum.chunk_every(@batch_size)
      |> Enum.flat_map(fn batch ->
        requests =
          Enum.map(batch, fn validator_id ->
            build_get_delegator_request(validator_id, address_hash)
          end)

        case EthereumJSONRPC.json_rpc(requests, json_rpc_named_arguments) do
          {:ok, responses} ->
            Enum.zip(batch, responses)
            |> Enum.map(fn {validator_id, response} ->
              parse_delegator_response(address_hash, validator_id, response, current_block)
            end)
            |> Enum.reject(&is_nil/1)

          {:error, reason} ->
            Logger.warning("Failed to fetch delegator positions batch: #{inspect(reason)}")
            []
        end
      end)

    {:ok, positions}
  end

  defp build_get_delegator_request(validator_id, address_hash) do
    staking_address = Contracts.staking_precompile()
    selector = Contracts.get_delegator_selector()

    # Encode validator_id as uint64 (padded to 32 bytes)
    encoded_id = validator_id |> Integer.to_string(16) |> String.pad_leading(64, "0")

    # Encode address (20 bytes padded to 32 bytes)
    encoded_address =
      address_hash
      |> Hash.Address.to_string()
      |> String.trim_leading("0x")
      |> String.downcase()
      |> String.pad_leading(64, "0")

    %{
      id: validator_id,
      jsonrpc: "2.0",
      method: "eth_call",
      params: [
        %{
          to: staking_address,
          data: selector <> encoded_id <> encoded_address
        },
        "latest"
      ]
    }
  end

  defp parse_delegator_response(address_hash, validator_id, %{result: "0x" <> hex_data}, current_block)
       when byte_size(hex_data) >= 448 do
    # getDelegator returns (encoded as 7 * 32 bytes = 224 bytes = 448 hex chars):
    # stake: uint256
    # accRewardPerToken: uint256
    # unclaimedRewards: uint256
    # deltaStake: uint256
    # nextDeltaStake: uint256
    # deltaEpoch: uint64
    # nextDeltaEpoch: uint64
    case Base.decode16(hex_data, case: :mixed) do
      {:ok, data} when byte_size(data) >= 96 ->
        <<
          stake::unsigned-big-integer-size(256),
          _acc_reward_per_token::unsigned-big-integer-size(256),
          unclaimed_rewards::unsigned-big-integer-size(256),
          _rest::binary
        >> = data

        # Only include if there's stake or unclaimed rewards
        if stake > 0 or unclaimed_rewards > 0 do
          %{
            delegator_address_hash: address_hash,
            validator_id: validator_id,
            stake: stake,
            unclaimed_rewards: unclaimed_rewards,
            updated_at_block: current_block
          }
        else
          nil
        end

      _ ->
        nil
    end
  end

  defp parse_delegator_response(_address_hash, _validator_id, _response, _current_block), do: nil
end
