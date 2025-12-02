defmodule Explorer.Chain.Monad.DelegatorPosition do
  @moduledoc """
  Represents a delegator's position with a specific validator.

  This table caches delegator stake and reward information fetched from the
  staking precompile via getDelegator(validatorId, address) calls.
  Used to provide real-time staking stats even when staking events haven't been indexed.

  Fields:
  - `delegator_address_hash`: The delegator's address
  - `validator_id`: The validator ID they delegated to
  - `stake`: Current delegated stake amount
  - `unclaimed_rewards`: Accumulated unclaimed rewards
  - `updated_at_block`: Block number when this snapshot was taken
  """

  use Explorer.Schema

  import Ecto.Query

  alias Explorer.Chain
  alias Explorer.Chain.{Address, Hash, Wei}

  @required_attrs ~w(
    delegator_address_hash
    validator_id
    stake
    updated_at_block
  )a

  @optional_attrs ~w(unclaimed_rewards)a

  @primary_key false
  typed_schema "monad_delegator_positions" do
    field(:validator_id, :integer, primary_key: true, null: false)
    field(:stake, Wei, null: false)
    field(:unclaimed_rewards, Wei)
    field(:updated_at_block, :integer, null: false)

    belongs_to(:delegator_address, Address,
      foreign_key: :delegator_address_hash,
      references: :hash,
      type: Hash.Address,
      primary_key: true,
      null: false
    )

    timestamps()
  end

  @doc """
  Creates a changeset for a delegator position record.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = position, attrs) do
    position
    |> cast(attrs, @required_attrs ++ @optional_attrs)
    |> validate_required(@required_attrs)
    |> validate_number(:validator_id, greater_than: 0)
    |> foreign_key_constraint(:delegator_address_hash)
    |> unique_constraint([:delegator_address_hash, :validator_id],
      name: :monad_delegator_positions_pkey
    )
  end

  # Query Helpers

  @doc """
  Fetches all positions for a given delegator address.
  """
  @spec get_by_address(Hash.Address.t(), keyword()) :: [t()]
  def get_by_address(address_hash, options \\ []) do
    __MODULE__
    |> where([p], p.delegator_address_hash == ^address_hash)
    |> order_by([p], asc: p.validator_id)
    |> Chain.select_repo(options).all()
  end

  @doc """
  Fetches a specific position for a delegator and validator.
  """
  @spec get_by_address_and_validator(Hash.Address.t(), integer(), keyword()) :: t() | nil
  def get_by_address_and_validator(address_hash, validator_id, options \\ []) do
    __MODULE__
    |> where([p], p.delegator_address_hash == ^address_hash and p.validator_id == ^validator_id)
    |> Chain.select_repo(options).one()
  end

  @doc """
  Calculates total stake across all validators for an address.
  """
  @spec total_stake_by_address(Hash.Address.t(), keyword()) :: Decimal.t()
  def total_stake_by_address(address_hash, options \\ []) do
    __MODULE__
    |> where([p], p.delegator_address_hash == ^address_hash)
    |> select([p], sum(p.stake))
    |> Chain.select_repo(options).one()
    |> Kernel.||(Decimal.new(0))
  end

  @doc """
  Calculates total unclaimed rewards across all validators for an address.
  """
  @spec total_unclaimed_rewards_by_address(Hash.Address.t(), keyword()) :: Decimal.t()
  def total_unclaimed_rewards_by_address(address_hash, options \\ []) do
    __MODULE__
    |> where([p], p.delegator_address_hash == ^address_hash)
    |> select([p], sum(p.unclaimed_rewards))
    |> Chain.select_repo(options).one()
    |> Kernel.||(Decimal.new(0))
  end

  # Cache TTL: 5 minutes
  @cache_ttl_seconds 300

  @doc """
  Checks if positions exist and are fresh (updated within cache TTL of 5 minutes).
  """
  @spec has_fresh_positions?(Hash.Address.t(), keyword()) :: boolean()
  def has_fresh_positions?(address_hash, options \\ []) do
    stale_threshold = DateTime.add(DateTime.utc_now(), -@cache_ttl_seconds, :second)

    __MODULE__
    |> where([p], p.delegator_address_hash == ^address_hash)
    |> where([p], p.updated_at >= ^stale_threshold)
    |> Chain.select_repo(options).exists?()
  end

  @doc """
  Returns validator IDs that an address has delegated to.
  """
  @spec validator_ids_by_address(Hash.Address.t(), keyword()) :: [integer()]
  def validator_ids_by_address(address_hash, options \\ []) do
    __MODULE__
    |> where([p], p.delegator_address_hash == ^address_hash)
    |> select([p], p.validator_id)
    |> Chain.select_repo(options).all()
  end
end
