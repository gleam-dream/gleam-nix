// A test helper with no tests: never an expected test module.
pub fn setup_state() -> String {
  get("tested", "missing")
}

@external(erlang, "persistent_term", "get")
fn get(key: String, default: String) -> String
