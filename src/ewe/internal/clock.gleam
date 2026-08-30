import gleam/erlang/process
import gleam/otp/actor
import gleam/result

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
    two_digits(day):bits,
    " ":utf8,
    month_to_string(month):utf8,
    " ":utf8,
    four_digits(year):bits,
    " ":utf8,
    two_digits(hour):bits,
    ":":utf8,
    two_digits(minute):bits,
    ":":utf8,
    two_digits(second):bits,
    " GMT":utf8,
  >>
}

fn two_digits(value: Int) -> BitArray {
  <<digit(value / 10), digit(value)>>
}

fn four_digits(value: Int) -> BitArray {
  <<digit(value / 1000), digit(value / 100), digit(value / 10), digit(value)>>
}

fn digit(value: Int) -> Int {
  0x30 + value % 10
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
