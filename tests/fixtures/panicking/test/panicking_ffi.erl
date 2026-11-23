-module(panicking_ffi).
-export([panic_in_main/0]).

panic_in_main() -> os:getenv("PANIC_IN_MAIN") =/= false.
