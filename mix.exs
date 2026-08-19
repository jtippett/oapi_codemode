defmodule OapiCodemode.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/jtippett/oapi_codemode"

  def project do
    [
      app: :oapi_codemode,
      version: @version,
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description:
        "OpenAPI search-and-execute tools for LLM agents, Cloudflare " <>
          "code-mode style — the sandbox never sees your credentials",
      package: package(),
      source_url: @source_url,
      homepage_url: @source_url,
      docs: [main: "readme", extras: ["README.md"]]
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
      {:req, "~> 0.5"},
      {:telemetry, "~> 1.2"},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:plug, "~> 1.16", only: :test},
      # Executor engines are dev/test-only so the suite exercises them but
      # they stay out of the hex package (hex deps must be hex packages);
      # consumers bring their own engine dep (see README). Becomes
      # {:ex_safejs, "~> 0.3.1", optional: true} once ex_safejs is on hex.
      # Ref = v0.3.1 + its precompiled-NIF checksums commit (the tag itself
      # predates the checksum file rustler_precompiled needs).
      {:ex_safejs,
       github: "jtippett/ex_safejs",
       ref: "a4d2503e89951f22faa6bbbc043af02d4ab38cf0",
       only: [:dev, :test]}
    ] ++ local_engine_deps()
  end

  # Path dep until the hardened ex_zapcode ships to hex (needs zapcode branch
  # harden/sandbox-untrusted-code pushed + rev-pinned first); then pin
  # {:ex_zapcode, "~> 0.2", optional: true}. Guarded so checkouts without the
  # local repo (CI, other machines) still compile — ZapCode tests skip there.
  defp local_engine_deps do
    zapcode = "/Users/james/Desktop/lib/ex_zapcode"

    if File.dir?(zapcode) do
      [
        {:ex_zapcode, path: zapcode, only: [:dev, :test]},
        # Forces the local NIF build for the path dep; goes away with the
        # hex pin above.
        {:rustler, ">= 0.0.0", only: [:dev, :test]}
      ]
    else
      []
    end
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url}
    ]
  end
end
