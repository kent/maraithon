defmodule Maraithon.Accounts.EmailTemplatesTest do
  use ExUnit.Case, async: true

  alias Maraithon.Accounts.EmailTemplates

  test "magic_link returns branded reusable content" do
    link = "https://maraithon.fly.dev/auth/magic/test-token"

    email = EmailTemplates.magic_link(link)

    assert email.subject == "Your Maraithon sign-in link"
    assert email.text_body =~ "Sign in to Maraithon"
    assert email.text_body =~ link
    assert email.html_body =~ "Maraithon"
    assert email.html_body =~ link
    assert email.html_body =~ "If the button does not work"
  end
end
