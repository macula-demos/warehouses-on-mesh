%% @doc Application-level replay and expiry guard for gateway commands.
%%
%% The mesh gives a call at-most-once delivery, but a legitimate command can
%% still be replayed by a compromised relay or a buggy caller. Each command
%% carries a random id and a wall-clock timestamp; the first accepted use of an
%% id is remembered for two minutes, and a stale or repeated id is refused.
-module(ot_command_guard).

-behaviour(gen_server).

-export([start_link/0, check/2]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(TTL_MS, 120_000).
-define(PRUNE_MS, 30_000).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% @doc `ok' for the first use of a fresh command, otherwise
%% `{error, command_replayed}' or `{error, command_expired}'.
-spec check(binary(), integer()) -> ok | {error, command_replayed | command_expired}.
check(CommandId, RequestedAt)
  when is_binary(CommandId), byte_size(CommandId) >= 8, is_integer(RequestedAt) ->
    gen_server:call(?MODULE, {check, CommandId, RequestedAt}, 5000).

init([]) ->
    {ok, #{seen => #{}, last_prune => erlang:system_time(millisecond)}}.

handle_call({check, CommandId, RequestedAt}, _From, State) ->
    Now = erlang:system_time(millisecond),
    State1 = prune(State, Now),
    Verdict = verdict(CommandId, RequestedAt, Now, State1),
    {reply, Verdict, record(Verdict, CommandId, Now, State1)};
handle_call(_Request, _From, State) ->
    {reply, {error, unknown_call}, State}.

handle_cast(_Message, State) ->
    {noreply, State}.

handle_info(_Message, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

verdict(CommandId, RequestedAt, Now, #{seen := Seen}) ->
    case abs(Now - RequestedAt) > ?TTL_MS of
        true ->
            {error, command_expired};
        false ->
            case maps:is_key(CommandId, Seen) of
                true -> {error, command_replayed};
                false -> ok
            end
    end.

record(ok, CommandId, Now, #{seen := Seen} = State) ->
    State#{seen => maps:put(CommandId, Now, Seen)};
record({error, _Reason}, _CommandId, _Now, State) ->
    State.

prune(#{last_prune := Last, seen := Seen} = State, Now)
  when Now - Last < ?PRUNE_MS, map_size(Seen) < 500 ->
    State;
prune(#{seen := Seen} = State, Now) ->
    Cutoff = Now - ?TTL_MS,
    Kept = maps:filter(fun(_CommandId, SeenAt) -> SeenAt >= Cutoff end, Seen),
    State#{seen => Kept, last_prune => Now}.
