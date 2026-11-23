// No run-time dependencies: gleam_stdlib arrives only through gleeunit, a
// development dependency, so it must stay out of the output.
pub fn greeting() -> String {
  "HELLO FROM THE FRONTEND"
}
