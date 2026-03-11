defmodule Maraithon.TestSupport.OnboardingProofStub do
  @moduledoc false

  def preview(_user_id) do
    Application.get_env(:maraithon, :onboarding_proof_stub_response, default_response())
  end

  def eligible?(_user_id), do: true

  defp default_response do
    {:ok,
     %{
       items: [],
       sources: [],
       generated_at: DateTime.utc_now()
     }}
  end
end
