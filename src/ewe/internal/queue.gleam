pub type Queue(a)

@external(erlang, "queue", "new")
pub fn new() -> Queue(a)

@external(erlang, "queue", "is_empty")
pub fn is_empty(queue: Queue(a)) -> Bool

pub fn push(queue: Queue(a), item: a) -> Queue(a) {
  queue_in(item, queue)
}

pub fn push_front(queue: Queue(a), item: a) -> Queue(a) {
  queue_in_r(item, queue)
}

@external(erlang, "ewe_ffi", "queue_pop")
pub fn pop(queue: Queue(a)) -> Result(#(a, Queue(a)), Nil)

@external(erlang, "queue", "in")
fn queue_in(item: a, queue: Queue(a)) -> Queue(a)

@external(erlang, "queue", "in_r")
fn queue_in_r(item: a, queue: Queue(a)) -> Queue(a)
