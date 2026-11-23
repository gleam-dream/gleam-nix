import gleeunit

// Setup in the test main, as `gleam test` runs it. The shard runner calls
// setup through its hook instead.
pub fn main() -> Nil {
  setup()
  gleeunit.main()
}

pub fn setup() -> Nil {
  put("tested", "ready")
  Nil
}

@external(erlang, "persistent_term", "put")
fn put(key: String, value: String) -> a
