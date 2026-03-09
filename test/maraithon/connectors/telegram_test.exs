defmodule Maraithon.Connectors.TelegramTest do
  # Non-async due to application config modification
  use ExUnit.Case, async: false

  import Plug.Test

  alias Maraithon.Connectors.Telegram

  setup do
    # Set up bot token so bot_id is extracted correctly
    Application.put_env(:maraithon, :telegram, bot_token: "12345:ABC", allow_unsigned: true)
    on_exit(fn -> Application.delete_env(:maraithon, :telegram) end)
    :ok
  end

  describe "handle_webhook/2" do
    test "parses text message" do
      params = %{
        "update_id" => 123_456_789,
        "message" => %{
          "message_id" => 100,
          "chat" => %{
            "id" => 12345,
            "type" => "private",
            "first_name" => "John"
          },
          "from" => %{
            "id" => 12345,
            "first_name" => "John",
            "username" => "johndoe"
          },
          "text" => "Hello bot!",
          "date" => 1_609_459_200
        }
      }

      conn = conn(:post, "/webhooks/telegram", params)

      {:ok, topic, event} = Telegram.handle_webhook(conn, params)

      assert topic == "telegram:12345:12345"
      assert event.type == "message"
      assert event.source == "telegram"
      assert event.data.text == "Hello bot!"
      assert event.data.chat_id == 12345
    end

    test "parses command message" do
      params = %{
        "update_id" => 123_456_789,
        "message" => %{
          "message_id" => 100,
          "chat" => %{"id" => 12345, "type" => "private"},
          "from" => %{"id" => 12345},
          "text" => "/start",
          "entities" => [%{"type" => "bot_command", "offset" => 0, "length" => 6}],
          "date" => 1_609_459_200
        }
      }

      conn = conn(:post, "/webhooks/telegram", params)

      {:ok, topic, event} = Telegram.handle_webhook(conn, params)

      assert topic == "telegram:12345:12345"
      # Commands come through as "message" type with entities
      assert event.type == "message"
      assert event.data.text == "/start"
      assert length(event.data.entities) == 1
    end

    test "parses photo message" do
      params = %{
        "update_id" => 123_456_789,
        "message" => %{
          "message_id" => 100,
          "chat" => %{"id" => 12345, "type" => "private"},
          "from" => %{"id" => 12345},
          "photo" => [
            %{"file_id" => "small", "width" => 100, "height" => 100},
            %{"file_id" => "large", "width" => 800, "height" => 600}
          ],
          "caption" => "Check this out",
          "date" => 1_609_459_200
        }
      }

      conn = conn(:post, "/webhooks/telegram", params)

      {:ok, _topic, event} = Telegram.handle_webhook(conn, params)

      assert event.type == "photo"
      assert event.data.caption == "Check this out"
    end

    test "parses callback query" do
      params = %{
        "update_id" => 123_456_789,
        "callback_query" => %{
          "id" => "callback-123",
          "from" => %{"id" => 12345, "first_name" => "John"},
          "message" => %{
            "message_id" => 100,
            "chat" => %{"id" => 12345}
          },
          "data" => "button_clicked"
        }
      }

      conn = conn(:post, "/webhooks/telegram", params)

      {:ok, _topic, event} = Telegram.handle_webhook(conn, params)

      assert event.type == "callback_query"
      # The data field is called 'data', not 'callback_data'
      assert event.data.data == "button_clicked"
    end

    test "parses inline query" do
      params = %{
        "update_id" => 123_456_789,
        "inline_query" => %{
          "id" => "query-123",
          "from" => %{"id" => 12345},
          "query" => "search term"
        }
      }

      conn = conn(:post, "/webhooks/telegram", params)

      {:ok, _topic, event} = Telegram.handle_webhook(conn, params)

      assert event.type == "inline_query"
      assert event.data.query == "search term"
    end

    test "parses group message" do
      params = %{
        "update_id" => 123_456_789,
        "message" => %{
          "message_id" => 100,
          "chat" => %{
            "id" => -100_123_456,
            "type" => "supergroup",
            "title" => "Test Group"
          },
          "from" => %{"id" => 12345},
          "text" => "Hello group!",
          "date" => 1_609_459_200
        }
      }

      conn = conn(:post, "/webhooks/telegram", params)

      {:ok, topic, _event} = Telegram.handle_webhook(conn, params)

      assert topic == "telegram:12345:-100123456"
    end

    test "parses document message" do
      params = %{
        "update_id" => 123_456_789,
        "message" => %{
          "message_id" => 100,
          "chat" => %{"id" => 12345, "type" => "private"},
          "from" => %{"id" => 12345},
          "document" => %{
            "file_id" => "doc-123",
            "file_name" => "test.pdf",
            "mime_type" => "application/pdf"
          },
          "date" => 1_609_459_200
        }
      }

      conn = conn(:post, "/webhooks/telegram", params)

      {:ok, _topic, event} = Telegram.handle_webhook(conn, params)

      assert event.type == "document"
    end

    test "parses voice message" do
      params = %{
        "update_id" => 123_456_789,
        "message" => %{
          "message_id" => 100,
          "chat" => %{"id" => 12345, "type" => "private"},
          "from" => %{"id" => 12345},
          "voice" => %{
            "file_id" => "voice-123",
            "duration" => 5
          },
          "date" => 1_609_459_200
        }
      }

      conn = conn(:post, "/webhooks/telegram", params)

      {:ok, _topic, event} = Telegram.handle_webhook(conn, params)

      assert event.type == "voice"
    end

    test "parses video message" do
      params = %{
        "update_id" => 123_456_789,
        "message" => %{
          "message_id" => 100,
          "chat" => %{"id" => 12345, "type" => "private"},
          "from" => %{"id" => 12345},
          "video" => %{
            "file_id" => "video-123",
            "duration" => 30,
            "width" => 1920,
            "height" => 1080
          },
          "caption" => "Cool video",
          "date" => 1_609_459_200
        }
      }

      conn = conn(:post, "/webhooks/telegram", params)

      {:ok, _topic, event} = Telegram.handle_webhook(conn, params)

      assert event.type == "video"
      assert event.data.caption == "Cool video"
    end

    test "parses audio message" do
      params = %{
        "update_id" => 123_456_789,
        "message" => %{
          "message_id" => 100,
          "chat" => %{"id" => 12345, "type" => "private"},
          "from" => %{"id" => 12345},
          "audio" => %{
            "file_id" => "audio-123",
            "duration" => 180,
            "performer" => "Artist",
            "title" => "Song"
          },
          "date" => 1_609_459_200
        }
      }

      conn = conn(:post, "/webhooks/telegram", params)

      {:ok, _topic, event} = Telegram.handle_webhook(conn, params)

      assert event.type == "audio"
    end

    test "parses location message" do
      params = %{
        "update_id" => 123_456_789,
        "message" => %{
          "message_id" => 100,
          "chat" => %{"id" => 12345, "type" => "private"},
          "from" => %{"id" => 12345},
          "location" => %{
            "latitude" => 51.5074,
            "longitude" => -0.1278
          },
          "date" => 1_609_459_200
        }
      }

      conn = conn(:post, "/webhooks/telegram", params)

      {:ok, _topic, event} = Telegram.handle_webhook(conn, params)

      assert event.type == "location"
      assert event.data.latitude == 51.5074
    end

    test "parses contact message" do
      params = %{
        "update_id" => 123_456_789,
        "message" => %{
          "message_id" => 100,
          "chat" => %{"id" => 12345, "type" => "private"},
          "from" => %{"id" => 12345},
          "contact" => %{
            "phone_number" => "+1234567890",
            "first_name" => "John"
          },
          "date" => 1_609_459_200
        }
      }

      conn = conn(:post, "/webhooks/telegram", params)

      {:ok, _topic, event} = Telegram.handle_webhook(conn, params)

      assert event.type == "contact"
    end

    test "parses sticker message" do
      params = %{
        "update_id" => 123_456_789,
        "message" => %{
          "message_id" => 100,
          "chat" => %{"id" => 12345, "type" => "private"},
          "from" => %{"id" => 12345},
          "sticker" => %{
            "file_id" => "sticker-123",
            "emoji" => "😀",
            "set_name" => "StickerSet"
          },
          "date" => 1_609_459_200
        }
      }

      conn = conn(:post, "/webhooks/telegram", params)

      {:ok, _topic, event} = Telegram.handle_webhook(conn, params)

      assert event.type == "sticker"
    end

    test "parses poll message" do
      params = %{
        "update_id" => 123_456_789,
        "message" => %{
          "message_id" => 100,
          "chat" => %{"id" => 12345, "type" => "private"},
          "from" => %{"id" => 12345},
          "poll" => %{
            "id" => "poll-123",
            "question" => "What's your favorite?",
            "options" => [%{"text" => "A"}, %{"text" => "B"}],
            "type" => "regular"
          },
          "date" => 1_609_459_200
        }
      }

      conn = conn(:post, "/webhooks/telegram", params)

      {:ok, _topic, event} = Telegram.handle_webhook(conn, params)

      assert event.type == "poll"
    end

    test "parses edited message" do
      params = %{
        "update_id" => 123_456_789,
        "edited_message" => %{
          "message_id" => 100,
          "chat" => %{"id" => 12345, "type" => "private"},
          "from" => %{"id" => 12345},
          "text" => "Edited text",
          "date" => 1_609_459_200,
          "edit_date" => 1_609_459_300
        }
      }

      conn = conn(:post, "/webhooks/telegram", params)

      {:ok, _topic, event} = Telegram.handle_webhook(conn, params)

      assert event.type == "edited_message"
      assert event.data.text == "Edited text"
    end

    test "parses channel post" do
      params = %{
        "update_id" => 123_456_789,
        "channel_post" => %{
          "message_id" => 100,
          "chat" => %{"id" => -100_123, "type" => "channel", "title" => "My Channel"},
          "text" => "Channel announcement",
          "date" => 1_609_459_200
        }
      }

      conn = conn(:post, "/webhooks/telegram", params)

      {:ok, _topic, event} = Telegram.handle_webhook(conn, params)

      assert event.type == "channel_message"
    end

    test "parses chat member update" do
      params = %{
        "update_id" => 123_456_789,
        "my_chat_member" => %{
          "chat" => %{"id" => -100_123, "type" => "group", "title" => "Test Group"},
          "from" => %{"id" => 12345},
          "old_chat_member" => %{"status" => "member"},
          "new_chat_member" => %{"status" => "administrator", "user" => %{"id" => 54321}}
        }
      }

      conn = conn(:post, "/webhooks/telegram", params)

      {:ok, _topic, event} = Telegram.handle_webhook(conn, params)

      assert event.type == "chat_member_updated"
    end

    test "parses new chat members" do
      params = %{
        "update_id" => 123_456_789,
        "message" => %{
          "message_id" => 100,
          "chat" => %{"id" => -100_123, "type" => "group", "title" => "Test Group"},
          "from" => %{"id" => 12345},
          "new_chat_members" => [
            %{"id" => 54321, "first_name" => "New User"}
          ],
          "date" => 1_609_459_200
        }
      }

      conn = conn(:post, "/webhooks/telegram", params)

      {:ok, _topic, event} = Telegram.handle_webhook(conn, params)

      assert event.type == "member_joined"
    end

    test "parses left chat member" do
      params = %{
        "update_id" => 123_456_789,
        "message" => %{
          "message_id" => 100,
          "chat" => %{"id" => -100_123, "type" => "group", "title" => "Test Group"},
          "from" => %{"id" => 12345},
          "left_chat_member" => %{"id" => 54321, "first_name" => "Leaving User"},
          "date" => 1_609_459_200
        }
      }

      conn = conn(:post, "/webhooks/telegram", params)

      {:ok, _topic, event} = Telegram.handle_webhook(conn, params)

      assert event.type == "member_left"
    end

    test "ignores unhandled update type" do
      params = %{
        "update_id" => 123_456_789,
        "unknown_update" => %{"data" => "something"}
      }

      conn = conn(:post, "/webhooks/telegram", params)

      {:ignore, msg} = Telegram.handle_webhook(conn, params)
      assert msg =~ "unhandled update type"
    end
  end

  describe "verify_signature/2" do
    test "returns error when webhook secret not configured and unsigned not allowed" do
      Application.put_env(:maraithon, :telegram,
        bot_token: "12345:ABC",
        allow_unsigned: false,
        webhook_secret_path: ""
      )

      conn =
        conn(:post, "/webhooks/telegram", %{}) |> Map.put(:request_path, "/webhooks/telegram")

      assert {:error, :webhook_secret_path_not_configured} = Telegram.verify_signature(conn, "{}")
    end

    test "returns ok when path contains secret" do
      Application.put_env(:maraithon, :telegram,
        bot_token: "12345:ABC",
        webhook_secret_path: "secret123"
      )

      conn =
        conn(:post, "/webhooks/telegram/secret123", %{})
        |> Map.put(:request_path, "/webhooks/telegram/secret123")

      assert :ok = Telegram.verify_signature(conn, "{}")
    end

    test "returns error when path doesn't contain secret" do
      Application.put_env(:maraithon, :telegram,
        bot_token: "12345:ABC",
        webhook_secret_path: "secret123"
      )

      conn =
        conn(:post, "/webhooks/telegram", %{})
        |> Map.put(:request_path, "/webhooks/telegram/wrong")

      assert {:error, :invalid_path} = Telegram.verify_signature(conn, "{}")
    end

    test "returns ok when allow_unsigned and no secret configured" do
      Application.put_env(:maraithon, :telegram,
        bot_token: "12345:ABC",
        allow_unsigned: true,
        webhook_secret_path: ""
      )

      conn =
        conn(:post, "/webhooks/telegram", %{}) |> Map.put(:request_path, "/webhooks/telegram")

      assert :ok = Telegram.verify_signature(conn, "{}")
    end
  end

  describe "handle_webhook/2 - reply messages" do
    test "parses message with reply_to_message" do
      params = %{
        "update_id" => 123_456_789,
        "message" => %{
          "message_id" => 100,
          "chat" => %{"id" => 12345, "type" => "private"},
          "from" => %{"id" => 12345, "first_name" => "John"},
          "text" => "This is a reply",
          "date" => 1_609_459_200,
          "reply_to_message" => %{
            "message_id" => 99,
            "from" => %{"id" => 54321, "first_name" => "Jane"},
            "text" => "Original message"
          }
        }
      }

      conn = conn(:post, "/webhooks/telegram", params)

      {:ok, _topic, event} = Telegram.handle_webhook(conn, params)

      assert event.type == "message"
      assert event.data.reply_to != nil
      assert event.data.reply_to.message_id == 99
      assert event.data.reply_to.text == "Original message"
    end
  end

  describe "handle_webhook/2 - forwarded messages" do
    test "parses forwarded message from user" do
      params = %{
        "update_id" => 123_456_789,
        "message" => %{
          "message_id" => 100,
          "chat" => %{"id" => 12345, "type" => "private"},
          "from" => %{"id" => 12345},
          "text" => "Forwarded text",
          "date" => 1_609_459_200,
          "forward_from" => %{
            "id" => 54321,
            "first_name" => "Original Author"
          }
        }
      }

      conn = conn(:post, "/webhooks/telegram", params)

      {:ok, _topic, event} = Telegram.handle_webhook(conn, params)

      assert event.type == "message"
      assert event.data.forward_from != nil
      assert event.data.forward_from.type == "user"
    end

    test "parses forwarded message from chat" do
      params = %{
        "update_id" => 123_456_789,
        "message" => %{
          "message_id" => 100,
          "chat" => %{"id" => 12345, "type" => "private"},
          "from" => %{"id" => 12345},
          "text" => "Forwarded from channel",
          "date" => 1_609_459_200,
          "forward_from_chat" => %{
            "id" => -100_123,
            "title" => "News Channel"
          }
        }
      }

      conn = conn(:post, "/webhooks/telegram", params)

      {:ok, _topic, event} = Telegram.handle_webhook(conn, params)

      assert event.type == "message"
      assert event.data.forward_from != nil
      assert event.data.forward_from.type == "chat"
    end

    test "parses forwarded message with hidden sender" do
      params = %{
        "update_id" => 123_456_789,
        "message" => %{
          "message_id" => 100,
          "chat" => %{"id" => 12345, "type" => "private"},
          "from" => %{"id" => 12345},
          "text" => "Forwarded from hidden user",
          "date" => 1_609_459_200,
          "forward_sender_name" => "Anonymous User"
        }
      }

      conn = conn(:post, "/webhooks/telegram", params)

      {:ok, _topic, event} = Telegram.handle_webhook(conn, params)

      assert event.type == "message"
      assert event.data.forward_from != nil
      assert event.data.forward_from.type == "hidden"
      assert event.data.forward_from.name == "Anonymous User"
    end
  end

  describe "handle_webhook/2 - callback query variations" do
    test "parses callback query without message (inline mode)" do
      params = %{
        "update_id" => 123_456_789,
        "callback_query" => %{
          "id" => "callback-123",
          "from" => %{"id" => 12345, "first_name" => "John"},
          "inline_message_id" => "inline-msg-123",
          "data" => "inline_button_clicked"
        }
      }

      conn = conn(:post, "/webhooks/telegram", params)

      {:ok, topic, event} = Telegram.handle_webhook(conn, params)

      assert topic == "telegram:12345"
      assert event.type == "callback_query"
      assert event.data.inline_message_id == "inline-msg-123"
    end
  end

  describe "handle_webhook/2 - channel posts" do
    test "parses channel photo post" do
      params = %{
        "update_id" => 123_456_789,
        "channel_post" => %{
          "message_id" => 100,
          "chat" => %{
            "id" => -100_123,
            "type" => "channel",
            "title" => "My Channel",
            "username" => "mychannel"
          },
          "photo" => [
            %{"file_id" => "photo-123", "width" => 800, "height" => 600}
          ],
          "caption" => "Channel photo",
          "date" => 1_609_459_200
        }
      }

      conn = conn(:post, "/webhooks/telegram", params)

      {:ok, _topic, event} = Telegram.handle_webhook(conn, params)

      assert event.type == "channel_photo"
    end
  end

  describe "handle_webhook/2 - unknown message type" do
    test "handles unknown message type" do
      params = %{
        "update_id" => 123_456_789,
        "message" => %{
          "message_id" => 100,
          "chat" => %{"id" => 12345, "type" => "private"},
          "from" => %{"id" => 12345},
          "date" => 1_609_459_200
          # No recognizable content type
        }
      }

      conn = conn(:post, "/webhooks/telegram", params)

      {:ok, _topic, event} = Telegram.handle_webhook(conn, params)

      assert event.type == "unknown"
    end
  end

  describe "handle_webhook/2 - chat_member updates" do
    test "parses chat_member update (not my_chat_member)" do
      params = %{
        "update_id" => 123_456_789,
        "chat_member" => %{
          "chat" => %{"id" => -100_123, "type" => "group", "title" => "Test Group"},
          "from" => %{"id" => 12345},
          "old_chat_member" => %{"status" => "member", "user" => %{"id" => 54321}},
          "new_chat_member" => %{"status" => "left", "user" => %{"id" => 54321}}
        }
      }

      conn = conn(:post, "/webhooks/telegram", params)

      {:ok, _topic, event} = Telegram.handle_webhook(conn, params)

      assert event.type == "chat_member_updated"
    end
  end

  describe "handle_webhook/2 - inline_query" do
    test "parses inline query" do
      params = %{
        "update_id" => 123_456_789,
        "inline_query" => %{
          "id" => "inline-123",
          "from" => %{"id" => 12345, "first_name" => "John"},
          "query" => "search term",
          "offset" => ""
        }
      }

      conn = conn(:post, "/webhooks/telegram", params)

      {:ok, _topic, event} = Telegram.handle_webhook(conn, params)

      assert event.type == "inline_query"
      assert event.data.query == "search term"
    end
  end

  describe "handle_webhook/2 - voice and video" do
    test "parses voice message" do
      params = %{
        "update_id" => 123_456_789,
        "message" => %{
          "message_id" => 100,
          "chat" => %{"id" => 12345, "type" => "private"},
          "from" => %{"id" => 12345, "first_name" => "John"},
          "date" => 1_609_459_200,
          "voice" => %{
            "file_id" => "voice-123",
            "duration" => 5
          }
        }
      }

      conn = conn(:post, "/webhooks/telegram", params)

      {:ok, _topic, event} = Telegram.handle_webhook(conn, params)

      assert event.type == "voice"
    end

    test "parses video message" do
      params = %{
        "update_id" => 123_456_789,
        "message" => %{
          "message_id" => 100,
          "chat" => %{"id" => 12345, "type" => "private"},
          "from" => %{"id" => 12345, "first_name" => "John"},
          "date" => 1_609_459_200,
          "video" => %{
            "file_id" => "video-123",
            "width" => 1280,
            "height" => 720,
            "duration" => 60
          }
        }
      }

      conn = conn(:post, "/webhooks/telegram", params)

      {:ok, _topic, event} = Telegram.handle_webhook(conn, params)

      assert event.type == "video"
    end
  end
end
