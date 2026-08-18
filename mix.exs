defmodule OapiCodemode.MixProject do
  use Mix.Project

  def project do
    [
      app: :oapi_codemode,
      version: "0.1.0",
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:yaml_elixir, "~> 2.11"},
      {:jason, "~> 1.4"},
      # Optional: only needed for OapiCodemode.Executor.ZapCode. Path dep until
      # the hardened ex_zapcode ships to hex (needs zapcode branch
      # harden/sandbox-untrusted-code pushed + rev-pinned first); then pin
      # {:ex_zapcode, "~> 0.2", optional: true}.
      {:ex_zapcode, path: "/Users/james/Desktop/lib/ex_zapcode", optional: true},
      # Needed only while ex_zapcode is a path dep (forces a local NIF build);
      # goes away with the hex pin above.
      {:rustler, ">= 0.0.0", optional: true},
      {:req, "~> 0.5"},
      {:telemetry, "~> 1.2"},
      {:plug, "~> 1.16", only: :test}
    ]
  end
end
