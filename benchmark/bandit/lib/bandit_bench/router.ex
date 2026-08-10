defmodule BanditBench.Router do
  use Plug.Router

  @small_count 100
  @big_count 64
  @big_repeats 256

  @small_line "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
  @big_line String.duplicate(@small_line, @big_repeats)

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

  get "/stream/small" do
    conn |> send_chunked(200) |> stream_burst(@small_line, @small_count)
  end

  get "/stream/big" do
    conn |> send_chunked(200) |> stream_burst(@big_line, @big_count)
  end

  get "/file/tiny" do
    conn
    |> put_resp_header("content-type", "application/octet-stream")
    |> send_file(200, "../priv/file_1kb.bin")
  end

  get "/file/small" do
    conn
    |> put_resp_header("content-type", "application/octet-stream")
    |> send_file(200, "../priv/file_100kb.bin")
  end

  get "/file/big" do
    conn
    |> put_resp_header("content-type", "application/octet-stream")
    |> send_file(200, "../priv/file_5mb.bin")
  end

  match _ do
    send_resp(conn, 404, "")
  end

  defp stream_burst(conn, _data, 0), do: conn

  defp stream_burst(conn, data, remaining) do
    case chunk(conn, data) do
      {:ok, conn} -> stream_burst(conn, data, remaining - 1)
      {:error, _reason} -> conn
    end
  end

  defp echo_chunked({:more, partial, conn}, acc) do
    Plug.Conn.read_body(conn, length: 4096) |> echo_chunked(acc <> partial)
  end

  defp echo_chunked({:ok, partial, conn}, acc) do
    Plug.Conn.assign(conn, :body, acc <> partial)
  end
end
