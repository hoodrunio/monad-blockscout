defmodule Explorer.Chain.Search.RPCFallback do
  @moduledoc """
  RPC fallback functions for search when database returns empty results.

  This module provides on-demand fetching from RPC for:
  - Addresses (balance + code)
  - Transactions (via block fetch)
  - Blocks (by hash or number)

  Results are persisted to the database for future searches.
  """

  require Logger

  alias EthereumJSONRPC
  alias Explorer.Chain
  alias Explorer.Chain.{Address, Block, Transaction}
  alias Indexer.Fetcher.OnDemand.Block, as: BlockOnDemand
  alias Indexer.Fetcher.OnDemand.Transaction, as: TransactionOnDemand

  @doc """
  Check if RPC fallback is enabled.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    Application.get_env(:explorer, __MODULE__)[:enabled] || false
  end

  @doc """
  Fetch an address from RPC by its hash.
  Returns search result format or empty list if not found/error.
  """
  @spec fetch_address(EthereumJSONRPC.address()) :: [map()]
  def fetch_address(address_hash) do
    if enabled?() do
      do_fetch_address(address_hash)
    else
      []
    end
  end

  @doc """
  Fetch a transaction from RPC by its hash.
  Uses OnDemand.Transaction which fetches the entire block for full context.
  Returns search result format or empty list if not found/error.
  """
  @spec fetch_transaction(EthereumJSONRPC.hash()) :: [map()]
  def fetch_transaction(tx_hash) do
    if enabled?() do
      do_fetch_transaction(tx_hash)
    else
      []
    end
  end

  @doc """
  Fetch a block from RPC by its hash.
  Uses OnDemand.Block for full indexing.
  Returns search result format or empty list if not found/error.
  """
  @spec fetch_block_by_hash(EthereumJSONRPC.hash()) :: [map()]
  def fetch_block_by_hash(block_hash) do
    if enabled?() do
      do_fetch_block_by_hash(block_hash)
    else
      []
    end
  end

  @doc """
  Fetch a block from RPC by its number.
  Uses OnDemand.Block for full indexing.
  Returns search result format or empty list if not found/error.
  """
  @spec fetch_block_by_number(non_neg_integer()) :: [map()]
  def fetch_block_by_number(block_number) do
    if enabled?() do
      do_fetch_block_by_number(block_number)
    else
      []
    end
  end

  # Private implementation

  defp do_fetch_address(address_hash) do
    json_rpc_args = json_rpc_named_arguments()
    address_hash_string = to_string(address_hash)

    with {:ok, balance_result} <-
           EthereumJSONRPC.fetch_balances(
             [%{block_quantity: "latest", hash_data: address_hash_string}],
             json_rpc_args
           ),
         {:ok, code_result} <-
           EthereumJSONRPC.fetch_codes(
             [%{block_quantity: "latest", address: address_hash_string}],
             json_rpc_args
           ) do
      balance = extract_balance(balance_result)
      code = extract_code(code_result)

      # Save address to database
      case save_address_to_db(address_hash, balance, code) do
        {:ok, address} ->
          [build_address_search_result(address, code)]

        {:error, reason} ->
          Logger.warning("RPCFallback: Failed to save address #{address_hash_string}: #{inspect(reason)}")
          # Still return result even if DB save fails
          [build_address_search_result_from_rpc(address_hash, balance, code)]
      end
    else
      {:error, reason} ->
        Logger.debug("RPCFallback: Failed to fetch address #{address_hash_string}: #{inspect(reason)}")
        []
    end
  end

  defp do_fetch_transaction(tx_hash) do
    case TransactionOnDemand.fetch_by_hash(nil, tx_hash) do
      {:ok, %Transaction{} = transaction} ->
        [build_transaction_search_result(transaction)]

      {:error, :pending_transaction} ->
        # Return pending transaction indicator
        [build_pending_transaction_search_result(tx_hash)]

      {:error, reason} ->
        Logger.debug("RPCFallback: Failed to fetch transaction #{tx_hash}: #{inspect(reason)}")
        []
    end
  end

  defp do_fetch_block_by_hash(block_hash) do
    case BlockOnDemand.fetch_by_hash(nil, block_hash) do
      {:ok, %Block{} = block} ->
        [build_block_search_result(block)]

      {:error, reason} ->
        Logger.debug("RPCFallback: Failed to fetch block by hash #{block_hash}: #{inspect(reason)}")
        []
    end
  end

  defp do_fetch_block_by_number(block_number) do
    case BlockOnDemand.fetch_by_number(nil, block_number) do
      {:ok, %Block{} = block} ->
        [build_block_search_result(block)]

      {:error, reason} ->
        Logger.debug("RPCFallback: Failed to fetch block by number #{block_number}: #{inspect(reason)}")
        []
    end
  end

  # Helper functions

  defp json_rpc_named_arguments do
    Application.get_env(:explorer, :json_rpc_named_arguments)
  end

  defp extract_balance(%EthereumJSONRPC.FetchedBalances{params_list: [%{value: value} | _]}), do: value
  defp extract_balance(_), do: 0

  defp extract_code(%EthereumJSONRPC.FetchedCodes{params_list: [%{code: code} | _]}), do: code
  defp extract_code(_), do: nil

  defp save_address_to_db(address_hash, balance, code) do
    # Determine if it's a contract based on code
    contract_code =
      case code do
        nil -> nil
        "0x" -> nil
        "" -> nil
        code_hex -> code_hex
      end

    address_params = %{
      hash: address_hash,
      fetched_coin_balance: balance,
      fetched_coin_balance_block_number: get_latest_block_number(),
      contract_code: contract_code
    }

    case Chain.import(%{
           addresses: %{
             params: [address_params],
             on_conflict: :nothing
           }
         }) do
      {:ok, %{addresses: [address | _]}} ->
        {:ok, address}

      {:ok, %{addresses: []}} ->
        # Address already exists, fetch it
        Chain.hash_to_address(address_hash)

      {:error, _} = error ->
        error
    end
  end

  defp get_latest_block_number do
    case Explorer.Chain.Cache.BlockNumber.get_max() do
      nil -> 0
      number -> number
    end
  end

  defp build_address_search_result(%Address{} = address, code) do
    is_contract = is_contract?(code)

    %{
      address_hash: address.hash,
      type: if(is_contract, do: "contract", else: "address"),
      name: nil,
      inserted_at: address.inserted_at,
      verified: false,
      certified: false,
      priority: 0,
      from_rpc: true
    }
  end

  defp build_address_search_result_from_rpc(address_hash, _balance, code) do
    is_contract = is_contract?(code)

    %{
      address_hash: address_hash,
      type: if(is_contract, do: "contract", else: "address"),
      name: nil,
      inserted_at: DateTime.utc_now(),
      verified: false,
      certified: false,
      priority: 0,
      from_rpc: true
    }
  end

  defp build_transaction_search_result(%Transaction{} = tx) do
    %{
      tx_hash: tx.hash,
      type: "transaction",
      block_number: tx.block_number,
      inserted_at: tx.inserted_at,
      timestamp: tx.block_timestamp,
      from_rpc: true
    }
  end

  defp build_pending_transaction_search_result(tx_hash) do
    %{
      tx_hash: tx_hash,
      type: "transaction",
      block_number: nil,
      inserted_at: DateTime.utc_now(),
      timestamp: nil,
      pending: true,
      from_rpc: true
    }
  end

  defp build_block_search_result(%Block{} = block) do
    %{
      block_hash: block.hash,
      block_number: block.number,
      type: "block",
      inserted_at: block.inserted_at,
      timestamp: block.timestamp,
      from_rpc: true
    }
  end

  defp is_contract?(nil), do: false
  defp is_contract?("0x"), do: false
  defp is_contract?(""), do: false
  defp is_contract?(_), do: true
end
