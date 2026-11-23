import gleeunit

pub fn main() -> Nil {
  case panic_in_main() {
    True -> fail_setup()
    False -> gleeunit.main()
  }
}

// The shard runner calls this as its setup hook.
pub fn fail_setup() -> Nil {
  panic as "setup failed in a fixture"
}

@external(erlang, "panicking_ffi", "panic_in_main")
fn panic_in_main() -> Bool
