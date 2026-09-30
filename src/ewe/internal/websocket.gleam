import ewe/internal/connection
import ewe/internal/rescue
import gleam/bit_array
import gleam/erlang/process
import gleam/option
import websocks

pub type Message(user_message) {
  TextFrame(text: String)
  BinaryFrame(data: BitArray)
  UserMessage(message: user_message)
}

pub type Transport(raw, user_message) {
  Transport(
    handle: fn(websocks.Context) -> connection.WebsocketConnection,
    selector: fn(process.Selector(user_message)) -> process.Selector(raw),
    receive: fn(process.Selector(raw)) -> Event(user_message),
    send: fn(BitArray) -> Result(Nil, String),
    close: fn(BitArray) -> Result(Nil, String),
  )
}

pub type Event(user_message) {
  Data(bytes: BitArray, last: Bool)
  User(message: user_message)
  Shutdown
  Gone
  Failed(reason: String)
}

type Session(raw, user_state, user_message) {
  Session(
    transport: Transport(raw, user_message),
    handler: fn(
      connection.WebsocketConnection,
      user_state,
      Message(user_message),
    ) -> connection.Next(user_state, user_message),
    on_close: fn(user_state) -> Nil,
    context: websocks.Context,
    selector: process.Selector(raw),
    state: user_state,
  )
}

pub fn run(
  transport: Transport(raw, user_message),
  context: websocks.Context,
  on_init: fn(connection.WebsocketConnection, process.Selector(user_message)) ->
    #(user_state, process.Selector(user_message)),
  handler: fn(connection.WebsocketConnection, user_state, Message(user_message)) ->
    connection.Next(user_state, user_message),
  on_close: fn(user_state) -> Nil,
) -> connection.Outcome {
  let #(state, messages) =
    on_init(transport.handle(context), process.new_selector())

  Session(
    transport:,
    handler:,
    on_close:,
    context:,
    selector: transport.selector(messages),
    state:,
  )
  |> loop
}

fn loop(session: Session(raw, user_state, user_message)) -> connection.Outcome {
  case session.transport.receive(session.selector) {
    Data(bytes:, last:) ->
      Session(..session, context: websocks.push_data(session.context, bytes))
      |> drain(last)
    User(message) -> {
      use session <- deliver(session, UserMessage(message))
      loop(session)
    }
    Shutdown ->
      close(
        session,
        websocks.CloseReason(websocks.GoingAway, "server shutting down"),
      )
    Gone -> ended(session, connection.Stopped)
    Failed(reason) -> ended(session, connection.StoppedAbnormal(reason))
  }
}

fn drain(
  session: Session(raw, user_state, user_message),
  last: Bool,
) -> connection.Outcome {
  case websocks.next_frame(session.context) {
    Error(violation) -> close(session, close_reason(violation))
    Ok(websocks.MoreData(context:)) -> {
      let session = Session(..session, context:)

      case last {
        True -> finish(session)
        False -> loop(session)
      }
    }
    Ok(websocks.Decoded(frame:, context:)) -> {
      let session = Session(..session, context:)

      case frame {
        websocks.Control(websocks.Ping(payload)) ->
          case
            session.transport.send(websocks.encode_pong_frame(
              payload:,
              masking: option.None,
            ))
          {
            Ok(Nil) -> drain(session, last)
            Error(reason) -> ended(session, connection.StoppedAbnormal(reason))
          }
        websocks.Control(websocks.Pong(_payload))
        | websocks.Continuation(_payload) -> drain(session, last)
        websocks.Control(websocks.Close(reason)) -> close(session, reason)
        websocks.Text(payload) -> {
          use session <- deliver(session, TextFrame(unsafe_to_string(payload)))
          drain(session, last)
        }
        websocks.Binary(payload) -> {
          use session <- deliver(session, BinaryFrame(payload))
          drain(session, last)
        }
      }
    }
  }
}

fn deliver(
  session: Session(raw, user_state, user_message),
  message: Message(user_message),
  next: fn(Session(raw, user_state, user_message)) -> connection.Outcome,
) -> connection.Outcome {
  let handle = session.transport.handle(session.context)

  case
    rescue.next("websocket handler", fn() {
      session.handler(handle, session.state, message)
    })
  {
    connection.Stop -> finish(session)
    connection.StopAbnormal(reason) ->
      ended(session, connection.StoppedAbnormal(reason))
    connection.Continue(user_state: state, selector:) -> {
      let selector =
        option.map(selector, session.transport.selector)
        |> option.unwrap(session.selector)

      next(Session(..session, state:, selector:))
    }
  }
}

fn close(
  session: Session(raw, user_state, user_message),
  reason: websocks.CloseReason,
) -> connection.Outcome {
  case session.transport.close(close_frame(reason)) {
    Ok(Nil) -> ended(session, connection.Stopped)
    Error(reason) -> ended(session, connection.StoppedAbnormal(reason))
  }
}

fn finish(
  session: Session(raw, user_state, user_message),
) -> connection.Outcome {
  let _sent = session.transport.close(<<>>)
  ended(session, connection.Stopped)
}

fn ended(
  session: Session(raw, user_state, user_message),
  outcome: connection.Outcome,
) -> connection.Outcome {
  rescue.logged("websocket close handler", fn() {
    session.on_close(session.state)
  })

  websocks.close_context(session.context)
  outcome
}

pub fn close_reason(error: websocks.ProcessError) -> websocks.CloseReason {
  let code = case error {
    websocks.ResolveFailed(websocks.NotUtf8)
    | websocks.ResolveFailed(websocks.DecompressionFailed) ->
      websocks.InvalidPayloadData

    websocks.ResolveFailed(websocks.MessageTooLarge(..))
    | websocks.DecodeFailed(websocks.FrameTooLarge(..)) ->
      websocks.MessageTooBig

    websocks.ResolveFailed(websocks.OrphanedContinuation)
    | websocks.ResolveFailed(websocks.FragmentationInterrupted)
    | websocks.ResolveFailed(websocks.ConcurrentFragmentation)
    | websocks.DecodeFailed(websocks.InvalidFrame)
    | websocks.DecodeFailed(websocks.NotEnoughData(_data)) ->
      websocks.ProtocolError
  }

  websocks.CloseReason(code, "")
}

pub fn text_frame(context: websocks.Context, text: String) -> BitArray {
  websocks.encode_text_frame(
    payload: bit_array.from_string(text),
    context:,
    masking: option.None,
  )
}

pub fn binary_frame(context: websocks.Context, data: BitArray) -> BitArray {
  websocks.encode_binary_frame(payload: data, context:, masking: option.None)
}

pub fn close_frame(reason: websocks.CloseReason) -> BitArray {
  websocks.encode_close_frame(reason:, masking: option.None)
}

pub fn compression(
  extensions: option.Option(String),
) -> option.Option(websocks.CompressionExtensions) {
  case extensions {
    option.Some(header) ->
      case websocks.has_deflate(header) {
        True -> option.Some(websocks.get_compression_extensions(header))
        False -> option.None
      }
    option.None -> option.None
  }
}

@external(erlang, "ewe_ffi", "identity")
fn unsafe_to_string(payload: BitArray) -> String
