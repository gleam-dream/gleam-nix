import gleeunit
import my_app

pub fn main() -> Nil {
  setup()
  gleeunit.main()
}

// Shared setup, such as migrations; the shard runner calls it as its hook.
pub fn setup() -> Nil {
  put("my_app", "ready")
}

pub fn greeting_test() {
  assert my_app.greeting() == "hello"
}

@external(erlang, "persistent_term", "put")
fn put(key: String, value: String) -> Nil
