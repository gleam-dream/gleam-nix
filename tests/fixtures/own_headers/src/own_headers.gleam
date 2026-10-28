pub type Value {
  Value(count: Int)
}

@external(erlang, "own_headers_ffi", "read")
fn read(value: Value) -> Int

pub fn answer() -> Int {
  read(Value(42))
}
