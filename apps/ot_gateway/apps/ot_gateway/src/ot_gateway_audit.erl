%% @doc The gateway's command audit.
%%
%% The legacy controller records its own account and the source IP. This
%% records the wire-verified operator node, the command id, and the result.
-module(ot_gateway_audit).

-behaviour(gen_server).

-export([start_link/0, record/1, list/1]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(LIMIT, 200).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec record(map()) -> ok.
record(Entry) when is_map(Entry) ->
    gen_server:call(?MODULE, {record, Entry}, 5000).

-spec list(pos_integer()) -> [map()].
list(Limit) when is_integer(Limit), Limit > 0 ->
    gen_server:call(?MODULE, {list, Limit}, 5000).

init([]) ->
    {ok, []}.

handle_call({record, Entry}, _From, Entries) ->
    {reply, ok, lists:sublist([Entry | Entries], ?LIMIT)};
handle_call({list, Limit}, _From, Entries) ->
    {reply, lists:sublist(Entries, Limit), Entries};
handle_call(_Request, _From, Entries) ->
    {reply, [], Entries}.

handle_cast(_Message, Entries) ->
    {noreply, Entries}.

handle_info(_Message, Entries) ->
    {noreply, Entries}.

terminate(_Reason, _Entries) ->
    ok.
