import frontend
import gleeunit

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn greeting_test() {
  assert frontend.greeting() == "HELLO FROM THE FRONTEND"
}
