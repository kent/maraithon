defmodule Maraithon.Accounts.MagicLinkSender do
  @moduledoc """
  Sends magic sign-in links.

  Uses Postmark when configured, otherwise logs the link.
  """

  require Logger

  @postmark_api_url "https://api.postmarkapp.com/email"

  def deliver(email, link) when is_binary(email) and is_binary(link) do
    case postmark_config() do
      {:ok, config} -> send_via_postmark(config, email, link)
      :disabled -> log_only(email, link)
    end
  end

  defp postmark_config do
    server_token = System.get_env("POSTMARK_SERVER_TOKEN", "") |> String.trim()
    from = System.get_env("AUTH_EMAIL_FROM", "") |> String.trim()
    message_stream = System.get_env("POSTMARK_MESSAGE_STREAM", "outbound") |> String.trim()

    cond do
      server_token == "" -> :disabled
      from == "" -> :disabled
      true -> {:ok, %{server_token: server_token, from: from, message_stream: message_stream}}
    end
  end

  defp send_via_postmark(config, email, link) do
    body = %{
      "From" => config.from,
      "To" => email,
      "Subject" => "Your Maraithon sign-in link",
      "TextBody" => "Sign in to Maraithon:\n\n#{link}\n\nThis link expires in 15 minutes.",
      "HtmlBody" =>
        "<p>Sign in to Maraithon:</p><p><a href=\"#{link}\">#{link}</a></p><p>This link expires in 15 minutes.</p>",
      "MessageStream" =>
        if(config.message_stream == "", do: "outbound", else: config.message_stream)
    }

    case Req.post(@postmark_api_url,
           headers: [{"X-Postmark-Server-Token", config.server_token}],
           json: body
         ) do
      {:ok, %Req.Response{status: status}} when status in 200..299 ->
        :ok

      {:ok, %Req.Response{status: status, body: response_body}} ->
        Logger.warning("Magic link email failed",
          status: status,
          response: inspect(response_body)
        )

        {:error, :email_delivery_failed}

      {:error, reason} ->
        Logger.warning("Magic link email transport error", reason: inspect(reason))
        {:error, :email_delivery_failed}
    end
  end

  defp log_only(email, link) do
    Logger.info("Magic link delivery fallback (log-only)",
      email: email,
      link: link
    )

    :ok
  end
end
