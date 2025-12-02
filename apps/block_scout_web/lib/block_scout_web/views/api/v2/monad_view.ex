defmodule BlockScoutWeb.API.V2.MonadView do
  @moduledoc """
  View functions for rendering Monad-related data in JSON format.
  """

  use BlockScoutWeb, :view

  alias BlockScoutWeb.API.V2.Helper
  alias Explorer.Chain.Monad.{StakingEvent, Validator}

  @doc """
  Renders a list of staking events with pagination.
  """
  def render("staking_events.json", %{
        events: events,
        next_page_params: next_page_params
      }) do
    %{
      items: Enum.map(events, &prepare_staking_event/1),
      next_page_params: next_page_params
    }
  end

  @doc """
  Renders staking statistics for an address.
  """
  def render("staking_stats.json", %{
        total_rewards_claimed: total_rewards_claimed,
        total_delegated: total_delegated,
        event_counts: event_counts
      }) do
    %{
      total_rewards_claimed: to_string(total_rewards_claimed),
      total_delegated: to_string(total_delegated),
      event_counts:
        Map.new(event_counts, fn {type, count} ->
          {to_string(type), count}
        end)
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

  @spec prepare_staking_event(StakingEvent.t()) :: map()
  defp prepare_staking_event(%StakingEvent{} = event) do
    base = %{
      block_number: event.block_number,
      log_index: event.log_index,
      transaction_hash: to_string(event.transaction_hash),
      event_type: to_string(event.event_type),
      validator_id: event.validator_id,
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
      total_stake: wei_to_string(validator.total_stake),
      consensus_stake: wei_to_string(validator.consensus_stake),
      commission: wei_to_string(validator.commission),
      unclaimed_rewards: wei_to_string(validator.unclaimed_rewards),
      flags: validator.flags,
      updated_at_block: validator.updated_at_block,
      updated_at: validator.updated_at
    }
  end

  defp wei_to_string(nil), do: nil
  defp wei_to_string(%Explorer.Chain.Wei{value: value}), do: to_string(value)
  defp wei_to_string(%Decimal{} = value), do: to_string(value)
  defp wei_to_string(value) when is_integer(value), do: to_string(value)

  defp block_timestamp(%{block: %{timestamp: timestamp}}) when not is_nil(timestamp) do
    DateTime.to_iso8601(timestamp)
  end

  defp block_timestamp(_), do: nil

  defp maybe_add_field(map, _key, nil), do: map
  defp maybe_add_field(map, key, value), do: Map.put(map, key, value)
end
