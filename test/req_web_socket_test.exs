defmodule ReqWebSocketTest do
  use ExUnit.Case, async: true

  @moduletag handler_action: {:ping, ""}, schemes: {:http, :ws}, send_conn: false

  setup context do
    Process.register(self(), context.test)
    :ok
  end

  setup [:build_req]

  describe "http negotiation" do
    @describetag :send_conn

    test "http for ws", context do
      spawn(fn -> Req.get(context.req, into: :self) end)
      assert_receive %{scheme: :http}
    end

    @tag schemes: {:https, :wss}
    test "https for wss", context do
      spawn(fn -> Req.get(context.req, into: :self) end)
      assert_receive %{scheme: :https}
    end

    test "includes headers", context do
      spawn(fn -> Req.get(context.req, auth: {:bearer, "token"}, into: :self) end)
      assert_receive conn
      assert {"authorization", "Bearer token"} in conn.req_headers
    end

    test "supports path params", context do
      spawn(fn ->
        Req.get(context.req, path_params: [token: "foo"], url: "/:token", into: :self)
      end)

      assert_receive conn
      assert conn.request_path == "/foo"
    end

    test "includes query params", context do
      spawn(fn -> Req.get(context.req, params: [token: "foo"], into: :self) end)

      assert_receive conn
      assert conn.query_string == "token=foo"
    end

    test "supports AWS signature", context do
      spawn(fn ->
        Req.get(context.req,
          aws_sigv4: [access_key_id: "id", secret_access_key: "key", service: :s3],
          into: :self
        )
      end)

      assert_receive conn
      assert List.keyfind(conn.req_headers, "authorization", 0)
    end

    test "ignores http(s) URLs", context do
      assert {:ok, resp} =
               Req.get(context.req, plug: &Req.Test.text(&1, "ok"), url: "https://example.com")

      assert resp.body == "ok"
    end
  end

  describe "into: fun" do
    test "receives ping as fun argument", context do
      assert {:ok, _resp} =
               Req.get(context.req,
                 into: fn {:data, frames}, {req, resp} ->
                   send(context.test, frames)
                   {:halt, {req, resp}}
                 end
               )

      assert_receive [{:ping, ""}]
    end

    test "sends frame in response to ping", context do
      assert {:ok, _resp} =
               Req.get(context.req,
                 into: fn
                   {:data, ping: _}, {req, resp} ->
                     {:cont, [{:text, "Hello, World"}], {req, resp}}

                   {:data, text: text}, acc ->
                     send(context.test, text)
                     {:halt, acc}
                 end
               )

      assert_receive "in: Hello, World"
    end

    test "sends frame and halts", context do
      assert {:ok, _resp} =
               Req.get(context.req,
                 into: fn
                   {:data, ping: _}, {req, resp} ->
                     {:halt, [{:text, "Hello, World"}], {req, resp}}
                 end
               )

      assert_receive "in: Hello, World"
    end

    @tag :send_conn
    test "accommodates redirects", context do
      spawn(fn -> Req.get(context.req, into: fn _, acc -> {:halt, acc} end, url: "/redirect") end)
      assert_receive %{request_path: "/"}
      refute_receive _
    end

    @tag :send_conn
    test "accommodates retries", context do
      spawn(fn ->
        Req.get(context.req, into: fn _, acc -> {:halt, acc} end, url: "/fail-once")
      end)

      assert_receive %{request_path: "/fail-once"}
      assert_receive %{request_path: "/fail-once"}
      refute_receive _
    end
  end

  describe "into: :self" do
    test "receives ping in process mailbox", context do
      spawn(fn ->
        {:ok, resp} = Req.get(context.req, into: :self)

        receive do
          message -> send(context.test, ReqWebSocket.parse_message(resp, message))
        end
      end)

      assert_receive {:ok, _resp, [ping: ""]}
    end

    test "does not intercept unrelated messages from mailbox", context do
      spawn(fn ->
        ref = make_ref()
        send(self(), ref)

        {:ok, resp} = Req.get(context.req, into: :self)

        assert_receive ^ref

        receive do
          message -> send(context.test, ReqWebSocket.parse_message(resp, message))
        end
      end)

      assert_receive {:ok, _resp, [ping: ""]}
    end

    @tag handler_action: nil
    test "sends frame", context do
      spawn(fn ->
        assert {:ok, resp} = Req.get(context.req, into: :self)
        assert {:ok, _resp} = ReqWebSocket.send_frame(resp, {:text, "Hello, World"})
      end)

      assert_receive "in: Hello, World"
    end

    @tag handler_action: nil
    test "sends frames", context do
      spawn(fn ->
        assert {:ok, resp} = Req.get(context.req, into: :self)
        assert {:ok, _resp} = ReqWebSocket.send_frames(resp, [{:text, "Hello"}, {:ping, ""}])

        receive do
          message -> send(context.test, ReqWebSocket.parse_message(resp, message))
        end
      end)

      assert_receive "in: Hello"
      assert_receive {:ok, _resp, [pong: ""]}
    end

    @tag :send_conn
    test "accommodates redirects", context do
      spawn(fn -> Req.get(context.req, into: :self, url: "/redirect") end)
      assert_receive %{request_path: "/"}
      refute_receive _
    end

    @tag :send_conn
    test "accommodates retries", context do
      spawn(fn -> Req.get(context.req, into: :self, url: "/fail-once") end)

      assert_receive %{request_path: "/fail-once"}
      assert_receive %{request_path: "/fail-once"}
      refute_receive _
    end

    @tag handler_action: nil
    test "closes connection", context do
      spawn(fn ->
        assert {:ok, resp} = Req.get(context.req, into: :self)
        assert {:ok, resp} = ReqWebSocket.close(resp)
        assert {:error, _resp, %{reason: :closed}} = ReqWebSocket.send_frame(resp, :ping)
      end)

      refute_receive _
    end
  end

  test "unknown message parsing", context do
    spawn(fn ->
      {:ok, resp} = Req.get(context.req, into: :self)
      send(context.test, ReqWebSocket.parse_message(resp, "junk"))
    end)

    assert_receive :unknown
  end

  defmodule StubHandler do
    @behaviour WebSock

    def handle_info(_, test), do: {:ok, test}

    def handle_in({msg, [opcode: :text]}, test) do
      send(test, "in: " <> msg)
      {:ok, test}
    end

    def handle_control(msg, [opcode: :ping], state) do
      {:push, [{:pong, msg}], state}
    end

    def init({nil, test}), do: {:ok, test}
    def init({action, test}), do: {:push, [action], test}
  end

  defp build_req(context) do
    agent = start_supervised!({Agent, fn -> 0 end})

    plug = fn
      %{request_path: "/fail-once"} = conn, _opts ->
        count = Agent.get_and_update(agent, &{&1, &1 + 1})

        if context.send_conn, do: send(context.test, conn)

        if count >= 1 do
          WebSockAdapter.upgrade(conn, StubHandler, {context.handler_action, context.test}, [])
        else
          Plug.Conn.send_resp(conn, 500, "error")
        end

      %{request_path: "/redirect"} = conn, _opts ->
        conn
        |> Plug.Conn.put_resp_header("location", "/")
        |> Plug.Conn.send_resp(301, "")

      conn, _opts ->
        if context.send_conn, do: send(context.test, conn)
        WebSockAdapter.upgrade(conn, StubHandler, {context.handler_action, context.test}, [])
    end

    {http_scheme, ws_scheme} = context.schemes
    {port, connect_options} = start_bandit!(http_scheme, plug)

    req =
      Req.new(
        base_url: "#{ws_scheme}://localhost:#{port}/",
        connect_options: connect_options,
        plugins: [ReqWebSocket],
        redirect_log_level: false,
        retry_delay: 0,
        retry_log_level: false
      )

    %{req: req}
  end

  defp start_bandit!(:http, plug) do
    pid =
      start_supervised!({Bandit, plug: plug, port: 0, scheme: :http, startup_log: false},
        restart: :temporary
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(pid)
    {port, []}
  end

  defp start_bandit!(:https, plug) do
    suite = X509.Test.Suite.new()

    pid =
      start_supervised!(
        {Bandit,
         plug: plug,
         port: 0,
         scheme: :https,
         startup_log: false,
         thousand_island_options: [
           transport_options: [
             cacerts: suite.chain ++ suite.cacerts,
             cert: X509.Certificate.to_der(suite.valid),
             key: {:PrivateKeyInfo, X509.PrivateKey.to_der(suite.server_key, wrap: true)}
           ]
         ]},
        restart: :temporary
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(pid)
    {port, [protocols: [:http1], transport_opts: [cacerts: suite.cacerts]]}
  end
end
