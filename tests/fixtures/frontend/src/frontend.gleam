import js_widgets

// Its only run-time dependency is local; gleam_stdlib arrives only through
// gleeunit, a development dependency, so it must stay out of the output.
pub fn greeting() -> String {
  js_widgets.label()
}
