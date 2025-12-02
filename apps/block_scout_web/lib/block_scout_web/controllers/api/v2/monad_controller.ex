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
  alias Explorer.Chain.Monad.{StakingEvent, Validator}

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

      conn
      |> render(:staking_events, %{
        events: events,
        next_page_params: next_page_params
      })
    end
  end

  @doc """
  GET /api/v2/addresses/:address_hash/monad/staking-stats

  Returns aggregated staking statistics for an address.
  """
  @spec staking_stats(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def staking_stats(conn, %{"address_hash_param" => address_hash_string}) do
    with {:ok, address_hash} <- Hash.Address.cast(address_hash_string) do
      total_rewards_claimed = StakingEvent.aggregate_rewards_by_address(address_hash, @api_true)
      total_delegated = StakingEvent.aggregate_delegations_by_address(address_hash, @api_true)
      event_counts = StakingEvent.count_by_address_and_type(address_hash, @api_true)

      conn
      |> render(:staking_stats, %{
        total_rewards_claimed: total_rewards_claimed,
        total_delegated: total_delegated,
        event_counts: event_counts
      })
    end
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

      conn
      |> render(:staking_events, %{
        events: events,
        next_page_params: next_page_params
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
