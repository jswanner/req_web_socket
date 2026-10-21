defmodule ReqWebSocket do
  @moduledoc """
  `Req` plugin for establishing WebSocket connections, using `Mint.WebSocket`.
  See `attach/2` for supported options.

  ## Examples

      {:ok, _resp, [pong: ""]} =
        Req.new("wss://echo.websocket.org/")
        |> ReqWebSocket.attach()
        |> Req.stream([], fn
          [text: _], resp, acc ->
            ReqWebSocket.send_frame(resp, :ping)
            {:cont, acc}

          frames, _resp, acc ->
            {:halt, acc ++ frames}
        end)

      resp =
        Req.new()
        |> ReqWebSocket.attach()
        |> Req.get!(into: :self, url: "wss://echo.websocket.org/")

      message = receive do message -> message end
      {:ok, [text: _]} = Req.parse_message(resp, message)

      {:ok, resp} = ReqWebSocket.send_frame(resp, :ping)

      message = receive do message -> message end
      {:ok, [pong: ""]} = Req.parse_message(resp, message)
  """

  defmodule UnsupportedIntoError do
    @moduledoc false

    defexception [:actual]

    @impl true
    def message(%{actual: actual}) do
      """
      unsupported `:into` option
      expected: :self or &fun/2
      actual:   #{inspect(actual)}\
      """
    end
  end

  @behaviour Req.Adapter

  @http_scheme Module.concat(__MODULE__, :http_scheme)
  @ws_scheme Module.concat(__MODULE__, :ws_scheme)

  @doc """
  Adds the plugin to the `Req.Request` struct. Since this plugin replaces the
  adapter that is used, not all of the options supported by `Req.new/1` are
  applicable, this also means there is no connection pooling. This plugin does
  not add any additional options beyond what Req itself provides.

  ## Supported Options

  Basic request options:

  * `:url` - the request URL. This plugin will only replace the adapter if the URL scheme is
    `wss` or `ws`, otherwise this plugin will have no affect on the request.

  * `:headers` - the request headers as a `{key, value}` enumerable (e.g. map, keyword list).

    The header names should be downcased.

    The headers are automatically encoded using these rules:

      * atom header names are turned into strings, replacing `_` with `-`. For example,
        `:user_agent` becomes `"user-agent"`.

      * string header names are downcased.

      * `%DateTime{}` header values are encoded as "HTTP date".

    If you set `:headers` options both in `Req.new/1` and `Req.request/2`, the
    header lists are merged.

    See also "Headers" section in the module documentation.

  Additional URL options:

  * `:base_url` - if set, the request URL is prepended with this base URL (via
    [`put_base_url`](`Req.Steps.put_base_url/1`) step.)

  * `:params` - if set, appends parameters to the request query string (via
    [`put_params`](`Req.Steps.put_params/1`) step.)

  * `:path_params` - if set, uses a templated request path (via
    [`put_path_params`](`Req.Steps.put_path_params/1`) step.)

  * `:path_params_style` (*available since v0.5.1*) - how path params are expressed (via
    [`put_path_params`](`Req.Steps.put_path_params/1`) step). Can be one of:

       * `:colon` - (default) for Plug-style parameters, such as `:code` in
         `https://httpbin.org/status/:code`.

       * `:curly` - for [OpenAPI](https://swagger.io/specification/)-style parameters, such as
         `{code}` in `https://httpbin.org/status/{code}`.

  Authentication options:

  * `:auth` - sets request authentication (via [`auth`](`Req.Steps.auth/1`) step.)

    Can be one of:

      * `{:basic, userinfo}` - uses Basic HTTP authentication.

      * `{:bearer, token}` - uses Bearer HTTP authentication.

      * `:netrc` - load credentials from the default .netrc file.

      * `{:netrc, path}` - load credentials from `path`.

      * `string` - sets to this value.

      * `&fun/0` - a function that returns one of the above (such as a `{:bearer, token}`).

  AWS Signature Version 4 options ([`put_aws_sigv4`](`Req.Steps.put_aws_sigv4/1`) step):

  * `:aws_sigv4` - if set, the AWS options to sign request:

      * `:access_key_id` - the AWS access key id.

      * `:secret_access_key` - the AWS secret access key.

      * `:service` - the AWS service.

      * `:region` - if set, AWS region. Defaults to `"us-east-1"`.

      * `:datetime` - the request datetime, defaults to `DateTime.utc_now(:second)`.

  Response body options:

  * `:into` - where to send the response body. It can be one of:

      * `:self` - stream response body into the current process mailbox.

        Received messages should be parsed with `Req.parse_message/2`.

      * `fun` - (Deprecated) stream response body using a function. The first argument is a
        `{:data, frames}` tuple containing the message frames of the response body. The second
        argument is a `{request, response}` tuple. To continue streaming frames, return
        `{:cont, {req, resp}}`. To cancel, return `{:halt, {req, resp}}`. See `send_frame/2` for
        supported frame types.
        For example:

            into: fn {:data, [ping: string]}, {req, resp} ->
              ReqWebSocket.send_frame(resp, {:pong, string})
              {:cont, {req, resp}}
            end

  Response redirect options ([`redirect`](`Req.Steps.redirect/1`) step):

  * `:redirect` - if set to `false`, disables automatic response redirects. Defaults to `true`.

  * `:redirect_trusted` - by default, authorization credentials are only sent on redirects
    with the same host, scheme and port. If `:redirect_trusted` is set to `true`, credentials
    will be sent to any host.

  * `:max_redirects` - the maximum number of redirects, defaults to `10`.

  Other response options:

  * `:http_errors` - how to handle HTTP 4xx/5xx error responses (via
    [`handle_http_errors`](`Req.Steps.handle_http_errors/1`) step).
    Can be one of the following:

    * `:return` (default) - return the response

    * `:raise` - raise an error

  Retry options ([`retry`](`Req.Steps.retry/1`) step):

  * `:retry` - can be one of the following:

      * `:safe_transient` (default) - retry safe (GET/HEAD) requests on one of:

          * HTTP 408/429/500/502/503/504 responses

          * `Req.TransportError` with `reason: :timeout | :econnrefused | :closed`

          * `Req.HTTPError` with `protocol: :http2, reason: :unprocessed`

      * `:transient` - same as `:safe_transient` except retries all HTTP methods (POST, DELETE, etc.)

      * `fun` - a 2-arity function that accepts a `Req.Request` and either a `Req.Response` or an exception struct
        and returns one of the following:

          * `true` - retry with the default delay controller by default delay option described below.

          * `{:delay, milliseconds}` - retry with the given delay.

          * `false/nil` - don't retry.

      * `false` - don't retry.

  * `:retry_delay` - if not set, which is the default, the retry delay is determined by
    the value of the `Retry-After` header on HTTP 429/503 responses. If the header is not set,
    the default delay follows a simple exponential backoff: 1s, 2s, 4s, 8s, ...

    `:retry_delay` can be set to a function that receives the retry count (starting at 0)
    and returns the delay, the number of milliseconds to sleep before making another attempt.

  * `:retry_log_level` - the log level to emit retry logs at. Can also be set to `false` to disable
    logging these messages. Defaults to `:warning`.

  * `:max_retries` - maximum number of retry attempts, defaults to `3` (for a total of `4`
    requests to the server, including the initial one.)

  Other request options:

  * `:connect_options` - used when establishing HTTP connection,
    (see `Mint.HTTP.connect/4` for details):

      * `:timeout` - socket connect timeout in milliseconds, defaults to `30_000`.

      * `:protocols` - the HTTP protocols to use, defaults to `[:http1, :http2]`.

      * `:hostname` - Mint explicit hostname.

      * `:transport_opts` - Mint transport options.

      * `:proxy_headers` - Mint proxy headers.

      * `:proxy` - Mint HTTP/1 proxy settings, a `{schema, address, port, options}` tuple.

      * `:client_settings` - Mint HTTP/2 client settings.
  """
  @spec attach(Req.Request.t(), keyword()) :: Req.Request.t()
  def attach(request, options \\ []) do
    request
    |> Req.Request.merge_options(options)
    |> Req.Request.append_request_steps(websocket: &put_websocket/1)
  end

  @doc """
  Closes WebSocket connection.
  """
  @spec close(Req.Response.t()) :: {:ok, Req.Response.t()}
  def close(response) do
    response =
      Req.Response.update_private(response, :conn, nil, fn
        nil ->
          nil

        conn ->
          socket = Mint.HTTP.get_socket(conn)
          {:ok, conn} = Mint.HTTP.close(conn)

          receive do
            {kind, ^socket} when kind in [:ssl_closed, :tcp_closed] -> :ok
          after
            100 -> :ok
          end

          conn
      end)

    {:ok, response}
  end

  @doc """
  Encodes frame and sends encoded data on the established WebSocket connection.

  Supported frame types:

  * `:close` - shorthand for `{:close, nil, nil}`
  * `:ping` - shorthand for `{:ping, ""}`
  * `:pong` - shorthand for `{:pong, ""}`
  * `{:binary, binary}`
  * `{:close, code, reason}`
  * `{:ping, binary}`
  * `{:pong, binary}`
  * `{:text, text}` - `text` must be valid utf8 encoded binary
  """
  @spec send_frame(Req.Response.t(), Mint.WebSocket.shorthand_frame() | Mint.WebSocket.frame()) ::
          {:ok, Req.Response.t()} | {:error, Req.Response.t(), any()}
  def send_frame(%Req.Response{} = response, frame), do: send_frames(response, [frame])

  @doc """
  Encodes frames and sends encoded data on an established WebSocket connection.
  See `send_frame/2` for supported frame types.
  """
  @spec send_frames(Req.Response.t(), [Mint.WebSocket.shorthand_frame() | Mint.WebSocket.frame()]) ::
          {:ok, Req.Response.t()} | {:error, Req.Response.t(), any()}
  def send_frames(response, frames) do
    conn = Req.Response.get_private(response, :conn)
    ref = Req.Response.get_private(response, :ref)
    web_socket = Req.Response.get_private(response, :web_socket)

    with {:ok, web_socket, encoded} <- encode_frames(conn, web_socket, frames),
         {:ok, conn} <- send_encoded(conn, ref, web_socket, encoded) do
      response =
        response
        |> Req.Response.put_private(:conn, conn)
        |> Req.Response.put_private(:web_socket, web_socket)

      {:ok, response}
    else
      {:error, conn, web_socket, reason} ->
        response =
          response
          |> Req.Response.put_private(:conn, conn)
          |> Req.Response.put_private(:web_socket, web_socket)

        {:error, response, reason}
    end
  end

  @impl Req.Adapter
  @spec stream(req, acc, fun, state) ::
          {:ok, resp, acc, state}
          | {:halt, resp, acc, state}
          | {{:error, err}, resp, acc, state}
        when req: Req.Request.t(),
             resp: Req.Response.t(),
             err: Exception.t(),
             acc: term(),
             fun: (event, resp, acc, state ->
                     {:ok, resp, acc, state}
                     | {:halt, resp, acc, state}
                     | {{:error, err}, resp, acc, state}),
             state: term(),
             event:
               {:status, non_neg_integer()}
               | {:headers, [{binary(), binary()}]}
               | {:data, binary()}
               | {:trailers, [{binary(), binary()}]}
  def stream(req, acc, fun, state) when is_function(fun, 4) do
    # Mint derives the host header from the address, producing an invalid
    # `::1:port` for IPv6 hosts, so set a bracketed one ourselves.
    req =
      if (req.url.host || "") =~ ":" do
        Req.Request.put_new_header(req, "host", "[#{req.url.host}]")
      else
        req
      end

    resp = Req.Response.new(status: nil, body: nil)
    resp = put_in(resp.request, req)

    case connect(req) do
      {:ok, conn} ->
        case start_request(req, conn, acc) do
          {:ok, conn, ref, acc} ->
            case req.into do
              :self ->
                stream_into_self(req, conn, ref, resp, acc, fun, state)

              _other ->
                stream_response(req, conn, ref, resp, acc, fun, state)
            end

          {:error, conn, error, acc} ->
            Mint.HTTP.close(conn)
            {{:error, normalize_error(error)}, resp, acc, state}
        end

      {:error, exception} ->
        {{:error, exception}, resp, acc, state}
    end
  end

  defp encode_frame(conn, web_socket, frame) do
    case Mint.WebSocket.encode(web_socket, frame) do
      {:ok, _websocket, _encoded} = result -> result
      {:error, web_socket, reason} -> {:error, conn, web_socket, reason}
    end
  end

  defp encode_frames(conn, web_socket, frames) do
    Enum.reduce_while(frames, {:ok, web_socket, <<>>}, fn frame, {_, web_socket, acc} ->
      case encode_frame(conn, web_socket, frame) do
        {:ok, web_socket, encoded} -> {:cont, {:ok, web_socket, acc <> encoded}}
        {:error, conn, web_socket, reason} -> {:halt, {:error, conn, web_socket, reason}}
      end
    end)
  end

  defp put_websocket(request) do
    case request.url.scheme do
      "ws" -> put_websocket(request, :http, :ws)
      "wss" -> put_websocket(request, :https, :wss)
      _other -> request
    end
  end

  defp put_websocket(request, http_scheme, ws_scheme) do
    request
    |> Req.Request.put_private(@http_scheme, http_scheme)
    |> Req.Request.put_private(@ws_scheme, ws_scheme)
    |> Map.put(:adapter, __MODULE__)
  end

  defp send_encoded(conn, ref, web_socket, encoded) do
    case Mint.WebSocket.stream_request_body(conn, ref, encoded) do
      {:ok, conn} -> {:ok, conn}
      {:error, conn, reason} -> {:error, conn, web_socket, reason}
    end
  end

  defp stream_response(req, conn, ref, resp, acc, fun, state) do
    timeouts = %{
      receive_timeout: req.options[:receive_timeout] || 15_000,
      deadline: deadline(req.options[:request_timeout])
    }

    stream_fun = fn
      {:status, status}, _conn, {resp, acc, state} ->
        resp = put_in(resp.status, status)

        case fun.({:status, status}, resp, acc, state) do
          {:ok, resp, acc, state} ->
            {:cont, {resp, acc, state}}

          {:halt, resp, acc, state} ->
            {:halt, {resp, acc, state}}

          {{:error, exception}, resp, acc, state} ->
            {:error, {resp, acc, state}, exception}
        end

      {:headers, headers}, _conn, {resp, acc, state} ->
        resp = put_in(resp.headers, Req.Fields.new_without_normalize_with_duplicates(headers))

        case fun.({:headers, headers}, resp, acc, state) do
          {:ok, resp, acc, state} ->
            {:cont, {resp, acc, state}}

          {:halt, resp, acc, state} ->
            {:halt, {resp, acc, state}}

          {{:error, exception}, resp, acc, state} ->
            {:error, {resp, acc, state}, exception}
        end

      {:data, datum}, _conn, {resp, acc, [data | state]} ->
        {:cont, {resp, acc, [[{:data, ref, datum} | data] | state]}}

      {:trailers, trailers}, _conn, {resp, acc, state} ->
        resp =
          put_in(resp.trailers, Req.Fields.new_without_normalize_with_duplicates(trailers))

        case fun.({:trailers, trailers}, resp, acc, state) do
          {:ok, resp, acc, state} ->
            {:cont, {resp, acc, state}}

          {:halt, resp, acc, state} ->
            {:halt, {resp, acc, state}}

          {{:error, exception}, resp, acc, state} ->
            {:error, {resp, acc, state}, exception}
        end
    end

    websocket_fun = fn
      {:data, data}, conn, {resp, websocket, acc, state} ->
        {:ok, websocket, data} = Mint.WebSocket.decode(websocket, data)

        resp = Req.Response.put_private(resp, :conn, conn)
        resp = Req.Response.put_private(resp, :web_socket, websocket)

        case fun.({:data, data}, resp, acc, state) do
          {:ok, resp, acc, state} ->
            {:cont, {resp, websocket, acc, state}}

          {:halt, resp, acc, state} ->
            {:halt, {resp, websocket, acc, state}}

          {{:error, exception}, resp, acc, state} ->
            {:error, {resp, websocket, acc, state}, exception}
        end
    end

    resp = Req.Response.put_private(resp, :ref, ref)

    case recv_stream(conn, ref, {resp, acc, [[] | state]}, stream_fun, timeouts) do
      {:ok, conn, {resp, acc, [data | state]}} when resp.status == 101 ->
        {:ok, conn, websocket} =
          Mint.WebSocket.new(conn, ref, resp.status, Req.Fields.get_list(resp.headers),
            mode: :passive
          )

        case drain_entries(data, conn, ref, {resp, websocket, acc, state}, websocket_fun) do
          {:ok, conn, acc} ->
            case recv_stream(conn, ref, acc, websocket_fun, timeouts) do
              {:ok, conn, {resp, _websocket, acc, state}} ->
                Mint.HTTP.close(conn)
                {:ok, resp, acc, state}

              {:halt, {resp, _websocket, acc, state}} ->
                {:halt, resp, acc, state}

              {:error, {resp, _websocket, acc, state}, exception} ->
                {{:error, exception}, resp, acc, state}
            end

          {:halt, _conn, {resp, _websocket, acc, state}} ->
            {:halt, resp, acc, state}

          {:error, _conn, {resp, _websocket, acc, state}, exception} ->
            {{:error, exception}, resp, acc, state}
        end

      {:ok, _conn, {resp, acc, [_data | state]}} ->
        {:ok, resp, acc, state}

      {:halt, {resp, acc, [_data | state]}} ->
        {:halt, resp, acc, state}

      {:error, {resp, acc, [_data | state]}, exception} ->
        {{:error, exception}, resp, acc, state}
    end
  end

  defp stream_into_self(req, conn, ref, resp, acc, fun, state) do
    timeouts = %{
      receive_timeout: req.options[:receive_timeout] || 15_000,
      deadline: deadline(req.options[:request_timeout])
    }

    case recv_status_and_headers(conn, ref, timeouts, nil, [], []) do
      {:ok, conn, status, headers, rest} when status == 101 ->
        resp = put_in(resp.status, status)

        case fun.({:status, status}, resp, acc, state) do
          {:ok, resp, acc, state} ->
            resp =
              put_in(resp.headers, Req.Fields.new_without_normalize_with_duplicates(headers))

            case fun.({:headers, headers}, resp, acc, state) do
              {:ok, resp, acc, state} ->
                {:ok, conn, websocket} =
                  Mint.WebSocket.new(conn, ref, status, headers, mode: :passive)

                async = %Req.Response.Async{
                  pid: self(),
                  ref: ref,
                  stream_fun: &parse_message/2,
                  cancel_fun: start_owner(conn, ref, websocket, rest, timeouts)
                }

                resp = put_in(resp.body, async)
                resp = Req.Response.put_private(resp, :conn, conn)
                resp = Req.Response.put_private(resp, :ref, ref)
                resp = Req.Response.put_private(resp, :web_socket, websocket)
                {:ok, resp, acc, state}

              {:halt, resp, acc, state} ->
                Mint.HTTP.close(conn)
                {:halt, resp, acc, state}

              {{:error, exception}, resp, acc, state} ->
                Mint.HTTP.close(conn)
                {{:error, exception}, resp, acc, state}
            end

          {:halt, resp, acc, state} ->
            Mint.HTTP.close(conn)
            {:halt, resp, acc, state}

          {{:error, exception}, resp, acc, state} ->
            Mint.HTTP.close(conn)
            {{:error, exception}, resp, acc, state}
        end

      {:ok, conn, status, headers, rest} ->
        resp = put_in(resp.status, status)

        case fun.({:status, status}, resp, acc, state) do
          {:ok, resp, acc, state} ->
            resp =
              put_in(resp.headers, Req.Fields.new_without_normalize_with_duplicates(headers))

            case fun.({:headers, headers}, resp, acc, state) do
              {:ok, resp, acc, state} ->
                async = %Req.Response.Async{
                  pid: self(),
                  ref: ref,
                  stream_fun: &parse_message/2,
                  cancel_fun: start_owner(conn, ref, rest, timeouts)
                }

                resp = put_in(resp.body, async)
                {:ok, resp, acc, state}

              {:halt, resp, acc, state} ->
                Mint.HTTP.close(conn)
                {:halt, resp, acc, state}

              {{:error, exception}, resp, acc, state} ->
                Mint.HTTP.close(conn)
                {{:error, exception}, resp, acc, state}
            end

          {:halt, resp, acc, state} ->
            Mint.HTTP.close(conn)
            {:halt, resp, acc, state}

          {{:error, exception}, resp, acc, state} ->
            Mint.HTTP.close(conn)
            {{:error, exception}, resp, acc, state}
        end

      {:error, conn, exception} ->
        Mint.HTTP.close(conn)
        {{:error, exception}, resp, acc, state}
    end
  end

  defp connect(req) do
    connect_options = req.options[:connect_options] || []

    transport_opts =
      Keyword.merge(
        Keyword.take(connect_options, [:timeout]),
        Keyword.get(connect_options, :transport_opts, [])
      )

    transport_opts =
      if req.options[:inet6] == true or (req.url.host || "") =~ ":" do
        Keyword.put(transport_opts, :inet6, true)
      else
        transport_opts
      end

    scheme = Req.Request.get_private(req, @http_scheme)

    transport_opts =
      if scheme == :https do
        transport_opts
      else
        # when redirecting from https to http, we may still have these ssl options which we need
        # to drop because mint errors otherwise
        Keyword.drop(transport_opts, [:cacertfile, :certfile, :keyfile])
      end

    {address, port, address_options} =
      if unix_socket = req.options[:unix_socket] do
        {{:local, unix_socket}, 0, [hostname: req.url.host]}
      else
        {req.url.host, req.url.port, []}
      end

    options =
      [
        mode: :passive,
        protocols: connect_options[:protocols] || [:http1],
        transport_opts: transport_opts
      ] ++ address_options

    case Mint.HTTP.connect(scheme, address, port, options) do
      {:ok, conn} ->
        {:ok, conn}

      {:error, exception} ->
        {:error, normalize_error(exception)}
    end
  end

  defp start_request(req, conn, acc) do
    headers = Req.Fields.get_list(req.headers)

    scheme = Req.Request.get_private(req, @ws_scheme)

    case Mint.WebSocket.upgrade(scheme, conn, request_path(req.url), headers) do
      {:ok, conn, ref} -> {:ok, conn, ref, acc}
      {:error, conn, error} -> {:error, conn, error, acc}
    end
  end

  defp request_path(url) do
    path = url.path || "/"

    if url.query in [nil, ""] do
      path
    else
      path <> "?" <> url.query
    end
  end

  defp drain_entries(entries, conn, ref, acc, fun) do
    case handle_entries(entries, conn, ref, :headers, acc, fun) do
      {:cont, conn, _phase, acc} ->
        {:ok, conn, acc}

      {:done, conn, acc} ->
        {:ok, conn, acc}

      {:halt, conn, acc} ->
        {:halt, conn, acc}

      {:error, conn, acc, error} ->
        {:error, conn, acc, normalize_error(error)}
    end
  end

  # Streams response entries into fun until :done, :halt, or error. Headers
  # received after the first body chunk are passed as {:trailers, fields}.
  defp recv_stream(conn, ref, acc, fun, timeouts) do
    case recv_loop(conn, ref, :headers, acc, fun, timeouts) do
      {:ok, conn, acc} ->
        {:ok, conn, acc}

      {:halt, conn, acc} ->
        Mint.HTTP.close(conn)
        {:halt, acc}

      {:error, conn, acc, exception} ->
        Mint.HTTP.close(conn)
        {:error, acc, exception}
    end
  end

  defp recv_loop(conn, ref, phase, acc, fun, timeouts) do
    case Mint.WebSocket.recv(conn, 0, recv_timeout(timeouts)) do
      {:ok, conn, entries} ->
        case handle_entries(entries, conn, ref, phase, acc, fun) do
          {:cont, conn, phase, acc} ->
            recv_loop(conn, ref, phase, acc, fun, timeouts)

          {:done, conn, acc} ->
            {:ok, conn, acc}

          {:halt, conn, acc} ->
            {:halt, conn, acc}

          {:error, conn, acc, error} ->
            {:error, conn, acc, normalize_error(error)}
        end

      {:error, conn, error, entries} ->
        case handle_entries(entries, conn, ref, phase, acc, fun) do
          {:cont, conn, _phase, acc} ->
            {:error, conn, acc, normalize_error(error)}

          {:done, conn, acc} ->
            {:ok, conn, acc}

          {:halt, conn, acc} ->
            {:halt, conn, acc}

          {:error, conn, acc, entries_error} ->
            {:error, conn, acc, normalize_error(entries_error)}
        end
    end
  end

  defp handle_entries([], conn, _ref, phase, acc, _fun) do
    {:cont, conn, phase, acc}
  end

  defp handle_entries([entry | rest], conn, ref, phase, acc, fun) do
    case entry do
      {:status, ^ref, status} ->
        apply_fun({:status, status}, rest, conn, ref, phase, acc, fun)

      {:headers, ^ref, fields} when phase == :headers ->
        apply_fun({:headers, fields}, rest, conn, ref, phase, acc, fun)

      {:headers, ^ref, fields} ->
        apply_fun({:trailers, fields}, rest, conn, ref, phase, acc, fun)

      {:data, ^ref, data} ->
        apply_fun({:data, data}, rest, conn, ref, :body, acc, fun)

      {:done, ^ref} ->
        {:done, conn, acc}

      {:error, ^ref, error} ->
        {:error, conn, acc, error}
    end
  end

  defp apply_fun(event, rest, conn, ref, phase, acc, fun) do
    case fun.(event, conn, acc) do
      {:cont, acc} ->
        handle_entries(rest, conn, ref, phase, acc, fun)

      {:halt, acc} ->
        {:halt, conn, acc}

      {:error, acc, error} ->
        {:error, conn, acc, error}
    end
  end

  # into: :self receives status and headers synchronously, then hands the
  # connection over to a spawned process that forwards Finch-shaped messages
  # ({ref, {:data, data}}, {ref, :done}, etc.) to the caller's mailbox.
  defp recv_status_and_headers(conn, ref, timeouts, status, headers, early_entries) do
    case Mint.WebSocket.recv(conn, 0, recv_timeout(timeouts)) do
      {:ok, conn, entries} ->
        case split_status_and_headers(entries, ref, status, headers, early_entries) do
          {:ok, status, headers, rest} ->
            {:ok, conn, status, headers, rest}

          {:cont, status, headers} ->
            recv_status_and_headers(conn, ref, timeouts, status, headers, early_entries)
        end

      {:error, conn, error, _entries} ->
        {:error, conn, normalize_error(error)}
    end
  end

  defp split_status_and_headers([entry | rest], ref, status, headers, early_entries) do
    case entry do
      {:status, ^ref, status} ->
        split_status_and_headers(rest, ref, status, headers, early_entries)

      {:headers, ^ref, fields} ->
        split_status_and_headers(rest, ref, status, headers ++ fields, early_entries)

      {:data, ^ref, _} ->
        split_status_and_headers(rest, ref, status, headers, [entry | early_entries])

      {:done, ^ref} ->
        {:ok, status, headers, rest}
    end
  end

  defp split_status_and_headers([], _ref, status, headers, early_entries) do
    {:cont, status, headers, early_entries}
  end

  defp start_owner(conn, ref, early_entries, timeouts) do
    caller = self()

    owner =
      spawn_link(fn ->
        receive do
          {:go, conn} ->
            {:ok, conn} = Mint.HTTP.set_mode(conn, :active)

            if forward_entries(early_entries, ref, caller) == :cont do
              owner_loop(conn, ref, caller, timeouts)
            end
        end
      end)

    {:ok, conn} = Mint.HTTP.controlling_process(conn, owner)
    send(owner, {:go, conn})

    fn ^ref ->
      monitor = Process.monitor(owner)
      send(owner, :cancel)

      receive do
        {:DOWN, ^monitor, _, _, _} ->
          :ok
      after
        1000 ->
          :ok
      end

      flush(ref)
    end
  end

  defp start_owner(conn, ref, websocket, early_entries, timeouts) do
    caller = self()

    owner =
      spawn_link(fn ->
        receive do
          {:go, conn, websocket} ->
            {:ok, conn} = Mint.HTTP.set_mode(conn, :active)

            if forward_entries(early_entries, ref, websocket, caller) == :cont do
              owner_loop(conn, ref, websocket, caller, timeouts)
            end
        end
      end)

    {:ok, conn} = Mint.HTTP.controlling_process(conn, owner)
    send(owner, {:go, conn, websocket})

    fn ^ref ->
      monitor = Process.monitor(owner)
      send(owner, :cancel)

      receive do
        {:DOWN, ^monitor, _, _, _} ->
          :ok
      after
        1000 ->
          :ok
      end

      flush(ref)
    end
  end

  defp owner_loop(conn, ref, caller, timeouts) do
    require Mint.HTTP

    receive do
      :cancel ->
        Mint.HTTP.close(conn)

      message when Mint.HTTP.is_connection_message(conn, message) ->
        case Mint.HTTP.stream(conn, message) do
          {:ok, conn, entries} ->
            case forward_entries(entries, ref, caller) do
              :cont ->
                owner_loop(conn, ref, caller, timeouts)

              :done ->
                Mint.HTTP.close(conn)
            end

          {:error, conn, error, entries} ->
            forward_entries(entries, ref, caller)
            send(caller, {ref, {:error, normalize_error(error)}})
            Mint.HTTP.close(conn)
        end
    after
      timeouts.receive_timeout ->
        send(caller, {ref, {:error, %Req.TransportError{reason: :timeout}}})
        Mint.HTTP.close(conn)
    end
  end

  defp owner_loop(conn, ref, websocket, caller, timeouts) do
    require Mint.HTTP

    receive do
      :cancel ->
        Mint.HTTP.close(conn)

      message when Mint.HTTP.is_connection_message(conn, message) ->
        case Mint.WebSocket.stream(conn, message) do
          {:ok, conn, entries} ->
            case forward_entries(entries, ref, websocket, caller) do
              :cont ->
                owner_loop(conn, ref, websocket, caller, timeouts)

              :done ->
                Mint.HTTP.close(conn)
            end

          {:error, conn, error, entries} ->
            forward_entries(entries, ref, websocket, caller)
            send(caller, {ref, {:error, normalize_error(error)}})
            Mint.HTTP.close(conn)
        end
    after
      timeouts.receive_timeout ->
        send(caller, {ref, {:error, %Req.TransportError{reason: :timeout}}})
        Mint.HTTP.close(conn)
    end
  end

  defp forward_entries([], _ref, _caller) do
    :cont
  end

  defp forward_entries([entry | rest], ref, caller) do
    case entry do
      {:data, ^ref, data} ->
        send(caller, {ref, {:data, data}})
        forward_entries(rest, ref, caller)

      {:headers, ^ref, fields} ->
        send(caller, {ref, {:trailers, fields}})
        forward_entries(rest, ref, caller)

      {:done, ^ref} ->
        send(caller, {ref, :done})
        :done

      {:error, ^ref, error} ->
        send(caller, {ref, {:error, normalize_error(error)}})
        :done
    end
  end

  defp forward_entries([], _ref, _websocket, _caller) do
    :cont
  end

  defp forward_entries([entry | rest], ref, websocket, caller) do
    case entry do
      {:data, ^ref, data} ->
        case Mint.WebSocket.decode(websocket, data) do
          {:ok, websocket, frames} ->
            send(caller, {ref, {:data, frames}})
            forward_entries(rest, ref, websocket, caller)

          {:error, websocket, error} ->
            send(caller, {ref, {:error, error}})
            forward_entries(rest, ref, websocket, caller)

          {:error, error} ->
            send(caller, {ref, {:error, error}})
            forward_entries(rest, ref, websocket, caller)
        end

      {:headers, ^ref, fields} ->
        send(caller, {ref, {:trailers, fields}})
        forward_entries(rest, ref, websocket, caller)

      {:done, ^ref} ->
        send(caller, {ref, :done})
        :done

      {:error, ^ref, error} ->
        send(caller, {ref, {:error, normalize_error(error)}})
        :done
    end
  end

  defp parse_message(ref, {ref, {:data, data}}) do
    {:ok, data}
  end

  defp parse_message(ref, {ref, :done}) do
    {:ok, [:done]}
  end

  defp parse_message(ref, {ref, {:trailers, trailers}}) do
    {:ok, [trailers: trailers]}
  end

  defp parse_message(ref, {ref, {:error, error}}) do
    {:error, error}
  end

  defp parse_message(_ref, _message) do
    :unknown
  end

  defp flush(ref) do
    receive do
      {^ref, _} ->
        flush(ref)
    after
      0 ->
        :ok
    end
  end

  defp deadline(nil) do
    nil
  end

  defp deadline(request_timeout) do
    System.monotonic_time(:millisecond) + request_timeout
  end

  defp recv_timeout(%{receive_timeout: receive_timeout, deadline: nil}) do
    receive_timeout
  end

  defp recv_timeout(%{receive_timeout: receive_timeout, deadline: deadline}) do
    min(receive_timeout, max(deadline - System.monotonic_time(:millisecond), 0))
  end

  defp normalize_error(%Mint.TransportError{reason: reason}) do
    %Req.TransportError{reason: reason}
  end

  defp normalize_error(%Mint.HTTPError{module: Mint.HTTP1, reason: reason}) do
    %Req.HTTPError{protocol: :http1, reason: reason}
  end

  defp normalize_error(%Mint.HTTPError{module: Mint.HTTP2, reason: reason}) do
    %Req.HTTPError{protocol: :http2, reason: reason}
  end

  defp normalize_error(error) when is_atom(error) do
    %Req.TransportError{reason: error}
  end

  defp normalize_error(error) do
    error
  end
end
