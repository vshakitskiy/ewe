import gleam/erlang/process
import gleam/int
import gleam/otp/actor
import gleam/result
import gleam/string

type Message {
  Tick
}

const tick_ms = 1000

pub fn start(_type: a, _args: b) -> Result(process.Pid, actor.StartError) {
  use actor.Started(pid:, ..) <- result.map(
    actor.new_with_initialiser(tick_ms, fn(subject) {
      tick(subject)

      actor.initialised(subject)
      |> actor.returning(subject)
      |> Ok
    })
    |> actor.on_message(fn(subject, _tick) {
      tick(subject)
      actor.continue(subject)
    })
    |> actor.start(),
  )

  pid
}

pub fn stop(_state: a) -> Nil {
  Nil
}

fn tick(subject: process.Subject(Message)) -> Nil {
  set_date(format_date(now()))
  process.send_after(subject, tick_ms, Tick)

  Nil
}

pub fn get() -> BitArray {
  case get_date() {
    Ok(date) -> date
    Error(Nil) -> format_date(now())
  }
}

fn format_date(time: #(Int, #(Int, Int, Int), #(Int, Int, Int))) -> BitArray {
  let #(weekday, #(year, month, day), #(hour, minute, second)) = time

  <<
    weekday_to_string(weekday):utf8,
    ", ":utf8,
    padded(day, 2):utf8,
    " ":utf8,
    month_to_string(month):utf8,
    " ":utf8,
    padded(year, 4):utf8,
    " ":utf8,
    padded(hour, 2):utf8,
    ":":utf8,
    padded(minute, 2):utf8,
    ":":utf8,
    padded(second, 2):utf8,
    " GMT":utf8,
  >>
}

fn padded(value: Int, width: Int) -> String {
  int.to_string(value) |> string.pad_start(width, "0")
}

fn weekday_to_string(weekday: Int) -> String {
  case weekday {
    1 -> "Mon"
    2 -> "Tue"
    3 -> "Wed"
    4 -> "Thu"
    5 -> "Fri"
    6 -> "Sat"
    7 -> "Sun"
    _weekday -> panic as "erlang day_of_the_week outside of 1-7 range"
  }
}

fn month_to_string(month: Int) -> String {
  case month {
    1 -> "Jan"
    2 -> "Feb"
    3 -> "Mar"
    4 -> "Apr"
    5 -> "May"
    6 -> "Jun"
    7 -> "Jul"
    8 -> "Aug"
    9 -> "Sep"
    10 -> "Oct"
    11 -> "Nov"
    12 -> "Dec"
    _month -> panic as "erlang month outside of 1-12 range"
  }
}

@external(erlang, "ewe_ffi", "now_datetime")
fn now() -> #(Int, #(Int, Int, Int), #(Int, Int, Int))

@external(erlang, "ewe_ffi", "set_http_date")
fn set_date(date: BitArray) -> Nil

@external(erlang, "ewe_ffi", "get_http_date")
fn get_date() -> Result(BitArray, Nil)
