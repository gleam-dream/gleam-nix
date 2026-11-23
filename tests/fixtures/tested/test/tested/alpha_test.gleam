import tested
import tested/helper

pub fn answer_test() {
  assert tested.answer() == 4
}

pub fn setup_ran_test() {
  assert helper.setup_state() == "ready"
}
