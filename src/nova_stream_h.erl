-module(nova_stream_h).
-behavior(cowboy_stream).

-export([
         init/3,
         data/4,
         info/3,
         terminate/3,
         early_error/5
        ]).

-include_lib("nova/include/nova.hrl").

-record(state, {
                next :: any(),
                req
               }).

-type state() :: #state{}.

-spec init(cowboy_stream:streamid(), cowboy_req:req(), cowboy:opts())
          -> {cowboy_stream:commands(), state()}.
init(StreamID, Req, Opts) ->
    Req0 =
        case nova:get_env(use_sessions, true) of
            true ->
                Cookies = cowboy_req:parse_cookies(Req),
                case lists:keyfind(<<"session_id">>, 1, Cookies) of
                    {_, _} -> Req;
                    _ ->
                        {ok, SessionId} = nova_session:generate_session_id(),
                        cowboy_req:set_resp_cookie(<<"session_id">>, SessionId, Req)
                end;
            false ->
                Req
        end,
    {Commands, Next} = cowboy_stream:init(StreamID, Req0, Opts),
    {Commands, #state{req = Req0, next = Next}}.

-spec data(cowboy_stream:streamid(), cowboy_stream:fin(), cowboy_req:resp_body(), State)
          -> {cowboy_stream:commands(), State} when State::state().
data(StreamID, IsFin, Data, State = #state{next = Next}) ->
    {Commands, Next0} = cowboy_stream:data(StreamID, IsFin, Data, Next),
    {Commands, State#state{next = Next0}}.

-spec info(cowboy_stream:streamid(), any(), State)
          -> {cowboy_stream:commands(), State} when State::state().
info(StreamID, {response, Code, _Headers, _Body} = Info, State = #state{next = Next, req = Req})
  when is_integer(Code) ->
    case nova_router:status_page(Code, Req) of
        {ok, _NovaHttpState = #{req := Req, resp_status := StatusCode}} ->
            StatusHeaders = cowboy_req:resp_headers(Req),
            StatusBody = maps:get(resp_body, Req, <<"">>),
            {[{error_response, StatusCode, StatusHeaders, StatusBody},
              stop], State};
        _ ->
            {Commands, Next0} = cowboy_stream:info(StreamID, Info, Next),
            {Commands, State#state{next = Next0}}
    end;
info(StreamID, Info, State = #state{next = Next}) ->
    {Commands, Next0} = cowboy_stream:info(StreamID, Info, Next),
    {Commands, State#state{next = Next0}}.

-spec terminate(cowboy_stream:streamid(), cowboy_stream:reason(), state()) -> any().
terminate(StreamID, Reason, #state{next = Next}) ->
    cowboy_stream:terminate(StreamID, Reason, Next).

-spec early_error(cowboy_stream:streamid(), cowboy_stream:reason(),
                  cowboy_stream:partial_req(), Resp, cowboy:opts())
                 -> Resp
                        when Resp::cowboy_stream:resp_command().
early_error(StreamID, Reason, PartialReq, {_, Status, _Headers, _} = Resp, Opts) ->
    case nova_router:status_page(Status, PartialReq) of
        {ok, _NovaHttpState = #{req := Req, resp_status := StatusCode}} ->
            StatusHeaders = cowboy_req:resp_headers(Req),
            StatusBody = maps:get(resp_body, Req, <<"">>),
            {response, StatusCode, StatusHeaders, StatusBody};
        _ ->
            cowboy_stream:early_error(StreamID, Reason, PartialReq, Resp, Opts)
    end.
