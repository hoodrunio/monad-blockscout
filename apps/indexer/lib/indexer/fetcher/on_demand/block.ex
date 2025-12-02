defmodule Indexer.Fetcher.OnDemand.Block do
  @moduledoc """
  Fetches a block on-demand when requested via API and not found in database.
  Performs full indexing including transactions, receipts, logs, and token transfers.

  Supports multiple archive RPCs with round-robin load balancing:
  - ON_DEMAND_ARCHIVE_JSON_RPC_URLS: Comma-separated list of archive RPC URLs
  - Falls back to primary JSON RPC if no archive URLs configured
  """

  require Logger

  use GenServer
  use Indexer.Fetcher, restart: :permanent

  alias EthereumJSONRPC.Blocks
  alias Explorer.Chain
  alias Explorer.Chain.Hash
  alias Explorer.Utility.RateLimiter
  alias Indexer.Block.Fetcher.Receipts
  alias Indexer.Transform.{Addresses, TokenTransfers}
  alias Indexer.Transform.Blocks, as: TransformBlocks

  @default_timeout :timer.seconds(30)

  # Block necessity by association for returning block with preloaded data
  @block_necessity_by_association %{
    :transactions => :optional,
    [miner: [:names, :smart_contract, :proxy_implementations]] => :optional,
    :nephews => :optional,
    :rewards => :optional,
    :withdrawals => :optional
  }

  @doc """
  Fetches a block by its hash. Synchronous operation - waits for fetch to complete.

  Returns `{:ok, block}` if successful, `{:error, reason}` otherwise.
  """
  @spec fetch_by_hash(String.t() | nil, Hash.Full.t()) ::
          {:ok, Explorer.Chain.Block.t()} | {:error, term()}
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

  @doc """
  Fetches a block by its number. Synchronous operation - waits for fetch to complete.

  Returns `{:ok, block}` if successful, `{:error, reason}` otherwise.
  """
  @spec fetch_by_number(String.t() | nil, non_neg_integer()) ::
          {:ok, Explorer.Chain.Block.t()} | {:error, term()}
  def fetch_by_number(caller \\ nil, number) do
    case RateLimiter.check_rate(caller, :on_demand_block_fetch) do
      :allow ->
        try do
          GenServer.call(__MODULE__, {:fetch_by_number, number}, timeout())
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
    archive_urls = parse_archive_urls()

    {:ok,
     %{
       json_rpc_named_arguments: json_rpc_named_arguments,
       archive_urls: archive_urls,
       current_index: 0
     }}
  end

  @impl true
  def handle_call({:fetch_by_hash, hash}, _from, state) do
    {result, new_state} = do_fetch_by_hash(hash, state)
    {:reply, result, new_state}
  end

  @impl true
  def handle_call({:fetch_by_number, number}, _from, state) do
    {result, new_state} = do_fetch_by_number(number, state)
    {:reply, result, new_state}
  end

  # Private implementation

  defp do_fetch_by_hash(hash, state) do
    hash_string = to_string(hash)
    {json_rpc_args, new_state} = get_next_json_rpc_args(state)

    result =
      with {:ok, %Blocks{} = blocks_data} <-
             EthereumJSONRPC.fetch_blocks_by_hash([hash_string], json_rpc_args, true),
           {:ok, _imported} <- import_block_data(blocks_data, json_rpc_args),
           {:ok, block} <-
             Chain.hash_to_block(hash, necessity_by_association: @block_necessity_by_association, api?: true) do
        {:ok, block}
      else
        {:error, :empty_response} ->
          {:error, :not_found}

        {:error, reason} ->
          Logger.warning("OnDemand.Block fetch_by_hash failed: #{inspect(reason)}")
          {:error, reason}
      end

    {result, new_state}
  end

  defp do_fetch_by_number(number, state) do
    {json_rpc_args, new_state} = get_next_json_rpc_args(state)

    result =
      with {:ok, %Blocks{} = blocks_data} <-
             EthereumJSONRPC.fetch_blocks_by_numbers([number], json_rpc_args, true),
           {:ok, _imported} <- import_block_data(blocks_data, json_rpc_args),
           {:ok, block} <-
             Chain.number_to_block(number, necessity_by_association: @block_necessity_by_association, api?: true) do
        {:ok, block}
      else
        {:error, :empty_response} ->
          {:error, :not_found}

        {:error, reason} ->
          Logger.warning("OnDemand.Block fetch_by_number failed: #{inspect(reason)}")
          {:error, reason}
      end

    {result, new_state}
  end

  defp import_block_data(
         %Blocks{
           blocks_params: blocks_params,
           transactions_params: transactions_params_without_receipts,
           block_second_degree_relations_params: block_second_degree_relations_params,
           withdrawals_params: withdrawals_params
         },
         json_rpc_args
       ) do
    if Enum.empty?(blocks_params) do
      {:error, :empty_response}
    else
      blocks =
        blocks_params
        |> TransformBlocks.transform_blocks()
        |> Enum.map(&Map.put(&1, :consensus, true))

      # Fetch receipts for transactions
      receipts_result = fetch_receipts(transactions_params_without_receipts, json_rpc_args)

      case receipts_result do
        {:ok, %{logs: logs, receipts: receipts}} ->
          transactions_with_receipts = Receipts.put(transactions_params_without_receipts, receipts)

          # Parse token transfers from logs
          %{token_transfers: token_transfers, tokens: tokens} = TokenTransfers.parse(logs)

          # Extract addresses
          addresses =
            Addresses.extract_addresses(%{
              blocks: blocks,
              logs: logs,
              token_transfers: token_transfers,
              transactions: transactions_with_receipts,
              withdrawals: withdrawals_params
            })

          # Build import options
          import_options = %{
            addresses: %{params: addresses},
            blocks: %{params: blocks},
            block_second_degree_relations: %{params: block_second_degree_relations_params},
            logs: %{params: logs},
            token_transfers: %{params: token_transfers},
            tokens: %{params: tokens},
            transactions: %{params: transactions_with_receipts},
            withdrawals: %{params: withdrawals_params}
          }

          Chain.import(import_options)

        {:error, reason} ->
          Logger.warning("OnDemand.Block receipts fetch failed: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  defp fetch_receipts([], _json_rpc_args), do: {:ok, %{logs: [], receipts: []}}

  defp fetch_receipts(transactions_params, json_rpc_args) do
    transaction_hashes = Enum.map(transactions_params, & &1.hash)

    case EthereumJSONRPC.fetch_transaction_receipts(transaction_hashes, json_rpc_args) do
      {:ok, receipts_params} -> {:ok, receipts_params}
      {:error, reason} -> {:error, reason}
    end
  end

  # Parse comma-separated archive URLs from config
  defp parse_archive_urls do
    config = Application.get_env(:indexer, __MODULE__, [])
    urls_string = config[:archive_json_rpc_urls] || ""

    urls_string
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.filter(&(&1 != ""))
  end

  # Round-robin URL selection
  defp get_next_json_rpc_args(%{archive_urls: [], json_rpc_named_arguments: default_args} = state) do
    # No archive URLs configured, use default RPC
    {default_args, state}
  end

  defp get_next_json_rpc_args(%{archive_urls: urls, current_index: index} = state) do
    # Round-robin through archive URLs
    url = Enum.at(urls, index)
    next_index = rem(index + 1, length(urls))

    json_rpc_args = build_json_rpc_args(url)
    new_state = %{state | current_index: next_index}

    Logger.debug("OnDemand.Block using archive RPC: #{url} (index: #{index}/#{length(urls)})")

    {json_rpc_args, new_state}
  end

  defp build_json_rpc_args(url) do
    [
      transport: EthereumJSONRPC.HTTP,
      transport_options: [
        http: EthereumJSONRPC.HTTP.HTTPoison,
        urls: [url],
        http_options: [recv_timeout: timeout(), timeout: timeout()]
      ]
    ]
  end

  defp timeout do
    Application.get_env(:indexer, __MODULE__)[:timeout] || @default_timeout
  end
end
