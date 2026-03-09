defmodule MaraithonWeb.AdminPageController do
  use MaraithonWeb, :controller

  def index(conn, _params) do
    redirect(conn, to: "/settings")
  end
end
