defmodule AdminUi.LegacyController do
  @moduledoc false

  @timeout_ms 2_000

  @spec list_freezers(String.t()) :: {:ok, [map()]} | {:error, String.t()}
  def list_freezers(base_url) do
    case request(:get, base_url <> "/api/freezers") do
      {:ok, %{"freezers" => freezers}} when is_list(freezers) -> {:ok, freezers}
      {:ok, other} -> {:error, "unexpected response: #{inspect(other)}"}
      error -> error
    end
  end

  @spec list_audit(String.t()) :: {:ok, [map()]} | {:error, String.t()}
  def list_audit(base_url) do
    case request(:get, base_url <> "/api/audit") do
      {:ok, %{"entries" => entries}} when is_list(entries) -> {:ok, entries}
      {:ok, other} -> {:error, "unexpected response: #{inspect(other)}"}
      error -> error
    end
  end

  @spec login(String.t(), String.t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def login(base_url, user, password) do
    case request(:get, base_url <> "/api/session", auth: basic(user, password)) do
      {:ok, %{"user" => signed_in}} -> {:ok, signed_in}
      {:ok, other} -> {:error, "unexpected response: #{inspect(other)}"}
      error -> error
    end
  end

  @spec set_target(String.t(), String.t(), String.t(), String.t(), number()) ::
          {:ok, map()} | {:error, String.t()}
  def set_target(base_url, user, password, id, target_c) do
    request(
      :post,
      base_url <> "/api/freezers/#{id}/target",
      auth: basic(user, password),
      json: %{"target_c" => target_c}
    )
  end

  @spec start_defrost(String.t(), String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, String.t()}
  def start_defrost(base_url, user, password, id) do
    request(:post, base_url <> "/api/freezers/#{id}/defrost", auth: basic(user, password))
  end

  @spec stop_defrost(String.t(), String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, String.t()}
  def stop_defrost(base_url, user, password, id) do
    request(:post, base_url <> "/api/freezers/#{id}/stop", auth: basic(user, password))
  end

  @spec reset(String.t(), String.t(), String.t()) :: {:ok, map()} | {:error, String.t()}
  def reset(base_url, user, password) do
    request(:post, base_url <> "/api/reset", auth: basic(user, password))
  end

  defp request(method, url, opts \\ [])

  defp request(:get, url, opts) do
    Req.get(url, Keyword.merge([receive_timeout: @timeout_ms], opts))
    |> normalize()
  end

  defp request(:post, url, opts) do
    Req.post(url, Keyword.merge([receive_timeout: @timeout_ms], opts))
    |> normalize()
  end

  defp basic(user, password), do: {:basic, "#{user}:#{password}"}

  defp normalize({:ok, %Req.Response{status: status, body: body}}) when status in 200..299 do
    {:ok, body}
  end

  defp normalize({:ok, %Req.Response{status: status, body: body}}) do
    {:error, "HTTP #{status}: #{inspect(body)}"}
  end

  defp normalize({:error, %Req.TransportError{reason: reason}})
       when reason in [:nxdomain, :econnrefused] do
    {:error, "the legacy edge is not reachable; it may have been stopped"}
  end

  defp normalize({:error, %Req.TransportError{reason: reason}}) do
    {:error, "transport error: #{inspect(reason)}"}
  end

  defp normalize({:error, reason}), do: {:error, inspect(reason)}
end
