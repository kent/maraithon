defmodule Maraithon.AssistantChat.CalculationIntent do
  @moduledoc """
  Deterministic arithmetic intent for short, explicit mobile chat calculations.

  This only accepts small arithmetic expressions made of numbers, parentheses,
  and operators. Anything semantic, ambiguous, date-shaped, or malformed falls
  back to the model path.
  """

  @max_chars 80

  def classify(text) when is_binary(text) do
    with {:ok, expression} <- calculation_expression(text),
         {:ok, formatted_result} <- evaluate_calculation(expression) do
      {:ok,
       %{
         type: :simple_calculation,
         expression: expression,
         result: formatted_result,
         reply: "#{expression} = #{formatted_result}."
       }}
    else
      _ -> :nomatch
    end
  end

  def classify(_text), do: :nomatch

  defp calculation_expression(text) do
    candidate =
      text
      |> String.trim()
      |> String.replace("×", "*")
      |> String.replace("÷", "/")
      |> String.replace("−", "-")
      |> String.replace(~r/^\s*(?:what(?:'|’)?s|what\s+is|calculate|compute|solve)\s+/iu, "")
      |> String.replace(~r/\s*(?:\?|=)\s*$/u, "")
      |> String.replace(~r/\s*\.\s*$/u, "")
      |> String.trim()

    compact = String.replace(candidate, ~r/\s+/u, "")

    cond do
      compact == "" ->
        :error

      String.length(candidate) > @max_chars ->
        :error

      date_like_candidate?(candidate) ->
        :error

      not Regex.match?(~r/[+\-*\/]/u, compact) ->
        :error

      Regex.match?(~r/[^\d+\-*\/().,\s]/u, candidate) ->
        :error

      not valid_numeric_format?(candidate) ->
        :error

      true ->
        {:ok, String.replace(candidate, ",", "")}
    end
  end

  defp date_like_candidate?(candidate) do
    compact = String.trim(candidate)

    not Regex.match?(~r/\s/u, compact) and
      (Regex.match?(~r/^\d{4}[-\/]\d{1,2}[-\/]\d{1,2}$/u, compact) or
         Regex.match?(~r/^\d{1,2}[-\/]\d{1,2}[-\/]\d{2,4}$/u, compact))
  end

  defp valid_numeric_format?(candidate) do
    ~r/[\d,.]+/u
    |> Regex.scan(candidate)
    |> Enum.all?(fn [token] -> valid_numeric_token?(token) end)
  end

  defp valid_numeric_token?(token) do
    case String.split(token, ".", parts: 3) do
      [integer] ->
        valid_integer_token?(integer)

      [integer, fraction] ->
        valid_integer_token?(integer) and Regex.match?(~r/^\d+$/u, fraction)

      _ ->
        false
    end
  end

  defp valid_integer_token?(""), do: true

  defp valid_integer_token?(integer) do
    if String.contains?(integer, ",") do
      Regex.match?(~r/^\d{1,3}(?:,\d{3})+$/u, integer)
    else
      Regex.match?(~r/^\d+$/u, integer)
    end
  end

  defp evaluate_calculation(expression) do
    context = %{Decimal.Context.get() | precision: @max_chars}

    Decimal.Context.with(context, fn ->
      with {:ok, tokens} <- tokenize_expression(expression),
           {:ok, value, []} <- parse_expression(tokens) do
        {:ok, format_decimal(value)}
      else
        _ -> :error
      end
    end)
  end

  defp tokenize_expression(expression) do
    compact = String.replace(expression, ~r/\s+/u, "")

    tokens =
      ~r/\d+(?:\.\d+)?|\.\d+|[()+\-*\/]/u
      |> Regex.scan(compact)
      |> List.flatten()

    if tokens != [] and Enum.join(tokens, "") == compact do
      {:ok, tokens}
    else
      :error
    end
  end

  defp parse_expression(tokens), do: parse_add_sub(tokens)

  defp parse_add_sub(tokens) do
    with {:ok, value, rest} <- parse_mul_div(tokens) do
      parse_add_sub_rest(value, rest)
    end
  end

  defp parse_add_sub_rest(value, ["+" | rest]) do
    with {:ok, rhs, rest} <- parse_mul_div(rest) do
      parse_add_sub_rest(Decimal.add(value, rhs), rest)
    end
  end

  defp parse_add_sub_rest(value, ["-" | rest]) do
    with {:ok, rhs, rest} <- parse_mul_div(rest) do
      parse_add_sub_rest(Decimal.sub(value, rhs), rest)
    end
  end

  defp parse_add_sub_rest(value, rest), do: {:ok, value, rest}

  defp parse_mul_div(tokens) do
    with {:ok, value, rest} <- parse_factor(tokens) do
      parse_mul_div_rest(value, rest)
    end
  end

  defp parse_mul_div_rest(value, ["*" | rest]) do
    with {:ok, rhs, rest} <- parse_factor(rest) do
      parse_mul_div_rest(Decimal.mult(value, rhs), rest)
    end
  end

  defp parse_mul_div_rest(value, ["/" | rest]) do
    with {:ok, rhs, rest} <- parse_factor(rest),
         false <- Decimal.equal?(rhs, Decimal.new(0)) do
      parse_mul_div_rest(Decimal.div(value, rhs), rest)
    else
      _ -> :error
    end
  end

  defp parse_mul_div_rest(value, rest), do: {:ok, value, rest}

  defp parse_factor(["+" | rest]), do: parse_factor(rest)

  defp parse_factor(["-" | rest]) do
    with {:ok, value, rest} <- parse_factor(rest) do
      {:ok, Decimal.negate(value), rest}
    end
  end

  defp parse_factor(["(" | rest]) do
    with {:ok, value, [")" | rest]} <- parse_expression(rest) do
      {:ok, value, rest}
    else
      _ -> :error
    end
  end

  defp parse_factor([token | rest]) do
    if Regex.match?(~r/^(?:\d+(?:\.\d+)?|\.\d+)$/u, token) do
      case Decimal.parse(normalize_decimal_token(token),
             max_digits: @max_chars,
             max_exponent: @max_chars
           ) do
        {decimal, ""} -> {:ok, decimal, rest}
        _invalid_or_out_of_bounds -> :error
      end
    else
      :error
    end
  end

  defp parse_factor([]), do: :error

  defp normalize_decimal_token("." <> rest), do: "0." <> rest
  defp normalize_decimal_token(token), do: token

  defp format_decimal(decimal) do
    decimal
    |> Decimal.normalize()
    |> Decimal.to_string(:normal)
  end
end
