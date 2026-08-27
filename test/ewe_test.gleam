import gleeunit
import logging

pub fn main() -> Nil {
  logging.configure()
  logging.set_level(logging.Info)

  gleeunit.main()
}
