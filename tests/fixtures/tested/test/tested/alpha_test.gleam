import tested
import tested_dev
import tested/helper

pub fn answer_test() {
  assert tested.answer() == tested_dev.fixture_value()
}

pub fn setup_ran_test() {
  assert helper.setup_state() == "ready"
}
