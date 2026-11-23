import gleeunit

pub fn main() -> Nil {
  setup()
  gleeunit.main()
}

// Shared setup, such as migrations; the shard runner calls it as its hook.
pub fn setup() -> Nil {
  Nil
}

pub fn main_test() {
  assert Nil == Nil
}
