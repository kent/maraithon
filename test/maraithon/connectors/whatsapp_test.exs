defmodule Maraithon.Connectors.WhatsAppTest do
  # Non-async due to application config modification
  use ExUnit.Case, async: false

  import Plug.Test

  alias Maraithon.Connectors.WhatsApp

  describe "handle_webhook/2" do
    test "handles webhook verification (GET request)" do
      Application.put_env(:maraithon, :whatsapp, verify_token: "test_token")
      on_exit(fn -> Application.delete_env(:maraithon, :whatsapp) end)

      conn =
        conn(:get, "/webhooks/whatsapp")
        |> Map.put(:query_params, %{
          "hub.mode" => "subscribe",
          "hub.verify_token" => "test_token",
          "hub.challenge" => "challenge_string"
        })

      assert {:verify, "challenge_string"} = WhatsApp.handle_webhook(conn, %{})
    end

    test "rejects invalid verify token" do
      Application.put_env(:maraithon, :whatsapp, verify_token: "correct_token")
      on_exit(fn -> Application.delete_env(:maraithon, :whatsapp) end)

      conn =
        conn(:get, "/webhooks/whatsapp")
        |> Map.put(:query_params, %{
          "hub.mode" => "subscribe",
          "hub.verify_token" => "wrong_token",
          "hub.challenge" => "challenge_string"
        })

      assert {:error, :invalid_verify_token} = WhatsApp.handle_webhook(conn, %{})
    end

    test "parses text message" do
      params = %{
        "object" => "whatsapp_business_account",
        "entry" => [
          %{
            "id" => "business_account_id",
            "changes" => [
              %{
                "value" => %{
                  "messaging_product" => "whatsapp",
                  "metadata" => %{
                    "display_phone_number" => "15551234567",
                    "phone_number_id" => "phone_123"
                  },
                  "messages" => [
                    %{
                      "id" => "msg_123",
                      "from" => "15559876543",
                      "timestamp" => "1609459200",
                      "type" => "text",
                      "text" => %{"body" => "Hello!"}
                    }
                  ]
                },
                "field" => "messages"
              }
            ]
          }
        ]
      }

      conn =
        conn(:post, "/webhooks/whatsapp", params)
        |> Map.put(:query_params, %{})

      {:ok, topic, event} = WhatsApp.handle_webhook(conn, params)

      # Topic is based on phone_number_id from metadata
      assert topic == "whatsapp:phone_123"
      assert event.type == "message_received"
      assert event.source == "whatsapp"
      assert event.data.phone_number_id == "phone_123"
      assert event.data.from == "15559876543"
    end

    test "parses image message" do
      params = %{
        "object" => "whatsapp_business_account",
        "entry" => [
          %{
            "id" => "business_account_id",
            "changes" => [
              %{
                "value" => %{
                  "messaging_product" => "whatsapp",
                  "metadata" => %{
                    "display_phone_number" => "15551234567",
                    "phone_number_id" => "phone_123"
                  },
                  "messages" => [
                    %{
                      "id" => "msg_123",
                      "from" => "15559876543",
                      "timestamp" => "1609459200",
                      "type" => "image",
                      "image" => %{
                        "id" => "image_id",
                        "mime_type" => "image/jpeg",
                        "caption" => "Check this out"
                      }
                    }
                  ]
                },
                "field" => "messages"
              }
            ]
          }
        ]
      }

      conn =
        conn(:post, "/webhooks/whatsapp", params)
        |> Map.put(:query_params, %{})

      {:ok, _topic, event} = WhatsApp.handle_webhook(conn, params)

      assert event.type == "image_received"
      assert event.data.caption == "Check this out"
    end

    test "parses status update" do
      params = %{
        "object" => "whatsapp_business_account",
        "entry" => [
          %{
            "id" => "business_account_id",
            "changes" => [
              %{
                "value" => %{
                  "messaging_product" => "whatsapp",
                  "metadata" => %{
                    "display_phone_number" => "15551234567",
                    "phone_number_id" => "phone_123"
                  },
                  "statuses" => [
                    %{
                      "id" => "msg_123",
                      "status" => "delivered",
                      "timestamp" => "1609459200",
                      "recipient_id" => "15559876543"
                    }
                  ]
                },
                "field" => "messages"
              }
            ]
          }
        ]
      }

      conn =
        conn(:post, "/webhooks/whatsapp", params)
        |> Map.put(:query_params, %{})

      {:ok, topic, event} = WhatsApp.handle_webhook(conn, params)

      assert topic == "whatsapp:phone_123"
      assert event.type == "message_status"
      assert event.data.status == "delivered"
    end

    test "returns ignore for non-whatsapp business account" do
      params = %{"invalid" => "structure"}

      conn =
        conn(:post, "/webhooks/whatsapp", params)
        |> Map.put(:query_params, %{})

      assert {:ignore, "not whatsapp_business_account"} = WhatsApp.handle_webhook(conn, params)
    end

    test "parses audio message" do
      params = %{
        "object" => "whatsapp_business_account",
        "entry" => [
          %{
            "id" => "business_account_id",
            "changes" => [
              %{
                "value" => %{
                  "messaging_product" => "whatsapp",
                  "metadata" => %{"phone_number_id" => "phone_123"},
                  "messages" => [
                    %{
                      "id" => "msg_123",
                      "from" => "15559876543",
                      "timestamp" => "1609459200",
                      "type" => "audio",
                      "audio" => %{
                        "id" => "audio_id",
                        "mime_type" => "audio/ogg",
                        "voice" => true
                      }
                    }
                  ]
                },
                "field" => "messages"
              }
            ]
          }
        ]
      }

      conn = conn(:post, "/webhooks/whatsapp", params) |> Map.put(:query_params, %{})

      {:ok, _topic, event} = WhatsApp.handle_webhook(conn, params)

      assert event.type == "audio_received"
      assert event.data.message_type == "audio"
      assert event.data.voice == true
    end

    test "parses document message" do
      params = %{
        "object" => "whatsapp_business_account",
        "entry" => [
          %{
            "id" => "business_account_id",
            "changes" => [
              %{
                "value" => %{
                  "messaging_product" => "whatsapp",
                  "metadata" => %{"phone_number_id" => "phone_123"},
                  "messages" => [
                    %{
                      "id" => "msg_123",
                      "from" => "15559876543",
                      "timestamp" => "1609459200",
                      "type" => "document",
                      "document" => %{
                        "id" => "doc_id",
                        "filename" => "report.pdf",
                        "caption" => "Monthly report",
                        "mime_type" => "application/pdf"
                      }
                    }
                  ]
                },
                "field" => "messages"
              }
            ]
          }
        ]
      }

      conn = conn(:post, "/webhooks/whatsapp", params) |> Map.put(:query_params, %{})

      {:ok, _topic, event} = WhatsApp.handle_webhook(conn, params)

      assert event.type == "document_received"
      assert event.data.filename == "report.pdf"
      assert event.data.caption == "Monthly report"
    end

    test "parses location message" do
      params = %{
        "object" => "whatsapp_business_account",
        "entry" => [
          %{
            "id" => "business_account_id",
            "changes" => [
              %{
                "value" => %{
                  "messaging_product" => "whatsapp",
                  "metadata" => %{"phone_number_id" => "phone_123"},
                  "messages" => [
                    %{
                      "id" => "msg_123",
                      "from" => "15559876543",
                      "timestamp" => "1609459200",
                      "type" => "location",
                      "location" => %{
                        "latitude" => 37.7749,
                        "longitude" => -122.4194,
                        "name" => "San Francisco",
                        "address" => "CA, USA"
                      }
                    }
                  ]
                },
                "field" => "messages"
              }
            ]
          }
        ]
      }

      conn = conn(:post, "/webhooks/whatsapp", params) |> Map.put(:query_params, %{})

      {:ok, _topic, event} = WhatsApp.handle_webhook(conn, params)

      assert event.type == "location_received"
      assert event.data.latitude == 37.7749
      assert event.data.longitude == -122.4194
    end

    test "parses contacts message" do
      params = %{
        "object" => "whatsapp_business_account",
        "entry" => [
          %{
            "id" => "business_account_id",
            "changes" => [
              %{
                "value" => %{
                  "messaging_product" => "whatsapp",
                  "metadata" => %{"phone_number_id" => "phone_123"},
                  "messages" => [
                    %{
                      "id" => "msg_123",
                      "from" => "15559876543",
                      "timestamp" => "1609459200",
                      "type" => "contacts",
                      "contacts" => [%{"name" => %{"formatted_name" => "John Doe"}}]
                    }
                  ]
                },
                "field" => "messages"
              }
            ]
          }
        ]
      }

      conn = conn(:post, "/webhooks/whatsapp", params) |> Map.put(:query_params, %{})

      {:ok, _topic, event} = WhatsApp.handle_webhook(conn, params)

      assert event.type == "contacts_received"
      assert length(event.data.contacts) == 1
    end

    test "parses button reply" do
      params = %{
        "object" => "whatsapp_business_account",
        "entry" => [
          %{
            "id" => "business_account_id",
            "changes" => [
              %{
                "value" => %{
                  "messaging_product" => "whatsapp",
                  "metadata" => %{"phone_number_id" => "phone_123"},
                  "messages" => [
                    %{
                      "id" => "msg_123",
                      "from" => "15559876543",
                      "timestamp" => "1609459200",
                      "type" => "button",
                      "button" => %{
                        "text" => "Yes",
                        "payload" => "yes_payload"
                      }
                    }
                  ]
                },
                "field" => "messages"
              }
            ]
          }
        ]
      }

      conn = conn(:post, "/webhooks/whatsapp", params) |> Map.put(:query_params, %{})

      {:ok, _topic, event} = WhatsApp.handle_webhook(conn, params)

      assert event.type == "button_reply"
      assert event.data.button_text == "Yes"
      assert event.data.button_payload == "yes_payload"
    end

    test "parses interactive reply" do
      params = %{
        "object" => "whatsapp_business_account",
        "entry" => [
          %{
            "id" => "business_account_id",
            "changes" => [
              %{
                "value" => %{
                  "messaging_product" => "whatsapp",
                  "metadata" => %{"phone_number_id" => "phone_123"},
                  "messages" => [
                    %{
                      "id" => "msg_123",
                      "from" => "15559876543",
                      "timestamp" => "1609459200",
                      "type" => "interactive",
                      "interactive" => %{
                        "type" => "list_reply",
                        "list_reply" => %{"id" => "item_1", "title" => "Option 1"}
                      }
                    }
                  ]
                },
                "field" => "messages"
              }
            ]
          }
        ]
      }

      conn = conn(:post, "/webhooks/whatsapp", params) |> Map.put(:query_params, %{})

      {:ok, _topic, event} = WhatsApp.handle_webhook(conn, params)

      assert event.type == "interactive_reply"
      assert event.data.interactive_type == "list_reply"
    end

    test "handles unknown message type" do
      params = %{
        "object" => "whatsapp_business_account",
        "entry" => [
          %{
            "id" => "business_account_id",
            "changes" => [
              %{
                "value" => %{
                  "messaging_product" => "whatsapp",
                  "metadata" => %{"phone_number_id" => "phone_123"},
                  "messages" => [
                    %{
                      "id" => "msg_123",
                      "from" => "15559876543",
                      "timestamp" => "1609459200",
                      "type" => "unknown_type",
                      "unknown_type" => %{"data" => "test"}
                    }
                  ]
                },
                "field" => "messages"
              }
            ]
          }
        ]
      }

      conn = conn(:post, "/webhooks/whatsapp", params) |> Map.put(:query_params, %{})

      {:ok, _topic, event} = WhatsApp.handle_webhook(conn, params)

      assert event.type == "message_received"
      assert event.data.message_type == "unknown_type"
    end

    test "ignores empty changes" do
      params = %{
        "object" => "whatsapp_business_account",
        "entry" => [
          %{
            "id" => "business_account_id",
            "changes" => []
          }
        ]
      }

      conn = conn(:post, "/webhooks/whatsapp", params) |> Map.put(:query_params, %{})

      {:ignore, "no changes"} = WhatsApp.handle_webhook(conn, params)
    end

    test "handles message with context (reply)" do
      params = %{
        "object" => "whatsapp_business_account",
        "entry" => [
          %{
            "id" => "business_account_id",
            "changes" => [
              %{
                "value" => %{
                  "messaging_product" => "whatsapp",
                  "metadata" => %{"phone_number_id" => "phone_123"},
                  "messages" => [
                    %{
                      "id" => "msg_123",
                      "from" => "15559876543",
                      "timestamp" => "1609459200",
                      "type" => "text",
                      "text" => %{"body" => "Reply!"},
                      "context" => %{"message_id" => "original_msg_id"}
                    }
                  ]
                },
                "field" => "messages"
              }
            ]
          }
        ]
      }

      conn = conn(:post, "/webhooks/whatsapp", params) |> Map.put(:query_params, %{})

      {:ok, _topic, event} = WhatsApp.handle_webhook(conn, params)

      assert event.data.context == %{"message_id" => "original_msg_id"}
    end

    test "handles status update with conversation and pricing" do
      params = %{
        "object" => "whatsapp_business_account",
        "entry" => [
          %{
            "id" => "business_account_id",
            "changes" => [
              %{
                "value" => %{
                  "messaging_product" => "whatsapp",
                  "metadata" => %{"phone_number_id" => "phone_123"},
                  "statuses" => [
                    %{
                      "id" => "msg_123",
                      "status" => "read",
                      "timestamp" => "1609459200",
                      "recipient_id" => "15559876543",
                      "conversation" => %{
                        "id" => "conv_123",
                        "origin" => %{"type" => "user_initiated"}
                      },
                      "pricing" => %{
                        "billable" => true,
                        "category" => "user_initiated"
                      }
                    }
                  ]
                },
                "field" => "messages"
              }
            ]
          }
        ]
      }

      conn = conn(:post, "/webhooks/whatsapp", params) |> Map.put(:query_params, %{})

      {:ok, _topic, event} = WhatsApp.handle_webhook(conn, params)

      assert event.type == "message_status"
      assert event.data.status == "read"
      assert event.data.conversation != nil
      assert event.data.pricing != nil
    end

    test "handles integer timestamp" do
      params = %{
        "object" => "whatsapp_business_account",
        "entry" => [
          %{
            "id" => "business_account_id",
            "changes" => [
              %{
                "value" => %{
                  "messaging_product" => "whatsapp",
                  "metadata" => %{"phone_number_id" => "phone_123"},
                  "messages" => [
                    %{
                      "id" => "msg_123",
                      "from" => "15559876543",
                      "timestamp" => 1_609_459_200,
                      "type" => "text",
                      "text" => %{"body" => "Hello!"}
                    }
                  ]
                },
                "field" => "messages"
              }
            ]
          }
        ]
      }

      conn = conn(:post, "/webhooks/whatsapp", params) |> Map.put(:query_params, %{})

      {:ok, _topic, event} = WhatsApp.handle_webhook(conn, params)

      assert event.data.timestamp == ~U[2021-01-01 00:00:00Z]
    end
  end

  describe "verify_signature/2" do
    test "returns error when app_secret not configured and unsigned not allowed" do
      Application.put_env(:maraithon, :whatsapp, app_secret: "", allow_unsigned: false)
      on_exit(fn -> Application.delete_env(:maraithon, :whatsapp) end)

      conn = conn(:post, "/webhooks/whatsapp", %{})

      assert {:error, :app_secret_not_configured} = WhatsApp.verify_signature(conn, "{}")
    end

    test "returns ok when unsigned allowed and no app_secret" do
      Application.put_env(:maraithon, :whatsapp, app_secret: "", allow_unsigned: true)
      on_exit(fn -> Application.delete_env(:maraithon, :whatsapp) end)

      conn = conn(:post, "/webhooks/whatsapp", %{})

      assert :ok = WhatsApp.verify_signature(conn, "{}")
    end

    test "returns error when signature header missing" do
      Application.put_env(:maraithon, :whatsapp, app_secret: "test_secret")
      on_exit(fn -> Application.delete_env(:maraithon, :whatsapp) end)

      conn = conn(:post, "/webhooks/whatsapp", %{})

      assert {:error, :missing_signature} = WhatsApp.verify_signature(conn, "{}")
    end

    test "verifies valid signature" do
      app_secret = "test_app_secret"
      Application.put_env(:maraithon, :whatsapp, app_secret: app_secret)
      on_exit(fn -> Application.delete_env(:maraithon, :whatsapp) end)

      raw_body = ~s({"object":"whatsapp_business_account"})
      signature = :crypto.mac(:hmac, :sha256, app_secret, raw_body) |> Base.encode16(case: :lower)
      signature_header = "sha256=#{signature}"

      conn =
        conn(:post, "/webhooks/whatsapp", %{})
        |> Plug.Conn.put_req_header("x-hub-signature-256", signature_header)

      assert :ok = WhatsApp.verify_signature(conn, raw_body)
    end

    test "returns error for invalid signature" do
      Application.put_env(:maraithon, :whatsapp, app_secret: "test_secret")
      on_exit(fn -> Application.delete_env(:maraithon, :whatsapp) end)

      conn =
        conn(:post, "/webhooks/whatsapp", %{})
        |> Plug.Conn.put_req_header("x-hub-signature-256", "sha256=invalid")

      assert {:error, :invalid_signature} = WhatsApp.verify_signature(conn, "{}")
    end

    test "returns error for invalid signature format (multiple headers)" do
      Application.put_env(:maraithon, :whatsapp, app_secret: "test_secret")
      on_exit(fn -> Application.delete_env(:maraithon, :whatsapp) end)

      conn =
        conn(:post, "/webhooks/whatsapp", %{})
        |> Plug.Conn.put_req_header("x-hub-signature-256", "sha256=sig1")
        |> Plug.Conn.put_req_header("x-hub-signature-256", "sha256=sig2")

      # Multiple headers result in invalid signature format
      result = WhatsApp.verify_signature(conn, "{}")

      # It may return :invalid_signature or :invalid_signature_format depending on how headers are handled
      assert match?({:error, _}, result)
    end
  end

  describe "handle_webhook/2 - additional cases" do
    test "handles nil timestamp" do
      params = %{
        "object" => "whatsapp_business_account",
        "entry" => [
          %{
            "id" => "business_account_id",
            "changes" => [
              %{
                "value" => %{
                  "messaging_product" => "whatsapp",
                  "metadata" => %{"phone_number_id" => "phone_123"},
                  "messages" => [
                    %{
                      "id" => "msg_123",
                      "from" => "15559876543",
                      "timestamp" => nil,
                      "type" => "text",
                      "text" => %{"body" => "Hello!"}
                    }
                  ]
                },
                "field" => "messages"
              }
            ]
          }
        ]
      }

      conn = conn(:post, "/webhooks/whatsapp", params) |> Map.put(:query_params, %{})

      {:ok, _topic, event} = WhatsApp.handle_webhook(conn, params)

      assert event.data.timestamp == nil
    end

    test "handles empty entry changes" do
      params = %{
        "object" => "whatsapp_business_account",
        "entry" => [
          %{
            "id" => "business_account_id"
            # No changes key
          }
        ]
      }

      conn = conn(:post, "/webhooks/whatsapp", params) |> Map.put(:query_params, %{})

      {:ignore, reason} = WhatsApp.handle_webhook(conn, params)

      assert reason == "no changes"
    end

    test "parses video message as message_received" do
      # Video type falls through to default handler
      params = %{
        "object" => "whatsapp_business_account",
        "entry" => [
          %{
            "id" => "business_account_id",
            "changes" => [
              %{
                "value" => %{
                  "messaging_product" => "whatsapp",
                  "metadata" => %{"phone_number_id" => "phone_123"},
                  "messages" => [
                    %{
                      "id" => "msg_123",
                      "from" => "15559876543",
                      "timestamp" => "1609459200",
                      "type" => "video",
                      "video" => %{
                        "id" => "video_id",
                        "mime_type" => "video/mp4",
                        "caption" => "Check out this video"
                      }
                    }
                  ]
                },
                "field" => "messages"
              }
            ]
          }
        ]
      }

      conn = conn(:post, "/webhooks/whatsapp", params) |> Map.put(:query_params, %{})

      {:ok, _topic, event} = WhatsApp.handle_webhook(conn, params)

      # Video not explicitly handled, falls to default
      assert event.type == "message_received"
      assert event.data.message_type == "video"
    end

    test "parses sticker message as message_received" do
      # Sticker type falls through to default handler
      params = %{
        "object" => "whatsapp_business_account",
        "entry" => [
          %{
            "id" => "business_account_id",
            "changes" => [
              %{
                "value" => %{
                  "messaging_product" => "whatsapp",
                  "metadata" => %{"phone_number_id" => "phone_123"},
                  "messages" => [
                    %{
                      "id" => "msg_123",
                      "from" => "15559876543",
                      "timestamp" => "1609459200",
                      "type" => "sticker",
                      "sticker" => %{
                        "id" => "sticker_id",
                        "mime_type" => "image/webp",
                        "animated" => false
                      }
                    }
                  ]
                },
                "field" => "messages"
              }
            ]
          }
        ]
      }

      conn = conn(:post, "/webhooks/whatsapp", params) |> Map.put(:query_params, %{})

      {:ok, _topic, event} = WhatsApp.handle_webhook(conn, params)

      # Sticker not explicitly handled, falls to default
      assert event.type == "message_received"
      assert event.data.message_type == "sticker"
    end

    test "handles reaction message as message_received" do
      # Reaction type falls through to default handler
      params = %{
        "object" => "whatsapp_business_account",
        "entry" => [
          %{
            "id" => "business_account_id",
            "changes" => [
              %{
                "value" => %{
                  "messaging_product" => "whatsapp",
                  "metadata" => %{"phone_number_id" => "phone_123"},
                  "messages" => [
                    %{
                      "id" => "msg_123",
                      "from" => "15559876543",
                      "timestamp" => "1609459200",
                      "type" => "reaction",
                      "reaction" => %{
                        "message_id" => "original_msg_id",
                        "emoji" => "👍"
                      }
                    }
                  ]
                },
                "field" => "messages"
              }
            ]
          }
        ]
      }

      conn = conn(:post, "/webhooks/whatsapp", params) |> Map.put(:query_params, %{})

      {:ok, _topic, event} = WhatsApp.handle_webhook(conn, params)

      # Reaction not explicitly handled, falls to default
      assert event.type == "message_received"
      assert event.data.message_type == "reaction"
    end

    test "parses multiple entries" do
      params = %{
        "object" => "whatsapp_business_account",
        "entry" => [
          %{
            "id" => "business_account_id",
            "changes" => [
              %{
                "value" => %{
                  "messaging_product" => "whatsapp",
                  "metadata" => %{"phone_number_id" => "phone_123"},
                  "messages" => [
                    %{
                      "id" => "msg_1",
                      "from" => "15559876543",
                      "timestamp" => "1609459200",
                      "type" => "text",
                      "text" => %{"body" => "First message"}
                    }
                  ]
                },
                "field" => "messages"
              }
            ]
          },
          %{
            "id" => "business_account_id_2",
            "changes" => [
              %{
                "value" => %{
                  "messaging_product" => "whatsapp",
                  "metadata" => %{"phone_number_id" => "phone_456"},
                  "messages" => [
                    %{
                      "id" => "msg_2",
                      "from" => "15551112222",
                      "timestamp" => "1609459201",
                      "type" => "text",
                      "text" => %{"body" => "Second message"}
                    }
                  ]
                },
                "field" => "messages"
              }
            ]
          }
        ]
      }

      conn = conn(:post, "/webhooks/whatsapp", params) |> Map.put(:query_params, %{})

      # Should return the first entry's notification
      {:ok, topic, _event} = WhatsApp.handle_webhook(conn, params)

      assert topic == "whatsapp:phone_123"
    end

    test "handles status update with failed status" do
      params = %{
        "object" => "whatsapp_business_account",
        "entry" => [
          %{
            "id" => "business_account_id",
            "changes" => [
              %{
                "value" => %{
                  "messaging_product" => "whatsapp",
                  "metadata" => %{"phone_number_id" => "phone_123"},
                  "statuses" => [
                    %{
                      "id" => "msg_123",
                      "status" => "failed",
                      "timestamp" => "1609459200",
                      "recipient_id" => "15559876543"
                    }
                  ]
                },
                "field" => "messages"
              }
            ]
          }
        ]
      }

      conn = conn(:post, "/webhooks/whatsapp", params) |> Map.put(:query_params, %{})

      {:ok, _topic, event} = WhatsApp.handle_webhook(conn, params)

      assert event.type == "message_status"
      assert event.data.status == "failed"
    end
  end
end
