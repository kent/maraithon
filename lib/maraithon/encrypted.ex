defmodule Maraithon.Encrypted do
  @moduledoc """
  Encrypted Ecto types using Cloak.

  These types automatically encrypt data when writing to the database
  and decrypt when reading.
  """
end

defmodule Maraithon.Encrypted.Binary do
  @moduledoc """
  Encrypted binary type for sensitive data like OAuth tokens.
  """
  use Cloak.Ecto.Binary, vault: Maraithon.Vault
end

defmodule Maraithon.Encrypted.Map do
  @moduledoc """
  Encrypted map type for sensitive structured data.
  """
  use Cloak.Ecto.Map, vault: Maraithon.Vault
end
