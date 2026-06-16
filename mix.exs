defmodule ReqWebSocket.MixProject do
  use Mix.Project

  @source_url "https://github.com/jswanner/req_web_socket"
  @version "0.1.2"

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  def cli do
    [preferred_envs: [docs: :docs, "hex.publish": :docs]]
  end

  defp deps do
    [
      {:bandit, "~> 1.7", only: :test},
      {:ex_doc, ">= 0.0.0", only: :docs, runtime: false, warn_if_outdated: true},
      {:mint_web_socket, "~> 1.0"},
      {:req, "~> 0.5.0 or ~> 0.6.0"},
      {:websock_adapter, "~> 0.5.8", only: :test},
      {:x509, "~> 0.9.0", only: :test}
    ]
  end

  def project do
    [
      app: :req_web_socket,
      deps: deps(),
      docs: [
        source_url: @source_url,
        source_ref: "v#{@version}",
        main: "readme",
        extras: ["README.md", "CHANGELOG.md"]
      ],
      elixir: "~> 1.14",
      package: [
        description: "Req plugin adding WebSocket support",
        licenses: ["MIT"],
        links: %{
          "GitHub" => @source_url
        }
      ],
      source_url: @source_url,
      start_permanent: Mix.env() == :prod,
      version: @version
    ]
  end
end
