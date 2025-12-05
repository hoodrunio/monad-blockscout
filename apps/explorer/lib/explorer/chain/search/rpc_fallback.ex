defmodule Explorer.Chain.Search.RPCFallback do
  @moduledoc """
  Behaviour for RPC fallback in search.

  This module defines the interface for on-demand fetching from RPC when
  database returns empty results. The actual implementation is provided
  by the Indexer app (Indexer.Search.RPCFallbackImpl) which has access
  to OnDemand fetchers.

  Supported operations:
  - Addresses (balance + code)
  - Transactions (via block fetch)
  - Blocks (by hash or number)
  """

  # Behaviour callbacks - implemented by Indexer.Search.RPCFallbackImpl
  @callback fetch_address(term()) :: [map()]
  @callback fetch_transaction(term()) :: [map()]
  @callback fetch_block_by_hash(term()) :: [map()]
  @callback fetch_block_by_number(non_neg_integer()) :: [map()]

  @doc """
  Get the configured implementation module.
  """
  @spec impl() :: module() | nil
  def impl do
    Application.get_env(:explorer, __MODULE__)[:implementation]
  end

  @doc """
  Check if RPC fallback is enabled.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    Application.get_env(:explorer, __MODULE__)[:enabled] || false
  end

  @doc """
  Fetch an address from RPC by its hash.
  Delegates to the configured implementation module.
  Returns search result format or empty list if not found/error/disabled.
  """
  @spec fetch_address(term()) :: [map()]
  def fetch_address(address_hash) do
    if enabled?() and impl() do
      impl().fetch_address(address_hash)
    else
      []
    end
  end

  @doc """
  Fetch a transaction from RPC by its hash.
  Delegates to the configured implementation module.
  Returns search result format or empty list if not found/error/disabled.
  """
  @spec fetch_transaction(term()) :: [map()]
  def fetch_transaction(tx_hash) do
    if enabled?() and impl() do
      impl().fetch_transaction(tx_hash)
    else
      []
    end
  end

  @doc """
  Fetch a block from RPC by its hash.
  Delegates to the configured implementation module.
  Returns search result format or empty list if not found/error/disabled.
  """
  @spec fetch_block_by_hash(term()) :: [map()]
  def fetch_block_by_hash(block_hash) do
    if enabled?() and impl() do
      impl().fetch_block_by_hash(block_hash)
    else
      []
    end
  end

  @doc """
  Fetch a block from RPC by its number.
  Delegates to the configured implementation module.
  Returns search result format or empty list if not found/error/disabled.
  """
  @spec fetch_block_by_number(non_neg_integer()) :: [map()]
  def fetch_block_by_number(block_number) do
    if enabled?() and impl() do
      impl().fetch_block_by_number(block_number)
    else
      []
    end
  end
end
