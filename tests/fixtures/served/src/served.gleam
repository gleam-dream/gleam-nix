// A service with a health endpoint, served by OTP's own inets.
pub fn main() -> Nil {
  start()
  sleep_forever()
}

@external(erlang, "served_ffi", "start")
fn start() -> Nil

@external(erlang, "served_ffi", "sleep_forever")
fn sleep_forever() -> Nil
