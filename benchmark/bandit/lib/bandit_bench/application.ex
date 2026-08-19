defmodule BanditBench.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Bandit, plug: BanditBench.Router, scheme: :http, port: 3004}
    ]

    opts = [strategy: :one_for_one, name: BanditBench.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
