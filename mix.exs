defmodule Hassock.MixProject do
  use Mix.Project

  @version "0.1.1"
  @source_url "https://github.com/bensheldon/hassock"

  def project do
    [
      app: :hassock,
      version: @version,
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: "Home Assistant WebSocket client for Elixir.",
      package: package(),
      docs: docs(),
      source_url: @source_url,
      elixirc_paths: elixirc_paths(Mix.env()),
      dialyzer: dialyzer()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Hassock.Application, []}
    ]
  end

  defp deps do
    [
      {:websockex, "~> 0.4.3"},
      {:jason, "~> 1.4"},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp dialyzer do
    [
      plt_local_path: "priv/plts/project.plt",
      plt_core_path: "priv/plts/core.plt",
      plt_add_apps: [:ex_unit, :mix]
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib mix.exs README.md LICENSE)
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      extras: ["README.md"],
      before_closing_body_tag: &before_closing_body_tag/1
    ]
  end

  # Render ```mermaid code fences as diagrams via mermaid.js CDN.
  defp before_closing_body_tag(:html) do
    """
    <script defer src="https://cdn.jsdelivr.net/npm/mermaid/dist/mermaid.min.js"></script>
    <script>
      let initialized = false;
      window.addEventListener("exdoc:loaded", () => {
        if (!initialized) {
          mermaid.initialize({
            startOnLoad: false,
            theme: document.body.className.includes("dark") ? "dark" : "default"
          });
          initialized = true;
        }

        let id = 0;
        for (const codeEl of document.querySelectorAll("pre code.mermaid")) {
          const preEl = codeEl.parentElement;
          const graphDefinition = codeEl.textContent;
          const graphEl = document.createElement("div");
          const graphId = "mermaid-graph-" + id++;
          mermaid.render(graphId, graphDefinition).then(({svg, bindFunctions}) => {
            graphEl.innerHTML = svg;
            bindFunctions?.(graphEl);
            preEl.insertAdjacentElement("afterend", graphEl);
            preEl.remove();
          });
        }
      });
    </script>
    """
  end

  defp before_closing_body_tag(_), do: ""

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]
end
