defmodule Indexer.Fetcher.OnDemand.Transaction do
  @moduledoc """
  Fetches a transaction on-demand by fetching its containing block.
  This ensures full context including receipts, logs, and related data.

  The transaction fetch flow:
  1. Use eth_getTransactionByHash to get block_number
  2. Call OnDemand.Block.fetch_by_number() to fetch and index the entire block
  3. Return the transaction from the database
  """

  require Logger

  use GenServer
  use Indexer.Fetcher, restart: :permanent

  alias Explorer.Chain
  alias Explorer.Chain.Hash
  alias Explorer.Utility.RateLimiter
  alias Indexer.Fetcher.OnDemand.Block, as: BlockOnDemand

  @default_timeout :timer.seconds(45)

  # Transaction necessity by association for returning transaction with preloaded data
  @transaction_necessity_by_association %{
    :block => :optional,
    [from_address: [:names, :smart_contract, :proxy_implementations]] => :optional,
    [to_address: [:names, :smart_contract, :proxy_implementations]] => :optional,
    [created_contract_address: [:names, :smart_contract, :proxy_implementations]] => :optional,
    :token_transfers => :optional
  }

  @doc """
  Fetches a transaction by its hash. Synchronous operation - waits for fetch to complete.

  Returns `{:ok, transaction}` if successful, `{:error, reason}` otherwise.
  """
  @spec fetch_by_hash(String.t() | nil, Hash.Full.t()) ::
          {:ok, Explorer.Chain.Transaction.t()} | {:error, term()}
  def fetch_by_hash(caller \\ nil, hash) do
    case RateLimiter.check_rate(caller, :on_demand_block_fetch) do
      :allow ->
        try do
          GenServer.call(__MODULE__, {:fetch_by_hash, hash}, timeout())
        catch
          :exit, {:timeout, _} -> {:error, :timeout}
        end

      :deny ->
        {:error, :rate_limited}
    end
  end

  def start_link([init_opts, server_opts]) do
    GenServer.start_link(__MODULE__, init_opts, server_opts)
  end

  @impl true
  def init(json_rpc_named_arguments) do
    {:ok, %{json_rpc_named_arguments: json_rpc_named_arguments}}
  end

  @impl true
  def handle_call({:fetch_by_hash, hash}, _from, state) do
    result = do_fetch_by_hash(hash, state)
    {:reply, result, state}
  end

  # Private implementation

  defp do_fetch_by_hash(hash, state) do
    with {:ok, block_number} <- get_transaction_block_number(hash, state),
         # Fetch the entire block (which includes all transactions)
         {:ok, _block} <- BlockOnDemand.fetch_by_number(nil, block_number),
         # Now the transaction should be in the database
         {:ok, transaction} <-
           Chain.hash_to_transaction(
             hash,
             necessity_by_association: @transaction_necessity_by_association,
             api?: true
           ) do
      {:ok, transaction}
    else
      {:error, :pending_transaction} ->
        Logger.debug("OnDemand.Transaction: Transaction #{hash} is pending")
        {:error, :pending_transaction}

      {:error, :not_found} ->
        {:error, :not_found}

      {:error, reason} ->
        Logger.warning("OnDemand.Transaction fetch_by_hash failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp get_transaction_block_number(hash, state) do
    hash_string = to_string(hash)
    json_rpc_args = get_json_rpc_args(state)

    request = %{
      id: 0,
      jsonrpc: "2.0",
      method: "eth_getTransactionByHash",
      params: [hash_string]
    }

    case EthereumJSONRPC.json_rpc([request], json_rpc_args) do
      {:ok, [%{result: nil}]} ->
        {:error, :not_found}

      {:ok, [%{result: %{"blockNumber" => block_number}}]} when not is_nil(block_number) ->
        {:ok, EthereumJSONRPC.quantity_to_integer(block_number)}

      {:ok, [%{result: %{"blockNumber" => nil}}]} ->
        {:error, :pending_transaction}

      {:ok, [%{error: error}]} ->
        Logger.warning("OnDemand.Transaction RPC error: #{inspect(error)}")
        {:error, :rpc_error}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp get_json_rpc_args(state) do
    config = Application.get_env(:indexer, BlockOnDemand, [])
    archive_url = config[:archive_json_rpc_url]
    archive_fallback_url = config[:archive_fallback_json_rpc_url]

    cond do
      archive_url && archive_url != "" ->
        build_json_rpc_args(archive_url)

      archive_fallback_url && archive_fallback_url != "" ->
        build_json_rpc_args(archive_fallback_url)

      true ->
        state.json_rpc_named_arguments
    end
  end

  defp build_json_rpc_args(url) do
    [
      transport: EthereumJSONRPC.HTTP,
      transport_options: [
        http: EthereumJSONRPC.HTTP.HTTPoison,
        url: url,
        http_options: [recv_timeout: timeout(), timeout: timeout()]
      ]
    ]
  end

  defp timeout do
    Application.get_env(:indexer, __MODULE__)[:timeout] || @default_timeout
  end
end
