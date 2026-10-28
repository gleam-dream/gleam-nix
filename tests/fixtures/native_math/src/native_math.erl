-module(native_math).
-export([double/1]).
-spec double(integer()) -> integer().
double(Value) -> Value * 2.
