-module(ot_gateway_handler).

-export([
    list_freezers/1,
    set_freezer_target/1,
    start_freezer_defrost/1,
    stop_freezer_defrost/1,
    list_freezer_commands/1
]).

%% The read path.
-spec list_freezers(term()) -> {ok, map()} | {error, term()}.
list_freezers(_Payload) ->
    ot_controller_client:list_freezers().

%% The write path. Each command carries a random id and a wall-clock timestamp;
%% the guard refuses a stale or repeated id, and the audit records the verified
%% caller and the result.
-spec set_freezer_target(map()) -> {ok, map()} | {error, term()}.
set_freezer_target(Payload) ->
    FreezerId = mcl_om_wire:field(<<"freezer_id">>, Payload),
    TargetC = mcl_om_wire:field(<<"target_c">>, Payload),

    case is_binary(FreezerId) andalso is_number(TargetC) of
        true ->
            with_command(
              Payload, <<"set_target">>, FreezerId,
              fun() -> ot_controller_client:set_target(FreezerId, TargetC) end);

        false ->
            {error, invalid_target_command}
    end.

-spec start_freezer_defrost(map()) -> {ok, map()} | {error, term()}.
start_freezer_defrost(Payload) ->
    with_freezer_command(Payload, <<"start_defrost">>, fun ot_controller_client:start_defrost/1).

-spec stop_freezer_defrost(map()) -> {ok, map()} | {error, term()}.
stop_freezer_defrost(Payload) ->
    with_freezer_command(Payload, <<"stop_defrost">>, fun ot_controller_client:stop_defrost/1).

-spec list_freezer_commands(term()) -> {ok, map()}.
list_freezer_commands(_Payload) ->
    {ok, #{<<"commands">> => ot_gateway_audit:list(50)}}.

with_freezer_command(Payload, Action, Fun) ->
    FreezerId = mcl_om_wire:field(<<"freezer_id">>, Payload),

    case is_binary(FreezerId) of
        true ->
            with_command(Payload, Action, FreezerId, fun() -> Fun(FreezerId) end);

        false ->
            {error, invalid_freezer_command}
    end.

with_command(Payload, Action, FreezerId, Fun) ->
    CommandId = mcl_om_wire:field(<<"command_id">>, Payload),
    RequestedAt = mcl_om_wire:field(<<"requested_at_ms">>, Payload),
    CallerHex = caller_hex(Payload),

    case valid_command(CommandId, RequestedAt) of
        true ->
            Result =
                case ot_command_guard:check(CommandId, RequestedAt) of
                    ok -> Fun();
                    {error, Reason} -> {error, Reason}
                end,
            audit(Action, FreezerId, CommandId, CallerHex, Result),
            Result;

        false ->
            audit(Action, FreezerId, CommandId, CallerHex, {error, invalid_command}),
            {error, invalid_command}
    end.

valid_command(CommandId, RequestedAt) ->
    is_binary(CommandId) andalso byte_size(CommandId) >= 8 andalso is_integer(RequestedAt).

caller_hex(Payload) ->
    case mcl_om_wire:caller_hex(Payload) of
        undefined -> <<"unknown">>;
        Hex -> Hex
    end.

audit(Action, FreezerId, CommandId, CallerHex, Result) ->
    ot_gateway_audit:record(#{
        <<"at_ms">> => erlang:system_time(millisecond),
        <<"caller">> => CallerHex,
        <<"action">> => Action,
        <<"freezer_id">> => safe_bin(FreezerId),
        <<"command_id">> => safe_bin(CommandId),
        <<"result">> => result_string(Result)
    }).

safe_bin(Value) when is_binary(Value) -> Value;
safe_bin(_Other) -> <<"unknown">>.

result_string({ok, _Value}) -> <<"ok">>;
result_string({error, Reason}) -> iolist_to_binary(io_lib:format("~p", [Reason]));
result_string(_Other) -> <<"unknown">>.
