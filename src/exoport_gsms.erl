%%%---- BEGIN COPYRIGHT -------------------------------------------------------
%%%
%%% Copyright (C) 2012 Feuerlabs, Inc. All rights reserved.
%%%
%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at http://mozilla.org/MPL/2.0/.
%%%
%%%---- END COPYRIGHT ---------------------------------------------------------
%%% @author Malotte W L�nne <malotte@malotte.net>
%%% @doc
%%%    Exoport gsms server
%%% Created : June 2013 by Malotte W L�nne
%%% @end
-module(exoport_gsms).
-behaviour(gen_server).

-include_lib("lager/include/log.hrl").
-include_lib("gsms/include/gsms.hrl").

%% api
-export([start_link/1, 
	 stop/0,
	 dump/0]).

%% gen_server callbacks
-export([init/1, 
	 handle_call/3, 
	 handle_cast/2, 
	 handle_info/2,
	 terminate/2, 
	 code_change/3]).

-compile(export_all).

-define(SERVER, ?MODULE). 
-define(EXODM_RE, "^EXODM-RPC:(sms|gprs)(,(sms|gprs))*:([0-9A-Fa-f][0-9A-Fa-f])*").

-define(dbg(Format, Args),
	lager:debug("~s(~p): " ++ Format, [?MODULE, self() | Args])).

%% for dialyzer
-type start_options()::{linked, TrueOrFalse::boolean()}.

%% loop data
-record(ctx,
	{
	  state = init ::atom(),
	  anumbers = [] ::list(string()),
	  ref::reference()
	}).

%%%===================================================================
%%% API
%%%===================================================================
%%--------------------------------------------------------------------
%% @doc
%% Starts the server.
%% Loads configuration from File.
%% @end
%%--------------------------------------------------------------------
-spec start_link(Opts::list(start_options())) -> 
			{ok, Pid::pid()} | 
			ignore | 
			{error, Error::term()}.

start_link(Opts) ->
    lager:info("~p: start_link: start options = ~p\n", [?MODULE, Opts]),
    F =	case proplists:get_value(linked,Opts,true) of
	    true -> start_link;
	    false -> start
	end,
    
    gen_server:F({local, ?SERVER}, ?MODULE, Opts, []).


%%--------------------------------------------------------------------
%% @doc
%% Stops the server.
%% @end
%%--------------------------------------------------------------------
-spec stop() -> ok | {error, Error::term()}.

stop() ->
    gen_server:call(?SERVER, stop).


%% Test functions
%% @private
dump() ->
    gen_server:call(?SERVER, dump).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Initializes the server
%%
%% @end
%%--------------------------------------------------------------------
-spec init(Args::list(start_options())) -> 
		  {ok, Ctx::#ctx{}} |
		  {stop, Reason::term()}.

init(Args) ->
    lager:info("~p: init: args = ~p,\n pid = ~p\n", [?MODULE, Args, self()]),
    Anums = case application:get_env(exoport, anumbers) of
	       undefined -> [];
	       {ok, A} -> A
	   end,
    ?dbg("init: A numbers ~p",[Anums]),
    Filter = create_filter(Anums),
    ?dbg("init: filter ~p",[Filter]),
    Ref = gsms_router:subscribe(Filter),
    {ok, #ctx {state = up, ref = Ref, anumbers = Anums}}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages.
%% Request can be the following:
%% <ul>
%% <li> dump - Writes loop data to standard out (for debugging).</li>
%% <li> stop - Stops the application.</li>
%% </ul>
%%
%% @end
%%--------------------------------------------------------------------
-type call_request()::
	dump |
	stop.

-spec handle_call(Request::call_request(), From::{pid(), Tag::term()}, 
		  Ctx::#ctx{}) ->
			 {reply, Reply::term(), Ctx::#ctx{}} |
			 {noreply, Ctx::#ctx{}} |
			 {stop, Reason::atom(), Reply::term(), Ctx::#ctx{}}.

handle_call(dump, _From, 
	    Ctx=#ctx {state = State, anumbers = Anums, ref = Ref}) ->
    io:format("Ctx: State = ~p, Anums = ~p, GsmsRef = ~p", 
	      [State, Anums, Ref]),
    {reply, ok, Ctx};

handle_call(stop, _From, Ctx) ->
    ?dbg("stop:",[]),
    {stop, normal, ok, Ctx};

handle_call(_Request, _From, Ctx) ->
    ?dbg("handle_call: unknown request ~p", [_Request]),
    {reply, {error, bad_call}, Ctx}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages.
%%
%% @end
%%--------------------------------------------------------------------
-type cast_msg()::
	term().

-spec handle_cast(Msg::cast_msg(), Ctx::#ctx{}) -> 
			 {noreply, Ctx::#ctx{}} |
			 {stop, Reason::term(), Ctx::#ctx{}}.

handle_cast(_Msg, Ctx) ->
    ?dbg("handle_cast: unknown msg ~p", [_Msg]),
    {noreply, Ctx}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling all non call/cast messages.
%% 
%% @end
%%--------------------------------------------------------------------
-type info()::
	{gsms, Ref::reference(), Msg::string()}.

-spec handle_info(Info::info(), Ctx::#ctx{}) -> 
			 {noreply, Ctx::#ctx{}} |
			 {noreply, Ctx::#ctx{}, Timeout::timeout()} |
			 {stop, Reason::term(), Ctx::#ctx{}}.

handle_info({gsms, _Ref, #gsms_deliver_pdu {ud = Msg, addr = Addr}} = _Info, 
	    Ctx) ->
    ?dbg("handle_info: ~p", [_Info]),
    %% Check ref ??
    
    case string:tokens(Msg, ":") of
	["EXODM-RPC", ReplyMethods, Call] -> 
	    handle_request(from_hex(string:strip(Call)), 
			   string:strip(ReplyMethods), 
			   Addr);
	["EXODM-RPC", Call] -> 
	    %% default
	    handle_request(from_hex(string:strip(Call)), 
			   ["sms"], Addr);
	    
	_ ->
	    ?dbg("handle_info: gsms, illegal msg ~p", [Msg]),
	    do_nothing
    end,
    {noreply, Ctx};

handle_info(_Info, Ctx) ->
    ?dbg("handle_info: unknown info ~p", [_Info]),
    {noreply, Ctx}.

%%--------------------------------------------------------------------
%% @private
%%--------------------------------------------------------------------
-spec terminate(Reason::term(), Ctx::#ctx{}) -> 
		       no_return().

terminate(_Reason, _Ctx=#ctx {state = State, ref = Ref}) ->
    ?dbg("terminate: terminating in state ~p, reason = ~p",
	 [State, _Reason]),
    gsms_router:unsubscribe(Ref),
    ok.
%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process ctx when code is changed
%%
%% @end
%%--------------------------------------------------------------------
-spec code_change(OldVsn::term(), Ctx::#ctx{}, Extra::term()) -> 
			 {ok, NewCtx::#ctx{}}.

code_change(_OldVsn, Ctx, _Extra) ->
    ?dbg("code_change: old version ~p", [_OldVsn]),
    {ok, Ctx}.


%%%===================================================================
%%% Internal functions
%%%===================================================================
%%--------------------------------------------------------------------
create_filter(Anums) ->
    AFilter = 
	lists:foldl(
	  fun(Anum, []) when is_list(Anum) -> 
		  {anumber, Anum};
	     (Anum, Acc) when is_list(Anum) -> 
		  {'or', {anumber, Anum}, Acc};
	     (_, Acc)->
		  Acc
	  end,
	  [], Anums),
    [{reg_exp, ?EXODM_RE}, AFilter].
    

%%--------------------------------------------------------------------
handle_request(Request, MethodsString, Addr) ->
    Methods = [list_to_atom(string:strip(M)) || 
		  M <- string:tokens(MethodsString, ",")],
    exec_req(Request, Methods, Addr).
    
exec_req(_Request, [],  _Addr) ->
    ?dbg("request: no one to reply to", []);
exec_req(Request, [Method | Methods], Addr) ->
    case exec_req1(Request, Method, Addr) of 
	ok -> 
	    ok;
	{error, Error} ->
	    ?dbg("request: failed using ~p, reason ~p", 
		 [Method, Error]),
	    %% Try next method
	    exec_req(Request, Methods, Addr)
    end.
	    
exec_req1(Request, sms, Addr) ->
    ?dbg("request: sms", []),
    Reply = 
	try exec_req(Request, external) of
	    Result -> Result
	catch
	    error:Error ->
		?error("CRASH: ~p; ~p~n", [Error, erlang:get_stacktrace()]),
		bert:to_binary({error, illegal_call})
	end,
    ?dbg("request: reply ~p", [bert:to_term(Reply)]),
    case gsms_router:send([{addr, Addr}], to_hex(Reply)) of
	{ok, _Ref} -> ok;
	E -> E
    end;
exec_req1(Request, gprs, _Addr) ->
    ?dbg("request: gprs", []),
    %% Make sure we are connected
    case exoport_server:session_active() of
	true -> ok;
	_ -> exoport_server:connect()
    end,
    %% Reply sent over socket
    exec_req(Request, internal);
exec_req1(_Request, Unknown, _Addr) ->
    ?dbg("request: unknown method ~p", [Unknown]),
    {error, unknown_method}.


exec_req(Request, ExtOrInt) ->
    DecodedReq = bert:to_term(Request),
    ?dbg("request: ~p", [DecodedReq]),
    bert:to_binary(bert_rpc_exec:request(DecodedReq, ExtOrInt)).

from_hex(String) when is_list(String) ->
    << << (erlang:list_to_integer([H], 16)):4 >> || H <- String >>.

%% convert to hex
to_hex(Bin) when is_binary(Bin) ->
    [ element(I+1,{$0,$1,$2,$3,$4,$5,$6,$7,$8,$9,
                   $a,$b,$c,$d,$e,$f}) || <<I:4>> <= Bin];
to_hex(List) when is_list(List) ->
    to_hex(list_to_binary(List));
to_hex(Int) when is_integer(Int) ->
    integer_to_list(Int, 16).