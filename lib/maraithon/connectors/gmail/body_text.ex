defmodule Maraithon.Connectors.Gmail.BodyText do
  @moduledoc """
  Readable Gmail evidence for model prompts. Provider bodies remain unchanged.

  Older Gmail fetches copied the HTML fallback into `text_body`, so a field's
  name alone does not prove it contains plain text. Render only a known HTML
  body; never strip angle-bracketed addresses or code from actual plain text.
  This is prompt text, not sanitized HTML for rendering in a browser.
  """

  @tag ~r/<\/?[a-zA-Z][a-zA-Z0-9:-]*\b(?:"[^"]*"|'[^']*'|[^'">])*>/s
  @attribute ~r/\s([a-zA-Z_:][a-zA-Z0-9_:.-]*)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))/
  @entities %{
    "amp" => "&",
    "lt" => "<",
    "gt" => ">",
    "quot" => "\"",
    "apos" => "'",
    "nbsp" => " ",
    "ndash" => "–",
    "mdash" => "—",
    "hellip" => "…",
    "lsquo" => "‘",
    "rsquo" => "’",
    "ldquo" => "“",
    "rdquo" => "”",
    "bull" => "•"
  }

  def from_message(message) when is_map(message) do
    html = present(message, "html_body")

    bodies = Enum.map(~w(body_text text_body body), &present(message, &1))
    body = Enum.find(bodies, &(is_binary(&1) and &1 != html)) || html

    if is_binary(html) and body == html, do: render_html(html), else: body
  end

  def from_message(_message), do: nil

  defp present(message, key) do
    case Map.get(message, key) do
      value when is_binary(value) -> if String.trim(value) != "", do: value
      _other -> nil
    end
  end

  defp render_html(html) do
    html
    # CSS and executable script are not the message's visible evidence. Keep
    # comment contents (including Outlook conditional content) conservatively.
    |> String.replace(~r/<(style|script)\b[^>]*>.*?<\/\1\s*>/isu, " ")
    |> then(&Regex.replace(@tag, &1, fn tag -> render_tag(tag) end))
    |> then(
      &Regex.replace(~r/&(#(?:x|X)[0-9a-fA-F]{1,8}|#[0-9]{1,7}|[A-Za-z]{1,31});/, &1, fn entity,
                                                                                         name ->
        decode_entity(entity, name)
      end)
    )
    |> String.replace(~r/[\x{200B}\x{FEFF}]/u, "")
    |> String.replace(~r/[^\S\n]+/u, " ")
    |> String.replace(~r/ *\n(?: *\n)+ */u, "\n\n")
    |> String.trim()
  end

  defp render_tag(tag) do
    # Attribute values can contain '>'; the tokenizer keeps quoted values
    # together. Preserve link destinations and descriptive text before removing
    # markup, including calls to action carried by linked images.
    attributes =
      Regex.scan(@attribute, tag, capture: :all_but_first)
      |> Enum.filter(fn [name | _values] -> String.downcase(name) in ~w(href alt title) end)
      |> Enum.map(fn [name | values] ->
        value = Enum.find(values, "", &(&1 != ""))
        " [#{String.downcase(name)}: #{value}] "
      end)
      |> Enum.join()

    separator =
      if Regex.match?(
           ~r/^<\/?(?:address|article|aside|blockquote|br|dd|div|dl|dt|figcaption|footer|h[1-6]|header|hr|li|main|ol|p|pre|section|table|td|th|tr|ul)\b/i,
           tag
         ),
         do: "\n",
         else: ""

    attributes <> separator
  end

  defp decode_entity(original, "#x" <> digits), do: decode_codepoint(original, digits, 16)
  defp decode_entity(original, "#X" <> digits), do: decode_codepoint(original, digits, 16)
  defp decode_entity(original, "#" <> digits), do: decode_codepoint(original, digits, 10)
  defp decode_entity(original, name), do: Map.get(@entities, name, original)

  defp decode_codepoint(original, digits, base) do
    case Integer.parse(digits, base) do
      {value, ""} when value > 0 and value <= 0x10FFFF and value not in 0xD800..0xDFFF ->
        <<value::utf8>>

      _invalid ->
        original
    end
  end
end
