-module(warned_lib_ffi).
-export([value/0]).

value() -> Unused = 0, 3.
