defmodule BanditBench.Router do
  use Plug.Router

  plug(:match)
  plug(:dispatch)

  get "/hello" do
    send_resp(conn, 200, "Hello, Joe!")
  end

  post "/echo" do
    {:ok, body, conn} = Plug.Conn.read_body(conn, length: 10_000_000)
    send_resp(conn, 200, body)
  end

  post "/echo/chunked" do
    conn = Plug.Conn.read_body(conn, length: 4096) |> echo_chunked(<<>>)
    send_resp(conn, 200, conn.assigns.body)
  end

  get "/stream" do
    conn = send_chunked(conn, 200)
    {:ok, conn} = chunk(conn, "hello, ")
    {:ok, conn} = chunk(conn, "Joe!")
    conn
  end

  get "/file/small" do
    conn
    |> put_resp_header("content-type", "application/octet-stream")
    |> send_file(200, "../priv/file_100kb.bin")
  end

  get "/file/big" do
    conn
    |> put_resp_header("content-type", "application/octet-stream")
    |> send_file(200, "../priv/file_1gb.bin")
  end

  match _ do
    send_resp(conn, 404, "")
  end

  defp echo_chunked({:more, partial, conn}, acc) do
    Plug.Conn.read_body(conn, length: 4096) |> echo_chunked(acc <> partial)
  end

  defp echo_chunked({:ok, partial, conn}, acc) do
    Plug.Conn.assign(conn, :body, acc <> partial)
  end
end
