defmodule Explorer.Chain.Monad.Validator do
  @moduledoc """
  Represents a Monad validator state snapshot from the staking precompile.

  Validator data is fetched periodically via getValidator(uint64) calls
  to the staking precompile at 0x1000.

  Fields:
  - `validator_id`: Unique identifier assigned when validator joins
  - `auth_address_hash`: Delegator address with authority over validator stake
  - `total_stake`: Total stake including all delegations (execution view)
  - `consensus_stake`: Active stake in consensus
  - `commission`: Proportion of block reward charged as commission (scaled by 1e18)
  - `unclaimed_rewards`: Accumulated unclaimed rewards
  - `flags`: Validator status flags
  - `secp_pubkey`: SECP256k1 public key for consensus
  - `bls_pubkey`: BLS public key for consensus
  - `updated_at_block`: Block number when this snapshot was taken
  """

  use Explorer.Schema

  import Ecto.Query

  alias Explorer.Chain
  alias Explorer.Chain.{Address, Hash, Wei}

  @required_attrs ~w(
    validator_id
    auth_address_hash
    total_stake
    commission
    updated_at_block
  )a

  @optional_attrs ~w(
    consensus_stake
    unclaimed_rewards
    flags
    secp_pubkey
    bls_pubkey
  )a

  @primary_key false
  typed_schema "monad_validators" do
    field(:validator_id, :integer, primary_key: true, null: false)
    field(:total_stake, Wei, null: false)
    field(:consensus_stake, Wei)
    # Commission is scaled by 1e18 (Wei-like): 10^18 = 100%, 10^17 = 10%, 10^16 = 1%
    field(:commission, Wei, null: false)
    field(:unclaimed_rewards, Wei)
    field(:flags, :integer)
    field(:secp_pubkey, :binary)
    field(:bls_pubkey, :binary)
    field(:updated_at_block, :integer, null: false)

    belongs_to(:auth_address, Address,
      foreign_key: :auth_address_hash,
      references: :hash,
      type: Hash.Address,
      null: false
    )

    timestamps()
  end

  @doc """
  Creates a changeset for a validator record.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = validator, attrs) do
    validator
    |> cast(attrs, @required_attrs ++ @optional_attrs)
    |> validate_required(@required_attrs)
    |> validate_number(:validator_id, greater_than: 0)
    # Note: commission is Wei type, validate_number doesn't work with Wei
    |> foreign_key_constraint(:auth_address_hash)
    |> unique_constraint(:validator_id, name: :monad_validators_pkey)
  end

  # Query Helpers

  @doc """
  Fetches all validators ordered by validator_id with pagination support.
  """
  @spec get_all(keyword()) :: [t()]
  def get_all(options \\ []) do
    necessity_by_association = Keyword.get(options, :necessity_by_association, %{})
    paging_options = Keyword.get(options, :paging_options, Explorer.PagingOptions.default_paging_options())

    __MODULE__
    |> order_by([v], asc: v.validator_id)
    |> page_validators(paging_options)
    |> Chain.join_associations(necessity_by_association)
    |> Chain.select_repo(options).all()
  end

  defp page_validators(query, %Explorer.PagingOptions{key: nil}), do: query

  defp page_validators(query, %Explorer.PagingOptions{key: %{validator_id: validator_id}}) do
    where(query, [v], v.validator_id > ^validator_id)
  end

  defp page_validators(query, _), do: query

  @doc """
  Fetches a validator by ID.
  """
  @spec get_by_id(integer(), keyword()) :: t() | nil
  def get_by_id(validator_id, options \\ []) do
    necessity_by_association = Keyword.get(options, :necessity_by_association, %{})

    __MODULE__
    |> where([v], v.validator_id == ^validator_id)
    |> Chain.join_associations(necessity_by_association)
    |> Chain.select_repo(options).one()
  end

  @doc """
  Fetches validators by auth address.
  """
  @spec get_by_auth_address(Hash.Address.t(), keyword()) :: [t()]
  def get_by_auth_address(address_hash, options \\ []) do
    necessity_by_association = Keyword.get(options, :necessity_by_association, %{})

    __MODULE__
    |> where([v], v.auth_address_hash == ^address_hash)
    |> order_by([v], asc: v.validator_id)
    |> Chain.join_associations(necessity_by_association)
    |> Chain.select_repo(options).all()
  end

  @doc """
  Counts total validators.
  """
  @spec count(keyword()) :: non_neg_integer()
  def count(options \\ []) do
    __MODULE__
    |> Chain.select_repo(options).aggregate(:count)
  end

  @doc """
  Gets total stake across all validators.
  """
  @spec total_stake(keyword()) :: Decimal.t()
  def total_stake(options \\ []) do
    __MODULE__
    |> select([v], sum(v.total_stake))
    |> Chain.select_repo(options).one()
    |> Kernel.||(Decimal.new(0))
  end

  @doc """
  Gets validators with stake above a threshold.
  """
  @spec get_active_validators(keyword()) :: [t()]
  def get_active_validators(options \\ []) do
    # Active validators have non-zero consensus stake
    necessity_by_association = Keyword.get(options, :necessity_by_association, %{})

    __MODULE__
    |> where([v], not is_nil(v.consensus_stake) and v.consensus_stake > 0)
    |> order_by([v], desc: v.consensus_stake)
    |> Chain.join_associations(necessity_by_association)
    |> Chain.select_repo(options).all()
  end

  @doc """
  Returns pagination parameters for the next page.
  """
  @spec next_page_params(t()) :: map()
  def next_page_params(%__MODULE__{validator_id: validator_id}) do
    %{validator_id: validator_id}
  end
end
