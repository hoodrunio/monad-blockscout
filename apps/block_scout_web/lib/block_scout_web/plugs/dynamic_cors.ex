defmodule BlockScoutWeb.Plugs.DynamicCORS do
  @moduledoc """
  A wrapper around CORSPlug that reads the allowed origin from
  API_V2_CORS_ALLOWED_ORIGIN environment variable at runtime.

  Supports:
  - Single origin: "https://example.com"
  - Multiple origins (comma-separated): "https://example1.com,https://example2.com"
  - Wildcard: "*" (default if not set)
  """

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, opts) do
    origin = get_cors_origin()
    cors_opts = Keyword.put(opts, :origin, origin)
    CORSPlug.call(conn, CORSPlug.init(cors_opts))
  end

  defp get_cors_origin do
    case System.get_env("API_V2_CORS_ALLOWED_ORIGIN") do
      nil -> "*"
      "" -> "*"
      "*" -> "*"
      origins ->
        origins
        |> String.split(",")
        |> Enum.map(&String.trim/1)
        |> case do
          [single] -> single
          multiple -> multiple
        end
    end
  end
end
