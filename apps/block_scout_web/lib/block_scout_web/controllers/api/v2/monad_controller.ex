defmodule BlockScoutWeb.API.V2.MonadController do
  @moduledoc """
  API V2 controller for Monad-specific endpoints.

  Provides endpoints for:
  - Staking events for addresses and validators
  - Staking statistics
  - Validator information
  """

  use BlockScoutWeb, :controller

  import BlockScoutWeb.Chain,
    only: [
      next_page_params: 4,
      split_list_by_page: 1,
      paging_options: 1
    ]

  import Explorer.PagingOptions, only: [default_paging_options: 0]

  alias Explorer.Chain.Hash
  alias Explorer.Chain.Monad.{DelegatorPosition, StakingEvent, Validator}
  alias Indexer.Fetcher.Monad.DelegatorOnDemand

  action_fallback(BlockScoutWeb.API.V2.FallbackController)

  @api_true [api?: true]

  @doc """
  GET /api/v2/addresses/:address_hash/monad/staking-events

  Returns staking events for a given address with pagination.
  """
  @spec staking_events(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def staking_events(conn, %{"address_hash_param" => address_hash_string} = params) do
    with {:ok, address_hash} <- Hash.Address.cast(address_hash_string) do
      options =
        @api_true
        |> Keyword.merge(paging_options(params))
        |> Keyword.merge(parse_event_type_filter(params))
        |> Keyword.merge(
          necessity_by_association: %{
            :transaction => :optional,
            :block => :optional
          }
        )

      {events, next_page} =
        address_hash
        |> StakingEvent.get_by_address(options)
        |> split_list_by_page()

      next_page_params =
        next_page_params(
          next_page,
          events,
          params,
          &StakingEvent.next_page_params/1
        )

      # Fetch validator info for secp_address lookup
      validators_map = get_validators_map_from_events(events)

      conn
      |> render(:staking_events, %{
        events: events,
        next_page_params: next_page_params,
        validators_map: validators_map
      })
    end
  end

  @doc """
  GET /api/v2/addresses/:address_hash/monad/staking-stats

  Returns aggregated staking statistics for an address.
  Combines data from indexed events and cached delegator positions.
  If cached positions are stale or missing, fetches from RPC.
  """
  @spec staking_stats(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def staking_stats(conn, %{"address_hash_param" => address_hash_string}) do
    with {:ok, address_hash} <- Hash.Address.cast(address_hash_string) do
      # Get event-based statistics (from indexed events)
      total_rewards_claimed = StakingEvent.aggregate_rewards_by_address(address_hash, @api_true)
      event_counts = StakingEvent.count_by_address_and_type(address_hash, @api_true)

      # Get position-based statistics (from cache or RPC)
      {total_delegated, total_unclaimed_rewards, positions} =
        get_position_stats(address_hash)

      # Fetch validator info for secp_address lookup
      validators_map = get_validators_map(positions)

      conn
      |> render(:staking_stats, %{
        total_rewards_claimed: total_rewards_claimed,
        total_delegated: total_delegated,
        total_unclaimed_rewards: total_unclaimed_rewards,
        event_counts: event_counts,
        positions: positions,
        validators_map: validators_map
      })
    end
  end

  # Get position stats from cache or RPC
  defp get_position_stats(address_hash) do
    # Check if we have fresh cached positions (5 minute TTL)
    if DelegatorPosition.has_fresh_positions?(address_hash, @api_true) do
      # Use cached data
      positions = DelegatorPosition.get_by_address(address_hash, @api_true)
      total_delegated = DelegatorPosition.total_stake_by_address(address_hash, @api_true)
      total_unclaimed = DelegatorPosition.total_unclaimed_rewards_by_address(address_hash, @api_true)

      {total_delegated, total_unclaimed, format_positions(positions)}
    else
      # Fetch from RPC and cache
      case DelegatorOnDemand.fetch_and_cache(address_hash) do
        {:ok, positions} when positions != [] ->
          total_delegated =
            positions
            |> Enum.map(& &1.stake)
            |> Enum.reduce(Decimal.new(0), fn stake, acc ->
              Decimal.add(acc, Decimal.new(stake))
            end)

          total_unclaimed =
            positions
            |> Enum.map(&(&1[:unclaimed_rewards] || 0))
            |> Enum.reduce(Decimal.new(0), fn rewards, acc ->
              Decimal.add(acc, Decimal.new(rewards))
            end)

          {total_delegated, total_unclaimed, format_raw_positions(positions)}

        _ ->
          # Fallback to event-based calculation if RPC fails
          total_delegated = StakingEvent.aggregate_delegations_by_address(address_hash, @api_true)
          {total_delegated, Decimal.new(0), []}
      end
    end
  end

  defp format_positions(positions) do
    Enum.map(positions, fn pos ->
      %{
        validator_id: pos.validator_id,
        stake: pos.stake,
        unclaimed_rewards: pos.unclaimed_rewards
      }
    end)
  end

  defp format_raw_positions(positions) do
    Enum.map(positions, fn pos ->
      %{
        validator_id: pos.validator_id,
        stake: pos.stake,
        unclaimed_rewards: pos[:unclaimed_rewards]
      }
    end)
  end

  # Fetch validators by IDs and create a map for quick lookup
  defp get_validators_map([]), do: %{}

  defp get_validators_map(positions) do
    validator_ids = Enum.map(positions, & &1.validator_id) |> Enum.uniq()

    validator_ids
    |> Validator.get_by_ids(@api_true)
    |> Map.new(fn v -> {v.validator_id, v} end)
  end

  # Fetch validators from events
  defp get_validators_map_from_events([]), do: %{}

  defp get_validators_map_from_events(events) do
    validator_ids =
      events
      |> Enum.map(& &1.validator_id)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    validator_ids
    |> Validator.get_by_ids(@api_true)
    |> Map.new(fn v -> {v.validator_id, v} end)
  end

  @doc """
  GET /api/v2/monad/validators

  Returns list of all validators with pagination.
  """
  @spec validators(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def validators(conn, params) do
    options =
      @api_true
      |> Keyword.merge(paging_options(params))
      |> Keyword.merge(
        necessity_by_association: %{
          :auth_address => :optional
        }
      )

    {validators, next_page} =
      options
      |> Validator.get_all()
      |> split_list_by_page()

    next_page_params =
      next_page_params(
        next_page,
        validators,
        params,
        &Validator.next_page_params/1
      )

    conn
    |> render(:validators, %{
      validators: validators,
      next_page_params: next_page_params
    })
  end

  @doc """
  GET /api/v2/monad/validators/:validator_id

  Returns details for a specific validator.
  """
  @spec validator(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def validator(conn, %{"validator_id" => validator_id_string}) do
    with {validator_id, ""} <- Integer.parse(validator_id_string),
         validator when not is_nil(validator) <-
           Validator.get_by_id(validator_id,
             api?: true,
             necessity_by_association: %{
               :auth_address => :optional
             }
           ) do
      conn
      |> render(:validator, %{validator: validator})
    else
      _ -> {:error, :not_found}
    end
  end

  @doc """
  GET /api/v2/monad/validators/:validator_id/staking-events

  Returns staking events for a specific validator.
  """
  @spec validator_staking_events(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def validator_staking_events(conn, %{"validator_id" => validator_id_string} = params) do
    with {validator_id, ""} <- Integer.parse(validator_id_string) do
      options =
        @api_true
        |> Keyword.merge(paging_options(params))
        |> Keyword.merge(
          necessity_by_association: %{
            :transaction => :optional,
            :block => :optional
          }
        )

      {events, next_page} =
        validator_id
        |> StakingEvent.get_by_validator(options)
        |> split_list_by_page()

      next_page_params =
        next_page_params(
          next_page,
          events,
          params,
          &StakingEvent.next_page_params/1
        )

      # Fetch validator info for secp_address lookup
      validators_map = get_validators_map_from_events(events)

      conn
      |> render(:staking_events, %{
        events: events,
        next_page_params: next_page_params,
        validators_map: validators_map
      })
    else
      _ -> {:error, :not_found}
    end
  end

  @doc """
  GET /api/v2/monad/validators/stats

  Returns aggregated statistics about all validators.
  """
  @spec validators_stats(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def validators_stats(conn, _params) do
    total_validators = Validator.count(@api_true)
    active_validators = Validator.get_active_validators(@api_true) |> length()
    total_stake = Validator.total_stake(@api_true)

    conn
    |> render(:validators_stats, %{
      total_validators: total_validators,
      active_validators: active_validators,
      total_stake: total_stake
    })
  end

  # Private helpers

  defp parse_event_type_filter(%{"type" => type_string}) when is_binary(type_string) do
    types =
      type_string
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.filter(&(&1 in ~w(claim delegate undelegate withdraw validator_rewarded)))
      |> Enum.map(&String.to_atom/1)

    [event_types: types]
  end

  defp parse_event_type_filter(_), do: [event_types: []]
end
