-module(own_headers_ffi).
-export([read/1]).
-include_lib("own_headers/include/own_headers_Value.hrl").

read(#value{count = Count}) -> Count.
