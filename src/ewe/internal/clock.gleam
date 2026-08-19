import gleam/bit_array
import gleam/erlang/process
import gleam/int
import gleam/otp/actor
import gleam/result
import gleam/string
import gleam/string_tree

type Message {
  Tick
}

const tick_ms = 1000

pub fn start(_type: a, _args: b) -> Result(process.Pid, actor.StartError) {
  use actor.Started(pid:, ..) <- result.map(
    actor.new_with_initialiser(tick_ms, fn(subject) {
      now()
      |> format_date
      |> set_date

      process.send_after(subject, tick_ms, Tick)

      actor.initialised(subject)
      |> actor.returning(subject)
      |> Ok
    })
    |> actor.on_message(fn(subject, _tick) {
      process.send_after(subject, tick_ms, Tick)

      now()
      |> format_date
      |> set_date

      actor.continue(subject)
    })
    |> actor.start(),
  )

  pid
}

pub fn stop(_state: a) -> Nil {
  Nil
}

pub fn get() -> BitArray {
  case get_date() {
    Ok(date) -> date
    Error(Nil) -> now() |> format_date
  }
}

fn format_date(time: #(Int, #(Int, Int, Int), #(Int, Int, Int))) -> BitArray {
  let #(weekday, #(year, month, day), #(hour, minute, second)) = time
  string_tree.new()
  |> string_tree.append(weekday_to_string(weekday))
  |> string_tree.append(", ")
  |> string_tree.append(int.to_string(day) |> string.pad_start(2, "0"))
  |> string_tree.append(" ")
  |> string_tree.append(month_to_string(month))
  |> string_tree.append(" ")
  |> string_tree.append(int.to_string(year) |> string.pad_start(4, "0"))
  |> string_tree.append(" ")
  |> string_tree.append(int.to_string(hour) |> string.pad_start(2, "0"))
  |> string_tree.append(":")
  |> string_tree.append(int.to_string(minute) |> string.pad_start(2, "0"))
  |> string_tree.append(":")
  |> string_tree.append(int.to_string(second) |> string.pad_start(2, "0"))
  |> string_tree.append(" GMT")
  |> string_tree.to_string
  |> bit_array.from_string
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
    _ -> panic as "erlang day_of_the_week outside of 1-7 range"
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
    _ -> panic as "erlang month outside of 1-12 range"
  }
}

@external(erlang, "ewe_ffi", "now_datetime")
fn now() -> #(Int, #(Int, Int, Int), #(Int, Int, Int))

@external(erlang, "ewe_ffi", "set_http_date")
fn set_date(date: BitArray) -> Nil

@external(erlang, "ewe_ffi", "get_http_date")
fn get_date() -> Result(BitArray, Nil)
