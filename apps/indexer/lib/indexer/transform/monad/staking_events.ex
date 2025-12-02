defmodule Indexer.Transform.Monad.StakingEvents do
  @moduledoc """
  Transforms Monad staking logs from the staking precompile into database records.

  Parses the following event types:
  - ClaimRewards: When a delegator claims accumulated rewards
  - ValidatorRewarded: When block rewards are distributed to a validator
  - Delegate: When stake is added to a validator
  - Undelegate: When stake withdrawal is initiated
  - Withdraw: When stake is withdrawn after unbonding period
  """

  require Logger

  alias EthereumJSONRPC.Monad.Constants.{Contracts, Events}
  alias Explorer.Chain.Hash

  @doc """
  Parses logs and extracts Monad staking events.

  ## Parameters
  - logs: List of log entries from the blockchain

  ## Returns
  - List of staking event maps ready for database import
  """
  @spec parse([map()]) :: [map()]
  def parse(logs) when is_list(logs) do
    chain_type = Application.get_env(:explorer, :chain_type)

    if chain_type == :monad do
      do_parse(logs)
    else
      []
    end
  end

  def parse(_), do: []

  defp do_parse(logs) do
    staking_address = Contracts.staking_precompile() |> String.downcase()

    logs
    |> Enum.filter(&staking_event?(&1, staking_address))
    |> Enum.map(&parse_log/1)
    |> Enum.reject(&is_nil/1)
  end

  defp staking_event?(log, staking_address) do
    address =
      case log do
        %{address_hash: %Hash{} = hash} -> Hash.to_string(hash) |> String.downcase()
        %{address_hash: address} when is_binary(address) -> String.downcase(address)
        _ -> nil
      end

    first_topic =
      case log do
        %{first_topic: topic} when is_binary(topic) -> topic
        _ -> nil
      end

    address == staking_address and
      first_topic != nil and
      Events.signature_to_type(first_topic) != nil
  end

  defp parse_log(log) do
    first_topic =
      case log do
        %{first_topic: topic} when is_binary(topic) -> topic
        _ -> nil
      end

    event_type = Events.signature_to_type(first_topic)

    case decode_event(event_type, log) do
      {:ok, decoded} ->
        build_event_record(event_type, log, decoded)

      {:error, reason} ->
        Logger.warning("Failed to decode Monad staking event: #{inspect(reason)}, log: #{inspect(log)}")
        nil
    end
  end

  defp decode_event(:claim, log), do: decode_claim_rewards(log)
  defp decode_event(:validator_rewarded, log), do: decode_validator_rewarded(log)
  defp decode_event(:delegate, log), do: decode_delegate(log)
  defp decode_event(:undelegate, log), do: decode_undelegate(log)
  defp decode_event(:withdraw, log), do: decode_withdraw(log)
  defp decode_event(_, _), do: {:error, :unknown_event_type}

  # ClaimRewards(uint64 indexed validatorId, address indexed delegator, uint256 amount, uint64 epoch)
  defp decode_claim_rewards(log) do
    with {:ok, validator_id} <- decode_indexed_uint64(log.second_topic),
         {:ok, delegator_hash} <- decode_indexed_address(log.third_topic),
         {:ok, {amount, epoch}} <- decode_data_claim(log.data) do
      {:ok,
       %{
         validator_id: validator_id,
         delegator_address_hash: delegator_hash,
         amount: amount,
         epoch: epoch
       }}
    end
  end

  # ValidatorRewarded(uint64 indexed validatorId, address indexed from, uint256 amount, uint64 epoch)
  defp decode_validator_rewarded(log) do
    with {:ok, validator_id} <- decode_indexed_uint64(log.second_topic),
         {:ok, delegator_hash} <- decode_indexed_address(log.third_topic),
         {:ok, {amount, epoch}} <- decode_data_claim(log.data) do
      {:ok,
       %{
         validator_id: validator_id,
         delegator_address_hash: delegator_hash,
         amount: amount,
         epoch: epoch
       }}
    end
  end

  # Delegate(uint64 indexed validatorId, address indexed delegator, uint256 amount, uint64 activationEpoch)
  defp decode_delegate(log) do
    with {:ok, validator_id} <- decode_indexed_uint64(log.second_topic),
         {:ok, delegator_hash} <- decode_indexed_address(log.third_topic),
         {:ok, {amount, activation_epoch}} <- decode_data_delegate(log.data) do
      {:ok,
       %{
         validator_id: validator_id,
         delegator_address_hash: delegator_hash,
         amount: amount,
         activation_epoch: activation_epoch
       }}
    end
  end

  # Undelegate(uint64 indexed validatorId, address indexed delegator, uint8 withdrawId, uint256 amount, uint64 activationEpoch)
  defp decode_undelegate(log) do
    with {:ok, validator_id} <- decode_indexed_uint64(log.second_topic),
         {:ok, delegator_hash} <- decode_indexed_address(log.third_topic),
         {:ok, {withdraw_id, amount, activation_epoch}} <- decode_data_undelegate(log.data) do
      {:ok,
       %{
         validator_id: validator_id,
         delegator_address_hash: delegator_hash,
         amount: amount,
         withdraw_id: withdraw_id,
         activation_epoch: activation_epoch
       }}
    end
  end

  # Withdraw(uint64 indexed validatorId, address indexed delegator, uint8 withdrawId, uint256 amount, uint64 withdrawEpoch)
  defp decode_withdraw(log) do
    with {:ok, validator_id} <- decode_indexed_uint64(log.second_topic),
         {:ok, delegator_hash} <- decode_indexed_address(log.third_topic),
         {:ok, {withdraw_id, amount, withdraw_epoch}} <- decode_data_withdraw(log.data) do
      {:ok,
       %{
         validator_id: validator_id,
         delegator_address_hash: delegator_hash,
         amount: amount,
         withdraw_id: withdraw_id,
         epoch: withdraw_epoch
       }}
    end
  end

  # Decode helpers

  defp decode_indexed_uint64(nil), do: {:error, :missing_topic}

  defp decode_indexed_uint64(topic) when is_binary(topic) do
    # Topic is a 32-byte hex string (0x + 64 hex chars)
    # uint64 is in the last 8 bytes
    case topic do
      "0x" <> hex_data ->
        {:ok, hex_data |> Base.decode16!(case: :mixed) |> :binary.decode_unsigned(:big)}

      _ ->
        {:error, :invalid_topic_format}
    end
  end

  defp decode_indexed_address(nil), do: {:error, :missing_topic}

  defp decode_indexed_address(topic) when is_binary(topic) do
    # Topic is a 32-byte hex string, address is in the last 20 bytes
    case topic do
      "0x" <> hex_data ->
        # Take last 40 chars (20 bytes) for address
        address_hex = String.slice(hex_data, -40, 40)
        Hash.Address.cast("0x" <> address_hex)

      _ ->
        {:error, :invalid_topic_format}
    end
  end

  # Decode data for ClaimRewards/ValidatorRewarded: (uint256 amount, uint64 epoch)
  defp decode_data_claim(nil), do: {:error, :missing_data}

  defp decode_data_claim("0x" <> hex_data) do
    case Base.decode16(hex_data, case: :mixed) do
      {:ok, data} when byte_size(data) >= 64 ->
        <<amount::unsigned-big-integer-size(256), epoch::unsigned-big-integer-size(256)>> = data
        {:ok, {amount, epoch}}

      _ ->
        {:error, :invalid_data_format}
    end
  end

  defp decode_data_claim(_), do: {:error, :invalid_data_format}

  # Decode data for Delegate: (uint256 amount, uint64 activationEpoch)
  defp decode_data_delegate(data), do: decode_data_claim(data)

  # Decode data for Undelegate: (uint8 withdrawId, uint256 amount, uint64 activationEpoch)
  defp decode_data_undelegate(nil), do: {:error, :missing_data}

  defp decode_data_undelegate("0x" <> hex_data) do
    case Base.decode16(hex_data, case: :mixed) do
      {:ok, data} when byte_size(data) >= 96 ->
        # Each field is padded to 32 bytes
        <<withdraw_id::unsigned-big-integer-size(256), amount::unsigned-big-integer-size(256),
          activation_epoch::unsigned-big-integer-size(256)>> = data

        {:ok, {withdraw_id, amount, activation_epoch}}

      _ ->
        {:error, :invalid_data_format}
    end
  end

  defp decode_data_undelegate(_), do: {:error, :invalid_data_format}

  # Decode data for Withdraw: (uint8 withdrawId, uint256 amount, uint64 withdrawEpoch)
  defp decode_data_withdraw(data), do: decode_data_undelegate(data)

  defp build_event_record(event_type, log, decoded) do
    block_number =
      case log do
        %{block_number: bn} when is_integer(bn) -> bn
        _ -> nil
      end

    log_index =
      case log do
        %{index: idx} when is_integer(idx) -> idx
        %{log_index: idx} when is_integer(idx) -> idx
        _ -> nil
      end

    transaction_hash =
      case log do
        %{transaction_hash: %Hash{} = hash} -> hash
        %{transaction_hash: hash} when is_binary(hash) -> hash
        _ -> nil
      end

    block_hash =
      case log do
        %{block_hash: %Hash{} = hash} -> hash
        %{block_hash: hash} when is_binary(hash) -> hash
        _ -> nil
      end

    if block_number && log_index && transaction_hash && block_hash do
      base_record = %{
        block_number: block_number,
        log_index: log_index,
        transaction_hash: transaction_hash,
        block_hash: block_hash,
        event_type: event_type,
        validator_id: decoded.validator_id,
        delegator_address_hash: decoded.delegator_address_hash,
        amount: decoded.amount
      }

      # Add optional fields
      base_record
      |> maybe_add_field(:epoch, decoded[:epoch])
      |> maybe_add_field(:withdraw_id, decoded[:withdraw_id])
      |> maybe_add_field(:activation_epoch, decoded[:activation_epoch])
    else
      nil
    end
  end

  defp maybe_add_field(map, _key, nil), do: map
  defp maybe_add_field(map, key, value), do: Map.put(map, key, value)
end
