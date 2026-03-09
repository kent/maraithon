defmodule Maraithon.Accounts.EmailTemplates do
  @moduledoc """
  Reusable transactional email templates for account flows.
  """

  @app_name "Maraithon"
  @magic_link_expiry_minutes 15

  @doc """
  Returns the branded magic-link email content.
  """
  def magic_link(link) when is_binary(link) do
    build_email(%{
      subject: "Your #{@app_name} sign-in link",
      title: "Sign in to #{@app_name}",
      intro: "Use the secure link below to access your account.",
      cta_label: "Sign in to #{@app_name}",
      cta_url: link,
      expiry_line: "This link expires in #{@magic_link_expiry_minutes} minutes.",
      safety_line: "If you did not request this email, you can safely ignore it."
    })
  end

  defp build_email(%{
         subject: subject,
         title: title,
         intro: intro,
         cta_label: cta_label,
         cta_url: cta_url,
         expiry_line: expiry_line,
         safety_line: safety_line
       }) do
    %{
      subject: subject,
      text_body: text_layout(title, intro, cta_url, expiry_line, safety_line),
      html_body: html_layout(title, intro, cta_label, cta_url, expiry_line, safety_line)
    }
  end

  defp text_layout(title, intro, cta_url, expiry_line, safety_line) do
    """
    #{title}

    #{intro}

    Open this secure link:
    #{cta_url}

    #{expiry_line}
    #{safety_line}
    """
  end

  defp html_layout(title, intro, cta_label, cta_url, expiry_line, safety_line) do
    """
    <!doctype html>
    <html>
      <body style="margin:0;padding:0;background:#f3f4f6;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;color:#0f172a;">
        <table role="presentation" cellpadding="0" cellspacing="0" width="100%" style="background:#f3f4f6;padding:24px 12px;">
          <tr>
            <td align="center">
              <table role="presentation" cellpadding="0" cellspacing="0" width="100%" style="max-width:560px;background:#ffffff;border:1px solid #e5e7eb;border-radius:12px;">
                <tr>
                  <td style="padding:24px 24px 8px;">
                    <p style="margin:0 0 12px;font-size:14px;letter-spacing:0.08em;color:#6366f1;font-weight:700;text-transform:uppercase;">
                      #{@app_name}
                    </p>
                    <h1 style="margin:0 0 12px;font-size:24px;line-height:1.3;color:#111827;">
                      #{title}
                    </h1>
                    <p style="margin:0 0 18px;font-size:16px;line-height:1.55;color:#475569;">
                      #{intro}
                    </p>
                    <p style="margin:0 0 20px;">
                      <a href="#{cta_url}" style="display:inline-block;background:#4f46e5;color:#ffffff;text-decoration:none;font-weight:600;padding:12px 18px;border-radius:8px;">
                        #{cta_label}
                      </a>
                    </p>
                    <p style="margin:0 0 10px;font-size:14px;line-height:1.55;color:#64748b;">
                      #{expiry_line}
                    </p>
                    <p style="margin:0;font-size:14px;line-height:1.55;color:#64748b;">
                      #{safety_line}
                    </p>
                  </td>
                </tr>
                <tr>
                  <td style="padding:16px 24px 24px;border-top:1px solid #e5e7eb;">
                    <p style="margin:0 0 8px;font-size:12px;color:#94a3b8;">
                      If the button does not work, copy and paste this URL into your browser:
                    </p>
                    <p style="margin:0;font-size:12px;line-height:1.5;word-break:break-word;">
                      <a href="#{cta_url}" style="color:#4f46e5;text-decoration:underline;">#{cta_url}</a>
                    </p>
                  </td>
                </tr>
              </table>
            </td>
          </tr>
        </table>
      </body>
    </html>
    """
  end
end
