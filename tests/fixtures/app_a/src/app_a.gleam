import build/kept
import shared_lib

pub fn answer() -> Int {
  shared_lib.answer() + kept.offset()
}
