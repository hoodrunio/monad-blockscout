defmodule Explorer.Chain.Monad.StakingEvent do
  @moduledoc """
  Represents a Monad staking event from the staking precompile at 0x1000.

  Events tracked:
  - `claim`: ClaimRewards - when a delegator claims accumulated rewards
  - `validator_rewarded`: ValidatorRewarded - when block rewards are distributed
  - `delegate`: Delegate - when stake is added to a validator
  - `undelegate`: Undelegate - when stake withdrawal is initiated
  - `withdraw`: Withdraw - when stake is withdrawn after unbonding period
  """

  use Explorer.Schema

  import Ecto.Query
  import Explorer.PagingOptions, only: [default_paging_options: 0]

  alias Explorer.{Chain, PagingOptions, SortingHelper}
  alias Explorer.Chain.{Address, Block, Hash, Transaction, Wei}

  @type event_type :: :claim | :delegate | :undelegate | :withdraw | :validator_rewarded
  @event_types ~w(claim delegate undelegate withdraw validator_rewarded)a

  @required_attrs ~w(
    block_number
    log_index
    transaction_hash
    block_hash
    event_type
    validator_id
    delegator_address_hash
    amount
  )a

  @optional_attrs ~w(epoch withdraw_id activation_epoch)a

  @primary_key false
  typed_schema "monad_staking_events" do
    field(:block_number, :integer, primary_key: true, null: false)
    field(:log_index, :integer, primary_key: true, null: false)

    field(:event_type, Ecto.Enum, values: @event_types, null: false)
    field(:validator_id, :integer, null: false)
    field(:amount, Wei, null: false)
    field(:epoch, :integer)
    field(:withdraw_id, :integer)
    field(:activation_epoch, :integer)

    belongs_to(:delegator_address, Address,
      foreign_key: :delegator_address_hash,
      references: :hash,
      type: Hash.Address,
      null: false
    )

    belongs_to(:block, Block,
      foreign_key: :block_hash,
      references: :hash,
      type: Hash.Full,
      null: false
    )

    belongs_to(:transaction, Transaction,
      foreign_key: :transaction_hash,
      references: :hash,
      type: Hash.Full,
      null: false
    )

    timestamps()
  end

  @doc """
  Creates a changeset for a staking event.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = event, attrs) do
    event
    |> cast(attrs, @required_attrs ++ @optional_attrs)
    |> validate_required(@required_attrs)
    |> validate_inclusion(:event_type, @event_types)
    |> foreign_key_constraint(:delegator_address_hash)
    |> foreign_key_constraint(:block_hash)
    |> foreign_key_constraint(:transaction_hash)
    |> unique_constraint([:block_number, :log_index], name: :monad_staking_events_pkey)
  end

  @doc """
  Returns the list of valid event types.
  """
  @spec event_types() :: [event_type()]
  def event_types, do: @event_types

  # Query Helpers

  @default_sorting [desc: :block_number, desc: :log_index]

  @doc """
  Fetches staking events for a given address with pagination.
  """
  @spec get_by_address(Hash.Address.t(), keyword()) :: [t()]
  def get_by_address(address_hash, options \\ []) do
    paging_options = Keyword.get(options, :paging_options, default_paging_options())
    necessity_by_association = Keyword.get(options, :necessity_by_association, %{})
    sorting = Keyword.get(options, :sorting, [])
    event_types_filter = Keyword.get(options, :event_types, [])

    __MODULE__
    |> where([e], e.delegator_address_hash == ^address_hash)
    |> apply_event_type_filter(event_types_filter)
    |> Chain.join_associations(necessity_by_association)
    |> SortingHelper.apply_sorting(sorting, @default_sorting)
    |> SortingHelper.page_with_sorting(paging_options, sorting, @default_sorting)
    |> Chain.select_repo(options).all()
  end

  @doc """
  Fetches staking events for a given validator ID with pagination.
  """
  @spec get_by_validator(integer(), keyword()) :: [t()]
  def get_by_validator(validator_id, options \\ []) do
    paging_options = Keyword.get(options, :paging_options, default_paging_options())
    necessity_by_association = Keyword.get(options, :necessity_by_association, %{})
    event_types_filter = Keyword.get(options, :event_types, [])

    __MODULE__
    |> where([e], e.validator_id == ^validator_id)
    |> apply_event_type_filter(event_types_filter)
    |> order_by([e], desc: e.block_number, desc: e.log_index)
    |> Chain.join_associations(necessity_by_association)
    |> SortingHelper.page_with_sorting(paging_options, [], @default_sorting)
    |> Chain.select_repo(options).all()
  end

  @doc """
  Calculates total claimed rewards for an address.
  """
  @spec aggregate_rewards_by_address(Hash.Address.t(), keyword()) :: Decimal.t()
  def aggregate_rewards_by_address(address_hash, options \\ []) do
    __MODULE__
    |> where([e], e.delegator_address_hash == ^address_hash)
    |> where([e], e.event_type == :claim)
    |> select([e], sum(e.amount))
    |> Chain.select_repo(options).one()
    |> Kernel.||(Decimal.new(0))
  end

  @doc """
  Calculates total delegated amount for an address.
  """
  @spec aggregate_delegations_by_address(Hash.Address.t(), keyword()) :: Decimal.t()
  def aggregate_delegations_by_address(address_hash, options \\ []) do
    delegated =
      __MODULE__
      |> where([e], e.delegator_address_hash == ^address_hash)
      |> where([e], e.event_type == :delegate)
      |> select([e], sum(e.amount))
      |> Chain.select_repo(options).one()
      |> Kernel.||(Decimal.new(0))

    undelegated =
      __MODULE__
      |> where([e], e.delegator_address_hash == ^address_hash)
      |> where([e], e.event_type in [:undelegate, :withdraw])
      |> select([e], sum(e.amount))
      |> Chain.select_repo(options).one()
      |> Kernel.||(Decimal.new(0))

    Decimal.sub(delegated, undelegated)
  end

  @doc """
  Gets event count by type for an address.
  """
  @spec count_by_address_and_type(Hash.Address.t(), keyword()) :: map()
  def count_by_address_and_type(address_hash, options \\ []) do
    __MODULE__
    |> where([e], e.delegator_address_hash == ^address_hash)
    |> group_by([e], e.event_type)
    |> select([e], {e.event_type, count(e.log_index)})
    |> Chain.select_repo(options).all()
    |> Map.new()
  end

  @doc """
  Returns pagination parameters for the next page.
  """
  @spec next_page_params(t()) :: map()
  def next_page_params(%__MODULE__{block_number: block_number, log_index: log_index}) do
    %{block_number: block_number, log_index: log_index}
  end

  @doc """
  Returns the last (highest) block number that has staking events.
  Used for catchup/backfill to determine where to resume from.
  """
  @spec get_last_block_number(keyword()) :: non_neg_integer() | nil
  def get_last_block_number(options \\ []) do
    __MODULE__
    |> select([e], max(e.block_number))
    |> Chain.select_repo(options).one()
  end

  # Private functions

  defp apply_event_type_filter(query, []), do: query

  defp apply_event_type_filter(query, types) when is_list(types) do
    where(query, [e], e.event_type in ^types)
  end
end
