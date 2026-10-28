@external(erlang, "native_math", "double")
fn double(value: Int) -> Int

@external(erlang, "Elixir.ElixirMath", "triple")
fn triple(value: Int) -> Int

pub fn answer() -> Int {
  double(4) + triple(5)
}
