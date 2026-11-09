%% @doc The lab realm's boot-claim responder.
%%
%% It issues a delegation only to the gateway's own wire-authenticated
%% caller. The `service_name' label is the gateway's claim label; a real
%% realm would gate this on membership and an operator's approval.
-module(ot_realm_claim_handler).

-behaviour(macula_response).

-export([init/1, handle_request/2]).

init(State) ->
    {ok, State}.

handle_request(Payload, State) ->
    Caller = maps:get(caller, Payload, undefined),
    Org = macula_record:payload_field(Payload, <<"org">>),
    Service = macula_record:payload_field(Payload, <<"service_name">>),
    admit(Org, Service, Caller, Payload, State).

admit(<<"ot">>, <<"mcl-ot-gateway">>, Caller, _Payload, State)
  when is_binary(Caller), byte_size(Caller) =:= 32 ->
    case ot_realm_fixture:issue_ot_delegation(State, Caller) of
        ok ->
            {reply, #{<<"status">> => <<"issued">>}, State};
        {error, Reason} ->
            {error, Reason, State}
    end;
admit(_Org, _Service, _Caller, _Payload, State) ->
    {error, not_admitted, State}.
