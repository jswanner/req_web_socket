defmodule ReqWebSocket do
  @moduledoc """
  `Req` plugin for establishing WebSocket connections, using `Mint.WebSocket`.
  See `attach/2` for supported options.

  ## Examples

      resp =
        Req.new()
        |> ReqWebSocket.attach()
        |> Req.get!(into: :self, url: "wss://echo.websocket.org/")

      message = receive do message -> message end
      {:ok, resp, [text: _]} = ReqWebSocket.parse_message(resp, message)

      {:ok, resp} = ReqWebSocket.send_frame(resp, :ping)

      message = receive do message -> message end
      {:ok, resp, [pong: ""]} = ReqWebSocket.parse_message(resp, message)
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

      * `fun` - stream response body using a function. The first argument is a `{:data, frames}`
        tuple containing the message frames of the response body. The second argument is a
        `{request, response}` tuple. To continue streaming frames, return `{:cont, {req, resp}}`
        or `{:cont, frames, {req, resp}}`. To cancel, return `{:halt, {req, resp}}` or
        `{:halt, frames, {req, resp}}`. See `send_frame/2` for supported frame
        types. For example:

            into: fn {:data, [{:ping, string}]}, {req, resp} ->
              {:cont, [{:pong, string}], {req, resp}}
            end

      * `:self` - stream response body into the current process mailbox.

        Received messages should be parsed with `ReqWebSocket.parse_message/2`.

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
    |> Req.Request.append_request_steps(put_web_socket: &put_web_socket/1)
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

  @doc """
  Attempts to parse `message` into WebSocket frames, if the given `message` is
  not from the connection's socket, this function returns `:unknown`.

  A WebSocket frame:

  * `{:binary, binary}` - a frame containing binary data. Binary frames
    can be used to send arbitrary binary data such as a PDF.
  * `{:close, code, reason}` - a control frame used to request that a connection
    be closed or to acknowledge a close frame sent by the server.
  * `{:ping, binary}` - a control frame which the server should respond to
    with a pong. The binary data must be echoed in the pong response.
  * `{:pong, binary}` - a control frame which forms a reply to a ping frame.
    Pings and pongs may be used to check the connection is alive or to estimate
    latency.
  * `{:text, text}` - a frame containing string data. Text frames must be
    valid utf8. Elixir has wonderful support for utf8: `String.valid?/1`
    can detect valid and invalid utf8.
  """
  @spec parse_message(Req.Response.t(), term()) ::
          {:ok, Req.Response.t(), [Mint.WebSocket.frame()]}
          | {:error, Req.Response.t(), any()}
          | :unknown
  def parse_message(%Req.Response{} = response, message) do
    conn = Req.Response.get_private(response, :conn)
    ref = Req.Response.get_private(response, :ref)
    web_socket = Req.Response.get_private(response, :web_socket)

    with {:ok, conn, responses} <- Mint.WebSocket.stream(conn, message),
         {:ok, web_socket, frames} <- parse_message(responses, ref, web_socket, []) do
      response =
        response
        |> Req.Response.put_private(:conn, conn)
        |> Req.Response.put_private(:web_socket, web_socket)

      {:ok, response, frames}
    else
      {:error, conn, reason} ->
        {:error, Req.Response.put_private(response, :conn, conn), reason}

      {:error, conn, reason, _responses} ->
        {:error, Req.Response.put_private(response, :conn, conn), reason}

      :unknown ->
        :unknown
    end
  end

  defp parse_message([{:data, ref, data} | rest], ref, web_socket, acc) do
    case Mint.WebSocket.decode(web_socket, data) do
      {:ok, web_socket, frames} -> parse_message(rest, ref, web_socket, Enum.concat(frames, acc))
      {:error, web_socket, _reason} -> parse_message(rest, ref, web_socket, acc)
    end
  end

  defp parse_message([], _ref, web_socket, acc), do: {:ok, web_socket, acc}

  defp put_web_socket(request) do
    case request.url.scheme do
      "ws" -> put_web_socket(request, :http, :ws)
      "wss" -> put_web_socket(request, :https, :wss)
      _other -> request
    end
  end

  defp put_web_socket(request, http_scheme, ws_scheme) do
    request
    |> Req.Request.put_private(:http_scheme, http_scheme)
    |> Req.Request.put_private(:ws_scheme, ws_scheme)
    |> Map.put(:adapter, &run_web_socket/1)
  end

  defp run_web_socket(request) do
    case request.into do
      fun when is_function(fun, 2) -> run_web_socket_fun(request)
      :self -> run_web_socket_self(request)
      other -> {request, UnsupportedIntoError.exception(actual: other)}
    end
  end

  defp run_web_socket_fun(request) do
    callers = [self() | Process.get(:"$callers", [])]
    parent = self()
    parent_ref = make_ref()

    spawn(fn ->
      Process.put(:"$callers", callers)

      case run_web_socket_self(request) do
        {request, %Req.Response{status: 101} = response} ->
          send(parent, {parent_ref, {request, response}})

          {request, response} = run_web_socket_loop({request, response})

          response =
            Req.Response.update_private(response, :conn, nil, fn conn ->
              {:ok, conn} = Mint.HTTP.close(conn)
              conn
            end)

          {request, response}

        {_request, _response_or_exception} = acc ->
          send(parent, {parent_ref, acc})
          acc
      end
    end)

    receive(do: ({^parent_ref, result} -> result))
  end

  defp run_web_socket_loop({request, response}) do
    fun = request.into

    case parse_message(response, receive(do: (message -> message))) do
      {:ok, response, frames} ->
        case List.keytake(frames, :close, 0) do
          nil ->
            case fun.({:data, frames}, {request, response}) do
              {:cont, frames, {request, response}} ->
                case send_frames(response, frames) do
                  {:ok, response} ->
                    run_web_socket_loop({request, response})

                  {:error, response, reason} ->
                    case fun.({:error, reason}, {request, response}) do
                      {:cont, acc} -> run_web_socket_loop(acc)
                      {:halt, acc} -> acc
                    end
                end

              {:cont, acc} ->
                run_web_socket_loop(acc)

              {:halt, frames, {request, response}} ->
                case send_frames(response, frames) do
                  {:ok, response} -> {request, response}
                  {:error, response, _reason} -> {request, response}
                end

              {:halt, acc} ->
                acc
            end

          {_close, []} ->
            {request, response}

          {_close, frames} ->
            {_, acc} = fun.({:data, frames}, {request, response})
            acc
        end

      {:error, response, reason} ->
        case fun.({:error, reason}, {request, response}) do
          {:cont, acc} -> run_web_socket_loop(acc)
          {:halt, acc} -> acc
        end

      :unknown ->
        run_web_socket_loop({request, response})
    end
  end

  defp run_web_socket_self(request) do
    with {:ok, conn} <- web_socket_connect(request),
         {:ok, conn, web_socket, ref, status, headers} <- web_socket_upgrade(request, conn) do
      response =
        Req.Response.new(headers: headers, status: status)
        |> Req.Response.put_private(:conn, conn)
        |> Req.Response.put_private(:ref, ref)
        |> Req.Response.put_private(:web_socket, web_socket)

      {request, response}
    else
      {:error, exception} -> {request, exception}
      {request, response_or_exception} -> {request, response_or_exception}
    end
  end

  defp send_encoded(conn, ref, web_socket, encoded) do
    case Mint.WebSocket.stream_request_body(conn, ref, encoded) do
      {:ok, conn} -> {:ok, conn}
      {:error, conn, reason} -> {:error, conn, web_socket, reason}
    end
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

  defp web_socket_connect(request) do
    %{host: host, port: port} = request.url
    connect_options = Req.Request.get_option(request, :connect_options, [])
    scheme = Req.Request.get_private(request, :http_scheme)

    Mint.HTTP.connect(scheme, host, port, connect_options)
  end

  defp web_socket_upgrade(request, conn) do
    headers =
      for {name, values} <- request.headers,
          value <- values do
        {name, value}
      end

    url = request.url
    path = if url.query, do: url.path <> "?" <> url.query, else: url.path
    scheme = Req.Request.get_private(request, :ws_scheme)

    case Mint.WebSocket.upgrade(scheme, conn, path, headers) do
      {:ok, conn, ref} -> web_socket_upgrade(request, conn, ref)
      {:error, _conn, exception} -> {:error, exception}
    end
  end

  defp web_socket_upgrade(request, conn, ref) do
    require Mint.HTTP

    with message <-
           receive(do: (message when Mint.HTTP.is_connection_message(conn, message) -> message)),
         {:ok, conn, responses} <- Mint.WebSocket.stream(conn, message),
         [{:status, ^ref, status}, {:headers, ^ref, headers}, {:done, ^ref}] <-
           web_socket_upgrade_maybe_pop_data(conn, ref, responses),
         {:ok, conn, web_socket} <- Mint.WebSocket.new(conn, ref, status, headers) do
      {:ok, conn, web_socket, ref, status, headers}
    else
      {:error, conn, %Mint.WebSocket.UpgradeFailureError{} = error}
      when error.status_code not in 200..299 ->
        response =
          Req.Response.new(headers: error.headers, status: error.status_code)
          |> Req.Response.put_private(:conn, conn)

        {request, response}

      {:error, _conn, exception} ->
        {:error, exception}

      {:error, _conn, exception, _responses} ->
        {:error, exception}
    end
  end

  defp web_socket_upgrade_maybe_pop_data(conn, ref, responses) do
    case Enum.split_with(responses, &match?({:data, ^ref, _}, &1)) do
      {[], _} ->
        responses

      {data, rest} ->
        binary = for {:data, _, binary} <- data, reduce: <<>>, do: (acc -> acc <> binary)
        socket = Mint.HTTP.get_socket(conn)
        tag = if Mint.HTTP.get_private(conn, :scheme) == :ws, do: :tcp, else: :ssl
        send(self(), {tag, socket, binary})
        rest
    end
  end
end
