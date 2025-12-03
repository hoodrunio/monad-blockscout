defmodule BlockScoutWeb.API.V2.MonadView do
  @moduledoc """
  View functions for rendering Monad-related data in JSON format.
  """

  use BlockScoutWeb, :view

  alias BlockScoutWeb.API.V2.Helper
  alias ExSecp256k1
  alias Explorer.Chain.Monad.{StakingEvent, Validator}

  @doc """
  Renders a list of staking events with pagination.
  """
  def render("staking_events.json", %{
        events: events,
        next_page_params: next_page_params,
        validators_map: validators_map
      }) do
    %{
      items: Enum.map(events, &prepare_staking_event(&1, validators_map)),
      next_page_params: next_page_params
    }
  end

  # Fallback for when validators_map is not provided
  def render("staking_events.json", %{
        events: events,
        next_page_params: next_page_params
      }) do
    %{
      items: Enum.map(events, &prepare_staking_event(&1, %{})),
      next_page_params: next_page_params
    }
  end

  @doc """
  Renders staking statistics for an address.
  """
  def render("staking_stats.json", %{
        total_rewards_claimed: total_rewards_claimed,
        total_delegated: total_delegated,
        total_unclaimed_rewards: total_unclaimed_rewards,
        event_counts: event_counts,
        positions: positions,
        validators_map: validators_map
      }) do
    %{
      total_rewards_claimed: wei_to_string(total_rewards_claimed),
      total_delegated: wei_to_string(total_delegated),
      total_unclaimed_rewards: wei_to_string(total_unclaimed_rewards),
      event_counts:
        Map.new(event_counts, fn {type, count} ->
          {to_string(type), count}
        end),
      positions: Enum.map(positions, &prepare_position(&1, validators_map))
    }
  end

  defp prepare_position(%{validator_id: validator_id, stake: stake, unclaimed_rewards: unclaimed_rewards}, validators_map) do
    validator = Map.get(validators_map, validator_id)
    secp_pubkey = if validator, do: validator.secp_pubkey, else: nil

    %{
      validator_id: validator_id,
      secp_pubkey: binary_to_hex(secp_pubkey),
      secp_address: secp_pubkey_to_address(secp_pubkey),
      stake: wei_to_string(stake),
      unclaimed_rewards: wei_to_string(unclaimed_rewards)
    }
  end

  @doc """
  Renders a list of validators with pagination.
  """
  def render("validators.json", %{
        validators: validators,
        next_page_params: next_page_params
      }) do
    %{
      items: Enum.map(validators, &prepare_validator/1),
      next_page_params: next_page_params
    }
  end

  @doc """
  Renders a single validator.
  """
  def render("validator.json", %{validator: validator}) do
    prepare_validator(validator)
  end

  @doc """
  Renders aggregated validator statistics.
  """
  def render("validators_stats.json", %{
        total_validators: total_validators,
        active_validators: active_validators,
        total_stake: total_stake
      }) do
    %{
      total_validators: total_validators,
      active_validators: active_validators,
      total_stake: wei_to_string(total_stake)
    }
  end

  # Private functions

  @spec prepare_staking_event(StakingEvent.t(), map()) :: map()
  defp prepare_staking_event(%StakingEvent{} = event, validators_map) do
    validator = Map.get(validators_map, event.validator_id)
    secp_pubkey = if validator, do: validator.secp_pubkey, else: nil

    base = %{
      block_number: event.block_number,
      log_index: event.log_index,
      transaction_hash: to_string(event.transaction_hash),
      event_type: to_string(event.event_type),
      validator_id: event.validator_id,
      secp_pubkey: binary_to_hex(secp_pubkey),
      secp_address: secp_pubkey_to_address(secp_pubkey),
      delegator:
        Helper.address_with_info(
          nil,
          event.delegator_address,
          event.delegator_address_hash,
          true
        ),
      amount: wei_to_string(event.amount),
      timestamp: block_timestamp(event)
    }

    # Add optional fields if present
    base
    |> maybe_add_field(:epoch, event.epoch)
    |> maybe_add_field(:withdraw_id, event.withdraw_id)
    |> maybe_add_field(:activation_epoch, event.activation_epoch)
  end

  @spec prepare_validator(Validator.t()) :: map()
  defp prepare_validator(%Validator{} = validator) do
    %{
      validator_id: validator.validator_id,
      auth_address:
        Helper.address_with_info(
          nil,
          validator.auth_address,
          validator.auth_address_hash,
          true
        ),
      secp_pubkey: binary_to_hex(validator.secp_pubkey),
      secp_address: secp_pubkey_to_address(validator.secp_pubkey),
      total_stake: wei_to_string(validator.total_stake),
      consensus_stake: wei_to_string(validator.consensus_stake),
      commission: wei_to_string(validator.commission),
      unclaimed_rewards: wei_to_string(validator.unclaimed_rewards),
      validator_unclaimed_rewards: wei_to_string(validator.validator_unclaimed_rewards),
      flags: validator.flags,
      updated_at_block: validator.updated_at_block,
      updated_at: validator.updated_at
    }
  end

  defp wei_to_string(nil), do: nil
  defp wei_to_string(%Explorer.Chain.Wei{value: value}), do: to_string(value)
  defp wei_to_string(%Decimal{} = value), do: to_string(value)
  defp wei_to_string(value) when is_integer(value), do: to_string(value)

  defp binary_to_hex(nil), do: nil
  defp binary_to_hex(<<>>), do: nil
  defp binary_to_hex(binary) when is_binary(binary), do: Base.encode16(binary, case: :lower)

  defp block_timestamp(%{block: %{timestamp: timestamp}}) when not is_nil(timestamp) do
    DateTime.to_iso8601(timestamp)
  end

  defp block_timestamp(_), do: nil

  defp maybe_add_field(map, _key, nil), do: map
  defp maybe_add_field(map, key, value), do: Map.put(map, key, value)

  # Derives Ethereum address from SECP256k1 public key
  # Public key formats:
  # - 65 bytes: 0x04 prefix + 64 bytes (uncompressed)
  # - 64 bytes: just the x,y coordinates (uncompressed without prefix)
  # - 33 bytes: 0x02/0x03 prefix + 32 bytes (compressed)
  defp secp_pubkey_to_address(nil), do: nil
  defp secp_pubkey_to_address(<<>>), do: nil

  # Uncompressed with 0x04 prefix (65 bytes)
  defp secp_pubkey_to_address(<<0x04, pubkey_bytes::binary-size(64)>>) do
    derive_address_from_pubkey(pubkey_bytes)
  end

  # Uncompressed without prefix (64 bytes)
  defp secp_pubkey_to_address(<<pubkey_bytes::binary-size(64)>>) do
    derive_address_from_pubkey(pubkey_bytes)
  end

  # Compressed with 0x02 prefix (33 bytes)
  defp secp_pubkey_to_address(<<0x02, _::binary-size(32)>> = compressed) do
    decompress_and_derive(compressed)
  end

  # Compressed with 0x03 prefix (33 bytes)
  defp secp_pubkey_to_address(<<0x03, _::binary-size(32)>> = compressed) do
    decompress_and_derive(compressed)
  end

  defp secp_pubkey_to_address(_), do: nil

  defp decompress_and_derive(compressed_pubkey) do
    case ExSecp256k1.public_key_decompress(compressed_pubkey) do
      {:ok, <<0x04, pubkey_bytes::binary-size(64)>>} ->
        derive_address_from_pubkey(pubkey_bytes)

      _ ->
        nil
    end
  end

  defp derive_address_from_pubkey(pubkey_bytes) when byte_size(pubkey_bytes) == 64 do
    # Keccak-256 hash of the public key, take last 20 bytes
    <<_::binary-size(12), address_bytes::binary-size(20)>> = ExKeccak.hash_256(pubkey_bytes)
    "0x" <> Base.encode16(address_bytes, case: :lower)
  end
end
