defmodule Indexer.Fetcher.Monad.StakingEventsCatchup do
  @moduledoc """
  Fetches historical Monad staking events from the staking precompile.

  This fetcher handles backfilling of staking events by scanning historical blocks
  from a configurable start block to the current block. After catchup is complete,
  it continues monitoring for new blocks.

  Configuration:
  - `INDEXER_MONAD_STAKING_START_BLOCK` - Block number to start scanning from
  - `INDEXER_MONAD_STAKING_LOGS_BATCH_SIZE` - Number of blocks per eth_getLogs request (default: 1000)
  - `INDEXER_MONAD_STAKING_BLOCK_CHECK_INTERVAL` - Interval to check for new blocks in ms (default: 5000)
  """

  use GenServer
  use Indexer.Fetcher

  require Logger

  alias EthereumJSONRPC.Monad.Constants.{Contracts, Events}
  alias Explorer.Chain
  alias Explorer.Chain.Monad.StakingEvent
  alias Indexer.Helper
  alias Indexer.Transform.Monad.StakingEvents, as: StakingEventsTransform

  @fetcher_name :monad_staking_events_catchup

  def child_spec(start_link_arguments) do
    spec = %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, start_link_arguments},
      restart: :transient,
      type: :worker
    }

    Supervisor.child_spec(spec, [])
  end

  def start_link(args, gen_server_options \\ []) do
    GenServer.start_link(__MODULE__, args, Keyword.put_new(gen_server_options, :name, __MODULE__))
  end

  @impl GenServer
  def init(args) do
    json_rpc_named_arguments = Keyword.fetch!(args, :json_rpc_named_arguments)

    Logger.metadata(fetcher: @fetcher_name)

    env = Application.get_all_env(:indexer)[__MODULE__]

    start_block = env[:start_block] || 1
    logs_batch_size = env[:logs_batch_size] || 1000
    block_check_interval = env[:block_check_interval] || 5_000

    Process.send_after(self(), :init, 1_000)

    {:ok,
     %{
       json_rpc_named_arguments: json_rpc_named_arguments,
       start_block: start_block,
       logs_batch_size: logs_batch_size,
       block_check_interval: block_check_interval,
       catchup_complete: false
     }}
  end

  @impl GenServer
  def handle_info(:init, state) do
    # Determine where to start from
    start_block = determine_start_block(state.start_block)

    Logger.info("Starting Monad staking events catchup from block #{start_block}")

    Process.send(self(), :continue, [])

    {:noreply, %{state | start_block: start_block}}
  end

  @impl GenServer
  def handle_info(:continue, state) do
    %{
      json_rpc_named_arguments: json_rpc_named_arguments,
      start_block: start_block,
      logs_batch_size: logs_batch_size,
      block_check_interval: block_check_interval
    } = state

    time_before = Timex.now()

    # Get the latest block number
    end_block =
      case Helper.get_block_number_by_tag("latest", json_rpc_named_arguments, Helper.infinite_retries_number()) do
        {:ok, block_number} -> block_number
        _ -> start_block
      end

    if end_block >= start_block do
      last_written_block = process_block_range(start_block, end_block, logs_batch_size, json_rpc_named_arguments)

      new_start_block = last_written_block + 1

      # Calculate delay for next iteration
      delay =
        if new_start_block > end_block do
          # Caught up - wait for new blocks
          elapsed = Timex.diff(Timex.now(), time_before, :milliseconds)
          max(block_check_interval - elapsed, 0)
        else
          # More blocks to process
          0
        end

      Process.send_after(self(), :continue, delay)

      catchup_complete = new_start_block > end_block and not state.catchup_complete

      if catchup_complete do
        Logger.info("Monad staking events catchup complete at block #{last_written_block}")
      end

      {:noreply, %{state | start_block: new_start_block, catchup_complete: catchup_complete or state.catchup_complete}}
    else
      # No blocks to process yet
      Process.send_after(self(), :continue, block_check_interval)
      {:noreply, state}
    end
  end

  @impl GenServer
  def handle_info({ref, _result}, state) do
    Process.demonitor(ref, [:flush])
    {:noreply, state}
  end

  # Private functions

  defp determine_start_block(configured_start_block) do
    # Check if we have any existing events and continue from there
    case StakingEvent.get_last_block_number() do
      nil ->
        # No events yet, use configured start block
        configured_start_block

      last_block ->
        # Continue from the last processed block + 1
        max(last_block + 1, configured_start_block)
    end
  end

  defp process_block_range(start_block, end_block, batch_size, json_rpc_named_arguments) do
    staking_address = Contracts.staking_precompile()
    event_signatures = Events.staking_event_signatures()

    chunks_number = ceil((end_block - start_block + 1) / batch_size)
    chunk_range = Range.new(0, max(chunks_number - 1, 0), 1)

    chunk_range
    |> Enum.reduce_while(start_block - 1, fn current_chunk, _acc ->
      chunk_start = start_block + batch_size * current_chunk
      chunk_end = min(chunk_start + batch_size - 1, end_block)

      if chunk_end >= chunk_start do
        log_chunk_processing(chunk_start, chunk_end, start_block, end_block)

        case fetch_and_import_events(
               chunk_start,
               chunk_end,
               staking_address,
               event_signatures,
               json_rpc_named_arguments
             ) do
          {:ok, count} ->
            Logger.info("Imported #{count} staking events from blocks #{chunk_start}-#{chunk_end}")
            {:cont, chunk_end}

          {:error, reason} ->
            Logger.error("Failed to fetch staking events for blocks #{chunk_start}-#{chunk_end}: #{inspect(reason)}")
            # Retry this chunk
            Process.sleep(1_000)
            {:cont, chunk_start - 1}
        end
      else
        {:cont, chunk_end}
      end
    end)
  end

  defp fetch_and_import_events(from_block, to_block, staking_address, event_signatures, json_rpc_named_arguments) do
    case Helper.get_logs(
           from_block,
           to_block,
           staking_address,
           [event_signatures],
           json_rpc_named_arguments,
           0,
           Helper.infinite_retries_number()
         ) do
      {:ok, logs} ->
        events = StakingEventsTransform.parse(logs)

        if Enum.empty?(events) do
          {:ok, 0}
        else
          case import_events(events) do
            {:ok, _} -> {:ok, length(events)}
            error -> error
          end
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp import_events(events) do
    Chain.import(%{
      monad_staking_events: %{params: events},
      timeout: :infinity
    })
  end

  defp log_chunk_processing(chunk_start, chunk_end, start_block, end_block) do
    total_blocks = end_block - start_block + 1
    processed_blocks = chunk_end - start_block + 1
    progress = Float.round(processed_blocks / total_blocks * 100, 1)

    Logger.info(
      "Processing Monad staking events: blocks #{chunk_start}-#{chunk_end} (#{progress}% complete, #{processed_blocks}/#{total_blocks} blocks)"
    )
  end
end
